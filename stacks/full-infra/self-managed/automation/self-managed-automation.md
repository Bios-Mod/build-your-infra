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
│ • Baseline Preparation (Steps 0–2): admin user, unattended-upgrades    │
│ • Access Chain (Steps 3–6): SSH port 22222, UFW, WireGuard, Fail2Ban  │
│ • System Hardening (Steps 7–12): sysctl, AppArmor, auditd, Lynis ≥ 90  │
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
- **Command Tables:** Standard operations share unified execution tables with explicit target limits and host variable paths (`Target | --limit | host_vars | Command | Expected`). Code blocks are only separated when commands or configurations genuinely diverge between platforms (such as WireGuard key exchange or SSH credential injection).
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
> - Run all Terraform operations inside a dedicated, isolated AWS lab account (`multi-lab-admin` profile).
> - Running an EC2 instance with an attached Elastic IP and gp3 root EBS volume incurs AWS charges. Terminate resources when the lab session is complete using `terraform destroy`.

### Step 1 — Provision EC2 Infrastructure

#### What was done
Configure input variables, initialize the Terraform working directory with pinned AWS provider `~> 6.50`, generate a plan, and apply the infrastructure.

1. Navigate to the terraform directory:
   ```bash
   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
   ```
2. Create `terraform.tfvars` from `terraform.tfvars.example`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
3. Locate the latest canonical Ubuntu 24.04 LTS ARM64 AMI in `eu-west-1` and configure `terraform.tfvars`:
   ```bash
   aws ec2 describe-images \
     --region eu-west-1 \
     --owners 099720109477 \
     --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
               "Name=state,Values=available" \
     --query "sort_by(Images, &CreationDate)[-1].[ImageId, Name]" \
     --output text
   # → ami-0xxxxxxxxxxxxxxxxx  ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-...
   ```
4. Edit `terraform.tfvars` to set your control node public IPv4 CIDR (`X.X.X.X/32`) in `ssh_bootstrap_cidr` (port 22) and `ssh_hardened_cidr` (port 22222):
   ```hcl
   aws_region         = "eu-west-1"
   aws_profile        = "multi-lab-admin"
   instance_type      = "t4g.micro"
   ami_id             = "ami-0xxxxxxxxxxxxxxxxx" # Canonical Ubuntu 24.04 ARM64 AMI
   key_name           = "multi-lab-key"
   ssh_bootstrap_cidr = "YOUR_PUBLIC_IP/32"      # Required for initial port 22 access
   ssh_hardened_cidr  = "YOUR_PUBLIC_IP/32"      # Required for port 22222 access during Step 3
   ```
5. Initialize provider plugins and apply the infrastructure:
   ```bash
   terraform init
   terraform apply
   ```

#### Why
The greenfield provisioning pattern deploys base cloud infrastructure without relying on pre-baked or unversioned AMIs. Setting `ssh_bootstrap_cidr` restricts port 22 access strictly to the operator's IP, while the IAM role `multi-lab-ec2-role` ensures out-of-band SSM Session Manager access remains available if network credentials fail.

---

### Step 2 — Verify Infrastructure Connectivity

#### What was done
Extract the allocated Elastic IP and instance ID from Terraform outputs, verify direct SSH access as the default `ubuntu` user, and confirm AWS Systems Manager connectivity.

#### Verification

```bash
# Retrieve instance outputs
terraform output
# → instance_id = "i-0xxxxxxxxxxxxxxxxx"
# → instance_public_ip = "X.X.X.X"
```

Verify SSH connectivity using the operator key:
```bash
ssh -i ~/.ssh/multi-lab-key ubuntu@$(terraform output -raw instance_public_ip) "uname -m"
# → aarch64
```

Verify SSM Session Manager status via AWS CLI:
```bash
aws ssm get-connection-status \
  --region eu-west-1 \
  --target $(terraform output -raw instance_id) \
  --query "Status" \
  --output text
# → Connected
```

---

## Control Node — Environment Setup

The Ansible automation layer is executed from a dedicated Python virtual environment on the operator's macOS workstation.

### Step 1 — Prepare the Control Node Toolchain

#### What was done
Create an isolated virtual environment with Python 3.12–3.14, install pinned requirements, install pinned Galaxy collections, configure inventory variables, and verify end-to-end connectivity.

