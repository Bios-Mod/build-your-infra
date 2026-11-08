# Self-Managed Stack — Automation

## Introduction

This document automates the self-managed stack in two decoupled phases:

1. **Terraform** provisions the AWS perimeter (VPC, subnet, internet gateway, security group, Elastic IP, SSM instance profile) and launches an Ubuntu Server 24.04 LTS ARM64 instance.
2. **Ansible** applies the OS and service configuration to both targets (EC2 and local VM) from a single codebase.

```
┌────────────────────────────────────────────────────────────────────────┐
│ Provisioning Layer (Terraform)                                         │
│ • AWS VPC (10.0.0.0/16) · Public Subnet (10.0.1.0/24) · Internet GW   │
│ • Security Group (multi-lab-sg) · Elastic IP · Instance Profile (SSM) │
│ • EC2 t4g.micro ARM64 (Ubuntu 24.04 LTS base)                          │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Gate: SSH port 22 reachable, SSM Online)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Configuration Layer (Ansible)                                          │
│ • Control node toolchain: pinned ansible-core, venv, collections       │
│ • Hardening: baseline (Steps 0–2) · access chain (3–6) · system (7–12) │
│ • Modules, one after another: file-transfer, dns, ...                  │
└────────────────────────────────────────────────────────────────────────┘
```

### Targets and Order

WireGuard is hub-and-spoke, so **EC2 is deployed and hardened first** and the VM joins second as a peer.

| Target | Inventory alias | `--limit` | Host variables | Role |
| --- | --- | --- | --- | --- |
| EC2 | `multi-lab-vps` | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | WireGuard hub `172.16.0.1` — deployed first |
| VM | `multi-lab-local` | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | WireGuard peer `172.16.0.3` — deployed second |

### How to Read This Document

- The sections are a chain: Terraform → Control Node → Hardening → each module in order. Each section starts where the previous one ended.
- Every code block states where it runs (`EC2 · multi-lab-vps`, `VM · multi-lab-local`, `Control node (Mac)`) and can be copied as is. Replace only the `<placeholders>`.
- All `ansible-playbook` commands run on the control node, from `~/build-your-infra/stacks/full-infra/self-managed/automation/ansible` with the virtualenv active.
- Verification links to the matching section of the manual module doc; those commands are not duplicated here.

---

## Terraform — Infrastructure Provisioning

The configuration in `stacks/full-infra/self-managed/automation/terraform/` launches a t4g.micro Graviton2 instance from the official Canonical AMI, attaches an Elastic IP and grants SSM access.

> [!CAUTION]
>
> - Do not deploy the `aws-native` hardening module in the same AWS account: both stacks use the same resource names (`multi-lab-vpc`, `multi-lab-sg`, `multi-lab-ec2-role`).
> - The 20 GiB gp3 volume keeps accruing cost while the instance is stopped, and every public IPv4 address (including Elastic IPs associated with running or stopped instances) incurs $0.005/hr since February 2024. Run `terraform destroy` when finished.

### Step 1 — Provision EC2 Infrastructure

#### What was done

Prerequisites: AWS CLI profile `multi-lab-admin` (`eu-west-1`), Terraform `>= 1.15.6`, and the lab key `~/.ssh/id_ed25519_multi-lab`.

Get the latest Ubuntu 24.04 ARM64 AMI:

**EC2 · multi-lab-vps · Run on control node:**

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --region eu-west-1 \
  --profile multi-lab-admin \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
  --query "sort_by(Images,&CreationDate)[-1].[ImageId,Name]"
# → ["ami-0xxxxxxxxxxxxxxxxx", "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-..."]
```

Activate the config files and initialize Terraform:

**EC2 · multi-lab-vps · Run on control node:**

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf
cp terraform.tfvars.example terraform.tfvars
terraform init
```

Set the AMI in `terraform.tfvars` (`ami_id`), then plan and apply. Your current public IP opens SSH port 22 (bootstrap) and 22222 (hardened) in the Security Group:

**EC2 · multi-lab-vps · Run on control node:**

```bash
terraform plan \
  -var "ssh_bootstrap_cidr=$(curl -s ifconfig.me)/32" \
  -var "ssh_hardened_cidr=$(curl -s ifconfig.me)/32"

terraform apply \
  -var "ssh_bootstrap_cidr=$(curl -s ifconfig.me)/32" \
  -var "ssh_hardened_cidr=$(curl -s ifconfig.me)/32"

terraform output
# → instance_public_ip = "X.X.X.X"
# → instance_id = "i-0xxxxxxxxxxxxxxxxx"
```

The Terraform configuration also supports provisioning the public Route 53 A record for the `web-server` module. By setting `route53_zone_name` in `terraform.tfvars` (e.g. `route53_zone_name = "buildyourinfra.click"`), Terraform queries the existing public hosted zone via data source and creates the root apex A record pointing to the instance Elastic IP.

📄 [`main.tf.example`](terraform/main.tf.example) · [`variables.tf`](terraform/variables.tf) · [`terraform.tfvars.example`](terraform/terraform.tfvars.example) · [`outputs.tf.example`](terraform/outputs.tf.example)

#### Why

A self-contained greenfield stack lets the EC2 target be rebuilt on demand in a clean account without importing resources. IMDSv2 is enforced (`http_tokens = "required"`, hop limit 1) to remove SSRF access to the metadata service, and ports 22/22222 are restricted to your `/32` until WireGuard is up.

### Step 2 — Verify Connectivity

#### What was done

Confirm SSH access and SSM registration.

**EC2 · multi-lab-vps · Run on control node:**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab ubuntu@<ec2_eip> uname -m
# → aarch64

aws ssm describe-instance-information \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --query "InstanceInformationList[*].{ID:InstanceId,Status:PingStatus}"
# → [{"ID": "i-0xxxxxxxxxxxxxxxxx", "Status": "Online"}]
```

---

## Control Node — Environment Setup

### Step 1 — Prepare the Control Node Toolchain

#### What was done

Create the virtualenv, install the pinned dependencies, create the real inventory files from their `.example` pairs, generate the lab key and install it on the VM installer user.

> [!NOTE]
> `ansible-core 2.21` supports Python 3.12–3.14 on the control node. Python 3.15 fails at startup. Check with `python3.14 --version`, or use an explicit `python3.12`/`python3.13` binary.

**Control node (Mac):**

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/ansible
python3.14 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml

cp inventories/hosts.yml.example inventories/hosts.yml
cp inventories/host_vars/multi-lab-local.yml.example inventories/host_vars/multi-lab-local.yml
cp inventories/host_vars/multi-lab-vps.yml.example inventories/host_vars/multi-lab-vps.yml

test -f ~/.ssh/id_ed25519_multi-lab || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_multi-lab -N "" -C "admin@multi-lab"
ssh-copy-id -i ~/.ssh/id_ed25519_multi-lab.pub <vm_initial_user>@<vm_lan_ip>
```

Add the key to both hosts in `~/.ssh/config` (`MaxAuthTries 3` after hardening locks you out if the agent offers other keys first):

```sshconfig
Host multi-lab-local
    IdentityFile ~/.ssh/id_ed25519_multi-lab
    IdentitiesOnly yes

Host multi-lab-vps
    IdentityFile ~/.ssh/id_ed25519_multi-lab
    IdentitiesOnly yes
```

If the key has a passphrase, run `ssh-add ~/.ssh/id_ed25519_multi-lab` once per terminal session.

Fill in the real host variables:

- `inventories/host_vars/multi-lab-local.yml`: `vm_initial_user`, `admin_username`, `vm_lan_ip`, `vm_interface` (from `ip link`), `vm_static_ip` (e.g. `192.168.1.50/24`), `vm_gateway`, `lan_trusted_cidr`, `admin_public_key_file: "~/.ssh/id_ed25519_multi-lab.pub"`, `ansible_ssh_private_key_file: "~/.ssh/id_ed25519_multi-lab"`, `connection_mode: "pre"`.
- `inventories/host_vars/multi-lab-vps.yml`: `ec2_eip` (from `terraform output instance_public_ip`), `ec2_initial_user: "ubuntu"`, `admin_username`, `admin_public_key_file`, `ansible_ssh_private_key_file`, `lan_trusted_cidr: ""`, `connection_mode: "pre"`.

`connection_mode` tracks where Ansible connects. Change it by hand in each host's variables file as the hardening progresses:

| Mode | Port | SSH user | Address | Set it when |
| --- | --- | --- | --- | --- |
| `pre` | 22 | Initial OS user | LAN IP / Elastic IP | Default; `bootstrap.yml` and before SSH hardening |
| `hardened` | 22222 | `admin_username` | LAN IP / Elastic IP | After the SSH hardening task has run |
| `wg` | 22222 | `admin_username` | `172.16.0.1` (EC2) / `172.16.0.3` (VM) | After the tunnel is up on the Mac |

> **Warning:** Never switch to `hardened` before `sshd` is running on port 22222. Never switch to `wg` before `ping 172.16.0.1` or `ssh -p 22222 <admin_username>@172.16.0.1` works from the Mac.

📄 [`requirements.txt`](ansible/requirements.txt) · [`requirements.yml`](ansible/requirements.yml) · [`inventories/hosts.yml.example`](ansible/inventories/hosts.yml.example) · [`host_vars/multi-lab-local.yml.example`](ansible/inventories/host_vars/multi-lab-local.yml.example) · [`host_vars/multi-lab-vps.yml.example`](ansible/inventories/host_vars/multi-lab-vps.yml.example)

#### Why

Pinned versions keep the toolchain identical on the control node, on delegated agents and in CI. `passlib` is required because Python ≥ 3.13 removed `crypt`, which the `password_hash` filter in `bootstrap.yml` needs. `hosts.yml` and `host_vars/*.yml` contain real addresses and are gitignored; only the `.example` files are versioned. Ansible cannot type a password, so key authentication on the installer user is required first.

#### Verification

**Control node (Mac):**

```bash
ansible --version
# → ansible [core 2.21.6]

ansible-galaxy collection list | grep -E "community.general|ansible.posix"
# → community.general ...
# → ansible.posix ...

ansible-playbook playbooks/ping.yml --limit multi-lab-local
# → ping reachability verified
```

If a host was rebuilt, remove its stale key first (`host_key_checking` is enforced): `ssh-keygen -R <ip>`.

---

## Hardening — Ansible Baseline

Automates [`hardening-self-managed.md`](../../../../modules/hardening/self-managed/hardening-self-managed.md) in three blocks. Run each `ansible-playbook` command twice; the second run must report `changed=0`.

### Step 1 — Baseline Preparation (manual Steps 0–2 · Tag `hardening_2a`)

#### What was done

- Step 0: creates `admin_username` with its Ed25519 key. On EC2 the key is copied from `ubuntu`; on the VM it comes from `admin_public_key_file`. The admin password is requested by `bootstrap.yml`.
- Step 1: full APT upgrade, unattended-upgrades and weekly `debsums`.
- Step 2 (**VM only**): static Netplan and the systemd-networkd `no-dhcp.conf` drop-in.

> **Warning:** The admin account and its key must work before the SSH hardening step. If not, you are locked out once password login and the default user are disabled.

On EC2, accept the host key first (`host_key_checking = True`):

**EC2 · multi-lab-vps · Run on control node:**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab ubuntu@<ec2_eip>
# → type 'yes', then exit
exit
```

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/bootstrap.yml --limit multi-lab-vps
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2a --ask-become-pass
```

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/bootstrap.yml --limit multi-lab-local --ask-become-pass
# → prompts for sudo and admin passwords
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2a --ask-become-pass
```

#### Why

A dedicated admin account removes the dependency on `ubuntu` and the installer user. The password is hashed at runtime (SHA-512, 65,536 rounds) via `vars_prompt`, so it never reaches git.

#### Verification

**Control node (Mac):**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab -o IdentitiesOnly=yes -p 22 <admin_username>@<vm_lan_ip>
# → authenticates without a password prompt
ssh -i ~/.ssh/id_ed25519_multi-lab <admin_username>@<ec2_eip>
# → authenticates without a password prompt
```

**VM · multi-lab-local · Run on VM:**

```bash
id <admin_username>
# → uid=1001(<admin_username>) groups=...,27(sudo),4(adm)...

ls -la /home/<admin_username>/.ssh/
# → drwx------ .ssh            <admin_username>:<admin_username>
# → -rw------- authorized_keys <admin_username>:<admin_username>
```

---

### Step 2 — Access Chain (manual Steps 3–6 · Tag `hardening_2b`)

#### What was done

