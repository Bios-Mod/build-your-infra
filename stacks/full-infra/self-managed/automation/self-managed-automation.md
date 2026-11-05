# Self-Managed Stack — Automation

## Introduction

This document defines the automated provisioning and configuration workflow for the self-managed infrastructure stack. The automation architecture separates concerns into two distinct, decoupled lifecycle phases:

1. **Infrastructure Provisioning (Terraform):** Declaratively provisions the AWS cloud perimeter (VPC, public subnet, internet gateway, route table, security group, Elastic IP, and EC2 instance profile) and launches an Ubuntu Server 24.04 LTS ARM64 instance on AWS EC2.
2. **Operating System & Service Configuration (Ansible):** Enforces a defense-in-depth security baseline, configures network tunnels, manages identities, and deploys workload daemons across both cloud and virtualized environments from a single unified codebase.

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
│ • Control Node Toolchain: pinned ansible-core, venv, Galaxy collections│
│ • Baseline Preparation (manual Steps 0–2): admin user, updates, Netplan│
│ • Access Chain (manual Steps 3–6): SSH port 22222, UFW, WireGuard, F2B │
│ • System Hardening (manual Steps 7–12): sysctl, AppArmor, auditd, Lynis│
└────────────────────────────────────────────────────────────────────────┘
```

### Target Environments & Deployment Sequence

The self-managed stack targets two independent execution environments. Because WireGuard uses an asymmetric hub-and-spoke topology where EC2 acts as the central VPN hub (`172.16.0.1`), **EC2 must be deployed and hardened first**, followed by the local VM as a spoke peer (`172.16.0.3`):

| Target | Inventory Alias | Ansible `--limit` | Host Variables File | Role & Topology |
|---|---|---|---|---|
| AWS EC2 Self-Managed | `multi-lab-vps` | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | WireGuard Hub (`172.16.0.1`). Public cloud anchor. Deployed first. |
| Local VM (Hypervisor) | `multi-lab-local` | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | WireGuard Peer (`172.16.0.3`). Private LAN spoke. Deployed second. |

### How to Read This Document

Execution is organized into modular sections with local step numbers (maximum 4 steps per section):
- **Command Tables:** Standard operations share unified execution tables with explicit target limits and host variable paths (`Target | --limit | host_vars | Command | Expected Output`). Code blocks are only separated when commands or configurations genuinely diverge between platforms (such as WireGuard key exchange or SSH credential injection).
- **Execution Context:** Every terminal block indicates its exact execution target and host (`EC2 · multi-lab-vps · Run on control node`, `VM · multi-lab-local · Run on control node`).
- **Connection Mode Lifecycle:** Target connectivity shifts across three modes (`pre` → `hardened` → `wg`), tracked explicitly in each host's variables file.
- **Verification:** Verification steps link directly to the corresponding verification procedures in [`hardening-self-managed.md`](../../../../modules/hardening/self-managed/hardening-self-managed.md) without duplicating raw verification commands.

### Module Automation Roadmap

| Module | Self-Managed Stack | Automation Status | Implementation Doc |
|---|---|---|---|
| **hardening** | OpenSSH · UFW · WireGuard · Fail2Ban · sysctl · AppArmor · auditd · Lynis | **Complete** | This document (Section: Hardening) |
| **file-transfer** | SFTP (`internal-sftp` subsystem with chroot jail) | Pending | Downstream implementation |
| **dns** | BIND9 authoritative private zone (`lab.internal`) | Pending | Downstream implementation |
| **web-server** | Nginx HTTPS reverse proxy + Certbot | Pending | Downstream implementation |
| **directory** | Samba 4 Active Directory Domain Controller | Pending | Downstream implementation |
| **dhcp** | Kea DHCP Server (local VM only) | Pending | Downstream implementation |

---

## Terraform — Infrastructure Provisioning

The Terraform configuration in `stacks/full-infra/self-managed/automation/terraform/` launches a clean, minimal AWS EC2 instance (t4g.micro Graviton2) running Ubuntu Server 24.04 LTS from the canonical AMI, attaching an Elastic IP and granting AWS Systems Manager (SSM) access.

> [!CAUTION]
> **Account Isolation & Billing:**
> - **Account Isolation Warning:** Do not deploy the `aws-native` hardening module in the same AWS account as the self-managed stack. Both stacks share identical global and regional resource names (`multi-lab-vpc`, `multi-lab-sg`, `multi-lab-ec2-role`), causing collision errors during resource creation.
> - **Billing Alert (EBS & Elastic IP):** The 20 GiB gp3 root volume persists and accrues cost even when the instance is stopped. The allocated Elastic IP is free only while associated with a running EC2 instance; stopped instances with associated Elastic IPs or unassociated Elastic IPs accrue hourly charges (~$0.005/hr). Release resources when no longer needed using `terraform destroy`.

### Step 1 — Provision EC2 Infrastructure

#### What was done
Configure input variables, initialize the Terraform working directory with pinned AWS provider `~> 6.50`, generate a plan, and apply the infrastructure.

Prerequisites:
- AWS CLI configured with profile `multi-lab-admin` in region `eu-west-1`.
- Terraform `>= 1.15.6`.
- Dedicated Ed25519 lab SSH key generated at `~/.ssh/id_ed25519_multi-lab`.

1. Query the latest official Canonical Ubuntu Server 24.04 LTS ARM64 AMI ID:

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

2. Activate the configuration files and initialize the working directory:

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
   cp main.tf.example main.tf
   cp outputs.tf.example outputs.tf
   cp terraform.tfvars.example terraform.tfvars

   terraform init
   ```

3. Set the discovered `ami_id` in `terraform.tfvars`. Generate the execution plan and apply the infrastructure, passing your current public IP via command-line variables to open temporary SSH bootstrap access (port 22) and hardened SSH access (port 22222) in the Security Group:

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

📄 [`main.tf.example`](terraform/main.tf.example)
📄 [`variables.tf`](terraform/variables.tf)
📄 [`terraform.tfvars.example`](terraform/terraform.tfvars.example)
📄 [`outputs.tf.example`](terraform/outputs.tf.example)