1. Navigate to the Ansible directory:
   ```bash
   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/ansible
   ```
2. Create and activate a Python virtual environment:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   ```
3. Install pinned Python dependencies:
   ```bash
   pip install --upgrade pip
   pip install -r requirements.txt
   ```
4. Install external collections pinned in `requirements.yml`:
   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```
5. Set up inventory host variables from templates:
   ```bash
   cp inventories/hosts.yml.example inventories/hosts.yml
   cp inventories/host_vars/multi-lab-vps.yml.example inventories/host_vars/multi-lab-vps.yml
   cp inventories/host_vars/multi-lab-local.yml.example inventories/host_vars/multi-lab-local.yml
   ```
6. Update `inventories/host_vars/multi-lab-vps.yml`:
   - Set `ansible_host` to the Terraform Elastic IP (`X.X.X.X`).
   - Set `connection_mode: "pre"` (port 22, user `ubuntu`).
   - Set `ansible_ssh_private_key_file` to `~/.ssh/multi-lab-key`.
7. Update `inventories/host_vars/multi-lab-local.yml`:
   - Set `ansible_host` to the local VM IP (`192.168.1.X`).
   - Set `connection_mode: "pre"` (port 22, installer user).
   - Set `vm_interface`, `vm_static_ip`, and `vm_gateway`.
8. Ensure the administrator Ed25519 keypair exists on the control node:
   ```bash
   test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "admin@multi-lab"
   ```

#### Connection Mode Lifecycle

The variable `connection_mode` in each host's `host_vars` file controls how Ansible connects to the target machine:

| Mode | Port | User | Transport | Applicable Lifecycle Stage |
|---|---|---|---|---|
| `pre` | `22` | `initial_user` (`ubuntu` on EC2, installer user on VM) | Direct IPv4 (Elastic IP or LAN IP) | Initial bootstrap (Step 0) and system updates (Step 1) |
| `hardened` | `22222` | `admin` | Direct IPv4 (SG port 22222 allowed on EC2) | Post-SSH hardening (Step 3) through UFW (Step 4) |
| `wg` | `22222` | `admin` | WireGuard VPN (`172.16.0.1` on EC2, `172.16.0.3` on VM) | Post-WireGuard lockdown (Step 5) and permanent operations |

#### Toolchain Pre-flight & Connectivity Test

Run the ping playbook to validate environment assertions and SSH connectivity:
```bash
ansible-playbook playbooks/ping.yml
```
```
# Expected output:
# → TASK [Assert control node toolchain environment] : ok
# → TASK [Ping target hosts] : multi-lab-vps : ok=2, multi-lab-local : ok=2
```

#### Why
Pinning Python versions (3.12–3.14) and `ansible-core==2.21.6` prevents control node discrepancies. On macOS, Homebrew Python 3.15 removes the legacy `crypt` module required by passlib for dynamic password hashing, and Ansible versions newer than 2.21.6 alter CLI flag parsing.

#### Troubleshooting — Control Node Issues
- **Python 3.15 Homebrew conflict:** If `ansible --version` shows Python 3.15, deactivate and verify the virtualenv was created with Python 3.14 (`python3.14 -m venv .venv`).
- **Passlib password hash failure:** Ensure `passlib==1.7.4` is installed inside `.venv`. Do not run playbooks outside the virtual environment.

---

## Hardening — Ansible Baseline

The hardening baseline automates the 13 security layers from [`hardening-self-managed.md`](../../../../modules/hardening/self-managed/hardening-self-managed.md) across three progressive execution blocks.

---

### Step 1 — Baseline Preparation (Manual Steps 0–2 · Tag `hardening_2a`)

#### What was done
Provision the dedicated non-root administrator account (`admin`), establish Ed25519 key authentication with sudo escalation, configure automated security updates via unattended-upgrades, and configure static networking on the local VM.

