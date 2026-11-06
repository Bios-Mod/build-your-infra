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
> - The 20 GiB gp3 volume keeps accruing cost while the instance is stopped, and the Elastic IP is charged (~$0.005/hr) unless attached to a running instance. Run `terraform destroy` when finished.

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

> [!WARNING]
> Never switch to `hardened` before `sshd` is running on port 22222. Never switch to `wg` before `ping 172.16.0.1` or `ssh -p 22222 <admin_username>@172.16.0.1` works from the Mac.

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

> [!WARNING]
> The admin account and its key must work before the SSH hardening step. If not, you are locked out once password login and the default user are disabled.

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

> The auditd rule (manual Step 5) and the client `~/.ssh/config` alias (manual Step 7) are not part of the role. The auditd rule stays manual because `99-hardening.rules` ends with `-e 2`; the client alias lives on your Mac.

First, point each host to the existing public key. Add this line to `inventories/host_vars/multi-lab-vps.yml` and to `inventories/host_vars/multi-lab-local.yml` (there is no default):

```yaml
file_transfer_sftp_public_key_file: "~/.ssh/id_ed25519_sftp.pub"
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

The `dns` role reproduces on EC2 (`dns_servers`) the state that the manual module leaves behind: BIND9 packages and checking utilities installed, `named.conf.options` restricting recursion and queries to `lab-net`, forward and reverse zone database files in `/etc/bind/zones/`, `named.conf.local` referencing the zones, full configuration checked with `named-checkconf -z`, `named` service enabled and started, UFW rules allowing UDP and TCP port 53 on `wg0`, AIDE drop-in `/etc/aide/aide.conf.d/97-dns`, and Netplan overlay `/etc/netplan/51-dns-lab.yaml` pointing the system resolver to `127.0.0.1` with the VPC resolver (`10.0.0.2`) as fallback.

Ensure `connection_mode: "wg"` is set in `inventories/host_vars/multi-lab-vps.yml`. With the WireGuard tunnel up, run the three commands in order on the EC2 hub: a dry run to review the diff, the real apply, and a second apply that must report `changed=0`.

**Control node (Mac):**

```bash
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --check --diff --ask-become-pass
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --ask-become-pass
ansible-playbook playbooks/dns.yml --limit multi-lab-vps --ask-become-pass
# → second run: changed=0
```

Following the playbook run, complete the manual steps outside Ansible:

**EC2 · multi-lab-vps:**

Append the auditd monitoring rule for BIND9 configuration and zone directories (manual Step 5):

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules < ~/build-your-infra/modules/dns/self-managed/configs/audit/99-hardening.rules
sudo augenrules --load
sudo systemctl restart auditd
```

> Hardening locks auditd in immutable mode (`-e 2`) and clears rules with `-D`. If auditd fails to restart due to immutable mode, reboot the EC2 instance (`sudo reboot now`) to load the new rule.

**VM · multi-lab-local:**

Configure WireGuard client DNS resolution to point to the EC2 DNS server (`172.16.0.1`):

> [!WARNING]
> Execute these commands over the local VM LAN connection, not through the WireGuard tunnel itself. Restarting `wg-quick@wg0` temporarily drops tunnel traffic. If the hardening Step 5 task is subsequently re-run on the VM, it restores the default Quad9 DNS in `wg0.conf`, requiring this manual step to be repeated.

```bash
sudo sed -i 's/^DNS\s*=.*/DNS = 172.16.0.1/' /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
```

**Control node (Mac):**

For macOS WireGuard DNS behavior and optional fallback configuration, follow [manual Step 7](../../../../modules/dns/self-managed/dns-self-managed.md#step-7--point-system-resolver-to-bind9).

#### Why

- **Configs as single source of truth:** the role copies files directly from `modules/dns/self-managed/configs/` without altering repo configs or manual documentation text. The configuration files take precedence over descriptive documentation.
- **Ordering (named before Netplan):** Netplan overlay `51-dns-lab.yaml` configures systemd-resolved to prioritize `127.0.0.1`. BIND9 must be fully running and validated (`named-checkconf -z`) before Netplan is applied to prevent local resolution failures.
- **Dedicated AIDE drop-in:** hardening owns `/etc/aide/aide.conf.d/99-hardening`. The role deploys `/etc/aide/aide.conf.d/97-dns` as an independent drop-in and regenerates the database only if the drop-in changes.
- **Manual auditd rule:** `-D` (flush rules) and `-e 2` (immutable mode) in `99-hardening.rules` prevent dynamic drop-in rule insertion at runtime without a kernel restart.
- **Manual peer DNS configuration:** the `hardening` role owns `/etc/wireguard/wg0.conf` on peers and would overwrite external changes during subsequent hardening runs.
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
| AIDE integrity | Drop-in `97-dns` monitors `/etc/bind` and excludes `/var/cache/bind` | [Step 6](../../../../modules/dns/self-managed/dns-self-managed.md#step-6--aide-extend-baseline) |

Test resolution from the WireGuard peer over the tunnel:

**VM · multi-lab-local:**

```bash
dig @172.16.0.1 vps.lab.internal +short
# → 172.16.0.1

dig google.com +short
# → <valid IP>
```