#### Why
A reproducible greenfield deployment allows provisioning the self-managed EC2 target on demand in any clean AWS account without importing pre-existing resources. The self-contained stack deploys the dedicated VPC (`10.0.0.0/16`), public subnet, route table, internet gateway, Elastic IP, and EC2 instance profile (`multi-lab-ec2-role`) with `AmazonSSMManagedInstanceCore` attached.

IMDSv2 is enforced at the instance layer (`http_tokens = "required"`, `http_put_response_hop_limit = 1`) to eliminate SSRF attack vectors against the metadata service. Dynamic ingress rules open ports 22 and 22222 restricted strictly to the operator's current public workstation IP (`/32`), preventing exposure to automated scanning bots before WireGuard is fully established.

---

### Step 2 — Verify Infrastructure Connectivity

#### What was done
Confirm that the instance is reachable over SSH and registered with AWS Systems Manager Session Manager.

#### Verification

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

The Ansible automation layer is executed from a dedicated Python virtual environment on the operator's macOS workstation.

### Step 1 — Prepare the Control Node Toolchain

#### What was done
Create an isolated Python environment, install the pinned dependencies and collections, create the real inventory files from their `.example` pairs, generate the dedicated lab SSH keypair, and install the public key on the installer user so Ansible can connect without a password.

> [!NOTE]
> **Python version:** verify your interpreter with `python3.14 --version` before creating the virtual environment. `ansible-core 2.21` supports Python 3.12 to 3.14 on the control node; Python 3.15 is incompatible and fails at startup with module import errors. If Python 3.14 is not installed, use an explicit `python3.12` or `python3.13` binary.

1. Navigate to the Ansible directory, create the virtualenv, and install dependencies:

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
   ```

2. Generate a dedicated Ed25519 lab SSH keypair (never use personal or GitHub keys):

   **Control node (Mac):**
   ```bash
   test -f ~/.ssh/id_ed25519_multi-lab || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_multi-lab -N "" -C "admin@multi-lab"
   ```

3. Install the public key on the local VM installer user:

   **Control node (Mac):**
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519_multi-lab.pub <vm_initial_user>@<vm_lan_ip>
   ```

#### SSH Client Configuration

In `~/.ssh/config`, add `IdentityFile ~/.ssh/id_ed25519_multi-lab` and `IdentitiesOnly yes` to the `Host multi-lab-local` and `Host multi-lab-vps` blocks:
```sshconfig
Host multi-lab-local
    IdentityFile ~/.ssh/id_ed25519_multi-lab
    IdentitiesOnly yes

Host multi-lab-vps
    IdentityFile ~/.ssh/id_ed25519_multi-lab
    IdentitiesOnly yes
```
Manual Step 3 hardening restricts authentication attempts to 3 (`MaxAuthTries 3`); without `IdentitiesOnly yes`, the SSH client presents all keys loaded in `ssh-agent`, which can exhaust allowed attempts and trigger a lockout before reaching the correct key. If the private key is protected with a passphrase, load it into your agent once per terminal session using `ssh-add ~/.ssh/id_ed25519_multi-lab`.

#### Inventory Host Variables

Configure the real host variables files created from their `.example` templates:

- **`inventories/host_vars/multi-lab-local.yml`:**
  - `vm_initial_user`: account created by the Ubuntu installer (used for pre-hardening connection).
  - `admin_username`: dedicated non-root administrator account name.
  - `vm_lan_ip`: current reachable IP on the local network.
  - `vm_interface`: network interface name identified via `ip link` (e.g. `enp2s0`).
  - `vm_static_ip`: target static IP with prefix (e.g. `192.168.1.50/24`).
  - `vm_gateway`: default gateway router IP (e.g. `192.168.1.1`).
  - `lan_trusted_cidr`: trusted local LAN subnet (e.g. `192.168.1.0/24`).
  - `admin_public_key_file`: `"~/.ssh/id_ed25519_multi-lab.pub"`.
  - `ansible_ssh_private_key_file`: `"~/.ssh/id_ed25519_multi-lab"`.
  - `connection_mode`: `"pre"`.

- **`inventories/host_vars/multi-lab-vps.yml`:**
  - `ec2_eip`: Elastic IP address from `terraform output instance_public_ip`.
  - `ec2_initial_user`: `"ubuntu"` (default cloud-init user on AWS AMI).
  - `admin_username`: dedicated administrator account name.
  - `admin_public_key_file`: `"~/.ssh/id_ed25519_multi-lab.pub"`.
  - `ansible_ssh_private_key_file`: `"~/.ssh/id_ed25519_multi-lab"`.
  - `lan_trusted_cidr`: `""` (empty on EC2; no local subnet is trusted directly).
  - `connection_mode`: `"pre"`.

The target connection IP is dynamically evaluated by group variables (`group_vars/vm.yml` and `group_vars/ec2.yml`) based on `connection_mode` (`vm_lan_ip` or `ec2_eip` during `pre`/`hardened`, and the WireGuard VPN IP during `wg`).

#### Connection States Lifecycle (`connection_mode`)

Host inventories track three progressive network connection states via `connection_mode`:

| Mode | Destination Port | SSH User | Target IP | When it applies |
|---|---|---|---|---|
| `pre` | `22` | Initial OS user (`vm_initial_user` on VM, `ubuntu` on EC2) | LAN IP (`vm_lan_ip`) or Elastic IP (`ec2_eip`) | Default state. Used during initial provisioning (`bootstrap.yml`) and pre-hardening tasks. |
| `hardened` | `22222` | Dedicated administrator (`admin_username`) | LAN IP (`vm_lan_ip`) or Elastic IP (`ec2_eip`) | Set in `host_vars/<host>.yml` after completing manual Step 3 (SSH Hardening), before WireGuard perimeter lockdown. |
| `wg` | `22222` | Dedicated administrator (`admin_username`) | WireGuard interface IP (`172.16.0.1` on EC2 hub, `172.16.0.3` on VM peer) | Set in `host_vars/<host>.yml` after manual Step 5 (WireGuard) is deployed and the VPN tunnel on the Mac control node is active. |