| Manual Step | Task File (`roles/hardening/tasks/`) | Tag | Ansible Implementation / Platform Delta |
|---|---|---|---|
| [Step 0 — Admin User Setup](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-0--admin-user-setup) | `step_00_admin_user.yml` | `hardening_step0` | Creates `admin` user. On EC2 (`is_cloud: true`), copies authorized key from `/home/ubuntu/.ssh/authorized_keys`. On VM (`not is_cloud`), deploys key from control node path `admin_public_key_file`. Admin password is provided via interactive prompt in `bootstrap.yml`. |
| [Step 1 — System Update & Security Upgrades](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-1--system-update--automated-security-upgrades) | `step_01_updates.yml` | `hardening_step1` | Runs APT full-upgrade, deploys `50unattended-upgrades` and `20auto-upgrades`, and enables weekly `debsums` integrity checks. |
| [Step 2 — Static IP Configuration](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-2--static-ip-configuration) | `step_02_static_ip.yml` | `hardening_step2` | **VM only (`when: not is_cloud`).** Deploys static Netplan configuration (`00-installer-config.yaml`) and systemd-networkd `no-dhcp.conf` drop-in. Skipped on EC2 (handled by VPC DHCP and Elastic IP). |

> [!WARNING]
> **Lockout Risk:**
> The `admin` user account and its authorized Ed25519 key must be fully provisioned and tested before proceeding to SSH hardening in Step 2. If the user account is misconfigured, permanent lockout will occur once password authentication and the default `ubuntu` user are disabled.

#### Execution Commands

1. **Bootstrap Admin User (Hardening Step 0):**
   Execute `bootstrap.yml` using `connection_mode: "pre"` (port 22):

   | Target | --limit | host_vars File | Command | Expected Output |
   |---|---|---|---|---|
   | EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/bootstrap.yml --limit multi-lab-vps` | `multi-lab-vps : ok=4 changed=1` |
   | VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/bootstrap.yml --limit multi-lab-local --ask-become-pass` | `multi-lab-local : ok=4 changed=1` |

2. **Apply Baseline Updates & Static IP (Steps 1–2):**
   Execute `hardening.yml` with tag `hardening_2a`:

   | Target | --limit | host_vars File | Command | Expected Output |
   |---|---|---|---|---|
   | EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2a --ask-become-pass` | `changed=2` (first run) / `changed=0` (second run) |
   | VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2a --ask-become-pass` | `changed=3` (first run) / `changed=0` (second run) |

#### Why
Creating a dedicated, unprivileged administrative account before locking down SSH eliminates dependence on cloud vendor default users (`ubuntu`) and hypervisor installer accounts. Dynamic password hashing with SHA-512 (65,536 rounds) via `vars_prompt` guarantees that administrative secrets are never committed to git.

---

### Step 2 — Access Chain & Network Perimeter (Manual Steps 3–6 · Tag `hardening_2b`)

#### What was done
Lock down OpenSSH daemon configuration to port 22222, enforce default-deny firewall policies via UFW, establish an encrypted WireGuard VPN tunnel between control node, EC2 hub, and VM peer, and activate Fail2Ban intrusion prevention.

> [!CAUTION]
> **High Lockout Risk — Security Group Prerequisite:**
> - On EC2, the AWS Security Group `multi-lab-sg` **MUST** allow inbound traffic on port 22222 (`ssh_hardened_cidr`) **BEFORE** running Step 3 and switching `connection_mode: "hardened"`.
> - Do not close public rate-limited port 22222 on EC2 until WireGuard tunnel connectivity is verified from the control node.
> - Maintain an active terminal session to the target host throughout the execution of this step.

#### 2.1 SSH Hardening (Manual Step 3)
- Deploys hardened `sshd_config` (port 22222, key-only authentication, root login disabled, idle timeout, max 3 authentication attempts, only `admin` permitted).
- Generates hardened Ed25519 host key and purges obsolete RSA, ECDSA, and DSA host keys.
- **Connection Mode Transition:** Once task `step_03_ssh.yml` completes, update `connection_mode: "hardened"` in `inventories/host_vars/multi-lab-vps.yml` (or `inventories/host_vars/multi-lab-local.yml`) before invoking subsequent tasks.

#### 2.2 UFW Firewall (Manual Step 4)
- Configures default-deny incoming and default-allow outgoing policies.
- Temporarily opens rate-limited port 22222 on all interfaces (`limit 22222/tcp`) so management access is preserved while configuring WireGuard.
- Enables medium firewall logging.