- Step 3 (SSH): port 22222, key-only, root login off, `MaxAuthTries 3`, `AllowUsers <admin_username>`, only the Ed25519 host key kept.
- Step 4 (UFW): default deny incoming, `limit 22222/tcp` while WireGuard is configured, medium logging.
- Step 5 (WireGuard): EC2 hub `172.16.0.1:51820`, Mac peer `172.16.0.2`, VM peer `172.16.0.3`. Each host generates its own private key; only public keys are shared.
- Step 6 (Fail2Ban): `banaction = ufw`, 24 h ban (48 h for SSH), `ignoreip` for `127.0.0.1/8 ::1` and `172.16.0.0/24` (plus the LAN on the VM).

> [!CAUTION]
> On EC2, `multi-lab-sg` must allow 22222 (`ssh_hardened_cidr`) and 51820/udp **before** the SSH hardening step. Keep an active session open throughout, and do not close public 22222 until the tunnel is verified from the Mac.

#### Phase A — EC2 hub

1. SSH hardening (`connection_mode: "pre"`):

   **EC2 · multi-lab-vps · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step3 --ask-become-pass
   ```

2. Set `connection_mode: "hardened"` in `inventories/host_vars/multi-lab-vps.yml`, then apply UFW:

   **EC2 · multi-lab-vps · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step4 --ask-become-pass
   ```

3. Get the Mac WireGuard public key (macOS app: **Edit** → **Public key**; CLI below; generate a pair if none exists):

   **Control node (Mac):**

   ```bash
   awk '/PrivateKey/ {print $3}' /etc/wireguard/wg0.conf | wg pubkey
   # no key pair yet:
   wg genkey | tee mac_private.key | wg pubkey > mac_public.key
   ```

   Add it to `inventories/host_vars/multi-lab-vps.yml`. A pre-flight assertion rejects placeholders and keys that are not 44-character base64:

   ```yaml
   wireguard_peer_public_keys:
     mac: "<mac-public-key>"
     local_vm: "CHANGE_ME_LOCAL_VM_WIREGUARD_PUBLIC_KEY"
   ```

4. Deploy the hub. Run it without `--check` the first time so the server key pair is generated. Copy the public key from the output:

   **EC2 · multi-lab-vps · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass
   # → WireGuard Public Key for multi-lab-vps: <hub-public-key>
   ```

5. On the Mac, keep your `[Interface]` (`Address = 172.16.0.2/32`; template in `configs/wireguard/client-template.conf`) and update only `[Peer]`. Never copy a PrivateKey between hosts.

   ```ini
   [Peer]
   PublicKey           = <hub-public-key>
   Endpoint            = <ec2_eip>:51820
   AllowedIPs          = 172.16.0.0/24
   PersistentKeepalive = 25
   ```

6. Bring the tunnel up and verify:

   **Control node (Mac):**

   ```bash
   sudo wg-quick up wg0
   sudo wg show
   # → latest handshake: a few seconds ago, transfer: ...
   ping -c 3 172.16.0.1
   ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@172.16.0.1
   # → connects over the VPN
   ```

7. Close public SSH. Set `hardening_wg_close_public_ssh: true` in `inventories/host_vars/multi-lab-vps.yml`, re-run Step 5, then close ports 22 and 22222 in the Security Group:

   **EC2 · multi-lab-vps · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass

   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
   terraform apply -var "ssh_bootstrap_cidr=" -var "ssh_hardened_cidr="
   ```

8. Set `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml` (Ansible now connects to `172.16.0.1:22222`) and apply Fail2Ban:

   **EC2 · multi-lab-vps · Run on control node:**

   ```bash
   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/ansible
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step6 --ask-become-pass
   ```

#### Phase B — VM peer

Prerequisite: EC2 hub deployed and Mac tunnel up.

1. Get the hub public key:

   **EC2 · multi-lab-vps · Run on EC2:**

   ```bash
   sudo cat /etc/wireguard/server_public.key
   # → <hub-public-key>
   ```

2. In `inventories/host_vars/multi-lab-local.yml` set `wireguard_hub_public_key: "<hub-public-key>"` and `wireguard_endpoint: "<ec2_eip>:51820"`. The endpoint is required and must be the EC2 public IP, never the VM's own LAN IP.

3. SSH hardening (`connection_mode: "pre"`):

   **VM · multi-lab-local · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step3 --ask-become-pass
   ```

4. Set `connection_mode: "hardened"` in `inventories/host_vars/multi-lab-local.yml`, then apply UFW:

   **VM · multi-lab-local · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step4 --ask-become-pass
   ```

5. Deploy the WireGuard client (without `--check` the first time, so the key pair is generated):

   **VM · multi-lab-local · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step5 --ask-become-pass
   # → WireGuard Public Key for multi-lab-local: <vm-public-key>
   ```

6. Put `<vm-public-key>` in `wireguard_peer_public_keys.local_vm` in `inventories/host_vars/multi-lab-vps.yml` and re-run Step 5 on EC2. The hub restarts `wg-quick@wg0`; if the session drops with `UNREACHABLE`, check `ping -c 3 172.16.0.1` or use SSM.

   **EC2 · multi-lab-vps · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass
   ```

7. Verify the tunnel:

   **VM · multi-lab-local · Run on VM:**

   ```bash
   sudo wg show
   # → peer: <hub-public-key>, latest handshake: X seconds ago, transfer: ...
   ping -c 3 172.16.0.1
   # → 0% packet loss
   ```

   **Control node (Mac):**

   ```bash
   ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@172.16.0.3
   # → connects over WireGuard
   ```

8. Set `connection_mode: "wg"` in `inventories/host_vars/multi-lab-local.yml` and apply Fail2Ban. The VM keeps `limit 22222/tcp` on the LAN as a recovery path (`hardening_wg_close_public_ssh: false`), so there is no Security Group step:

   **VM · multi-lab-local · Run on control node:**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step6 --ask-become-pass
   ```

#### Why

Moving SSH to 22222 behind WireGuard keeps administrative access off the public Internet and away from scanners. `banaction = ufw` drops banned IPs at the packet filter before they reach any daemon.

#### Troubleshooting

- **`Key is not the correct length or format`:** a `CHANGE_ME_...` placeholder is still in `host_vars` or `wg0.conf`. Keys must be 44 base64 characters ending in `=`.
- **No handshake in `wg show`:** check that `multi-lab-sg` allows `51820/udp` from `0.0.0.0/0`, that the hub and client public keys are not crossed, and `sudo journalctl -xeu wg-quick@wg0` on the hub.
- **`Timeout waiting for privilege escalation prompt`:** `meta: reset_connection` ignores `when` in ansible-core 2.21. The role only reaches it through `include_tasks` guarded by `connection_mode == 'pre'`.
- **EC2 unreachable over SSH:** open an SSM session (no inbound ports needed):

  **Control node (Mac):**

  ```bash
  aws ssm start-session --target <instance_id> --profile multi-lab-admin
  ```

---

### Step 3 — System Hardening (manual Steps 7–12 · Tag `hardening_2c`)

#### What was done

Applies the remaining layers. Each manual step has its own tag, e.g. `--tags hardening_step7`.

| Manual step | Tag | What the role does |
| --- | --- | --- |
| 7 — sysctl | `hardening_step7` | Deploys `99-z-hardening.conf`, named to load after the system `99-protect-links.conf` |
| 8 — AppArmor | `hardening_step8` | Installs `apparmor-utils` and `apparmor-profiles` |
| 9.1 — Services | `hardening_step9_1` | Disables ModemManager, masks packagekit and udisks2, purges apport. **EC2 only:** migrates `amazon-ssm-agent` from snap to deb and purges snapd |
| 9.2 — Users and filesystem | `hardening_step9_2` | Permissions on crontab and `sudoers.d`, PAM password and session, `limits.conf`, UMASK 027. `chage -E` is omitted on purpose (avoids account-expiry lockout; Lynis AUTH-9282) |
| 9.3 — Kernel modules | `hardening_step9_3` | Blacklists `dccp`, `sctp`, `rds`, `tipc` and rebuilds initramfs |
| 9.4 — Monitoring | `hardening_step9_4` | `rkhunter`, `acct`, `sysstat` |
| 10 — Audit | `hardening_step10` | auditd rules (ARM64 syscalls, trailing newline forced) and AIDE database |
| 11 — Logging | `hardening_step11` | rsyslog routing for UFW and security logs, logrotate |
| 12 — Lynis | `hardening_step12` | Custom profile and score check against `hardening_lynis_min_score` (90 EC2, 88 VM); warns but does not stop the run |

Before starting, open a second SSH session to the target (PAM changes can lock you out). After the run, execute `passwd` on the target once to re-hash the admin password with 65,536 rounds.

Auditd immutable mode (`-e 2`) is controlled by `hardening_auditd_immutable_mode`: `true` by default (`defaults/main.yml`), `false` for the VM in `group_vars/vm.yml` during development so rules can be reloaded without a reboot. For the from-scratch rebuild, set it to `true` in `inventories/host_vars/multi-lab-local.yml` (host variables override group variables).

Use `connection_mode: "wg"`. Run each target once with `--check --diff` (review the diff), then apply, then apply again:

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --check --diff --ask-become-pass
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --ask-become-pass
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --ask-become-pass
# → second run: changed=0
```

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --check --diff --ask-become-pass
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --ask-become-pass
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --ask-become-pass
# → second run: changed=0
```

#### Why

The `99-z-` prefix makes the sysctl file load last, so system defaults cannot revert hardened values. Removing snapd on EC2 closes attack surface, and the deb `amazon-ssm-agent` keeps out-of-band management working.

#### Troubleshooting

- **snapd state in memory:** `dpkg` fails if `/var/lib/snapd` is removed while `snapd.service` is active. `step_09_1_services.yml` stops `snap.amazon-ssm-agent.amazon-ssm-agent.service` and `snapd.service` first.
- **`rkhunter --update` exit code 2:** it means data files were updated. `step_09_4_monitoring.yml` accepts 0, 1 and 2 and fails only on "Update failed".
- **`Enable must be 0, 1, or 2 was 2##`:** `augenrules` concatenated rule files without a trailing newline. `step_10_audit.yml` forces one.
- **APT lock after boot:** unattended-upgrades holds the dpkg lock for minutes. Playbooks set `lock_timeout: 600` in `module_defaults`.

---

### Step 4 — Verification and Convergence

#### What was done

Run the full playbook on each target. It must finish with `changed=0` (documented exception: `/var/log/fail2ban.log` may show `changed=1` if logrotate rotated it between runs).

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --ask-become-pass
# → multi-lab-vps : ok=... changed=0 failed=0
```

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --ask-become-pass
# → multi-lab-local : ok=... changed=0 failed=0
```

Expected values by target, checked with the manual Verification sections:

| Item | EC2 | VM | Manual verification |
| --- | --- | --- | --- |
| Lynis Hardening Index | ≥ 90 | ≥ 88 | [Step 12](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-12--security-audit-baseline-lynis) |
| Audit status | `enabled 2` | `enabled 1` in development, `enabled 2` after the clean rebuild | [Step 10](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-10--audit-trail-auditd--aide) |
| Connection | `wg`, `172.16.0.1:22222` | `wg`, `172.16.0.3:22222` | `inventories/host_vars/<host>.yml` |
| OpenSSH | Port 22222, key-only, non-root | Same | [Step 3](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-3--ssh-hardening) |
| UFW | Active, default deny incoming, rate-limit | Same | [Step 4](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-4--ufw-firewall) |
| WireGuard | `wg0` active, handshake recorded | Same | [Step 5](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-5--wireguard-vpn) |
| Fail2Ban | `sshd` jail active, banaction `ufw` | Same | [Step 6](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-6--fail2ban) |
| sysctl | `99-z-hardening.conf` applied | Same | [Step 7](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-7--kernel-hardening-sysctl) |
| AppArmor | Profiles loaded | Same | [Step 8](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-8--apparmor) |
| Services | `snapd` and `apport` purged | Same | [Step 9.1](../../../../modules/hardening/self-managed/hardening-self-managed.md#91--services--daemons) |
| Filesystem and users | umask 027, SHA-512 65536 rounds | Same | [Step 9.2](../../../../modules/hardening/self-managed/hardening-self-managed.md#92--filesystem--user-hardening) |
| Kernel modules | Unused protocols disabled | Same | [Step 9.3](../../../../modules/hardening/self-managed/hardening-self-managed.md#93--kernel-modules) |
| Monitoring | `acct` and `sysstat` active | Same | [Step 9.4](../../../../modules/hardening/self-managed/hardening-self-managed.md#94--monitoring--forensics) |
| Logging | Dedicated `ufw.log`, mode `0640` | Same | [Step 11](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-11--log-management-rsyslog--logrotate) |

#### Known Deviations

1. **`/var/log/fail2ban.log`:** created as `syslog:adm` in Step 11, but Fail2Ban writes as root and logrotate recreates it as `root:adm` (`0640`). One `changed` after a rotation is expected.
2. **Block 2B idempotency:** the `reset_connection` fix (`step_03_ssh_transition.yml`) is confirmed live only when the full 2B gate passes on both targets; the from-scratch rebuild is deferred to Phase 9.
3. **WireGuard endpoint on the VM:** `wireguard_endpoint` must be `<ec2_eip>:51820` in `host_vars/multi-lab-local.yml`. Defaulting to the VM's own IP prevented the handshake.
4. **UFW 22222 on EC2:** `step_04_ufw.yml` skips `limit 22222/tcp` when `hardening_wg_close_public_ssh: true`, so Step 4 does not recreate what Step 5 deletes.
5. **APT system updates (`upgrade: full`):** `step_01_updates.yml` applies `upgrade: full` (`hardening_upgrade_type`). When upstream package updates or kernel releases appear in the repositories between playbook runs, the task reports `changed=1`. The role intentionally avoids unattended reboots; this is an expected exception to the `changed=0` idempotency check.

---

## File Transfer — SFTP Service

**Starting point:** hardening is finished on both targets — the Hardening Step 4 gate reported `changed=0`, both hosts use `connection_mode: "wg"` and the WireGuard tunnel is up on the Mac. Nothing else has to be prepared before this section.

It automates [`file-transfer-self-managed.md`](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md): an SFTP server on the OpenSSH `internal-sftp` subsystem with a chroot jail, reachable only through the tunnel on port 22222.

### Step 1 — Apply (Tag `file_transfer`)

#### What was done

The `file-transfer` role reproduces on both hosts the state that the manual module leaves behind: the `sftpuser` account with no shell, the root-owned chroot with its writable `uploads/` directory, the public key in `authorized_keys`, the `Match User` SSH block and the AIDE entry for the chroot. It reuses the SFTP key pair you already created in the manual module (`~/.ssh/id_ed25519_sftp`); Ansible only reads the `.pub` file and generates nothing.

The public key file must already exist on the control node at the path you set; Ansible copies it to `/home/sftpuser/.ssh/authorized_keys` on each host, so no manual copy is needed. If only the private key is present, derive the public one:

**Control node (Mac):**

```bash
ssh-keygen -y -f ~/.ssh/id_ed25519_sftp > ~/.ssh/id_ed25519_sftp.pub
```

The auditd rule is deployed as a drop-in at `/etc/audit/rules.d/99-zz-file-transfer.rules`. Because the hardening baseline locks auditd in immutable mode (`-e 2`) on EC2, loading the new audit rule requires a kernel reboot. The role handles this via `file_transfer_auditd_reboot: true`, which automatically reboots EC2 on the first pass (terminating the active WireGuard tunnel; reconnect after the instance returns). On the local VM, `hardening_auditd_immutable_mode: false` allows rules to load directly without rebooting. The client `~/.ssh/config` alias (manual Step 7) lives on your Mac.

First, point each host to the existing public key and configure auditd reboot behavior. Add these lines to `inventories/host_vars/multi-lab-vps.yml`:

```yaml
file_transfer_sftp_public_key_file: "~/.ssh/id_ed25519_sftp.pub"
file_transfer_auditd_reboot: true
```

And to `inventories/host_vars/multi-lab-local.yml`:

```yaml
file_transfer_sftp_public_key_file: "~/.ssh/id_ed25519_sftp.pub"
file_transfer_auditd_reboot: false
```

With the WireGuard tunnel up, run the three commands in order on each host: a dry run to review the diff, the real apply, and a second apply that must report `changed=0`.

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-vps --check --diff --ask-become-pass
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-vps --ask-become-pass
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-vps --ask-become-pass
# → second run: changed=0
```

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-local --check --diff --ask-become-pass
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-local --ask-become-pass
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-local --ask-become-pass
# → second run: changed=0
```

#### Why

- **Drop-ins instead of editing shared files:** hardening owns `/etc/ssh/sshd_config` and the AIDE `99-hardening` file and rewrites them on every run, so appended blocks would be overwritten. `Include /etc/ssh/sshd_config.d/*.conf` loads the SFTP block without touching the baseline.
- **`AllowUsers sftpuser` inside the `Match`:** hardening sets a global `AllowUsers <admin>`; without this line `sftpuser` is rejected before authentication.
- **`password: "*"`:** no usable password, but the account is not locked (`!`), so key login keeps working.
- **Dedicated group:** hardening sets `USERGROUPS_ENAB=no`, so `useradd` (used by Ansible) does not create a private group per user, unlike the manual `adduser`. The role creates the `sftpuser` group explicitly and sets it as the primary group.

#### Verification

**Target host (via WireGuard SSH):**

```bash
sudo sshd -t
# → no output

sudo systemctl is-active ssh
# → active
```

---

### Step 2 — Verify (Tag `file_transfer_verify`)

#### What was done

Run the role assertions without re-applying anything, then configure the SFTP client on the Mac and test a real transfer.

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-vps --tags file_transfer_verify --ask-become-pass
# → changed=0 failed=0
```

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/file-transfer.yml --limit multi-lab-local --tags file_transfer_verify --ask-become-pass
# → changed=0 failed=0
```

What the assertions check, on both targets:

| Check | Expected | Manual verification |
| --- | --- | --- |
| `sftpuser` | Exists, shell `/usr/sbin/nologin` | [Step 1](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-1--dedicated-sftp-user) |
| Directories | `/srv`, `/srv/sftp` root-owned without group/other write; chroot `root:root 0755`; `uploads/` `sftpuser:sftpuser 0750` | [Step 2](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-2--chroot-directory-structure) |
| SSH key | `.ssh` `0700`, `authorized_keys` `0600`, owned by `sftpuser` | [Step 3](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-3--ssh-key-for-sftp-user) |
| sshd for `sftpuser` | `forcecommand internal-sftp -l VERBOSE`, chroot directory, `passwordauthentication no`, `allowtcpforwarding no`, `allowusers sftpuser` only (the `Match` replaces the global list for that user) | [Step 4](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-4--sshd_config-match-user-block) |
| sshd for the admin | Port `22222`, `forcecommand none`, `allowusers` is the admin only | [Step 4](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-4--sshd_config-match-user-block) |
| auditd rules | Active rules contain `-w /srv/sftp/ -p rwa -k sftp_activity` | [Step 5](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-5--auditd-sftp-chroot-activity-rule) |
| AIDE | `98-file-transfer` contains the `sftpuser` entry | [Step 6](../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md#step-6--aide-extend-baseline) |

Client setup (manual Step 7). Add the alias for EC2 to `~/.ssh/config` on the Mac:

```sshconfig
Host multi-lab-sftp
  HostName 172.16.0.1
  User sftpuser
  Port 22222
  IdentityFile ~/.ssh/id_ed25519_sftp
```

Test the transfer, with the tunnel up:

**EC2 · multi-lab-vps · Run on control node (Mac):**

```bash
echo "sftp-test" > /tmp/sftp_test.txt
sftp multi-lab-sftp
# sftp> cd /
# sftp> ls
# → uploads/   (only)
# sftp> put /tmp/sftp_test.txt uploads/
# sftp> ls uploads/
# → sftp_test.txt
# sftp> rm uploads/sftp_test.txt
# sftp> bye
```

**VM · multi-lab-local · Run on control node (Mac):**

```bash
sftp -i ~/.ssh/id_ed25519_sftp -P 22222 -o "StrictHostKeyChecking=accept-new" sftpuser@172.16.0.3
# same checks as on EC2
```

Clean up the client:

**Control node (Mac):**

```bash
rm /tmp/sftp_test.txt
```

---

## DNS — BIND9 Authoritative Service

**Starting point:** hardening is finished on both targets, EC2 uses `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml`, and the WireGuard tunnel is up on the Mac. Nothing else has to be prepared before this section.

It automates [`dns-self-managed.md`](../../../../modules/dns/self-managed/dns-self-managed.md): an internal authoritative BIND9 DNS server for `lab.internal` and reverse lookup zone `0.16.172.in-addr.arpa`, deployed exclusively on the EC2 hub (`172.16.0.1`).

### Step 1 — Apply (Tag `dns`)

#### What was done

The `dns` role reproduces on EC2 (`dns_servers`) the state that the manual module leaves behind: BIND9 packages and checking utilities installed, `named.conf.options` restricting recursion and queries to `lab-net`, forward and reverse zone database files in `/etc/bind/zones/`, `named.conf.local` referencing the zones, full configuration checked with `named-checkconf -z`, `named` service enabled and started, UFW rules allowing UDP and TCP port 53 on `wg0`, AIDE drop-in `/etc/aide/aide.conf.d/99-zz-dns` validated with `aide --config-check`, and Netplan overlay `/etc/netplan/51-dns-lab.yaml` pointing the system resolver to `127.0.0.1` with the VPC resolver (`10.0.0.2`) as fallback (restarting `systemd-resolved` to lock resolution to loopback).

> **Coexistence note (`dns_listen_on`):** To permit coexistence with Samba 4 Active Directory on EC2, set `dns_listen_on: "127.0.0.1; 172.16.0.1;"` in `inventories/host_vars/multi-lab-vps.yml` before applying the `directory` module. This restricts BIND9 listeners and frees the EC2 private IP on port 53 for Samba's internal DNS. Furthermore, an automated systemd drop-in for `named.service` (`10-restart-resolved.conf`) restarts `systemd-resolved` on every `named` startup, a handler restarts it after each reload, and `playbooks/dns.yml` automatically repairs the resolver on each run if it had already fallen back to `10.0.0.2`; verifying `resolvectl status ens5` (`Current DNS Server: 127.0.0.1`) remains the verification.

Ensure `connection_mode: "wg"` is set and configure BIND9 listeners and auditd reboot behavior in `inventories/host_vars/multi-lab-vps.yml`:

```yaml
# Semicolon-terminated list of IPv4 addresses on which BIND9 listens; frees EC2 private IP on port 53 for Samba 4 AD DC
dns_listen_on: "127.0.0.1; 172.16.0.1;"

# Controls automatic host reboot when auditd rules change in immutable mode (-e 2)
dns_auditd_reboot: true
```

With the WireGuard tunnel up, run the three commands in order on the EC2 hub: a dry run to review the diff, the real apply, and a second apply that must report `changed=0`.

**Control node (Mac):**

```bash
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --check --diff --ask-become-pass
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --ask-become-pass
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --ask-become-pass
# → second run: changed=0
```

Following the playbook run, note that on EC2 the first run triggers an automated reboot to apply the new audit rules in immutable mode (`-e 2`):

> **Warning:** Because the hardening baseline locks auditd in immutable mode (`-e 2`), loading the audit drop-in `/etc/audit/rules.d/99-zz-dns.rules` requires a kernel reboot. The role manages this via `dns_auditd_reboot: true` in `host_vars/multi-lab-vps.yml`, automatically rebooting EC2 on the first pass (terminating the active WireGuard tunnel; re-establish the tunnel once the host returns). Following reboot, the system resolver automatically converges back to loopback (`127.0.0.1`) thanks to the `named.service` drop-in (`10-restart-resolved.conf`) and the playbook's convergence check.

Then configure WireGuard client DNS declaratively on the local VM peer:

**VM · multi-lab-local:**

In `inventories/host_vars/multi-lab-local.yml`:
1. Set `hardening_wg_client_dns: "172.16.0.1"` to direct VM WireGuard DNS queries to BIND9 across the tunnel.
2. Temporarily switch to `connection_mode: "hardened"` (connecting via LAN IP on port 22222).

> **Important:** Modifying `/etc/wireguard/wg0.conf` triggers the `Restart wireguard` handler (`systemctl restart wg-quick@wg0`). When connected via `connection_mode: "wg"`, restarting the `wg0` interface drops the active tunnel, terminating Ansible's SSH session mid-execution (analogous to how re-applying Step 5 on the EC2 hub restarts `wg0` and drops peer traffic, as noted in [Hardening Step 2, Phase A & B](#step-2--access-chain-manual-steps-36--tag-hardening_2b)). Because the local VM keeps LAN port 22222 permitted in UFW (`hardening_wg_close_public_ssh: false`), switching temporarily to `connection_mode: "hardened"` ensures Ansible's connection survives the WireGuard service restart.

Apply Step 5 to render the updated `wg0.conf`:

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step5 --ask-become-pass
```

After Step 5 completes successfully, restore `connection_mode: "wg"` in `inventories/host_vars/multi-lab-local.yml` (Ansible resumes communicating via `172.16.0.3:22222`).

**Control node (Mac):**

For macOS WireGuard DNS behavior and optional fallback configuration, follow [manual Step 7](../../../../modules/dns/self-managed/dns-self-managed.md#step-7--point-system-resolver-to-bind9).

#### Why

- **Configs as single source of truth:** the role copies files directly from `modules/dns/self-managed/configs/` without altering repo configs or manual documentation text. The configuration files take precedence over descriptive documentation.
- **Ordering (named before Netplan):** Netplan overlay `51-dns-lab.yaml` configures systemd-resolved to prioritize `127.0.0.1`. BIND9 must be fully running and validated (`named-checkconf -z`) before Netplan is applied to prevent local resolution failures.
- **Dedicated AIDE drop-in and syntax check:** hardening owns `/etc/aide/aide.conf.d/99-hardening`. The role deploys `/etc/aide/aide.conf.d/99-zz-dns` (ordered after `99-hardening`, which defines the `CONTENTEX` group) as an independent drop-in, validates configuration syntax with `aide --config-check` before flushing handlers, and regenerates the database only if the drop-in changes.
- **Restarting systemd-resolved:** with `127.0.0.1` and `10.0.0.2` on the same interface (`ens5`), `systemd-resolved` retains its current server and only falls over on failure. If `127.0.0.1` was not responding at apply time, resolved stays with the VPC resolver (`10.0.0.2`), which returns NXDOMAIN for `lab.internal`. Restarting `systemd-resolved` after Netplan application while BIND9 is active resets query routing to the primary server (`127.0.0.1`).
- **VPC domain forwarding and DNSSEC exception:** queries for internal VPC names (e.g. `*.compute.internal`) and reverse lookups for the host VPC IP (e.g. `141.1.0.10.in-addr.arpa` in `10.in-addr.arpa`) fail DNSSEC validation in Quad9 forwarders (`broken trust chain`), returning SERVFAIL. As a result, `systemd-resolved` marks `127.0.0.1` defective and permanently falls back to the VPC resolver (`10.0.0.2`), which returns NXDOMAIN for `lab.internal`. The role adds `validate-except { "compute.internal"; "10.in-addr.arpa"; };` in `named.conf.options` and two forward-only zones (`compute.internal` and `10.in-addr.arpa`) pointing to `10.0.0.2` in `named.conf.local` without modifying manual configs.
- **Drop-in auditd rule with controlled reboot:** hardening locks auditd in immutable mode (`-e 2`) and clears rules with `-D`. The role deploys an independent drop-in at `/etc/audit/rules.d/99-zz-dns.rules` to monitor `/etc/bind/` and `/var/lib/bind/` with key `dns_config` without touching `99-hardening.rules`. In immutable mode, `dns_auditd_reboot: true` triggers a controlled reboot on the first pass to load the rules into the kernel.
- **Declarative WireGuard peer DNS configuration:** the `hardening` role owns `/etc/wireguard/wg0.conf` on client peers. Hardcoding or manually editing `DNS` with `sed` gets overwritten on subsequent playbook runs (`hardening.yml` or `site.yml`). The `hardening_wg_client_dns` variable declaratively configures `/etc/wireguard/wg0.conf` (`172.16.0.1`), ensuring idempotence. Because `wg-quick@wg0` restarts via handler when the configuration changes, temporarily switching to `connection_mode: "hardened"` avoids SSH disconnection over `wg0`.
- **Exclusion of Step 8:** pre-AMI sanitization of `/etc/resolv.conf` is omitted because the automated provisioning architecture is greenfield (Terraform and Ansible build clean environments), removing dependencies on golden AMIs.

#### Verification

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --tags dns_verify --ask-become-pass
# → changed=0 failed=0
```

Verify service status and config syntax directly on the EC2 host:

**EC2 · multi-lab-vps:**

```bash
sudo named-checkconf
# → (no output)

sudo systemctl is-active named
# → active
```

---

### Step 2 — Verify (Tag `dns_verify`)

#### What was done

Run the role assertions without re-applying anything, and test DNS resolution across the WireGuard tunnel from the local VM client.

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --tags dns_verify --ask-become-pass
# → changed=0 failed=0
```

What the assertions check on EC2 (`multi-lab-vps`):

| Check | Expected | Manual verification |
| --- | --- | --- |
| `named` daemon | Active and running | [Step 1](../../../../modules/dns/self-managed/dns-self-managed.md#step-1--install-bind9) |
| BIND9 configuration | Syntax clean, forward and reverse zones loaded (`named-checkconf -z`) | [Step 2 & 3](../../../../modules/dns/self-managed/dns-self-managed.md#step-2--configure-namedconfoptions) |
| Socket listener | UDP port 53 listening on `127.0.0.1` and `172.16.0.1` (`ss -ulnH`) | [Step 2](../../../../modules/dns/self-managed/dns-self-managed.md#step-2--configure-namedconfoptions) |
| Forward resolution | `ns1.lab.internal` and `vps.lab.internal` resolve to `172.16.0.1` | [Step 3](../../../../modules/dns/self-managed/dns-self-managed.md#step-3--zone-configuration-forward--reverse) |
| Reverse resolution | `172.16.0.1` resolves to `ns1.lab.internal.` and `vps.lab.internal.` | [Step 3](../../../../modules/dns/self-managed/dns-self-managed.md#step-3--zone-configuration-forward--reverse) |
| External recursion | `google.com` resolves via forwarders | [Step 2](../../../../modules/dns/self-managed/dns-self-managed.md#step-2--configure-namedconfoptions) |
| UFW rules | Incoming `53/udp` and `53/tcp` allowed on `wg0` (`ALLOW IN`) | [Step 4](../../../../modules/dns/self-managed/dns-self-managed.md#step-4--ufw-allow-dns) |
| Netplan resolver | `ens5` configured with `127.0.0.1`, `10.0.0.2` and domain `lab.internal` | [Step 7](../../../../modules/dns/self-managed/dns-self-managed.md#step-7--point-system-resolver-to-bind9) |
| System resolution | Local system resolver resolves `ns1.lab.internal` to `172.16.0.1` | [Step 7](../../../../modules/dns/self-managed/dns-self-managed.md#step-7--point-system-resolver-to-bind9) |
| PTR of the VPC host IP via BIND | NOERROR | [Step 7](../../../../modules/dns/self-managed/dns-self-managed.md#step-7--point-system-resolver-to-bind9) |
| Active DNS server | Current DNS Server: 127.0.0.1 (no fallback to VPC resolver) | [Step 7](../../../../modules/dns/self-managed/dns-self-managed.md#step-7--point-system-resolver-to-bind9) |
| auditd rules | Active rules contain `-w /etc/bind/ -p wa -k dns_config` and `-w /var/lib/bind/ -p wa -k dns_config` | [Step 5](../../../../modules/dns/self-managed/dns-self-managed.md#step-5--auditd-zone-file-monitoring) |
| AIDE integrity | Drop-in `99-zz-dns` monitors `/etc/bind` and excludes `/var/cache/bind` | [Step 6](../../../../modules/dns/self-managed/dns-self-managed.md#step-6--aide-extend-baseline) |

Verify that systemd-resolved is anchored to the local BIND9 resolver (`127.0.0.1`):

**EC2 · multi-lab-vps:**

```bash
resolvectl status ens5 | grep "Current DNS Server"
# → Current DNS Server: 127.0.0.1
```

Test resolution and resolver status from the WireGuard peer over the tunnel:

**VM · multi-lab-local:**

```bash
resolvectl status wg0
# → Link ... (wg0)
# → Current DNS Server: 172.16.0.1
# → DNS Servers: 172.16.0.1
# → DNS Domain: ~.

resolvectl query vps.lab.internal
# → vps.lab.internal: 172.16.0.1

dig @172.16.0.1 vps.lab.internal +short
# → 172.16.0.1

dig google.com +short
# → <valid IP>
```

---

## Web Server — Nginx HTTPS Service

**Starting point:** hardening and DNS are finished, EC2 uses `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml`, and the WireGuard tunnel is up on the Mac. Nothing else has to be prepared before this section.

It automates [`web-server-self-managed.md`](../../../../modules/web-server/self-managed/web-server-self-managed.md): an Nginx web server terminating HTTPS and reverse proxying upstream traffic, deployed on both targets with environment-specific TLS strategies (self-signed certificate on the local VM, Let's Encrypt automated certificate on EC2).

#### One-Time Lab Prerequisite — Public Hosted Zone & Registrar Delegation

The domain `buildyourinfra.click` is registered in Route 53 under the same AWS account (any authoritative DNS provider is valid). The public hosted zone and registrar nameserver delegation are configured once outside Terraform as an account-level prerequisite. The root A record itself is **not** created manually; it is managed declaratively by Terraform in Step 1.

**Control node (Mac):**

1.1 Create the public hosted zone (one time; persists after the lab as the base DNS zone for the registered domain):

```bash
aws route53 create-hosted-zone \
  --name buildyourinfra.click \
  --caller-reference "multi-lab-$(date +%s)" \
  --profile multi-lab-admin \
  --query 'HostedZone.Id' \
  --output text
# → /hostedzone/<ZONE_ID>
```

1.2 Point the registered domain to the new zone's nameservers (one time):

```bash
ZONE_ID=$(aws route53 list-hosted-zones --profile multi-lab-admin --query "HostedZones[?Name=='buildyourinfra.click.'].Id | [0]" --output text | awk -F'/' '{print $NF}')
N1=$(aws route53 get-hosted-zone --id "$ZONE_ID" --profile multi-lab-admin --query 'DelegationSet.NameServers[0]' --output text)
N2=$(aws route53 get-hosted-zone --id "$ZONE_ID" --profile multi-lab-admin --query 'DelegationSet.NameServers[1]' --output text)
N3=$(aws route53 get-hosted-zone --id "$ZONE_ID" --profile multi-lab-admin --query 'DelegationSet.NameServers[2]' --output text)
N4=$(aws route53 get-hosted-zone --id "$ZONE_ID" --profile multi-lab-admin --query 'DelegationSet.NameServers[3]' --output text)
aws route53domains update-domain-nameservers --domain-name buildyourinfra.click --region us-east-1 --profile multi-lab-admin --nameservers Name=$N1 Name=$N2 Name=$N3 Name=$N4
aws route53domains list-operations --region us-east-1 --profile multi-lab-admin --query 'Operations[0].[Type,Status]' --output text
# → UPDATE_NAMESERVER  SUCCESSFUL
dig +short NS buildyourinfra.click @1.1.1.1
# → the four nameservers of the new zone (propagation may take a while)
```

### Step 1 — Apply (Tag `web-server`)

#### What was done

The `web-server` role reproduces on both targets the state that the manual module leaves behind: Nginx installed and enabled, UFW application profile `Nginx Full` (ports 80 and 443) allowed, TLS certificates provisioned (397-day self-signed certificate on VM; Certbot Let's Encrypt certificate and `certbot.timer` auto-renewal on EC2), default site removed from `sites-enabled/`, dedicated virtual host `multi-lab.conf` deployed and validated with `nginx -t`, default lab `index.html` placed in `/var/www/html/`, auditd activity monitoring drop-in `/etc/audit/rules.d/99-zz-web-server.rules` deployed with automated reboot handling for immutable kernels, and AIDE drop-in `/etc/aide/aide.conf.d/99-zz-web-server` validated with `aide --config-check`.

The root DNS A record pointing to the EC2 Elastic IP is provisioned declaratively via Terraform, avoiding manual DNS records or drifting state. Port mapping and TLS modes are defined per target in `host_vars`.

##### Staging vs Production (EC2 ACME Issuance)

Let's Encrypt limits include 5 failed validations per account, per hostname, per hour, and 5 duplicate certificates (same set of hostnames) per 7 days; the 50-per-week limit applies per registered domain. These limits can lock out automated deployments if DNS propagation or firewall rules fail. EC2 issuance is therefore executed in two sequential stages:

1. **Staging rehearsal (`web_server_certbot_staging: true`):** Validates the complete ACME HTTP-01 challenge against Let's Encrypt staging environment without consuming production quotas.
2. **Production issuance (`web_server_certbot_staging: false`):** Promotes the existing lineage to the production ACME endpoint (`--server https://acme-v02.api.letsencrypt.org/directory --force-renewal --cert-name`) without deleting certificate files or renewal configurations.

**Control node (Mac):**

Provision the Route 53 A record pointing to the EC2 Elastic IP:

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
terraform plan
# → Plan: 1 to add, 0 to change, 0 to destroy.

terraform apply
dig +short A buildyourinfra.click @1.1.1.1
# → <EC2_ELASTIC_IP>
```

> If the plan shows changes to the security group or the instance, do not apply and review the diff; the `ssh_bootstrap_cidr` and `ssh_hardened_cidr` values must remain empty after hardening.

**Control node (Mac):**

Configure host variables for the local VM in `inventories/host_vars/multi-lab-local.yml`:

```yaml
tls_mode: "self_signed"
web_server_upstream_port: 8080
web_server_auditd_reboot: false
```

Configure host variables for EC2 in `inventories/host_vars/multi-lab-vps.yml` (initiating rehearsal with staging mode enabled):

```yaml
tls_mode: "letsencrypt"
web_server_domain: "buildyourinfra.click"
web_server_upstream_port: 8080
web_server_certbot_email: "<your-email>"
web_server_certbot_staging: true
web_server_auditd_reboot: true
```

**VM · multi-lab-local · Run on control node:**

Deploy web server on the local VM with self-signed TLS certificate:

```bash
ansible-playbook playbooks/web-server.yml --limit multi-lab-local --check --diff --ask-become-pass
ansible-playbook playbooks/web-server.yml --limit multi-lab-local --ask-become-pass
ansible-playbook playbooks/web-server.yml --limit multi-lab-local --ask-become-pass
# → second run: changed=0
```

**EC2 · multi-lab-vps · Run on control node:**

Run ACME staging rehearsal on EC2 (`web_server_certbot_staging: true`):

> **Warning:** Because `hardening_auditd_immutable_mode` is enabled (`-e 2`) and `web_server_auditd_reboot` is `true`, the initial deployment will reboot the EC2 instance to load `/etc/audit/rules.d/99-zz-web-server.rules`. This terminates the active WireGuard tunnel. Re-establish the WireGuard connection before running subsequent commands, and verify DNS resolution via `resolvectl status` if necessary.

```bash
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --check --diff --ask-become-pass
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --ask-become-pass
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --ask-become-pass
# → second run: changed=0
```

**EC2 · multi-lab-vps · Run on control node:**

Promote to production Let's Encrypt certificate by updating `inventories/host_vars/multi-lab-vps.yml`:

```yaml
web_server_certbot_staging: false
```

Execute the playbook to issue the trusted production certificate, then confirm idempotence on the second run:

```bash
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --ask-become-pass
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --ask-become-pass
# → second run: changed=0
```

#### Why

- **ACME staging rehearsal:** Let's Encrypt enforces strict production rate limits. Staging issuance verifies public DNS resolution, ingress firewall rules, and Nginx challenge routing without penalty before requesting the production certificate.
- **Production promotion without lineage regeneration:** Promoting from staging with `--cert-name <domain> --server https://acme-v02.api.letsencrypt.org/directory --force-renewal` avoids deleting `/etc/letsencrypt/` directories or re-creating symlinks, ensuring a seamless transition to the production CA.
- **Automated auditd drop-in:** Rather than manually appending rules to `99-hardening.rules` (which would be wiped if hardening is re-run), the role deploys `/etc/audit/rules.d/99-zz-web-server.rules` containing only active ASCII rules. For immutable kernels (`-e 2`), `web_server_auditd_reboot: true` handles the required kernel reload cleanly via an Ansible reboot handler.
- **Declarative DNS A record via Terraform:** Querying the Route 53 hosted zone via Terraform `data "aws_route53_zone"` keeps DNS state declarative and attached to the EC2 Elastic IP lifecycle, preventing manual drift and orphaned records.
- **Alphabetical AIDE drop-in:** hardens against configuration tampering by placing `/etc/aide/aide.conf.d/99-zz-web-server` after `99-hardening` (which defines the `CONTENTEX` rule group), validating syntax with `aide --config-check` before updating database checksums.
- **Vhost validation prior to reload:** `multi-lab.conf` is an included server block that cannot be verified standalone with `nginx -t -c %s`. The role links the virtual host and runs `nginx -t` before handlers run, aborting execution before bad syntax can reach the live server.
- **Simulated reverse proxy upstream:** `<upstream_port>` (8080) has no listening backend service. Nginx correctly returns `502 Bad Gateway`, verifying reverse proxy routing without requiring mock backend software.

#### Verification

Step 2 executes the complete test suite across both targets using `--tags web-server_verify`, testing daemon status, firewall rules, certificate lineages, virtual host syntax, proxy routing, audit rules, and AIDE database integrity.

---

### Step 2 — Verify (Tag `web-server_verify`)

#### What was done

Run the role assertions without modifying configuration state. On EC2, verify active production certificates, test automated renewal dry-run via `-e web_server_verify_renewal=true`, and inspect the AWS Security Group.

**EC2 · multi-lab-vps · Run on control node:**

```bash
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --tags web-server_verify --ask-become-pass
# → changed=0 failed=0
```

Verify automated renewal simulation on EC2 with opt-in dry-run check:

```bash
ansible-playbook playbooks/web-server.yml --limit multi-lab-vps --tags web-server_verify -e web_server_verify_renewal=true --ask-become-pass
# → changed=0 failed=0
```

**VM · multi-lab-local · Run on control node:**

```bash
ansible-playbook playbooks/web-server.yml --limit multi-lab-local --tags web-server_verify --ask-become-pass
# → changed=0 failed=0
```

Verify AWS Security Group ingress rules (read-only check from control node):

**Control node (Mac):**

```bash
aws ec2 describe-security-groups --region eu-west-1 --profile multi-lab-admin --filters Name=group-name,Values=multi-lab-sg \
  --query 'SecurityGroups[0].IpPermissions[?ToPort==`80` || ToPort==`443`].[FromPort,ToPort,IpRanges[0].CidrIp]' --output text
# → 80   80   0.0.0.0/0
# → 443  443  0.0.0.0/0
```

What the assertions check on each target:

| Check | Expected | Manual verification |
| --- | --- | --- |
| `nginx` daemon | Active and running | [Step 1](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-1--install-nginx-and-open-firewall) |
| UFW firewall | `Nginx Full` ALLOW IN rule present | [Step 1](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-1--install-nginx-and-open-firewall) |
| Self-signed TLS (VM) | Certificate (0644) and key (0600) present; subject CN=multi-lab-local | [Step 2](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-2--tls-certificate) |
| Let's Encrypt TLS (EC2) | Live lineage present; `certbot.timer` active | [Step 2](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-2--tls-certificate) |
| Certbot renewal dry-run (EC2) | `certbot renew --dry-run` succeeds (`web_server_verify_renewal: true`) | [Step 2](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-2--tls-certificate) |
| Nginx configuration | `nginx -t` test successful | [Step 3](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-3--nginx-https-virtual-host) |
| Virtual host symlink | `sites-enabled/default` absent; `sites-enabled/multi-lab.conf` active symlink | [Step 3](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-3--nginx-https-virtual-host) |
| Reverse proxy port | `nginx -T` contains `proxy_pass http://127.0.0.1:8080/;` without placeholder | [Step 3](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-3--nginx-https-virtual-host) |
| Index page | `/var/www/html/index.html` present with mode 0644 | [Step 3](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-3--nginx-https-virtual-host) |
| HTTP redirect | `curl http://localhost` returns 301 redirect to `https://` | [Step 4](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-4--http--https-redirect) |
| HTTPS reverse proxy | `curl -k https://localhost` returns 502 Bad Gateway (or 200 OK if backend up) | [Reverse Proxy](../../../../modules/web-server/self-managed/web-server-self-managed.md#reverse-proxy) |
| Audit rules | `auditctl -l` contains key `nginx_config` (or notice displayed if reboot pending) | [Step 5](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-5--auditd-web-server-activity-rule) |
| AIDE integrity | Drop-in `99-zz-web-server` present (0644); `aide --config-check` returns exit code 0 | [Step 6](../../../../modules/web-server/self-managed/web-server-self-managed.md#step-6--aide-extend-baseline) |

---

## Directory — Samba 4 Active Directory Service

**Starting point:** hardening, DNS, and web-server are finished on EC2, EC2 uses `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml`, and the WireGuard tunnel is up on the Mac. Nothing else has to be prepared before this section.

It automates [`directory-self-managed.md`](../../../../modules/directory/self-managed/directory-self-managed.md): a Samba 4 Active Directory Domain Controller (`multilab.internal`) with internal DNS (`SAMBA_INTERNAL`) and Kerberos realm (`MULTILAB.INTERNAL`), deployed exclusively on the EC2 hub (`directory_servers`).

### Step 1 — Apply (Tag `directory`)

#### What was done

The `directory` role reproduces on EC2 (`directory_servers`) the state that the manual module leaves behind: pre-flight validation of the hardening OpenSSH port, host IPv4 matching, port 53 listener availability, and interactive administrator password entry; system hostname set to `dc01.multilab.internal` and local `/etc/hosts` mapping configured to the DC private IP (leaving `systemd-resolved` and `/etc/resolv.conf` untouched without `chattr`); Samba 4, winbind, Kerberos client, and diagnostic utilities installed; standalone daemons (`smbd`, `nmbd`, `winbind`) stopped and disabled; `samba-ad-dc` service unmasked; domain provisioned with `samba-tool domain provision` using `SAMBA_INTERNAL` DNS backend, RFC2307 schema, and explicit Windows Server 2016 functional levels; `smb.conf` restricted to the private IP (`interfaces` and `bind interfaces only = yes`) with `dns forwarder = 127.0.0.1` pointing to local BIND9; reference Kerberos client configuration deployed to `/etc/krb5.conf`; `samba-ad-dc` enabled and started; UFW rules opened for AD DS ports (88, 389, 636, 445, 135, 3268) from the WireGuard subnet `172.16.0.0/24`; auditd activity monitoring drop-in `/etc/audit/rules.d/99-zz-directory.rules` deployed with automated reboot handling for immutable kernels; and AIDE drop-in `/etc/aide/aide.conf.d/99-zz-directory` validated with `aide --config-check`.

Obtain the private IPv4 address of the EC2 instance on interface `ens5`:

**EC2 · multi-lab-vps:**

```bash
ip -4 -br addr
# → ens5 UP <ec2_private_ip>/24 ...
```

Configure host variables for EC2 in `inventories/host_vars/multi-lab-vps.yml`:

```yaml
dns_listen_on: "127.0.0.1; 172.16.0.1;"
directory_dc_ip: "<ec2_private_ip>"
directory_auditd_reboot: true
```

Before deploying the `directory` role, re-apply `playbooks/dns.yml` to update `listen-on` in BIND9 and free the EC2 private IP on port 53:

**Control node (Mac):**

```bash
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --check --diff --ask-become-pass
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --ask-become-pass
```

Inspect active port 53 listening sockets on EC2 to verify BIND9 no longer listens on `<directory_dc_ip>:53`:

**EC2 · multi-lab-vps:**

```bash
sudo ss -H -lunpt 'sport = :53'
# → udp  UNCONN  ... 127.0.0.1:53   ... users:(("named",...))
# → udp  UNCONN  ... 172.16.0.1:53  ... users:(("named",...))
# → tcp  LISTEN  ... 127.0.0.1:53   ... users:(("named",...))
# → tcp  LISTEN  ... 172.16.0.1:53  ... users:(("named",...))
```

> **Warning:** On the first deployment with `directory_auditd_reboot: true`, the playbook automatically reboots the EC2 instance upon applying the auditd rules drop-in to enforce immutable kernel configuration (`-e 2`). This reboot terminates the active WireGuard tunnel. Reconnect the WireGuard tunnel on the control node before continuing. With `playbooks/dns.yml` applied beforehand (including the `named.service` drop-in), `Current DNS Server` must remain `127.0.0.1` after reboot; verify this on EC2 with `resolvectl status ens5`.

> **Administrator Password Prompt:** `playbooks/directory.yml` prompts interactively for the Domain Administrator password (`vars_prompt`, minimum 8 characters). Password complexity (at least 3 of 4 classes: lowercase `[a-z]`, uppercase `[A-Z]`, digits `[0-9]`, and special characters `[^a-zA-Z0-9]`) is only required during initial domain provisioning; with the domain already provisioned, an incorrect password fails during verification (`directory_verify`) in `kinit` with a clear message.

> **Partial Provision Recovery:** If pre-flight assertions detect a partial Samba provision (`sam.ldb` exists without `/var/lib/samba/private/krb5.conf`), the playbook aborts without modifying existing files. Clean the slate manually per Step 3 of [`directory-self-managed.md`](../../../../modules/directory/self-managed/directory-self-managed.md#step-3--domain-provisioning) (remove `/etc/samba/smb.conf` and `/var/lib/samba/*`) before rerunning the playbook.

Deploy the Samba 4 Active Directory Domain Controller role:

**Control node (Mac):**

```bash
ansible-playbook playbooks/directory.yml --limit multi-lab-vps --check --diff --ask-become-pass
ansible-playbook playbooks/directory.yml --limit multi-lab-vps --ask-become-pass
ansible-playbook playbooks/directory.yml --limit multi-lab-vps --ask-become-pass
# → second run: changed=0
```

> **Manual Step 8 Note:** In Step 8 of the manual documentation, `samba-tool dns serverinfo 127.0.0.1` queries loopback. Because `interfaces = <directory_dc_ip>` and `bind interfaces only = yes` restrict Samba internal DNS strictly to the DC private IP, loopback port 53 is owned exclusively by BIND9. Samba internal DNS queries must target `<directory_dc_ip>` instead.

#### Why

- **SAMBA_INTERNAL DNS backend:** Eliminates packaging permissions failures and AppArmor scoping defects present with the `BIND9_DLZ` driver on Ubuntu 24.04. Samba manages its own internal DNS on `<directory_dc_ip>:53` while BIND9 handles `lab.internal` and forward resolution on `127.0.0.1:53` and `172.16.0.1:53`. Upstream queries from Samba are forwarded to BIND9 via `dns forwarder = 127.0.0.1`.
- **Windows Server 2016 functional level:** Samba 4.19 defaults to 2008_R2. Supplying both `--function-level=2016` and `--option="ad dc functional level = 2016"` ensures that forest, domain, and lowest DC functional levels match the Windows Server 2016 specification expected by the manual documentation.
- **System resolver preservation:** `systemd-resolved` and `/etc/resolv.conf` remain intact without `chattr +i`, preserving the multi-tier resolver architecture established in the `dns` module. Local resolution of the DC FQDN is handled by `/etc/hosts`.
- **Static Kerberos client configuration:** The reference configuration in `configs/krb5/krb5.conf` is deployed directly to `/etc/krb5.conf`, ensuring deterministic KDC pointers without relying on runtime file generation.
- **Admin password security:** The domain Administrator password is supplied interactively via `vars_prompt` in `playbooks/directory.yml` (`no_log: true`), preventing password hashes from residing in playbooks or version-controlled files.
- **Conditional audit rule:** The `samba_keytab` watch rule is excluded from `/etc/audit/rules.d/99-zz-directory.rules` unless `dns.keytab` exists on disk, as auditctl rejects watch rules for non-existent files.
- **Automated auditd drop-in:** Follows the established drop-in pattern with automated reboot handling for immutable kernels (`-e 2`) via `directory_auditd_reboot: true`.

#### Verification

Step 2 executes the verification test suite on EC2 using `--tags directory_verify`, testing daemon status, domain functional level, socket listeners, DNS resolution, Kerberos authentication, UFW rules, audit rules, and AIDE database integrity.

---

### Step 2 — Verify (Tag `directory_verify`)

#### What was done

Run the role assertions without modifying configuration state:

**Control node (Mac):**

```bash
ansible-playbook playbooks/directory.yml --limit multi-lab-vps --tags directory_verify --ask-become-pass
# → changed=0 failed=0
```

What the assertions check on EC2:

| Check | Expected | Manual verification |
| --- | --- | --- |
| Hostname & local resolution | `hostname -f` == `dc01.multilab.internal`; `getent hosts` resolves to `directory_dc_ip` | [Step 1](../../../../modules/directory/self-managed/directory-self-managed.md#step-1--pre-provision-system-preparation) |
| Standalone daemons | `smbd`, `nmbd`, and `winbind` inactive and disabled | [Step 2](../../../../modules/directory/self-managed/directory-self-managed.md#step-2--install-samba-and-dependencies) |
| `samba-ad-dc` service | Active and enabled in systemd | [Step 6](../../../../modules/directory/self-managed/directory-self-managed.md#step-6--start-samba-ad-dc-service) |
| Samba configuration | `testparm -s` confirms `server role = active directory domain controller`, interfaces, bind interfaces only, forwarder | [Step 3](../../../../modules/directory/self-managed/directory-self-managed.md#step-3--domain-provisioning) |
| Socket listeners | TCP 88 (`kdc`), 389 (`ldap`), 445 (`smbd`) on `directory_dc_ip`; UDP 53 on `directory_dc_ip` (`dns[master]`, not named) and on `127.0.0.1` (named) | [Step 6](../../../../modules/directory/self-managed/directory-self-managed.md#step-6--start-samba-ad-dc-service) |
| UFW firewall | Inbound rules for ports 88, 389, 636, 445, 135, 3268 ALLOW IN from `172.16.0.0/24` | [Step 7](../../../../modules/directory/self-managed/directory-self-managed.md#step-7--firewall-rules) |
| Functional level | `samba-tool domain level show` reports 2016 for forest, domain, and lowest DC | [Step 6](../../../../modules/directory/self-managed/directory-self-managed.md#step-6--start-samba-ad-dc-service) |
| AD DNS SRV records | `_ldap._tcp` and `_kerberos._tcp` SRV queries to `directory_dc_ip` return `dc01.multilab.internal` | [Step 4](../../../../modules/directory/self-managed/directory-self-managed.md#step-4--dns-coexistence-samba--bind9) |
| AD DNS SOA record | SOA query for `multilab.internal` to `directory_dc_ip` returns status NOERROR | [Step 4](../../../../modules/directory/self-managed/directory-self-managed.md#step-4--dns-coexistence-samba--bind9) |
| Kerberos configuration | `/etc/krb5.conf` contains default_realm `MULTILAB.INTERNAL` and kdc `dc01.multilab.internal` | [Step 5](../../../../modules/directory/self-managed/directory-self-managed.md#step-5--kerberos-configuration) |
| Kerberos authentication | `kinit Administrator` via stdin succeeds, `klist` shows ticket, `kdestroy` cleans cache | [Step 5](../../../../modules/directory/self-managed/directory-self-managed.md#step-5--kerberos-configuration) |
| Audit rules | `auditctl -l` contains keys `samba_config` and `samba_db` (and `samba_keytab` if keytab present) | [Step 9](../../../../modules/directory/self-managed/directory-self-managed.md#step-9--auditd-directory-service-activity-rule) |
| AIDE integrity | Drop-in `99-zz-directory` present (0644); `aide --config-check` returns exit code 0 | [Step 10](../../../../modules/directory/self-managed/directory-self-managed.md#step-10--aide-extend-baseline) |

#### Why

- **Server role verification via `testparm`:** `dns backend` is an option passed to `samba-tool domain provision`, not a configuration parameter stored in `smb.conf`. Running `testparm -s --parameter-name="dns backend"` fails with exit code 1 because `testparm` only inspects valid `smb.conf` parameters. The role instead queries `server role` via `testparm -s` (confirming `active directory domain controller`) alongside `realm`, `interfaces`, `bind interfaces only`, and `dns forwarder`. Internal DNS backend operation is independently verified by asserting that the UDP port 53 listener bound to `<directory_dc_ip>` is owned by Samba's `dns[master]` process.
- **Kerberos authentication in check mode:** Kerberos ticket acquisition and cache destruction tasks execute with `check_mode: false` to allow non-destructive credential verification against an already provisioned Domain Controller during dry-run testing.

---

## DHCP — Kea DHCPv4 Service

The `dhcp` role automates the deployment of the Kea DHCPv4 daemon exclusively on the local VM (`dhcp_servers` / `multi-lab-local`). Kea is the ISC-supported successor to `isc-dhcp-server`, providing JSON-based configuration, dynamic pool allocation, static reservations, auditd lease tracking, and AIDE baseline monitoring.

The DHCP service operates exclusively on the local bridged LAN segment (`192.168.1.0/24`), serving clients on the local network while advertising the EC2 BIND9 resolver (`172.16.0.1` over WireGuard) as the primary DNS server.

### Host Variables Configuration

Before deploying `playbooks/dhcp.yml`, ensure the following host variables are defined in `inventories/host_vars/multi-lab-local.yml`:

- `vm_interface`: The bridged network interface on the local VM (e.g. `ens160` or `enp2s0`). Pre-flight assertions verify that this interface exists on the host and has an assigned IPv4 address in `192.168.1.0/24`.
- `dhcp_reservations`: A list of static MAC-to-IP reservations. Reserved IPs must be placed in `192.168.1.201`–`192.168.1.254` (outside the dynamic pool `.100`–`.200`). Set to `[]` if no reservations are needed.
- `dhcp_auditd_reboot`: Boolean flag controlling automatic reboot when auditd rules are updated on immutable kernels (`-e 2`). Not triggered on the local VM while `hardening_auditd_immutable_mode` is `false`.

Identify the bridged LAN interface and MAC address of target clients to reserve:

**VM · multi-lab-local:**

```bash
ip -4 -br addr
# → identify bridged LAN interface name (e.g., ens160, enp2s0) with IP in 192.168.1.0/24

ip link show <vm_interface>
# → link/ether <mac_address>  ← MAC of client machine to reserve
```

Configure host variables in `inventories/host_vars/multi-lab-local.yml`:

```yaml
# inventories/host_vars/multi-lab-local.yml
vm_interface: "<vm_interface>"

dhcp_reservations:
  - hw_address: "<mac_of_reserved_host>"
    ip_address: "192.168.1.<201-254>"
    hostname: "<hostname>"

dhcp_auditd_reboot: false
```

---

### Step 1 — Apply (Role `dhcp`)

#### What was done

Deploy the Kea DHCPv4 service to the local VM:

**Control node (Mac):**

```bash
ansible-playbook playbooks/dhcp.yml --limit multi-lab-local --check --diff --ask-become-pass
ansible-playbook playbooks/dhcp.yml --limit multi-lab-local --ask-become-pass
ansible-playbook playbooks/dhcp.yml --limit multi-lab-local --ask-become-pass
# → second run: changed=0
```

Verify that Kea DHCPv4 is active and listening on UDP port 67:

**VM · multi-lab-local:**

```bash
sudo systemctl status kea-dhcp4-server
# → Active: active (running)

sudo ss -H -lunp 'sport = :67'
# → UNCONN ... 0.0.0.0:67 ... users:(("kea-dhcp4",...))
```

#### Why

- **Kea DHCPv4 over ISC DHCP:** `isc-dhcp-server` reached end-of-life in 2022. Kea provides a modular architecture, clean JSON configuration format, built-in REST control socket (`/run/kea/kea4-ctrl-socket`), and active upstream maintenance.
- **Raw Sockets & Absence of UFW Rules:** Kea is configured with `"dhcp-socket-type": "raw"`. AF_PACKET raw sockets attach directly to the network interface driver, intercepting DHCPDISCOVER broadcasts before the Linux netfilter stack processes them. Consequently, UFW does not inspect or filter DHCP packets, and no UFW perimeter rules are required.
- **Source of Truth & Jinja Replacement:** The reference configuration in `modules/dhcp/self-managed/configs/kea/kea-dhcp4.conf` serves as the single source of truth. Dynamic interface binding and host reservations are injected via `copy` with `content` (`lookup` + `replace`), avoiding duplicated template configurations.
- **Post-Deployment Configuration Validation:** Using Ansible's `copy` module `validate:` parameter is not viable because `kea-dhcp4 -t` only opens configuration files located within `/etc/kea/`, rejecting temporary files generated by Ansible in `/tmp` or `/home` with `Unable to open file`. The playbook validates `/etc/kea/kea-dhcp4.conf` immediately after deployment and prior to service handlers executing, failing the play before restarting the daemon if syntax is invalid.
- **Delayed Auditd Rule Deployment:** Kernel `auditctl` rejects file watches on paths that do not exist on disk. The playbook starts Kea and waits for `/var/lib/kea/kea-leases4.csv` to be created before deploying `/etc/audit/rules.d/99-zz-dhcp.rules`.
- **AIDE Baseline Extension:** The Kea configuration directory (`/etc/kea`) is added to AIDE monitoring via `/etc/aide/aide.conf.d/99-zz-dhcp` (ordered after `99-hardening`), while `/var/lib/kea/kea-leases4.csv` is explicitly excluded to eliminate false positives on routine lease issuance.

#### Verification

Step 2 executes the verification test suite on the local VM using `--tags dhcp_verify`, checking daemon status, configuration syntax, socket listener, lease database presence, auditd rules, AIDE baseline integrity, and end-to-end broadcast discovery.

---

### Step 2 — Verify (Tag `dhcp_verify`)

#### What was done

Run the role assertions without modifying configuration state:

**Control node (Mac):**

```bash
ansible-playbook playbooks/dhcp.yml --limit multi-lab-local --tags dhcp_verify --ask-become-pass
# → changed=0 failed=0
```

What the assertions check on the local VM:

| Check | Expected | Manual verification |
| --- | --- | --- |
| `kea-dhcp4-server` service | Active and enabled in systemd | [Step 1](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-1--install-kea-dhcp) |
| Configuration syntax | `kea-dhcp4 -t /etc/kea/kea-dhcp4.conf` returns exit code 0 | [Step 2](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-2--configure-kea-dhcp) |
| Socket listener | UDP port 67 active and bound to `kea-dhcp4` process | [Step 2](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-2--configure-kea-dhcp) |
| Configuration content | Subnet `192.168.1.0/24`, pool `.100`–`.200`, router `192.168.1.1`, DNS `172.16.0.1`, domain `lab.internal`, interface, and reservations present | [Step 2](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-2--configure-kea-dhcp) |
| Lease database | `/var/lib/kea/kea-leases4.csv` exists on disk | [Step 3](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-3--static-reservations) |
| Audit rules | `auditctl -l` contains key `dhcp_lease` watching `/var/lib/kea/kea-leases4.csv` | [Step 4](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-4--auditd-dhcp-activity-rule) |
| AIDE integrity | Drop-in `99-zz-dhcp` present (0644); `aide --config-check` returns exit code 0 | [Step 5](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-5--aide-extend-baseline) |
| Broadcast DHCP discovery | `nmap --script broadcast-dhcp-discover` confirms DHCPOFFER with Server ID, Router, DNS, Domain, Subnet Mask, Lease Time, and Offered IP in pool | [Step 6](../../../../modules/dhcp/self-managed/dhcp-self-managed.md#step-6--end-to-end-verification) |

#### Why

- **End-to-End Verification via `nmap` Script:** Simulating a DHCP client using `nmap --script broadcast-dhcp-discover -e {{ vm_interface }}` sends a DHCPDISCOVER broadcast and captures the DHCPOFFER response directly from the VM host. This validates the full operational configuration (pool, router, DNS, domain name, lease time) in a single command without requiring an external physical client on the LAN.

---

## Full-Stack Orchestration (site.yml)

**Starting point:** The control node virtual environment is active, Ansible collections and toolchain dependencies are installed, and both target environments (EC2 and local VM) have completed the bootstrap phase (`playbooks/bootstrap.yml`) with dedicated administrator keys in place.

[`playbooks/site.yml`](ansible/playbooks/site.yml) provides a unified top-level orchestration playbook that executes all downstream service modules in dependency order across target inventory groups.

**Validation status:** Each individual module in this repository was validated live incrementally against running hosts (initial dry-run, execution, and second pass confirming idempotence with `changed=0`). `playbooks/site.yml` validates syntax and linting in CI and is used for full-stack convergence over already-deployed hosts. A full greenfield rebuild from scratch is discarded by architectural decision; initial deployment follows EC2 hub first, then local VM peer.

### Step 1 — Apply (Master Playbook Execution)

#### What was done

`playbooks/site.yml` composes the six automated modules in sequential dependency order using `import_playbook`:
1. `hardening.yml` (groups `vm:ec2`, tag `hardening`) — System, access, and logging baseline.
2. `file-transfer.yml` (groups `vm:ec2`, tags `file-transfer`, `file_transfer`) — Hardened SFTP chroot jail on port 22222.
3. `dns.yml` (group `dns_servers` / EC2 hub, tag `dns`) — Authoritative BIND9 DNS server for `lab.internal`.
4. `web-server.yml` (groups `vm:ec2`, tag `web-server`) — Nginx HTTPS reverse proxy with TLS certificates.
5. `directory.yml` (group `directory_servers` / EC2 hub, tag `directory`) — Samba 4 Active Directory Domain Controller.
6. `dhcp.yml` (group `dhcp_servers` / local VM, tag `dhcp`) — Kea DHCPv4 service for local LAN.

Each playbook retains its specific group targeting, allowing execution to be scoped to a single target host with `--limit` or to specific modules using module-scoped tags (`--tags <module>`).

To apply the complete stack or individual modules, run a dry-run first, execute the playbook, and run a second pass to confirm complete idempotence (`changed=0`):

**Control node (Mac):**

```bash
# Execute dry-run across all modules on both targets
ansible-playbook playbooks/site.yml --check --diff --ask-become-pass

# Execute full-stack convergence across all modules
ansible-playbook playbooks/site.yml --ask-become-pass

# Execute second run to confirm convergence
ansible-playbook playbooks/site.yml --ask-become-pass
# → second run: changed=0
```

Targeting individual hosts or specific modules:

**Control node (Mac):**

```bash
# Target only the EC2 hub host
ansible-playbook playbooks/site.yml --limit multi-lab-vps --ask-become-pass

# Target only the local VM peer
ansible-playbook playbooks/site.yml --limit multi-lab-local --ask-become-pass

# Target a specific module across applicable hosts
ansible-playbook playbooks/site.yml --tags web-server --ask-become-pass
```

#### Why

While `site.yml` orchestrates all module playbooks for ongoing maintenance and convergence, initial host deployment requires executing several deliberate gates and out-of-band prerequisites by design:

- **Separate Bootstrap (`playbooks/bootstrap.yml`):** Initial bootstrapping connects over port 22 using the default or installer account (`connection_mode: "pre"`). It cannot run inside `site.yml` because once the hardening baseline executes, port 22 and default logins are permanently disabled. See [Hardening Step 1](#step-1--baseline-preparation-manual-steps-02--tag-hardening_2a).
- **Phased Connection Mode Transitions (`pre` → `hardened` → `wg`):** Transitioning connection modes requires human verification between access phases (verifying key-based access before disabling password logins; verifying the WireGuard VPN tunnel before closing public SSH ports). Running transitions unattended would risk permanent lockout if a handshake fails. See [Control Node — Environment Setup](#control-node--environment-setup) and [Hardening Step 2](#step-2--access-chain-manual-steps-36--tag-hardening_2b).
- **Out-of-Band Cloud Infrastructure (Security Groups & SSM):** AWS Security Groups, VPC routes, and IAM instance profiles are managed declaratively in Terraform or AWS Console. Ansible operates exclusively within the guest OS and does not create cloud perimeter resources. See [Terraform — Infrastructure Provisioning](#terraform--infrastructure-provisioning).
- **WireGuard Asymmetric Key Exchange:** Private keys are generated locally on each host and never leave the system. Public keys must be exchanged between the EC2 hub (`multi-lab-vps.yml`) and peers (`multi-lab-local.yml`) out-of-band before the tunnel can establish. See [Hardening Step 2](#step-2--access-chain-manual-steps-36--tag-hardening_2b).
- **WireGuard Client DNS Configuration on VM (`hardening_wg_client_dns`):** On the local VM, `hardening_wg_client_dns` must be explicitly configured to `"172.16.0.1"` in `inventories/host_vars/multi-lab-local.yml` before running `site.yml` a second time (or during full convergence). Because `wg-quick` registers the DNS server with a routing domain `~.` on `wg0`, all VM queries are routed over the tunnel. If left at the default Quad9 (`9.9.9.9`), the queries cannot reach Quad9 across the tunnel (`172.16.0.0/24`), leaving the VM without working DNS resolution. See [DNS Step 1](#dns--bind9-authoritative-service).
- **Interactive Password Prompts (`vars_prompt`):** Administrative passwords for the system admin (`bootstrap.yml`) and Samba Active Directory Administrator (`directory.yml`) are prompted interactively and hashed in memory. They are never stored in plaintext in version control or host variable files. See [Directory Step 1](#step-1--apply-tag-directory).
- **Controlled Reboots for Immutable Audit Rules (`*_auditd_reboot`):** The hardening baseline locks the kernel audit subsystem in immutable mode (`-e 2`). New audit drop-ins (`file-transfer`, `dns`, `web-server`, `directory`) require a kernel reboot to take effect on EC2 (`*_auditd_reboot: true`). Automated reboots temporarily drop the active WireGuard tunnel, requiring tunnel verification before resuming. See [Hardening Step 3](#step-3--system-hardening-manual-steps-712--tag-hardening_2c).
- **Public Domain & Route 53 Delegation Prerequisite:** Let's Encrypt requires public DNS resolution for the registered domain (`buildyourinfra.click`). The public hosted zone and registrar delegation are configured once as an account-level prerequisite outside Ansible. See [Web Server Step 1](#step-1--apply-tag-web-server).
- **Let's Encrypt Rate Limits:** Automated certificate issuance enforces `web_server_certbot_staging: true` during initial testing to avoid hitting ACME production rate limits before production cutover. See [Web Server Step 1](#step-1--apply-tag-web-server).
- **SMB2 Protocol Omission:** Samba 4.19.5 on Ubuntu 24.04 ARM64 has an upstream bug preventing SMB2 file-sharing service startup in AD DC mode. AD authentication, Kerberos, LDAP, and RPC operate normally; SMB2 file sharing is excluded as an accepted deviation. See [Directory Step 1](#step-1--apply-tag-directory).
- **Client-Side Configuration Steps:** Workstation-specific settings (SFTP client alias in `~/.ssh/config`, WireGuard peer DNS forwarding, joining client machines to the Active Directory domain) run outside the control node playbook and are applied on the operator's machine. See [File Transfer Step 2](#step-2--verify-tag-file_transfer_verify) and [Directory Step 2](#step-2--verify-tag-directory_verify).

#### Verification

Verify service status directly on target hosts:

**EC2 · multi-lab-vps:**

```bash
# Check WireGuard hub interface
sudo wg show wg0
# → interface: wg0 ...

# Check BIND9 DNS service
sudo systemctl is-active named
# → active

# Check Nginx HTTPS service
sudo systemctl is-active nginx
# → active

# Check Samba AD DC service
sudo systemctl is-active samba-ad-dc
# → active
```

**VM · multi-lab-local:**

```bash
# Check WireGuard client interface
sudo wg show wg0
# → interface: wg0 ...

# Check Kea DHCPv4 service
sudo systemctl is-active kea-dhcp4-server
# → active
```

---

### Step 2 — Verify (Tags `*_verify`)

#### What was done

Run the dedicated verification test suites for each module across the infrastructure stack using the module-specific verification tags. Each verification playbook must report `changed=0 failed=0`:

**Control node (Mac):**

```bash
# Verify Hardening baseline convergence
ansible-playbook playbooks/hardening.yml --ask-become-pass
# → changed=0 failed=0

# Verify SFTP service assertions across both targets
ansible-playbook playbooks/site.yml --tags file_transfer_verify --ask-become-pass
# → changed=0 failed=0

# Verify Authoritative BIND9 DNS server assertions on EC2
ansible-playbook playbooks/site.yml --tags dns_verify --ask-become-pass
# → changed=0 failed=0

# Verify Nginx HTTPS and reverse proxy assertions across both targets
ansible-playbook playbooks/site.yml --tags web-server_verify --ask-become-pass
# → changed=0 failed=0

# Verify Samba 4 Active Directory Domain Controller assertions on EC2
ansible-playbook playbooks/site.yml --tags directory_verify --ask-become-pass
# → changed=0 failed=0

# Verify Kea DHCPv4 service assertions on local VM
ansible-playbook playbooks/site.yml --tags dhcp_verify --ask-become-pass
# → changed=0 failed=0
```

Summary of assertions validated across the full-stack suite:

| Check | Expected | Manual verification |
| --- | --- | --- |
| Hardening (`hardening`) | SSH port 22222, UFW rules, WireGuard tunnel, sysctl kernel parameters, AIDE baseline, Lynis score (≥88 VM, ≥90 EC2), Audit status = enabled 2 | [Hardening Step 4](#step-4--verification-and-convergence) |
| SFTP (`file_transfer_verify`) | `sftpuser` with `nologin`, chroot ownership (`root:root 0755`), uploads permissions (`0750`), `internal-sftp` Match User rules, auditd watch | [File Transfer Step 2](#step-2--verify-tag-file_transfer_verify) |
| DNS (`dns_verify`) | `named` active, `named-checkconf -z` clean, UDP/TCP 53 on `wg0`, forward/reverse zone lookups, system resolver on `127.0.0.1`, auditd watch | [DNS Step 2](#step-2--verify-tag-dns_verify) |
| Web Server (`web-server_verify`) | Nginx service active, TLS certificate valid, HTTP to HTTPS redirect, reverse proxy 502 upstream response, auditd watch | [Web Server Step 2](#step-2--verify-tag-web-server_verify) |
| Directory (`directory_verify`) | `samba-ad-dc` active, domain level 2016, Kerberos ticket via `kinit`, LDAP SRV query, AD listening ports (53, 88, 389, 445), auditd watch | [Directory Step 2](#step-2--verify-tag-directory_verify) |
| DHCP (`dhcp_verify`) | `kea-dhcp4-server` active, `kea-dhcp4 -t` syntax clean, UDP port 67 bound, lease CSV exists, broadcast DHCP discovery response | [DHCP Step 2](#step-2--verify-tag-dhcp_verify) |

#### Why

- **Independent Module Verification:** Dedicated `*_verify` tags allow operators to validate the operational health and security assertions of any individual module without re-applying configuration changes or restarting daemons.
- **End-to-End State Assurance:** Running the verification suite across all modules guarantees that downstream service configurations have not introduced drift, broken firewall rules, or degraded the baseline security controls established by earlier playbooks.

---

## Teardown — Destroy All Lab Resources

When testing and experimentation conclude, all infrastructure and cloud resources created across both paths must be destroyed to eliminate recurring cloud billing.

### Billable Resources Inventory

The following resources generate ongoing costs or represent external dependencies:

- **Self-Managed Stack (Terraform):**
  - **EC2 Instance (`multi-lab-aws`):** Compute charges for the t4g.micro Graviton2 instance.
  - **EBS Root Volume:** 20 GiB gp3 block device ($0.08/GB-month = ~$1.60/month). Accrues cost continuously even when the instance is stopped.
  - **Public IPv4 Address / Elastic IP (`multi-lab-eip`):** Incurs $0.005/hr (~$3.60/month) continuously since February 2024, regardless of whether attached to a running instance, stopped instance, or unallocated.
  - **VPC & Network Perimeter:** `multi-lab-vpc`, public subnet `multi-lab-vpc-subnet-public1-eu-west-1a`, Internet Gateway `multi-lab-vpc-igw`, Route Table `multi-lab-vpc-rtb-public`, Security Group `multi-lab-sg`, and IAM instance profile/role `multi-lab-ec2-role`. (No ongoing direct charges for standard VPC/IAM, but network dependencies prevent clean account teardown if orphaned).
  - **Route 53 A-Record:** Managed dynamically when `route53_zone_name` is set in `terraform.tfvars`. `terraform destroy` removes this record automatically.
- **External Prerequisites (Out-of-Band / Route 53):**
  - **Route 53 Public Hosted Zone:** $0.50/month (unprorated flat fee per hosted zone per month). Not created or deleted by the self-managed Terraform stack.
  - **Registered Domain Name (`buildyourinfra.click`):** Annual registrar registration and renewal fee. Non-refundable once registered.
- **AWS Native Stack (Optional Deployment):**
  - **AWS Directory Service (Managed Microsoft AD):** $0.10/hr (~$72/month) continuous billing from creation.
  - **AWS Transfer Family Server:** $0.30/hr (~$216/month) continuous billing from creation, plus associated Elastic IP ($0.005/hr).
  - **Persistent & Baseline Resources:** S3 storage buckets (`multi-lab-web-origin-*`, `multi-lab-transfer-*`, `multi-lab-cloudtrail-*`), CloudFront distribution (`multi-lab-cf`), CloudWatch log groups (`/aws/vpc/multi-lab-vpc`), Route 53 Private Hosted Zone ($0.50/month), GuardDuty detector, and SNS topic (`multi-lab-ad-alerts`).

---

### Step 1 — Destroy (Infrastructure Teardown & Local Cleanup)

#### What was done

Follow the destruction procedure in order:

##### 1. Self-Managed Cloud Stack Teardown (Terraform)

Destroy the EC2 instance, Elastic IP, EBS volume, and perimeter resources managed by the self-managed Terraform configuration.

**CLI — Run on control node (Mac):**

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform

# Execute terraform destroy using existing terraform.tfvars
terraform destroy

# → Plan: 0 to add, 0 to change, 11 to destroy
# → Destroy complete! Resources: 11 destroyed.
```

> **Note:** `terraform destroy` reads `terraform.tfvars` for required parameters (`ami_id`, `instance_type`, `key_name`). CIDR variables default to closed (`""`), avoiding exposing any ports during the destroy cycle. Destroying the stack deletes the managed Route 53 A record pointing to the Elastic IP, but leaves the public hosted zone intact.

**Console Alternative:**
1. **EC2 Console (`eu-west-1`):** Navigate to **Instances** → Select `multi-lab-aws` → **Instance state** → **Terminate instance**.
2. **Elastic IPs:** Navigate to **Network & Security** → **Elastic IPs** → Select `multi-lab-eip` → **Actions** → **Release Elastic IP addresses**.
3. **VPC Console:** Navigate to **Your VPCs** → Select `multi-lab-vpc` → **Actions** → **Delete VPC** (automatically deletes subnets, IGW, and route tables).
4. **Security Groups & IAM:** Delete security group `multi-lab-sg` and IAM role `multi-lab-ec2-role` in their respective consoles.

##### 2. Route 53 Hosted Zone & Domain Retention (Optional)

Decide whether to retain or decommission the public domain:
- **Retain:** If you plan to redeploy the lab or use the domain for other projects, keep the public hosted zone ($0.50/month) and leave domain auto-renewal active.
- **Decommission:** To achieve $0.00/month recurring cost, delete all custom DNS records (keeping only apex NS and SOA records), delete the hosted zone, and disable domain auto-renewal.

**CLI — Run on control node (Mac):**

```bash
# Locate the public hosted zone ID by exact domain name
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "buildyourinfra.click." \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='buildyourinfra.click.'].Id" \
  --output text | cut -d'/' -f3)

# Delete the public hosted zone (only after custom records are removed)
aws route53 delete-hosted-zone \
  --id "$ZONE_ID" \
  --profile multi-lab-admin

# Disable annual auto-renewal for the registered domain (us-east-1 endpoint)
aws route53domains disable-domain-auto-renew \
  --domain-name "buildyourinfra.click" \
  --region us-east-1 \
  --profile multi-lab-admin
```

> [!CAUTION]
> Always query the hosted zone by exact domain name (`--dns-name "buildyourinfra.click."`). Never delete unrelated hosted zones in the AWS account. Domain registrations are non-refundable; disabling auto-renewal ensures the domain simply lapses at the end of its paid registration period without new charges.

**Console Alternative:**
1. **Route 53 Console:** Navigate to **Hosted zones** → Select `buildyourinfra.click` → Delete all non-default records → Click **Delete zone**.
2. **Registered domains:** Navigate to **Registered domains** → Select `buildyourinfra.click` → Under **Auto-renew**, click **Disable**.

##### 3. AWS Native Stack Teardown (If Deployed)

If the `aws-native` stack was provisioned, destroy resources in reverse order of deployment to respect inter-module dependencies:

**CLI — Run on control node (Mac):**

```bash
# If using the full-stack orchestration composition:
cd ~/build-your-infra/stacks/full-infra/aws-native/automation/terraform
terraform destroy -auto-approve

# Alternatively, if deployed module-by-module, destroy in reverse dependency order:
# 1. Directory (Managed AD - stops $0.10/hr charges):
cd ~/build-your-infra/modules/directory/aws-native/automation/terraform && terraform destroy -auto-approve

# 2. Web Server (CloudFront & S3 origin):
cd ~/build-your-infra/modules/web-server/aws-native/automation/terraform && terraform destroy -auto-approve

# 3. File Transfer (Transfer Family - stops $0.30/hr charges & Transfer EIP):
cd ~/build-your-infra/modules/file-transfer/aws-native/automation/terraform && terraform destroy -auto-approve

# 4. DNS (Private Hosted Zone & Resolver Logging):
cd ~/build-your-infra/modules/dns/aws-native/automation/terraform && terraform destroy -auto-approve

# 5. Hardening (VPC, Subnets, GuardDuty, CloudTrail, Flow Logs):
cd ~/build-your-infra/modules/hardening/aws-native/automation/terraform && terraform destroy -auto-approve
```

See individual module automation guides for specific module teardown documentation: [`hardening-aws-native-automation.md`](../../../../modules/hardening/aws-native/automation/hardening-aws-native-automation.md), [`dns-aws-native-automation.md`](../../../../modules/dns/aws-native/automation/dns-aws-native-automation.md), [`file-transfer-aws-native-automation.md`](../../../../modules/file-transfer/aws-native/automation/file-transfer-aws-native-automation.md), [`web-server-aws-native-automation.md`](../../../../modules/web-server/aws-native/automation/web-server-aws-native-automation.md), and [`directory-aws-native-automation.md`](../../../../modules/directory/aws-native/automation/directory-aws-native-automation.md).

##### 4. Local Workstation Cleanup (Zero Cost)

Clean up local state and keys on the operator workstation:

**Control node (Mac):**

```bash
# Tear down local WireGuard VPN interface
sudo wg-quick down wg0

# Remove stale host keys from ~/.ssh/known_hosts
ssh-keygen -R 172.16.0.1
ssh-keygen -R 172.16.0.3
ssh-keygen -R <ec2_eip>
ssh-keygen -R <vm_lan_ip>
```

**Local Hypervisor (VMware Fusion / VirtualBox):**
- Shut down the `multi-lab-local` virtual machine.
- Delete all local snapshots and remove the VM from disk to reclaim local storage.

#### Why

AWS charges compute per second, public IPv4 addresses per hour, and EBS storage continuously. Managed AD and Transfer Family generate high hourly costs ($0.10/hr and $0.30/hr). A systematic, ordered teardown guarantees no orphaned dependencies prevent resource destruction, eliminates all billing, and returns the cloud account to a clean baseline.

---

### Step 2 — Verify (Cloud Billing & Resource Verification)

#### What was done

Execute explicit AWS CLI verification checks against `eu-west-1` using the `multi-lab-admin` profile to confirm that zero billable infrastructure remains active:

**Control node (Mac):**

```bash
# 1. Verify no running or stopped EC2 instances remain:
aws ec2 describe-instances \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --filters "Name=tag:Name,Values=multi-lab-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key=='Name'].Value|[0]]" \
  --output table
# → empty

# 2. Verify no EBS storage volumes remain:
aws ec2 describe-volumes \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --filters "Name=tag:Name,Values=multi-lab-*" \
  --query "Volumes[*].[VolumeId,State,Size]" \
  --output table
# → empty

# 3. Verify no Elastic IPs / public IPv4 allocations remain:
aws ec2 describe-addresses \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --filters "Name=tag:Name,Values=multi-lab-*" \
  --query "Addresses[*].[PublicIp,AllocationId,AssociationId]" \
  --output table
# → empty

# 4. Verify VPC has been deleted:
aws ec2 describe-vpcs \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --filters "Name=tag:Name,Values=multi-lab-*" \
  --query "Vpcs[*].[VpcId,CidrBlock]" \
  --output table
# → empty

# 5. Verify no NAT Gateways remain:
aws ec2 describe-nat-gateways \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[*].[NatGatewayId,State]" \
  --output table
# → empty

# 6. Verify Transfer Family server is deleted (aws-native):
aws transfer list-servers \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --query "Servers[*].[ServerId,State]" \
  --output table
# → empty

# 7. Verify Managed AD directory is deleted (aws-native):
aws ds describe-directories \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --query "DirectoryDescriptions[?Name=='multi-lab.internal'].[DirectoryId,Stage]" \
  --output table
# → empty

# 8. Check Route 53 public hosted zone status (exact query):
aws route53 list-hosted-zones-by-name \
  --dns-name "buildyourinfra.click." \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='buildyourinfra.click.'].[Id,Name]" \
  --output table
# → empty (if decommissioned) or 1 entry (if retained)
```

##### Billing & Cost Explorer Audit

AWS Billing and Cost Explorer data updates with a 24-hour reporting latency.
To confirm complete cessation of billing:
1. Log in to the **AWS Management Console**.
2. Navigate to **Billing and Cost Management** → **Cost Explorer**.
3. Set the date range to include the day after teardown, group by **Usage type** or **Service**, and inspect daily unblended costs.
4. Daily costs must drop to **$0.00** (or ~$0.016/day if only the Route 53 public hosted zone is retained).

#### Why

AWS CLI validation queries verify state directly from AWS API endpoints, eliminating the possibility of orphaned resources caused by aborted scripts, forgotten manual test resources, or partial Terraform runs. Performing a Cost Explorer audit 24 hours later provides independent billing confirmation directly from AWS financial metering.