> [!WARNING]
> **Transition Timing:** Never switch to `connection_mode: "hardened"` until manual Step 3 has successfully reconfigured and restarted `sshd` on port 22222. Never switch to `connection_mode: "wg"` until the WireGuard tunnel on your control node (Mac) is up and you have confirmed end-to-end reachability to the VPN IP (`ping 172.16.0.1` or `ssh -p 22222 <admin_user>@172.16.0.1`).

📄 [`requirements.txt`](ansible/requirements.txt)
📄 [`requirements.yml`](ansible/requirements.yml)
📄 [`inventories/hosts.yml.example`](ansible/inventories/hosts.yml.example)
📄 [`inventories/host_vars/multi-lab-local.yml.example`](ansible/inventories/host_vars/multi-lab-local.yml.example)
📄 [`inventories/host_vars/multi-lab-vps.yml.example`](ansible/inventories/host_vars/multi-lab-vps.yml.example)

#### Why
`requirements.txt` and `requirements.yml` pin the exact versions of `ansible-core`, `ansible-lint` and the two collections, so every run — on the control node, on a delegated agent and in CI — uses the same toolchain. The virtual environment keeps those versions isolated from the system Python. The `passlib` package is included because the `password_hash` filter used in `bootstrap.yml` runs locally on the control node, and modern Python releases on macOS (Python >= 3.13) remove the standard library `crypt` module. `hosts.yml` and `host_vars/*.yml` contain real addresses and usernames, so they are gitignored; only the `.example` pairs are versioned. Ansible runs over SSH and cannot type a password, so key authentication on the installer user is required before the first connection.

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

#### Troubleshooting
- **Python 3.15 incompatibility:** `ansible-core 2.21` supports Python 3.12 to 3.14 on the control node. Python 3.15 is incompatible and fails at startup with module import errors. Use Python 3.14 to create `.venv`.
- **`passlib` requirement on modern macOS:** Python >= 3.13 removes the standard library `crypt` module. The `passlib` package is pinned in `requirements.txt` to enable the `password_hash('sha512', rounds=65536)` Jinja filter on the local macOS control node without depending on deprecated system C-bindings.
- **Host key changed after rebuilding a host:** remove the stale entry with `ssh-keygen -R <ip>` before reconnecting (`host_key_checking` is enforced).

---

## Hardening — Ansible Baseline

The hardening baseline automates the security layers from [`hardening-self-managed.md`](../../../../modules/hardening/self-managed/hardening-self-managed.md) across three progressive execution blocks.

---

### Step 1 — Baseline Preparation (manual Steps 0–2 · Tag `hardening_2a`)

#### What was done
Provision the dedicated non-root administrator account (`admin_username`), establish Ed25519 key authentication with sudo escalation, configure automated security updates via unattended-upgrades, and configure static networking on the local VM.

| Manual Step | Task File (`roles/hardening/tasks/`) | Tag | Ansible Implementation / Platform Delta |
|---|---|---|---|
| [Step 0 — Admin User Setup](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-0--admin-user-setup) | `step_00_admin_user.yml` | `hardening_step0` | Creates `admin_username` account. On EC2 (`is_cloud: true`), copies authorized key from `/home/ubuntu/.ssh/authorized_keys`. On VM (`not is_cloud`), deploys key from control node path `admin_public_key_file`. Admin password is provided via interactive prompt in `bootstrap.yml`. |
| [Step 1 — System Update & Security Upgrades](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-1--system-update--automated-security-upgrades) | `step_01_updates.yml` | `hardening_step1` | Runs APT full-upgrade, deploys `50unattended-upgrades` and `20auto-upgrades`, and enables weekly `debsums` integrity checks. |
| [Step 2 — Static IP Configuration](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-2--static-ip-configuration) | `step_02_static_ip.yml` | `hardening_step2` | **VM only (`when: not is_cloud`).** Deploys static Netplan configuration (`00-installer-config.yaml`) and systemd-networkd `no-dhcp.conf` drop-in. Skipped on EC2 (handled by VPC DHCP and Elastic IP). |

> [!WARNING]
> **Lockout Risk:**
> The `admin_username` user account and its authorized Ed25519 key must be fully provisioned and verified before proceeding to SSH hardening in Step 2. If the user account is misconfigured, permanent lockout will occur once password authentication and the default `ubuntu` user are disabled.

#### Execution Commands

Before running `bootstrap.yml` on EC2, establish initial SSH connectivity as `ubuntu` to accept the host key into `~/.ssh/known_hosts` (`ansible.cfg` enforces `host_key_checking = True`):

**Control node (Mac):**
```bash
ssh -i ~/.ssh/id_ed25519_multi-lab ubuntu@<ec2_eip>
# → Type 'yes' to accept host key fingerprint; then exit the session
exit
```

| Target | --limit | host_vars File | Command | Expected Output |
|---|---|---|---|---|
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/bootstrap.yml --limit multi-lab-vps` | First run: changed > 0; second run: changed=0 |
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2a --ask-become-pass` | First run: changed > 0; second run: changed=0 |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/bootstrap.yml --limit multi-lab-local --ask-become-pass` | Prompts for sudo and admin passwords; first run: changed > 0; second run: changed=0 |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2a --ask-become-pass` | First run: changed > 0; second run: changed=0 |

#### Why
Creating a dedicated, unprivileged administrative account before locking down SSH eliminates dependence on cloud vendor default users (`ubuntu`) and hypervisor installer accounts. Dynamic password hashing with SHA-512 (65,536 rounds) via `vars_prompt` guarantees that administrative secrets are never committed to git.

#### Verification

Test passwordless SSH authentication with the newly provisioned administrator account from a new terminal window:

**Control node (Mac):**
```bash
ssh -i ~/.ssh/id_ed25519_multi-lab -o IdentitiesOnly=yes -p 22 <admin_username>@<vm_lan_ip>
# → must authenticate without a password prompt
```

Verify account identity, group memberships, and directory permissions inside the SSH session on the VM:

**VM · multi-lab-local · Run on VM:**
```bash
id <admin_username>
# → uid=1001(<admin_username>) groups=...,27(sudo),4(adm)...

ls -la /home/<admin_username>/.ssh/
# → drwx------ .ssh            <admin_username>:<admin_username>
# → -rw------- authorized_keys <admin_username>:<admin_username>
```

On EC2, verify administrator account provisioning and key authentication from the control node:

**Control node (Mac):**
```bash
ssh -i ~/.ssh/id_ed25519_multi-lab <admin_username>@<ec2_eip>
# → authenticates without password prompt
```

---

### Step 2 — Access Chain & Network Perimeter (manual Steps 3–6 · Tag `hardening_2b`)

#### What was done
Lock down OpenSSH daemon configuration to port 22222, enforce default-deny firewall policies via UFW, establish an encrypted WireGuard VPN tunnel between control node, EC2 hub, and VM peer, and activate Fail2Ban intrusion prevention.

> [!CAUTION]
> **High Lockout Risk — Security Group Prerequisite:**
> - On EC2, the AWS Security Group `multi-lab-sg` **MUST** allow inbound traffic on port 22222 (`ssh_hardened_cidr`) and port 51820/udp **BEFORE** running manual Step 3 and switching `connection_mode: "hardened"`.
> - Do not close public rate-limited port 22222 on EC2 until WireGuard tunnel connectivity is verified from the control node.
> - Maintain an active terminal session to the target host throughout the execution of this step.

#### 2.1 SSH Hardening (manual Step 3)
- Deploys hardened `sshd_config` (port 22222, key-only authentication, root login disabled, idle timeout, max 3 authentication attempts, only `admin_username` permitted via `AllowUsers`).
- Removes legacy RSA and ECDSA host private and public keys (`/etc/ssh/ssh_host_rsa_key*`, `/etc/ssh/ssh_host_ecdsa_key*`), retaining exclusively the Ed25519 host key.
- **Connection Mode Transition:** Once task `step_03_ssh.yml` completes, update `connection_mode: "hardened"` in the target host's variables file (`inventories/host_vars/multi-lab-vps.yml` for EC2 in Phase A; `inventories/host_vars/multi-lab-local.yml` for VM in Phase B) before invoking subsequent tasks.

#### 2.2 UFW Firewall (manual Step 4)
- Configures default-deny incoming and default-allow outgoing policies.
- Temporarily opens rate-limited port 22222 on all interfaces (`limit 22222/tcp`) so management access is preserved while configuring WireGuard (skipped when `hardening_wg_close_public_ssh: true` on EC2 to avoid rule flapping with Step 5).
- Enables medium firewall logging.

#### 2.3 WireGuard VPN (manual Step 5)
- **Topology:** EC2 acts as the public WireGuard VPN hub (`172.16.0.1:51820`), macOS control node acts as client peer `172.16.0.2`, and local VM acts as client peer `172.16.0.3`.
- **Key Management:** Target hosts generate their own private keys in `/etc/wireguard/server_private.key` (mode 0600) via `creates:`. Peer public keys are declared in host inventory variables (`wireguard_peer_public_keys`).
- **Public Port Closure Policy:**
  - **EC2:** Once the WireGuard tunnel is established and verified, set `hardening_wg_close_public_ssh: true` in `inventories/host_vars/multi-lab-vps.yml` and re-run tag `hardening_step5` to delete `limit 22222/tcp` from UFW. In Terraform, clear `ssh_bootstrap_cidr = ""` and `ssh_hardened_cidr = ""` to close ports 22 and 22222 in the AWS Security Group.
  - **Local VM:** Does not expose public ports to the Internet. The VM keeps `limit 22222/tcp` open on its local hypervisor LAN (`hardening_wg_close_public_ssh: false`) as a recovery backdoor.
- **Connection Mode Transition:** Update `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml` (connecting to `172.16.0.1:22222`) and `inventories/host_vars/multi-lab-local.yml` (connecting to `172.16.0.3:22222`).

#### 2.4 Fail2Ban (manual Step 6)
- Configures aggressive bantime (24 hours for general filters, 48 hours for SSH).
- Enforces `banaction = ufw`.
- Configures `ignoreip` to whitelist `127.0.0.1/8 ::1` and the WireGuard VPN subnet `172.16.0.0/24` (plus LAN subnet on local VM).

#### Safe Sequence & Progression Protocol

Execute the exact validated sequences below to transition from public SSH to the WireGuard perimeter without lockout risk.

##### Phase A — EC2 Hub Deployment

**Pre-WireGuard Access Chain:**

1. Apply manual Step 3 (SSH Hardening) on EC2 using initial credentials (`connection_mode: "pre"` on port 22):

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step3 --ask-become-pass
   ```

2. Update `inventories/host_vars/multi-lab-vps.yml`: set `connection_mode: "hardened"`.

3. Apply manual Step 4 (UFW Firewall) on EC2 using hardened SSH (`connection_mode: "hardened"` on port 22222):

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step4 --ask-become-pass
   ```

**WireGuard Hub Deployment (6 Validated Steps):**

1. **Obtain Mac Public Key Before Initial Run:**
   Retrieve the public key of your Mac control node.
   - If using the WireGuard macOS App: open the tunnel, click **Edit**, and copy the **Public key**.
   - If using CLI (`wireguard-tools`):
     ```bash
     awk '/PrivateKey/ {print $3}' /etc/wireguard/wg0.conf | wg pubkey
     ```
   - If no key pair exists yet on the Mac, generate one:
     ```bash
     wg genkey | tee mac_private.key | wg pubkey > mac_public.key
     ```
   Configure the 44-character public key in `inventories/host_vars/multi-lab-vps.yml`:
   ```yaml
   wireguard_peer_public_keys:
     mac: "<mac-public-key>"
     local_vm: "CHANGE_ME_LOCAL_VM_WIREGUARD_PUBLIC_KEY"
   ```
   Ansible enforces an assertion verifying that `mac` exists, contains no placeholder text (`CHANGE_ME`, `<`), and is valid 44-character base64 before deploying the hub.