#### 2.3 WireGuard VPN (Manual Step 5)
- **Topology:** EC2 acts as the public WireGuard VPN hub (`172.16.0.1:51820`), macOS control node acts as client peer `172.16.0.2`, and local VM acts as client peer `172.16.0.3`.
- **Key Management:** Target hosts generate their own private keys in `/etc/wireguard/server_private.key` (mode 0600) via `creates:`. Peer public keys are declared in host inventory variables (`wireguard_peer_public_keys`).
- **Public Port Closure Policy:**
  - **EC2:** Once the WireGuard tunnel is established and verified, set `hardening_wg_close_public_ssh: true` in `inventories/host_vars/multi-lab-vps.yml` and re-run tag `hardening_step5` to delete `limit 22222/tcp` from UFW. In Terraform, clear `ssh_hardened_cidr = ""` to close port 22222 in the AWS Security Group.
  - **Local VM:** Does not expose public ports to the Internet. The VM keeps `limit 22222/tcp` open on its local hypervisor LAN as a recovery backdoor.
- **Connection Mode Transition:** Update `connection_mode: "wg"` in `inventories/host_vars/multi-lab-vps.yml` (connecting to `172.16.0.1:22222`) and `inventories/host_vars/multi-lab-local.yml` (connecting to `172.16.0.3:22222`).

#### 2.4 Fail2Ban (Manual Step 6)
- Configures aggressive bantime (24 hours for general filters, 48 hours for SSH).
- Enforces `banaction = ufw`.
- Configures `ignoreip` to whitelist `127.0.0.1/8 ::1` and the WireGuard VPN subnet `172.16.0.0/24` (plus LAN subnet on local VM).

#### Execution Sequence & Commands

Because EC2 serves as the WireGuard hub, the access chain is executed sequentially: **EC2 first, then VM**.

##### Phase A — EC2 Hub Deployment

**EC2 · multi-lab-vps · Run on control node:**
```bash
# 1. Apply Step 3 (SSH Hardening) on EC2 using connection_mode: "pre" (port 22)
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step3 --ask-become-pass

# 2. Update inventories/host_vars/multi-lab-vps.yml:
#    Change connection_mode: "hardened"

# 3. Apply Step 4 (UFW Firewall) on EC2 using connection_mode: "hardened" (port 22222)
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step4 --ask-become-pass

# 4. Generate local client WireGuard keypair on control node:
wg genkey | tee ~/.ssh/mac_wg_private.key | wg pubkey > ~/.ssh/mac_wg_public.key

# 5. Add Mac public key to inventories/host_vars/multi-lab-vps.yml under wireguard_peer_public_keys.mac:
#    wireguard_peer_public_keys:
#      mac: "<mac-public-key-contents>"

# 6. Apply Step 5 (WireGuard Hub) on EC2:
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass

# 7. Apply Step 6 (Fail2Ban) on EC2:
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step6 --ask-become-pass
```

**Control Node Client Activation:**
Retrieve the generated EC2 server public key from `/etc/wireguard/client-mac.conf` on EC2, configure your local WireGuard tunnel interface (`172.16.0.2`), and start the tunnel:
```bash
sudo wg-quick up /path/to/wg0.conf
ping -c 3 172.16.0.1
# → 3 packets transmitted, 3 received, 0% packet loss
```

Once the tunnel is active, update `connection_mode: "wg"` and `hardening_wg_close_public_ssh: true` in `inventories/host_vars/multi-lab-vps.yml`, re-run Step 5 to close port 22222 in UFW, and clear `ssh_hardened_cidr` in Terraform:
```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass
```

##### Phase B — Local VM Spoke Deployment

**VM · multi-lab-local · Run on control node:**
```bash
# 1. Apply Step 3 (SSH Hardening) on VM using connection_mode: "pre" (port 22)
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step3 --ask-become-pass

# 2. Update inventories/host_vars/multi-lab-local.yml:
#    Change connection_mode: "hardened"

# 3. Apply Step 4 (UFW Firewall) on VM using connection_mode: "hardened" (port 22222)
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step4 --ask-become-pass

# 4. Exchange keys:
#    - Add EC2 hub public key to inventories/host_vars/multi-lab-local.yml as wireguard_hub_public_key
#    - Add VM public key to inventories/host_vars/multi-lab-vps.yml under wireguard_peer_public_keys.local_vm
#    - Re-run Step 5 on EC2 to register the VM peer:
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_step5 --ask-become-pass

# 5. Apply Step 5 (WireGuard Spoke) and Step 6 (Fail2Ban) on VM:
ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_step5,hardening_step6 --ask-become-pass

# 6. Update inventories/host_vars/multi-lab-local.yml:
#    Change connection_mode: "wg"
```

#### Why
Restricting OpenSSH to port 22222 over an encrypted WireGuard tunnel shields administrative access from port scanning and brute-force bots on the public Internet. Using `banaction = ufw` ensures malicious IPs are dropped at the packet filter level before hitting daemon sockets.

#### Troubleshooting — WireGuard & Perimeter
- **Handshake not completing:** Run `sudo wg show` on both peers. If `latest handshake` is missing, verify UDP port 51820 is open in the AWS Security Group and that peer public keys match across `inventories/host_vars/multi-lab-vps.yml` and `inventories/host_vars/multi-lab-local.yml`.
- **EC2 lockout rescue:** If an SSH configuration error occurs on EC2 before WireGuard is established, connect via AWS Systems Manager Session Manager (`aws ssm start-session --target <instance-id>`) to inspect `/var/log/auth.log` and restore `/etc/ssh/sshd_config`.

---

### Step 3 — System Hardening & Compliance (Manual Steps 7–12 · Tag `hardening_2c`)

#### What was done
Deploy remaining defense-in-depth layers across kernel, filesystem, application, audit, and log subsystems:

| Manual Step | Task File (`roles/hardening/tasks/`) | Tag | Ansible Implementation / Platform Delta |
|---|---|---|---|
| [Step 7 — Kernel Hardening (sysctl)](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-7--kernel-hardening-sysctl) | `step_07_sysctl.yml` | `hardening_step7` | Deploys `99-z-hardening.conf` to guarantee lexicographically last evaluation over package defaults. Configures ASLR, restrict dmesg/kptr, disable source routing, and enable SYN cookies. |
| [Step 8 — AppArmor](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-8--apparmor) | `step_08_apparmor.yml` | `hardening_step8` | Installs `apparmor-utils` and `apparmor-profiles`, and enables enforce mode for base daemons. |
| [Step 9.1 — Services & Daemons](../../../../modules/hardening/self-managed/hardening-self-managed.md#91--services--daemons) | `step_09_1_services.yml` | `hardening_step9_1` | Purges legacy and crash daemons (`apport*`). On EC2 (`is_cloud: true`), cleanly stops snapd and migrates `amazon-ssm-agent` from snap to official deb package before purging snapd. Holds `snapd` at `dpkg_selections`. |
| [Step 9.2 — Filesystem & Users](../../../../modules/hardening/self-managed/hardening-self-managed.md#92--filesystem--user-hardening) | `step_09_2_users_fs.yml` | `hardening_step9_2` | Sets restrictive permissions on crontab (`0600`) and sudoers.d (`0750`). Deploys PAM `common-password` (SHA-512 with 65,536 rounds, pwquality minimum 12 chars), `common-session` (pam_tmpdir), and `/etc/security/limits.conf` (disables core dumps). Configures UMASK 027 in `/etc/login.defs`. Note: `chage -E` is intentionally omitted to preserve administrative access (suppressing Lynis AUTH-9282). |
| [Step 9.3 — Kernel Modules](../../../../modules/hardening/self-managed/hardening-self-managed.md#93--kernel-modules) | `step_09_3_modprobe.yml` | `hardening_step9_3` | Deploys `disable-unused-protocols.conf` to `/etc/modprobe.d/` blacklisting obsolete network protocols (`dccp`, `sctp`, `rds`, `tipc`), and regenerates initramfs. |
| [Step 9.4 — Monitoring & Forensics](../../../../modules/hardening/self-managed/hardening-self-managed.md#94--monitoring--forensics) | `step_09_4_monitoring.yml` | `hardening_step9_4` | Installs and enables `rkhunter`, `acct` (process accounting), and `sysstat` (system activity monitoring). |
| [Step 10 — Audit Trail (auditd + AIDE)](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-10--audit-trail-auditd--aide) | `step_10_audit.yml` | `hardening_step10` | Deploys comprehensive audit rules (`99-hardening.rules`) with a guaranteed trailing newline. Adapts syscall rules for ARM64 ABI (`unlinkat`, `renameat`, `renameat2`). Initializes AIDE integrity database idempotently (`creates: /var/lib/aide/aide.db`). Enforces immutable mode (`-e 2`) on EC2 and clean convergence runs. |
| [Step 11 — Log Management](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-11--log-management-rsyslog--logrotate) | `step_11_logging.yml` | `hardening_step11` | Configures rsyslog routing for UFW (`20-ufw.conf`) and security logs (`99-hardening.conf`), enforcing `0640 syslog:adm` permissions. Configures logrotate policies (`hardening-logs`). |
| [Step 12 — Security Audit Baseline](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-12--security-audit-baseline-lynis) | `step_12_lynis.yml` | `hardening_step12` | Deploys custom Lynis profile (`custom.prf`) suppressing non-applicable virtualization and cloud warnings. Executes compliance scan and validates target Hardening Index (≥ 90 EC2, ≥ 88 VM). |

#### Operational Notes
1. **Secondary SSH Session:** Open a separate, persistent SSH session to the target host before applying Step 3 to safeguard against PAM `common-session` or `common-password` locking errors.
2. **Password Re-encryption:** After deploying PAM configurations, execute `passwd` manually on the target machine to re-hash the existing administrator password in `/etc/shadow` with 65,536 rounds.
3. **Auditd Immutable Mode:** `hardening_auditd_immutable_mode` defaults to `true` in `defaults/main.yml`. In `inventories/host_vars/multi-lab-local.yml`, it is set to `false` during incremental development so rules can be reloaded without rebooting, and set to `true` during the final convergence run.

#### Unified Execution Commands

Run Block 2C across both environments using `connection_mode: "wg"`:

| Target | --limit | host_vars File | Command | Expected Output |
|---|---|---|---|---|
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --check --diff --ask-become-pass` | Inspect diff; verify 0 errors |
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --ask-become-pass` | `multi-lab-vps : ok=... changed=...` |
| EC2 | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-vps --tags hardening_2c --ask-become-pass` | `changed=0` (idempotence gate) |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --check --diff --ask-become-pass` | Inspect diff; verify 0 errors |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --ask-become-pass` | `multi-lab-local : ok=... changed=...` |
| VM | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `ansible-playbook playbooks/hardening.yml --limit multi-lab-local --tags hardening_2c --ask-become-pass` | `changed=0` (idempotence gate) |

#### Why
Naming sysctl configuration `99-z-hardening.conf` guarantees that security parameters take precedence over operating system defaults loaded earlier in lexicographical order. Removing snapd on EC2 closes attack surfaces while migrating `amazon-ssm-agent` to native deb packages preserves out-of-band management.

#### Verified Troubleshooting — System Hardening
- **Snapd state in memory:** Removing `/var/lib/snapd` while `snapd.service` is active causes `dpkg` pre-installation scripts to fail. Task `step_09_1_services.yml` explicitly stops `snap.amazon-ssm-agent.amazon-ssm-agent.service` and `snapd.service` before cleaning disk state and installing the `.deb`.
- **Rkhunter initial exit code 2:** On clean systems, rkhunter emits return code 2 if properties have not been baseline-linked. Task `step_09_4_monitoring.yml` runs `rkhunter --propupd` immediately after package installation.
- **Auditd trailing newline:** `augenrules --load` fails silently or truncates rules if `99-hardening.rules` lacks a trailing LF character. Task `step_10_audit.yml` enforces explicit newline termination.
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
| **OpenSSH Port & Access** | Port `22222`, key-only, non-root `admin` | Port `22222`, key-only, non-root `admin` | [SSH Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-3--ssh-hardening) |
| **UFW Status** | `active`, default deny incoming, rate-limit | `active`, default deny incoming, rate-limit | [UFW Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-4--ufw-firewall) |
| **WireGuard Interface** | `wg0` active, handshake recorded | `wg0` active, handshake recorded | [WireGuard Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-5--wireguard-vpn) |
| **Fail2Ban Jail** | `sshd` active, banaction `ufw` | `sshd` active, banaction `ufw` | [Fail2Ban Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-6--fail2ban) |
| **Kernel Sysctl** | `99-z-hardening.conf` applied | `99-z-hardening.conf` applied | [Sysctl Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-7--kernel-hardening-sysctl) |
| **AppArmor Enforce** | Profiles active, no denied errors | Profiles active, no denied errors | [AppArmor Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-8--apparmor) |
| **Service Attack Surface** | `snapd` purged, `apport` masked | `snapd` purged, `apport` masked | [Services Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#91--services--daemons) |
| **Filesystem & Users** | umask 027, SHA-512 rounds 65536 | umask 027, SHA-512 rounds 65536 | [Filesystem Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#92--filesystem--user-hardening) |
| **Kernel Modprobe** | Unused protocols disabled | Unused protocols disabled | [Kernel Modules Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#93--kernel-modules) |
| **System Monitoring** | `acct` & `sysstat` active | `acct` & `sysstat` active | [Monitoring Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#94--monitoring--forensics) |
| **System Logging** | Dedicated `ufw.log`, permissions `0640` | Dedicated `ufw.log`, permissions `0640` | [Logging Verification](../../../../modules/hardening/self-managed/hardening-self-managed.md#step-11--log-management-rsyslog--logrotate) |

#### Full Idempotency Gate (0 Changed)

Execute the full hardening playbook across both hosts. The execution must complete with **0 changed**:

```bash
ansible-playbook playbooks/hardening.yml --limit all --ask-become-pass
```
```
# Expected output:
# multi-lab-vps   : ok=54   changed=0    unreachable=0    failed=0
# multi-lab-local : ok=55   changed=0    unreachable=0    failed=0
```

#### Known Deviations & Pending Checks
1. **`/var/log/fail2ban.log` ownership:** Systemd or rsyslog creates this file with initial permissions `syslog:adm` or `root:adm`. The logrotate policy enforces `0640 syslog:adm`. If a logrotate cycle executes between runs, task `step_11_logging.yml` may report `changed=1` to enforce ownership.
2. **VM Block 2B Gate Idempotency:** The VM Block 2B execution gate was verified iteratively; clean idempotency (`changed=0`) on Step 3 will be re-confirmed during the from-scratch convergence rebuild (hypothesis under evaluation: sshd handler notify on successive passes).

---

## Appendix A — Legacy Operations (Historical Reference)

> [!NOTE]
> This section documents the legacy Phase 1 workflow for importing pre-existing AWS resources into Terraform state and redeploying from custom AMI snapshots. It is preserved strictly as an architectural reference and is **not used** during standard greenfield provisioning.

### Legacy Import Workflow

In the original Phase 1 architecture, resources were provisioned manually in the AWS Management Console and subsequently adopted into Terraform management:

1. **Collect Resource IDs:** Query existing AWS resources (VPC, Subnet, IGW, Route Table, Security Group, EC2 instance, Elastic IP) via AWS CLI.
2. **Configure Import Blocks:** Populate `import.tf` from `import.tf.example` with gathered resource IDs.
3. **Generate Configuration:** Execute `terraform plan -generate-config-out=generated.tf` to generate initial resource HCL.
4. **Reconcile Generated HCL:** Reconcile differences in `generated.tf` against project standards:

| Resource Block | Required Adjustment | Reason |
|---|---|---|
| `aws_vpc` | Remove `enable_classiclink`, `enable_classiclink_dns_support` | Deprecated in AWS provider v5+ |
| `aws_route_table` | Remove inline `route` blocks; use standalone `aws_route` | Prevents route table collision |
| `aws_security_group` | Remove inline `ingress`/`egress` blocks; use `aws_security_group_rule` | Enables dynamic rule attachment |
| `aws_instance` | Retain `multi-lab-ec2-role` instance profile, remove auto-generated attachments | State alignment |

5. **Apply Import & Finalize:** Execute `terraform apply` to absorb resources into `terraform.tfstate`, remove `import.tf`, and activate `main.tf`.

### Legacy AMI Redeployment

The Phase 2 prototype redeployed instances from a pre-hardened custom AMI (`multi-lab-aws-active-directory`). This was replaced by greenfield provisioning from canonical Ubuntu 24.04 LTS ARM64 AMIs (Step 1) combined with Ansible configuration management, providing full end-to-end reproducibility from code.