2. **Deploy Step 5 on EC2 Hub (without `--check`):**
   Run the playbook with `hardening_wg_close_public_ssh: false` (the default). Execute without `--check` on initial deployment so the server key pair is generated on disk:

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass
   ```
   Copy the displayed WireGuard Public Key from the Ansible output:
   `# → WireGuard Public Key for multi-lab-vps: <hub-public-key>`

3. **Configure Mac WireGuard Tunnel:**
   In your Mac WireGuard configuration (`/etc/wireguard/wg0.conf` or macOS App), retain the existing `[Interface]` section (or populate from `configs/wireguard/client-template.conf` with `Address = 172.16.0.2/32`). Update ONLY the `[Peer]` section with the hub parameters:
   ```ini
   [Peer]
   PublicKey           = <hub-public-key>
   Endpoint            = <ec2_eip>:51820
   AllowedIPs          = 172.16.0.0/24
   PersistentKeepalive = 25
   ```
   > ⚠️ **Security Rule:** Never copy or paste a PrivateKey. Each host generates and stores its private key locally; only public keys are shared.

4. **Activate Tunnel and Verify Connectivity:**
   Start the tunnel on the Mac and verify the handshake, ICMP ping, and SSH over VPN:

   **Control node (Mac):**
   ```bash
   sudo wg-quick up wg0
   sudo wg show
   # → latest handshake: a few seconds ago, transfer: ...
   ping -c 3 172.16.0.1
   ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@172.16.0.1
   # → connects successfully over the encrypted VPN interface
   ```

5. **Close Public SSH on UFW and AWS Security Group:**
   With tunnel connectivity verified, set `hardening_wg_close_public_ssh: true` in `inventories/host_vars/multi-lab-vps.yml` and re-run Step 5 to delete the public rate-limited port 22222 rule from UFW:

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass
   ```
   Then update the AWS Security Group `multi-lab-sg` via Terraform with empty CIDR variables to close ports 22 and 22222 publicly:

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
   terraform apply -var "ssh_bootstrap_cidr=" -var "ssh_hardened_cidr="
   ```

6. **Switch Connection Mode in Inventory & Apply Fail2Ban:**
   Update `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml`. From this point forward, Ansible connects exclusively via `172.16.0.1:22222`. Apply Fail2Ban (manual Step 6):

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step6 --ask-become-pass
   ```

##### Phase B — Local VM Spoke Deployment

The local VM acts as a VPN client (`172.16.0.3/32`), routing into the EC2 hub:

1. **Prerequisite:** The EC2 hub is fully deployed and the Mac WireGuard tunnel is active.
2. **Retrieve Hub Public Key:** Read `/etc/wireguard/server_public.key` on EC2 (public keys only; never transfer private keys):

   **EC2 · multi-lab-vps · Run on EC2:**
   ```bash
   sudo cat /etc/wireguard/server_public.key
   # → <hub-public-key>
   ```

3. **Configure VM Host Variables:** In `inventories/host_vars/multi-lab-local.yml`, configure `wireguard_hub_public_key: "<hub-public-key>"` and `wireguard_endpoint: "<ec2_eip>:51820"`. The `wireguard_endpoint` variable is required and must explicitly specify EC2's public Elastic IP and port (`<ec2_eip>:51820`); never use the VM's own LAN IP.

4. **Apply SSH Hardening & UFW on VM:**
   Apply manual Step 3 (SSH Hardening) on VM using initial credentials (`connection_mode: "pre"` on port 22):

   **VM · multi-lab-local · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step3 --ask-become-pass
   ```

   Update `inventories/host_vars/multi-lab-local.yml`: set `connection_mode: "hardened"` (port 22222, `admin_username`).

   Apply manual Step 4 (UFW Firewall) on VM using hardened SSH (`connection_mode: "hardened"` on port 22222):

   **VM · multi-lab-local · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step4 --ask-become-pass
   ```

5. **Deploy Client Configuration on VM:**
   Run Step 5 without `--check` on initial run so the VM keypair is generated:

   **VM · multi-lab-local · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step5 --ask-become-pass
   # → WireGuard Public Key for multi-lab-local: <vm-public-key>
   ```

6. **Register VM Peer on EC2 Hub:** Copy `<vm-public-key>` into `wireguard_peer_public_keys.local_vm` in `inventories/host_vars/multi-lab-vps.yml` and re-run Step 5 on EC2.

   > ⚠️ **Transient Connection Notice:** The handler restarts `wg-quick@wg0` on the hub, which may momentarily disrupt the active Ansible session going through that tunnel. If an `UNREACHABLE` error occurs at the very end of task execution, check connectivity with `ping -c 3 172.16.0.1` and use SSM Session Manager if inspection is needed.

   **EC2 · multi-lab-vps · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass
   ```

7. **Verify VM Tunnel & Connectivity:**

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
   # → connects successfully over WireGuard tunnel
   ```

8. **Switch Connection Mode in Inventory & Apply Fail2Ban:**
   Set `connection_mode: "wg"` in `inventories/host_vars/multi-lab-local.yml`. Note: the VM keeps the rate-limited port 22222 rule over LAN (`hardening_wg_close_public_ssh: false`; decision 2026-11-04); there is no public closure step or Security Group update for the VM. Apply Fail2Ban (manual Step 6):

   **VM · multi-lab-local · Run on control node:**
   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step6 --ask-become-pass
   ```

#### Why
Restricting OpenSSH to port 22222 over an encrypted WireGuard tunnel shields administrative access from port scanning and brute-force bots on the public Internet. Using `banaction = ufw` ensures malicious IPs are dropped at the packet filter level before hitting daemon sockets.

#### Troubleshooting — WireGuard & Perimeter
- **`meta: reset_connection` ignores `when` in ansible-core 2.21:** the role runs it only through `include_tasks` guarded by `connection_mode == 'pre'`. Before this fix, every pass reset the SSH connection and the next task using `become` failed with 'Timeout waiting for privilege escalation prompt'.
- **`Key is not the correct length or format`:** WireGuard public keys must be exactly 32 bytes encoded in base64 (44 characters ending with `=`). This error occurs when example placeholder text (such as `CHANGE_ME_...`) is left in `host_vars` or copied into `wg0.conf`. The role pre-flight assertion prevents deployment if the key is invalid.
- **Absence of Handshake (`latest handshake` missing in `wg show`):**
  - Verify AWS Security Group: port `51820/udp` must be allowed from `0.0.0.0/0` in `multi-lab-sg`.
  - Check for crossed keys: the client `[Peer] PublicKey` must equal the hub public key, and the hub `[Peer] PublicKey` must equal the client public key.
  - Check service logs: run `sudo journalctl -xeu wg-quick@wg0` on the hub to identify syntax or interface errors.
- **SSM Session Manager as Emergency Recovery Path:** If SSH connectivity is interrupted on EC2, start an AWS Systems Manager session to inspect and recover network access without open inbound ports:
  ```bash
  aws ssm start-session --target <instance_id> --profile multi-lab-admin
  ```

---

### Step 3 — System Hardening & Compliance (manual Steps 7–12 · Tag `hardening_2c`)

#### What was done
Deploy remaining defense-in-depth layers across kernel, filesystem, application, audit, and log subsystems:

| Manual Step | Task File (`roles/hardening/tasks/`) | Tag | Ansible Implementation / Platform Delta |
|---|---|---|---|
| [Step 7 — Kernel Hardening (sysctl)](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-7--kernel-hardening-sysctl) | `step_07_sysctl.yml` | `hardening_step7` | Deploys `99-z-hardening.conf` to guarantee lexicographically last evaluation over package defaults like `99-protect-links.conf`. Configures ASLR, restrict dmesg/kptr, disable source routing, and enable SYN cookies. |
| [Step 8 — AppArmor](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-8--apparmor) | `step_08_apparmor.yml` | `hardening_step8` | Installs `apparmor-utils` and `apparmor-profiles`. Ubuntu loads installed profiles automatically in enforce mode. |
| [Step 9.1 — Services & Daemons](../../../../modules/hardening/self-managed/hardening-self-managed.md#91--services--daemons) | `step_09_1_services.yml` | `hardening_step9_1` | Disables and stops ModemManager, masks packagekit and udisks2, and purges apport packages (reloading sysctl to re-assert `fs.suid_dumpable = 0`). On EC2 (`is_cloud: true`), cleanly stops `snap.amazon-ssm-agent.amazon-ssm-agent.service` and `snapd.service` before removing snap IPC sockets, installs the official deb package of `amazon-ssm-agent`, purges `snapd`, removes `/var/lib/snapd`, and holds `snapd` via `dpkg_selections`. |
| [Step 9.2 — Filesystem & Users](../../../../modules/hardening/self-managed/hardening-self-managed.md#92--filesystem--user-hardening) | `step_09_2_users_fs.yml` | `hardening_step9_2` | Sets restrictive permissions on crontab (`0600`) and sudoers.d (`0750`). Deploys PAM `common-password` (SHA-512 with 65,536 rounds, pwquality minimum 12 chars), `common-session` (pam_tmpdir), and `/etc/security/limits.conf` (disables core dumps). Configures UMASK 027 in `/etc/login.defs`. Note: `chage -E` is intentionally omitted to preserve administrative access (suppressing Lynis AUTH-9282). |
| [Step 9.3 — Kernel Modules](../../../../modules/hardening/self-managed/hardening-self-managed.md#93--kernel-modules) | `step_09_3_modprobe.yml` | `hardening_step9_3` | Deploys `disable-unused-protocols.conf` to `/etc/modprobe.d/` blacklisting obsolete network protocols (`dccp`, `sctp`, `rds`, `tipc`), and regenerates initramfs. |
| [Step 9.4 — Monitoring & Forensics](../../../../modules/hardening/self-managed/hardening-self-managed.md#94--monitoring--forensics) | `step_09_4_monitoring.yml` | `hardening_step9_4` | Installs and enables `rkhunter`, `acct` (process accounting), and `sysstat`. `rkhunter --update` returns exit code 2 when it updates data files; the task accepts 0, 1 and 2 and fails on 'Update failed'. `--propupd` runs only when the package or its configuration changed in that run. |
| [Step 10 — Audit Trail (auditd + AIDE)](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-10--audit-trail-auditd--aide) | `step_10_audit.yml` | `hardening_step10` | Deploys comprehensive audit rules (`99-hardening.rules`) with a guaranteed trailing newline. Adapts syscall rules for ARM64 ABI (`unlinkat`, `renameat`, `renameat2`). Initializes AIDE integrity database idempotently (`creates: /var/lib/aide/aide.db`). Enforces immutable mode (`-e 2`) on EC2 and clean convergence runs. |
| [Step 11 — Log Management](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-11--log-management-rsyslog--logrotate) | `step_11_logging.yml` | `hardening_step11` | Configures rsyslog routing for UFW (`20-ufw.conf`) and security logs (`99-hardening.conf`), enforcing `0640 syslog:adm` permissions. Configures logrotate policies (`hardening-logs`). |
| [Step 12 — Security Audit Baseline](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-12--security-audit-baseline-lynis) | `step_12_lynis.yml` | `hardening_step12` | Deploys custom Lynis profile (`custom.prf`). Executes compliance scan, registers Hardening Index score, and emits an advisory warning if score drops below threshold (`hardening_lynis_min_score`, 90 EC2, 88 VM) without halting execution. |

#### Operational Notes
1. **Secondary SSH Session:** Open a separate, persistent SSH session to the target host before applying Step 3 to safeguard against PAM `common-session` or `common-password` locking errors.
2. **Password Re-encryption:** After deploying PAM configurations, execute `passwd` manually on the target machine to re-hash the existing administrator password in `/etc/shadow` with 65,536 rounds. `chage -E` is intentionally omitted to prevent account expiration lockouts.
3. **Auditd Immutable Mode & Precedence:** `hardening_auditd_immutable_mode` defaults to `true` in `defaults/main.yml`. In `group_vars/vm.yml`, it is set to `false` during incremental development so rules can be reloaded without rebooting. For the from-scratch convergence rebuild, `hardening_auditd_immutable_mode: true` is configured in `inventories/host_vars/multi-lab-local.yml`, where host variables take precedence over group variables.

#### Unified Execution Commands

Run Block 2C across both environments using `connection_mode: "wg"`:

| Target | --limit | host_vars File | Command | Expected Output |
|---|---|---|---|---|
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --check --diff --ask-become-pass` | Inspect diff; verify 0 errors |
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --ask-become-pass` | First run: changed > 0 |
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --ask-become-pass` | changed=0 (idempotence gate) |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --check --diff --ask-become-pass` | Inspect diff; verify 0 errors |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --ask-become-pass` | First run: changed > 0 |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --ask-become-pass` | changed=0 (idempotence gate) |

#### Why
Naming sysctl configuration `99-z-hardening.conf` guarantees that security parameters take precedence over operating system defaults loaded earlier in lexicographical order. Removing snapd on EC2 closes attack surfaces while migrating `amazon-ssm-agent` to native deb packages preserves out-of-band management.

#### Verified Troubleshooting — System Hardening
- **Snapd state in memory:** Removing `/var/lib/snapd` while `snapd.service` is active causes `dpkg` pre-installation scripts to fail. Task `step_09_1_services.yml` explicitly stops `snap.amazon-ssm-agent.amazon-ssm-agent.service` and `snapd.service` before cleaning disk state and installing the `.deb`.
- **Rkhunter update return code 2:** `rkhunter --update` returns exit code 2 when it updates data files; the task in `step_09_4_monitoring.yml` accepts 0, 1 and 2 and fails only on 'Update failed'. `--propupd` has no relation to that code — it runs only when the package or its configuration changed in that run to record file properties.
- **Auditd trailing newline:** Without a trailing newline, `augenrules --load` fails with `Enable must be 0, 1, or 2 was 2##` because `augenrules` concatenates rule files and appends `##` on the same line. Task `step_10_audit.yml` forces an explicit single trailing newline on `99-hardening.rules`.
- **APT lock timeout:** Unattended-upgrades holds `/var/lib/dpkg/lock-frontend` for several minutes after system startup. Playbooks declare `module_defaults` with `ansible.builtin.apt: { lock_timeout: 600 }`.

---

### Step 4 — Verification & Convergence

#### What was done
Execute post-deployment compliance checks, confirm target score thresholds, verify idempotency (0 changed), and review platform deviations.

#### Target Compliance Thresholds

| Inspection Item | AWS EC2 (`multi-lab-vps`) | Local VM (`multi-lab-local`) | Verification Link |
|---|---|---|---|
| **Lynis Hardening Index** | ≥ **90** | ≥ **88** | [Lynis Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-12--security-audit-baseline-lynis) |
| **Audit Subsystem Status** | `enabled 2` (immutable mode active) | `enabled 1` (dev) / `enabled 2` (clean convergence) | [Auditd Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-10--audit-trail-auditd--aide) |
| **Connection Mode** | `wg` (`172.16.0.1:22222`) | `wg` (`172.16.0.3:22222`) | `inventories/host_vars/<host>.yml` |
| **OpenSSH Port & Access** | Port `22222`, key-only, non-root `admin_username` | Port `22222`, key-only, non-root `admin_username` | [SSH Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-3--ssh-hardening) |
| **UFW Status** | `active`, default deny incoming, rate-limit | `active`, default deny incoming, rate-limit | [UFW Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-4--ufw-firewall) |
| **WireGuard Interface** | `wg0` active, handshake recorded | `wg0` active, handshake recorded | [WireGuard Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-5--wireguard-vpn) |
| **Fail2Ban Jail** | `sshd` active, banaction `ufw` | `sshd` active, banaction `ufw` | [Fail2Ban Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-6--fail2ban) |
| **Kernel Sysctl** | `99-z-hardening.conf` applied | `99-z-hardening.conf` applied | [Sysctl Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-7--kernel-hardening-sysctl) |
| **AppArmor Profiles** | Profiles loaded, no denied boot errors | Profiles loaded, no denied boot errors | [AppArmor Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-8--apparmor) |
| **Service Attack Surface** | `snapd` purged, `apport` purged | `snapd` purged, `apport` purged | [Services Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#91--services--daemons) |
| **Filesystem & Users** | umask 027, SHA-512 rounds 65536 | umask 027, SHA-512 rounds 65536 | [Filesystem Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#92--filesystem--user-hardening) |
| **Kernel Modprobe** | Unused protocols disabled | Unused protocols disabled | [Kernel Modules Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#93--kernel-modules) |
| **System Monitoring** | `acct` & `sysstat` active | `acct` & `sysstat` active | [Monitoring Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#94--monitoring--forensics) |
| **System Logging** | Dedicated `ufw.log`, permissions `0640` | Dedicated `ufw.log`, permissions `0640` | [Logging Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-11--log-management-rsyslog--logrotate) |

#### Full Idempotency Gate (0 Changed)

Execute the full hardening playbook separately per target (administrative sudo passwords may differ between EC2 and VM). With the documented exception of `/var/log/fail2ban.log` (which may report `changed=1` if rotated by logrotate), execution must complete with **changed=0**:

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

#### Known Deviations & Pending Checks
1. **`/var/log/fail2ban.log` ownership:** The file is created initially with `syslog:adm` ownership in Step 11 (`step_11_logging.yml`). However, the Fail2Ban daemon writes directly as `root`, and logrotate (`configs/logrotate/hardening-logs`) specifies `create 640 root adm`. If logrotate rotates the file between runs, the task in Step 11 reports `changed=1` to restore `syslog:adm` ownership.
2. **VM Block 2B Gate Idempotency:** The 'Timeout waiting for privilege escalation prompt' encountered during Block 2B was caused by `meta: reset_connection` executing unconditionally on every pass in ansible-core 2.21, resetting the SSH connection right before UFW privilege escalation. This was resolved by isolating the transition in `step_03_ssh_transition.yml` via conditional `include_tasks`. Live idempotency verification (full Block 2B gate with `changed=0` across both targets) will be confirmed following this fix, while the from-scratch rebuild is deferred to Phase 9.
3. **WireGuard Client Endpoint Trap:** In the local VM client configuration, `wireguard_endpoint` must explicitly point to the public Elastic IP and port of the EC2 hub (`<ec2_eip>:51820`). It must be declared in `inventories/host_vars/multi-lab-local.yml` and must never default to the VM's own LAN IP, which previously prevented handshake completion.
4. **UFW Port 22222 Flapping Prevention:** In `step_04_ufw.yml`, the task that allows rate-limited incoming connections on port 22222 is guarded by `when: not hardening_wg_close_public_ssh`. This prevents the rule from being recreated on Step 4 and deleted on Step 5 on every run in EC2 when public SSH closure is active.

---

## Appendix A — Legacy Operations (Historical Reference)

> [!NOTE]
> This section documents the legacy Phase 1 workflow for importing pre-existing AWS resources into Terraform state and redeploying from custom AMI snapshots. It is preserved strictly as an architectural reference and is **not used** during standard greenfield provisioning.

### Legacy Import Workflow

In the original Phase 1 architecture, resources were provisioned manually in the AWS Management Console and subsequently adopted into Terraform management:

1. **Collect Resource IDs:** Query existing AWS resources (VPC, Subnet, IGW, Route Table, Security Group, EC2 instance, Elastic IP) via AWS CLI.
2. **Configure Import Blocks:** Populate `import.tf` from `import.tf.example` with gathered resource IDs.
3. **Generate Configuration:** Execute `terraform plan -generate-config-out=generated.tf` to generate initial resource HCL.
4. **Fix `generated.tf` Before Applying (Expected Errors):**
   The experimental config generator creates conflicting or incomplete attributes that the AWS provider rejects. Edit `generated.tf` manually before proceeding:

   **Lines to delete:**

   | Resource | Remove this line | Why |
   |---|---|---|
   | `aws_subnet.public` | `availability_zone_id = ...` | Conflicts with `availability_zone` |
   | `aws_subnet.public` | `enable_lni_at_device_index = 0` | Invalid outside AWS Outposts |
   | `aws_subnet.public` | `map_customer_owned_ip_on_launch = ...` | Requires `outpost_arn` — not applicable |
   | `aws_vpc.main` | `ipv6_ipam_pool_id = ...` | Requires `ipv6_netmask_length` — remove both |
   | `aws_vpc.main` | `ipv6_netmask_length = ...` | Remove if not using IPv6 IPAM |
   | `aws_instance.main` | `primary_network_interface { ... }` block | Conflicts with `associate_public_ip_address` |
   | `aws_instance.main` | `ipv6_address_count = ...` | Conflicts with `ipv6_addresses` — remove both |
   | `aws_instance.main` | `ipv6_addresses = ...` | Remove both if not using IPv6 |
   | `aws_eip_association.main` | `network_interface_id = ...` | Conflicts with `instance_id` — keep `instance_id` |

   **Line to add:**

   In `aws_key_pair.main`, add `public_key = ""` (required by provider schema, not applied during import):
   ```hcl
   resource "aws_key_pair" "main" {
     # ... generated attributes ...
     public_key = "" # Required by provider schema — not applied during import
   }
   ```

   **Add missing resource block:**

   The generator fails to produce `aws_route_table_association` because the import ID is not a standard resource ID. Add manually to `generated.tf`:
   ```hcl
   resource "aws_route_table_association" "public" {
     subnet_id      = "subnet-XXXXXXXXXX"   # your subnet ID
     route_table_id = "rtb-XXXXXXXXXX"      # your route table ID
   }
   ```

   **Fix `aws_route_table.public`:**

   The generator produces `route = []`, ignoring existing routes, and generates incorrect tag values. Replace with the correct block:
   ```hcl
   resource "aws_route_table" "public" {
     propagating_vgws = []
     region           = "eu-west-1"
     route = [{
       cidr_block                 = "0.0.0.0/0"
       gateway_id                 = "igw-XXXXXXXXXX"   # your IGW ID
       carrier_gateway_id         = null
       core_network_arn           = null
       destination_prefix_list_id = null
       egress_only_gateway_id     = null
       instance_id                = null
       ipv6_cidr_block            = null
       local_gateway_id           = null
       nat_gateway_id             = null
       network_interface_id       = null
       odb_network_arn            = null
       transit_gateway_id         = null
       vpc_endpoint_id            = null
       vpc_peering_connection_id  = null
     }]
     tags = {
       Name = "multi-lab-vpc-rtb-public"
     }
     tags_all = {
       Name = "multi-lab-vpc-rtb-public"
     }
     vpc_id = "vpc-XXXXXXXXXX"   # your VPC ID
   }
   ```

5. **Apply Import & Finalize:** Execute `terraform plan` (verify `Plan: 10 to import, 0 to add, 0 to change, 0 to destroy`) and `terraform apply` to absorb resources into `terraform.tfstate`. Delete `import.tf` and activate `main.tf`.

### Legacy AMI Redeployment

The Phase 2 prototype redeployed instances from a pre-hardened custom AMI (`multi-lab-aws-active-directory`). This was replaced by greenfield provisioning from canonical Ubuntu 24.04 LTS ARM64 AMIs (Step 1) combined with Ansible configuration management, providing full end-to-end reproducibility from code.
