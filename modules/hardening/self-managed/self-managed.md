# Hardening — Self-Managed

**Ubuntu 24.04 LTS · VM / VPS**

---

## Introduction
This document covers the hardening process applied before deploying any service.
The goal is to reduce the attack surface to a minimum following the **defense in depth**
principle: multiple independent security layers, where the failure of one does not
compromise the entire system.

The server is designed to run internet-facing services — base hardening is a
non-negotiable prerequisite before opening any port to the public network.

> **Note:** IP addresses shown throughout this doc (192.168.X.X) are placeholders.
> Replace with your actual values — LAN subnet for VM, or the public IP
> assigned by your provider for VPS.

### Security Layers

```
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 0 — PERIMETER WireGuard VPN (optional — recommended        │
│ for internet-facing servers)                                     │
│ SSH hidden from public internet                                  │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 1 — NETWORK UFW (default-deny + rate-limit)                │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 2 — ACCESS SSH hardened (key-only, no forwarding,          │
│ AllowUsers, StrictModes, VERBOSE log)                            │
│ + Fail2Ban (escalating ban policy)                               │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 3 — KERNEL sysctl (ASLR, BPF, ptrace, rp_filter,           │
│ martians, syncookies, sysrq...)                                  │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 4 — PROCESSES AppArmor MAC (enforce mode)                  │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 5 — SURFACE Unused services disabled · apport removed      │
│ · snapd removed + pinned                                         │
│ · kernel modules blacklisted                                     │
│ (dccp, sctp, rds, tipc, usb_storage)                             │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 6 — AUDIT auditd (immutable -e 2)                          │
│ + rsyslog (dedicated log files)                                  │
│ + AIDE (file integrity monitoring)                               │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 7 — PATCHES Unattended upgrades (security only)            │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 8 — VALIDATION Lynis — runtime verification of all         │
│ controls · custom profile with                                   │
│ documented deviations                                            │
└──────────────────────────────────────────────────────────────────┘
```

---

## Environment

| Parameter | Value |
|---|---|
| Operating System | Ubuntu Server 24.04 LTS (Noble Numbat) |
| Architecture | ARM64 (aarch64) / x86_64 |
| Platform | VMware Fusion (macOS) · VMware / VirtualBox (Linux/Windows) · VPS |
| IP | 192.168.X.X (static) |
| Network | Bridged — LAN 192.168.X.X |
| Gateway | 192.168.X.1 |
| DNS | 9.9.9.9 / 149.112.112.112 (Quad9) |
| Admin user | `<username>` (non-root with sudo) |
| Access | SSH key-based (Ed25519) only |

---

## Prerequisites

All steps reference configuration files from this repository.
Obtain them before executing any step — either clone the repo or copy
individual files directly from GitHub:

```bash
# Option A — clone (requires git configured)
git clone https://github.com/Bios-Mod/build-your-infra.git
cd build-your-infra

# Option B — copy individual files directly from GitHub
# Navigate to the file in the repo, click Raw, copy the content
# https://github.com/Bios-Mod/build-your-infra/tree/main/modules/hardening/self-managed/configs
```

All `cp` commands assume the current directory is the repo root.

---

## Step 0 — Admin User Setup

> **This step must be completed before applying any SSH or sudo configuration.**
> The `sshd_config` in Step 3 uses `AllowUsers <username>` — if the target
> user does not exist when SSH is reloaded, the session is locked out.

### What was done
A dedicated non-root admin user is created, added to the required groups,
assigned a password, and configured with the SSH public key before any
other hardening is applied.

**Create and configure the admin user:**

```bash
# Create user with home directory
sudo adduser <username>

# Add to admin groups
sudo usermod -aG sudo,adm,admin <username>

# Set a strong password for sudo privilege escalation
sudo passwd <username>

# Switch to the new user and verify sudo access
sudo su - <username>
sudo whoami
# → root
exit
```

**SSH key setup — VM:**

```bash
# Check for existing Ed25519 key
ls ~/.ssh/id_ed25519.pub 2>/dev/null || echo "no key found"

# Generate if missing
ssh-keygen -t ed25519 -C "multi-lab" -f ~/.ssh/id_ed25519
# → passphrase recommended — protects the private key at rest

# Copy public key to the VM (password auth still active at this stage)
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 22 <username>@192.168.X.X
# → adds the public key to /home/<username>/.ssh/authorized_keys on the VM

# Verify key auth works before proceeding
ssh -i ~/.ssh/id_ed25519 -p 22 <username>@192.168.X.X
# → must authenticate without password prompt
```

**SSH key setup — EC2:**

```bash
# The key injected at launch lands in /home/ubuntu/.ssh/authorized_keys only.
# Copy it to the new user — cloud-init is unaware of accounts created post-launch.
sudo mkdir -p /home/<username>/.ssh
sudo cp /home/ubuntu/.ssh/authorized_keys /home/<username>/.ssh/authorized_keys
sudo chown -R <username>:<username> /home/<username>/.ssh
sudo chmod 700 /home/<username>/.ssh
sudo chmod 600 /home/<username>/.ssh/authorized_keys
```

### Why
Operating as the default AMI user (`ubuntu`) exposes a predictable username.
A named user provides an explicit, auditable identity — all sudo actions in
`/var/log/auth.log` are attributed to it, and `AllowUsers` in Step 3
whitelists exactly that name. A password is required for `sudo` privilege
escalation even with key-based SSH — ensuring a second factor is always
present before any privileged operation. Root login is disabled at the SSH
level in Step 3. The `ubuntu` user is left intact — removing it risks
breaking cloud-init hooks on EC2.

### Verification

> **Open a new terminal and confirm SSH access before proceeding.**
> Step 3 disables password authentication — an unverified key means permanent
> lockout without console access.

```bash
# Confirm groups — must include sudo and adm
id <username>
# → uid=1001(<username>) gid=1001(<username>) groups=...,27(sudo),4(adm)...

# Confirm key-based login from a new terminal
ssh -i ~/.ssh/id_ed25519 -p 22 <username>@<server-ip>
# → must authenticate successfully

# Confirm authorized_keys ownership and permissions
ls -la /home/<username>/.ssh/
# → drwx------  .ssh            <username>:<username>
# → -rw-------  authorized_keys <username>:<username>
```

> **Do not proceed until SSH login as `<username>` is confirmed working in
> a second terminal.** This is the same lockout prevention principle applied
> throughout the hardening steps — always verify access before closing the
> current session.

---

## Step 1 — System Update & Automated Security Upgrades

### What was done
System updated and unattended upgrades configured to automatically apply
security patches daily.

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt autoremove && sudo apt autoclean
```

Install unattended-upgrades and package audit tools:

```bash
sudo apt install unattended-upgrades debsums apt-show-versions apt-listchanges -y

# debsums ships with automated checks disabled — enable weekly cron
sudo sed -i 's/^#\?CRON_CHECK=.*/CRON_CHECK=weekly/' /etc/default/debsums
```

> **`apt-listbugs` is Debian-only** — not available in Ubuntu repos.
> See Lynis deviation `DEB-0810` in Step 12.

Deploy the unattended-upgrades configuration:

```bash
sudo cp modules/hardening/self-managed/configs/unattended-upgrades/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
sudo cp modules/hardening/self-managed/configs/unattended-upgrades/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
sudo systemctl restart unattended-upgrades
```

📄 [`configs/unattended-upgrades/50unattended-upgrades`](modules/hardening/self-managed/configs/unattended-upgrades/50unattended-upgrades)
📄 [`configs/unattended-upgrades/20auto-upgrades`](modules/hardening/self-managed/configs/unattended-upgrades/20auto-upgrades)

#### Package integrity & audit tools
Two complementary tools covering package hygiene:

| Tool | Role |
|---|---|
| `debsums` | Verifies installed package files against dpkg's checksum database — package-level tamper detection, complements AIDE |
| `apt-show-versions` | Reports installed vs available version per package with repository origin — confirms all security packages are current |
| `apt-listchanges` | Displays significant changes in packages before upgrade — prevents unexpected behavior from silent changelog changes |

### Why
An outdated system carries known, publicly documented vulnerabilities.
Attackers automate the exploitation of known CVEs — keeping the system
current eliminates this attack category before it can occur.

Automating only security patches (not general upgrades) minimizes the risk
of an update breaking a running service while keeping the system protected.
`Automatic-Reboot: false` is critical on a server — a kernel update must
not trigger an unattended reboot that causes unexpected downtime.

> For full upgrade automation beyond security patches, a cron job calling
> `apt upgrade -y` with output logging is a common approach. Evaluate based
> on tolerance for unattended changes on running services.

### Verification
```bash
# Pending updates
sudo apt list --upgradable

# Dry run — simulate an unattended-upgrades cycle
sudo unattended-upgrade --dry-run --debug

# Service active
systemctl status unattended-upgrades

# Recent upgrade history
tail -n 20 /var/log/apt/history.log

# All packages current — no output = correct
apt-show-versions -u

# No security packages behind — no output = correct
apt-show-versions | grep "security" | grep -v "uptodate"

# Package integrity clean — no output = correct
sudo debsums -s

# Weekly cron active
grep CRON_CHECK /etc/default/debsums
# → CRON_CHECK=weekly
```

---

## Step 2 — Static IP Configuration

> **Platform note:** All configuration values in this lab reflect a specific
> build on Ubuntu Server 24.04 LTS / VMware Fusion / ARM64. Adapt to your
> deployment — the reasoning applies universally, the exact values do not.

> **AWS/Cloud skip:** On EC2 the network is managed by cloud-init and the
> VPC DHCP server. Do not modify Netplan — the Elastic IP handles the static
> public address at the AWS layer. Proceed directly to Step 3.

### What was done
Replaces the temporary address from the local VM setup with the hardened
Netplan config. Key decisions:
- Address chosen **outside the router's DHCP pool** to prevent future conflicts
- `dhcp4: no` · `dhcp6: no` · `link-local: []` — all dynamic address paths disabled
- DNS set directly to Quad9 (`9.9.9.9` / `149.112.112.112`), bypassing the router resolver

```bash
sudo cp modules/hardening/self-managed/configs/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml
sudo netplan apply
```

📄 [`configs/netplan/00-installer-config.yaml`](modules/hardening/self-managed/configs/netplan/00-installer-config.yaml)


> **Deployment notes:**
> - **VM (VMware/VirtualBox):** configure Bridged mode in hypervisor settings
>   first — the VM must appear as a direct host on the LAN.
>   Interface name varies by hypervisor — verify with `ip link` before deploying.
> - **VPS:** verify the existing Netplan config with `cat /etc/netplan/*.yaml`
>   before overwriting — providers often pre-configure it via cloud-init.
>   Replace address/gateway values with those assigned by the provider.
> - **Cloud Provider Note (cloud-init):**
>   Cloud providers often use `cloud-init`, which can dynamically overwrite
>   `/etc/netplan/` configurations on every reboot.
>   Ensure `cloud-init` network management is disabled (e.g., by creating
>   `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`
>   with `network: {config: disabled}`) before applying your static IP.

**Ubuntu 24.04 — Netplan DHCP bug:** Netplan 0.106 generates `DHCP=ipv4` in
the systemd-networkd unit even when `dhcp4: no` is set — a known bug when
static addresses coexist with explicit route definitions. The interface
requests a dynamic address from the router alongside the static one.

Fixed via a systemd-networkd drop-in that overrides only the `DHCP=`
directive — the Netplan-generated base file stays untouched.
The drop-in directory name mirrors the Netplan-generated unit name and
includes the interface name — replace `enp2s0` with your actual interface:

```bash
sudo mkdir -p /etc/systemd/network/10-netplan-enp2s0.network.d/
sudo cp modules/hardening/self-managed/configs/netplan/no-dhcp.conf /etc/systemd/network/10-netplan-enp2s0.network.d/
sudo systemctl daemon-reload
sudo systemctl restart systemd-networkd
```

📄 [`configs/netplan/no-dhcp.conf`](modules/hardening/self-managed/configs/netplan/no-dhcp.conf)

### Why
A static IP is a prerequisite for every service that follows — DNS, DHCP,
Samba 4, and all firewall rules depend on a stable, known address. On a VPS
the public IP is already static — Netplan formalizes it and disables any
DHCP client that may have been active.

Quad9 is a non-profit, no-log, DNSSEC-validating resolver that blocks known
malicious domains at the resolver level — a meaningful security improvement
over using the ISP or router resolver at zero cost.

### Verification
```bash
# Single static IP — no secondary dynamic address
ip a show enp2s0

# Default route via static gateway
ip route show

# Active DNS resolvers
resolvectl status | grep "DNS Servers"
```

---

## Step 3 — SSH Hardening

### What was done
`/etc/ssh/sshd_config` hardened across six areas: authentication, access
control, session limits, forwarding, cryptographic policy, and host key identity.

Audit `sshd_config.d/` before enabling the `Include` directive — a drop-in
could silently re-enable password auth or root login:

```bash
ls -la /etc/ssh/sshd_config.d/
sudo grep -r "PasswordAuthentication\|PermitRootLogin\|PubkeyAuthentication" \
  /etc/ssh/sshd_config.d/ 2>/dev/null
# → no conflicting directives
```

Deploy the config, create the banner, and remove unused host key material from disk:

> **Critical operational note (Preventing Lockout):**
> Before restarting the SSH daemon, keep a recovery path open until the new
> port is confirmed from a second session or console access.

> **Note:** When changing the SSH port (`Port 22222`), use a full restart
> after validating the config and enable the service so it persists across reboot.

> **Cloud Provider Note:** On EC2 and VPS, verify that `cloud-init` does not
> override SSH settings or `authorized_keys` on reboot. Confirm the effective
> configuration after restart and after a reboot test.

```bash
sudo cp modules/hardening/self-managed/configs/ssh/sshd_config /etc/ssh/sshd_config
sudo chmod 600 /etc/ssh/sshd_config
sudo cp modules/hardening/self-managed/configs/ssh/issue.net.template /etc/issue.net
sudo rm /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
sudo rm /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub
sudo sshd -t
sudo systemctl enable ssh
sudo systemctl restart ssh
sudo ss -tuln | grep 22222
sudo systemctl is-enabled ssh
```

> **`/etc/issue` vs `/etc/issue.net`:** `/etc/issue.net` serves the SSH
> pre-authentication banner (configured above). `/etc/issue` serves the
> local console login prompt — both should carry the same legal warning:
> ```bash
> sudo cp /etc/issue.net /etc/issue
> ```

📄 [`configs/ssh/sshd_config`](modules/hardening/self-managed/configs/ssh/sshd_config)
📄 [`configs/ssh/issue.net.template`](modules/hardening/self-managed/configs/ssh/issue.net.template)

Key decisions — each directive is documented inline in the config:

| Area | Directives | Decision |
|---|---|---|
| Authentication | `PasswordAuthentication no` · `PubkeyAuthentication yes` · `PermitEmptyPasswords no` · `KbdInteractiveAuthentication no` | Ed25519 key only — no password path remains open |
| Access control | `PermitRootLogin no` · `AllowUsers <username>` · `AuthorizedKeysFile .ssh/authorized_keys` | Explicit whitelist; single authorized_keys path eliminates legacy `.authorized_keys2` persistence vector |
| Session & connection | `MaxAuthTries 3` · `LoginGraceTime 30` · `MaxSessions 2` · `MaxStartups 10:30:60` · `UseDNS no` | Limits exposure window and pre-auth connection exhaustion; reverse DNS lookup disabled — avoids PTR delays with internal DNS active |
| Forwarding | `AllowTcpForwarding no` · `AllowAgentForwarding no` · `X11Forwarding no` | SSH used for interactive shell only — tunneling and proxy paths disabled |
| Cryptographic policy | `Ciphers` · `MACs` · `KexAlgorithms` · `HostKey` · `HostKeyAlgorithms` | Modern authenticated-encryption only; CBC, non-ETM MACs, and weak DH groups excluded — host identity restricted to Ed25519, RSA and ECDSA key files removed from disk |

> **`AllowTcpForwarding no` vs `ip_forward`:** These are independent controls.
> `AllowTcpForwarding no` disables SSH-level port forwarding through the daemon.
> `net.ipv4.ip_forward = 1` is a kernel parameter required for WireGuard to route
> packets between the VPN interface (`wg0`) and the network stack — it is enabled
> in Step 5 and has no relationship to SSH forwarding. Both can and should coexist.

> **SFTP — Step 02:** `AllowTcpForwarding no` does not affect the SFTP
> subsystem — SFTP runs over the standard SSH channel, not a TCP forward.
> No change to this file is required when SFTP is deployed in Step 02.

> **`DebianBanner no`** suppresses the OpenSSH version string from the
> identification banner — reduces information leakage without affecting
> functionality.

### Why
SSH is the primary attack vector on internet-facing servers. Disabling
password authentication makes brute-force attacks irrelevant — with no
password to try, there is no attack. Ed25519 is the most modern and
efficient key algorithm available in OpenSSH.

`PermitRootLogin no` removes the most valuable privilege escalation target.
`AllowUsers` is an explicit whitelist — any account not listed cannot connect
even if it exists on the system.

Port 22222 is not a security control — a full `nmap` scan finds SSH on any
port within minutes. The real benefit is operational: bots that only scan
well-known ports never reach the server, keeping `auth.log` clean and
reducing Fail2Ban workload. All actual security is provided by key-only
authentication, Fail2Ban, and UFW.

### Verification

```bash
# Effective merged config — reads all files including drop-ins
sudo sshd -T | grep -E "allowtcpforwarding|allowagentforwarding|tcpkeepalive|loglevel|maxauthtries|maxsessions|strictmodes|banner|maxstartups"

# Password auth must fail
ssh -p 22222 -o PubkeyAuthentication=no -o PreferredAuthentications=password \
  <username>@X.X.X.X

# Server must not advertise 'password' as available auth method
ssh -vv -p 22222 <username>@X.X.X.X 2>&1 | grep "Authentications that can continue"

# Banner appears before authentication prompt
ssh -p 22222 <username>@X.X.X.X
# → legal warning text before key prompt

# VERBOSE logging — key fingerprint visible after login
sudo grep "Accepted publickey" /var/log/auth.log | tail -3
# → Accepted publickey for <username> ... SHA256:<fingerprint>

# Single authorized_keys path — no authorized_keys2
sudo sshd -T | grep authorizedkeysfile
# → authorizedkeysfile .ssh/authorized_keys

# No conflicting drop-in
sudo grep -r "PasswordAuthentication\|PermitRootLogin\|PubkeyAuthentication" \
  /etc/ssh/sshd_config.d/ 2>/dev/null

# Cryptographic policy active
sudo sshd -T | grep -E "^ciphers|^macs|^kexalgorithms"
# → ciphers chacha20-poly1305@openssh.com,...
# → macs hmac-sha2-512-etm@openssh.com,...
# → kexalgorithms curve25519-sha256,...

# Ed25519 is the only active host key — RSA and ECDSA must not appear
sudo sshd -T | grep -E 'hostkey|hostkeyalgorithms|usedns'
# → hostkey /etc/ssh/ssh_host_ed25519_key
# → hostkeyalgorithms ssh-ed25519
# → usedns no

# Key files — only Ed25519 pair on disk
ls /etc/ssh/ssh_host_*
# → /etc/ssh/ssh_host_ed25519_key
# → /etc/ssh/ssh_host_ed25519_key.pub

# Service enabled for reboot persistence
systemctl is-enabled ssh
# → enabled
```

---

### 3.1 — EC2: SSM Session Manager Access

> **EC2 only.** SSM Session Manager replaces SSH as the primary shell access
> method — no inbound port required, no key distribution needed. Requires
> the aws-native hardening baseline:
> [`modules/hardening/aws-native/aws-native.md`](../../aws-native/aws-native.md)
> Steps 2 and 6 must be completed before SSM access is available.

#### What was done

Session Manager plugin installed on the local machine and SSM shell access
verified against the EC2 instance.

**Install the Session Manager plugin — local machine (one-time):**

```bash
# macOS
brew install --cask session-manager-plugin

# Linux (x86_64)
wget https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
sudo dpkg -i session-manager-plugin.deb
rm session-manager-plugin.deb
```

**Start a session:**

**Console**

Systems Manager → Session Manager → Start session →
select `<instance-id>` → Start session.

**CLI**

```bash
aws ssm start-session \
  --target <instance-id> \
  --profile multi-lab-admin
# → opens an interactive shell — no SSH port or key required
```

#### Verification

```bash
# Agent registered and reachable
aws ssm describe-instance-information \
  --profile multi-lab-admin \
  --query "InstanceInformationList[*].{ID:InstanceId,Status:PingStatus}"
# → PingStatus: "Online"

# Session logged automatically — no manual action required
# Console: Systems Manager → Session Manager → Session history
```

---

## Step 4 — UFW (Firewall)

### What was done
UFW configured with a default-deny inbound policy. Only SSH is opened at
this stage — additional ports are added in their respective service steps.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 22222/tcp
sudo ufw logging medium
sudo ufw enable
```

UFW applies `/etc/ufw/sysctl.conf` on every reload, **after** all
`/etc/sysctl.d/` files — overriding any matching value. `log_martians`
was corrected from `0` to `1` in that file to stay consistent with the
hardening baseline set in Step 7.

📄 [`configs/ufw/sysctl.conf`](modules/hardening/self-managed/configs/ufw/sysctl.conf)

### Why
All inbound traffic is blocked by default — ports are opened only when a
service is deployed, never in advance.

`ufw limit` on port 22222 adds rate limiting (max 6 connections per 30
seconds per IP) at the network layer, before packets reach SSH. Rules apply
automatically to both IPv4 and IPv6.

Logging level `medium` captures all packets blocked by the default-deny
policy, not just those matching an explicit rule. Level `low` misses the
majority of scan and probe traffic that hits the default policy directly.
UFW log entries land in `/var/log/ufw.log` — configured in Step 11.

> `51820/udp` (WireGuard) and the SSH interface restriction are added in
> Step 5 — the `limit 22222/tcp` rule is replaced at that point if
> WireGuard is deployed. Additional service ports (80/tcp, 443/tcp, 53…)
> are opened in their respective steps.

### Verification
```bash
# Active rules and default policies
sudo ufw status verbose

# Confirm port 22222 has the LIMIT tag
sudo ufw status numbered

# Confirm logging level
sudo ufw status verbose | grep Logging
# → Logging: on (medium)
```

---

## Step 5 — WireGuard VPN

> **This step is optional.** Evaluate based on your deployment:
>
> | Scenario | Recommendation |
> |---|---|
> | LAN-only management (VM on local network) | Not required — key-based SSH is sufficient |
> | Remote access from outside the LAN | **Recommended** — hides SSH from the public internet |
> | Server exposed to the internet | **Strongly recommended** — SSH becomes invisible to scanners |
>
> If skipped, SSH remains on port 22222 protected by key-only authentication
> and Fail2Ban. That is a valid and secure configuration for LAN-managed servers.

### What was done
WireGuard configured as a VPN perimeter layer. SSH access restricted to the
VPN interface — port 22222 is no longer reachable from the public internet.

**VPN subnet:** server `172.16.0.1`, clients from `.2` onward. One `[Peer]`
block per device, unique IP per peer.

> ⚠️ **CIDR conflict — EC2:** The VPN subnet must not overlap with the VPC CIDR.
> If the VPC uses `10.0.0.0/16`, AWS injects DHCP routes for the entire block
> at boot — including `10.0.0.0/24` — overriding the WireGuard routes and
> breaking tunnel traffic silently (handshake succeeds, no data passes).
> Use `172.16.0.0/24` to avoid this. The `192.168.0.0/16` range is also
> commonly used by home routers — avoid it for client-facing deployments.

#### Server

```bash
sudo apt install wireguard -y

# Generate server keypair — private key written to disk, never displayed
wg genkey | sudo tee /etc/wireguard/server_private.key \
  | wg pubkey | sudo tee /etc/wireguard/server_public.key
sudo chmod 600 /etc/wireguard/server_private.key

# Generate client keypair on the server — transfer to client, then delete
wg genkey | tee mac_private.key | wg pubkey > mac_public.key
```

📄 [`configs/wireguard/wg0.conf`](modules/hardening/self-managed/configs/wireguard/wg0.conf)

```bash
sudo cp modules/hardening/self-managed/configs/wireguard/wg0.conf /etc/wireguard/wg0.conf
sudo wg-quick up wg0
sudo systemctl enable wg-quick@wg0
```

> **Key cleanup:** once the client keypair is transferred to the device,
> delete it from the server — a private key must never persist outside its owner:
> ```bash
> rm ~/mac_private.key ~/mac_public.key
> ```

#### UFW — open WireGuard port and restrict SSH to VPN interface

```bash
sudo ufw allow 51820/udp comment 'WireGuard VPN'
sudo ufw allow in on wg0 to any port 22222 proto tcp comment 'SSH via WireGuard only'
sudo ufw delete limit 22222/tcp
sudo ufw route allow in on wg0 out on wg0 comment 'WireGuard peer-to-peer forwarding'
sudo ufw reload
```

> UFW's default forward policy is DROP. Without the route allow rule, packets between
> peers are forwarded by the kernel (ip_forward = 1) but dropped by UFW before they
> leave wg0 — the handshake succeeds and `wg show` reports an active tunnel, but no
> traffic passes. This rule is the fix for that failure mode.

> SSH continues to listen on all interfaces at the socket level — UFW drops
> any packet arriving on port 22222 outside `wg0` before it reaches the
> daemon. Firewall enforcement is more robust than `ListenAddress`: it applies
> regardless of sshd configuration and cannot be bypassed by a misconfigured
> drop-in.

#### ip_forward

```bash
sudo cp modules/hardening/self-managed/configs/sysctl/99-wireguard.conf /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system | grep ip_forward
# → net.ipv4.ip_forward = 1
```

📄 [`configs/sysctl/99-wireguard.conf`](modules/hardening/self-managed/configs/sysctl/99-wireguard.conf)

#### Client setup

Fill in the template before deploying — every client gets a unique IP within
the VPN subnet:

| Field | Source | Example |
|---|---|---|
| `[Interface] Address` | Assign manually — unique per client | `172.16.0.2/32` |
| `[Interface] PrivateKey` | Generated on server, transferred once, then deleted | `<client-private-key>` |
| `[Interface] DNS` | Pre-filled — Quad9 | `9.9.9.9` |
| `[Peer] PublicKey` | `/etc/wireguard/server_public.key` on the server | `<server-public-key>` |
| `[Peer] Endpoint` | LAN IP (VM) or public IP (VPS) + port | `192.168.X.X:51820` |
| `[Peer] AllowedIPs` | Split tunnel — VPN subnet only | `172.16.0.0/24` |
| `[Peer] PersistentKeepalive` | Pre-filled — required behind NAT | `25` |

📄 [`configs/wireguard/client-template.conf`](modules/hardening/self-managed/configs/wireguard/client-template.conf)

##### macOS
```bash
brew install wireguard-tools wireguard-go
sudo mkdir -p /etc/wireguard
sudo cp modules/hardening/self-managed/configs/wireguard/client-template.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo wg-quick up wg0

# Autostart at boot (optional)
sudo launchctl load /Library/LaunchDaemons/com.wireguard.wg0.plist
```

##### Linux
```bash
sudo apt install wireguard -y       # Debian/Ubuntu
# sudo dnf install wireguard-tools  # Fedora/RHEL

sudo mkdir -p /etc/wireguard
sudo cp modules/hardening/self-managed/configs/wireguard/client-template.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo wg-quick up wg0
sudo systemctl enable wg-quick@wg0
```

##### Windows
Download [WireGuard for Windows](https://www.wireguard.com/install/).
Import the filled template via `Add Tunnel → Import tunnel(s) from file`.
To autostart: right-click the tunnel → `Edit tunnel` → check
`Launch WireGuard on startup`.

#### AWS EC2 — deployment notes
The steps above apply to both environments. EC2-specific deltas:

**Endpoint:** use the Elastic IP (`<EIP>`) instead of the LAN address.
The Elastic IP is static — client configs do not need updating on instance stop/start.

**Security Group:** once WireGuard is active, remove the inbound rule for
`22222/tcp` from `multi-lab-sg`. UFW enforces SSH access via `wg0` — the
Security Group rule is redundant and increases attack surface.
`51820/udp` must remain open to `0.0.0.0/0`.

**Hub-and-spoke topology:** EC2 acts as the WireGuard hub. All devices connect
as peers via outbound connections to the Elastic IP — this bypasses CGNAT on the
home network without requiring an inbound-reachable IP on either the Mac or the VM.

| Peer | VPN address | Endpoint |
|---|---|---|
| Mac | `172.16.0.2` | `<EIP>:51820` |
| VM (VMware) | `172.16.0.3` | `<EIP>:51820` |

> **`wg0.conf` and `client-template.conf`** do not require changes — the
> `Endpoint` field in the client template already uses a placeholder. Fill it
> with the Elastic IP at deployment time. Peer IPs are assigned sequentially
> from the existing VPN subnet (`10.0.0.0/24`).

### Why
WireGuard adds a cryptographic perimeter in front of SSH. A client without a
valid private key receives no response from the server — the port appears
closed to scanners and bots. This is authentication at the network layer
before any application protocol is involved, not port obscurity.

Restricting SSH to the `wg0` interface eliminates the entire category of
internet-facing SSH attacks. Fail2Ban and UFW remain active as
defense-in-depth layers for any traffic that reaches the VPN.

Split tunnel (`AllowedIPs = 10.0.0.0/24`) routes only VPN subnet traffic
through the server — peer-to-peer traffic between clients is forwarded by
the hub, but each client's regular internet traffic exits locally.
Full tunnel (`0.0.0.0/0`) would route all client internet traffic through
the server, adding unnecessary load and latency without security benefit
for this use case.

### Verification
```bash
# Server — interface active, peers registered, port listening
sudo wg show

# UFW rules — correct state after Step 5
sudo ufw status numbered
# → 51820/udp  ALLOW     Anywhere     (WireGuard VPN)
# → 22222/tcp  ALLOW IN  on wg0       (SSH via WireGuard only)
# → Anywhere on wg0  ALLOW FWD        Anywhere on wg0
# → NO open rule for 22222/tcp to Anywhere

# Client — ping server VPN IP with tunnel active
ping 172.16.0.1

# Client — SSH via VPN
ssh -p 22222 <username>@172.16.0.1

# Negative test — SSH must be unreachable without WireGuard
# EC2 only: do NOT run wg-quick down from inside the tunnel.
# Dropping wg0 cuts the only SSH path — the instance becomes unreachable
# until restarted from the AWS EC2 console.
# Run this test from a second terminal with an active tunnel, or skip it —
# the UFW rule check above is sufficient to confirm the configuration is correct.
sudo wg-quick down wg0          # VM/bare metal only
ssh -p 22222 -o ConnectTimeout=5 <server-ip>
# → Connection timed out
sudo wg-quick up wg0

# Confirm handshake on server
sudo wg show
# → latest handshake: X seconds ago
# → transfer: X KiB received, X KiB sent
```

---

## Step 6 — Fail2Ban

### What was done
`fail2ban` installed, then `jail.local` created as the upgrade-safe override — `jail.conf` is never edited directly. Ban escalation policy across three jails:

| Jail | Trigger | Ban duration |
|---|---|---|
| `[DEFAULT]` | 3 failures / 5 min | 24 hours |
| `[sshd]` | 3 failures / 5 min | 48 hours |
| `[recidive]` | 3 bans / 7 days | 30 days |

Key decisions:
- `banaction = ufw` — bans applied as UFW rules, not separate iptables chains
- `port = 22222` — set explicitly; the `ssh` keyword resolves to port 22 regardless of what SSH is actually listening on
- `filter = sshd[mode=aggressive]` — combines normal + ddos + extra pattern sets
- `[recidive]` reads from `/var/log/fail2ban.log` — requires rsyslog routing from Step 11 to be active

`ignoreip` whitelists loopback, the LAN subnet, and the WireGuard VPN subnet.

> **VM:** include your LAN subnet (`192.168.X.X/X`) in `ignoreip`.
> **VPS with no trusted LAN:** keep only `127.0.0.1/8 ::1` and `172.16.0.0/24`
> (WireGuard subnet). Remove the LAN entry if WireGuard was not deployed.
> **Cloud note:** In EC2, avoid whitelisting a dynamic home IP in `ignoreip`.
> Keep only loopback unless you have a stable private access path such as
> WireGuard.

`allowipv6` fix — `fail2ban.conf` ships with this value commented out,
causing a `WARNING` on every `fail2ban-client` invocation. Applied via the
official override directory, upgrade-safe:

```bash
sudo apt install fail2ban -y
sudo systemctl enable fail2ban
sudo cp modules/hardening/self-managed/configs/fail2ban/jail.local /etc/fail2ban/jail.local
sudo mkdir -p /etc/fail2ban/fail2ban.d
sudo cp modules/hardening/self-managed/configs/fail2ban/fail2ban.d/allowipv6.conf /etc/fail2ban/fail2ban.d/allowipv6.conf
sudo systemctl restart fail2ban
```

📄 [`configs/fail2ban/jail.local`](modules/hardening/self-managed/configs/fail2ban/jail.local)
📄 [`configs/fail2ban/fail2ban.d/allowipv6.conf`](modules/hardening/self-managed/configs/fail2ban/fail2ban.d/allowipv6.conf)

### Why
Fail2Ban operates at the application layer, complementing UFW at the network
layer. It reads SSH logs directly and bans IPs that exceed the failure
threshold — making the server statistically unattractive to automated attacks.

The escalation policy is intentional: the `[recidive]` jail targets repeat
offenders across multiple ban cycles with a 30-day ban, creating a long-term
deterrent against persistent attackers that a single `[sshd]` ban does not
provide.

### Verification
```bash
# Active jails — sshd and recidive must appear
sudo fail2ban-client status

# sshd jail detail — fail counts and banned IPs
sudo fail2ban-client status sshd

# Aggressive mode active — must return 33 or more failregex
sudo fail2ban-client get sshd failregex | wc -l

# banaction = ufw working — ban appears as a UFW DENY rule (no f2b- prefix)
sudo fail2ban-client set sshd banip 10.0.0.99
sudo ufw status | grep "10.0.0.99"
# → 10.0.0.99  DENY IN
sudo fail2ban-client set sshd unbanip 10.0.0.99

# Fail2Ban reading from systemd journal (correct on Ubuntu 24.04)
sudo fail2ban-client get sshd journalmatch
# → _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

> **Fail2Ban v1.0.x:** `get sshd mode` and `get sshd filter` return
> `Invalid command` — expected behavior on v1.0.x. Use `failregex | wc -l`
> above to confirm aggressive mode.

---

## Step 7 — Kernel Hardening (sysctl)

### What was done
`/etc/sysctl.d/99-z-hardening.conf` applies hardening parameters across four
areas: network stack, kernel internals, filesystem protections, and core dump
control. Each parameter is documented inline in the config file.

```bash
sudo cp modules/hardening/self-managed/configs/sysctl/99-z-hardening.conf /etc/sysctl.d/99-z-hardening.conf
sudo sysctl --system
```

> **Load order — file naming:** Ubuntu 24.04 loads sysctl files in
> alphanumeric order across `/usr/lib/sysctl.d/`, `/run/sysctl.d/`, and
> `/etc/sysctl.d/`. The system package `99-protect-links.conf` (in
> `/usr/lib/sysctl.d/`) sets `fs.protected_fifos = 1` and loads **after**
> a plain `99-hardening.conf`, silently reverting the hardened value of `2`.
> The `99-z-` prefix guarantees this file loads last, winning over any
> system-provided `99-*` file.

📄 Full config with inline comments →
[`configs/sysctl/99-z-hardening.conf`](modules/hardening/self-managed/configs/sysctl/99-z-hardening.conf)

### Why
The kernel exposes information and capabilities by default that facilitate
post-compromise exploitation — these parameters do not prevent an attacker
from gaining access, but make privilege escalation, lateral movement, and
information extraction significantly harder once inside.

The network parameters are especially relevant on internet-facing servers:
they block IP spoofing, absorb SYN flood attacks without exhausting connection
tables, and prevent routing manipulation via ICMP.

`fs.suid_dumpable = 0` is applied here at the kernel layer. Shell-level
enforcement via `pam_limits` is added in Step 9 — both layers are required.

### Verification
```bash
# Confirm load order — 99-z-hardening must appear last
sudo sysctl --system | grep "Applying"

# Verify key runtime values
# Kernel — memory and privilege hardening
sysctl kernel.randomize_va_space        # → 2
sysctl kernel.kptr_restrict             # → 2
sysctl kernel.dmesg_restrict            # → 1
sysctl kernel.sysrq                     # → 0
sysctl kernel.perf_event_paranoid       # → 3
sysctl kernel.unprivileged_bpf_disabled # → 2
sysctl kernel.core_uses_pid             # → 1
sysctl kernel.modules_disabled          # → 0  (WireGuard module — see KRNL-6000)

# Filesystem
sysctl fs.suid_dumpable                 # → 0
sysctl fs.protected_fifos               # → 2
sysctl fs.protected_hardlinks           # → 1
sysctl fs.protected_symlinks            # → 1

# Network
sysctl net.ipv4.tcp_syncookies          # → 1
sysctl net.ipv4.tcp_rfc1337             # → 1
sysctl net.ipv4.conf.all.rp_filter      # → 1
sysctl net.ipv4.conf.all.accept_redirects    # → 0
sysctl net.ipv4.conf.all.send_redirects      # → 0
sysctl net.ipv4.conf.all.accept_source_route # → 0
sysctl net.ipv6.conf.all.accept_redirects    # → 0
sysctl net.ipv6.conf.all.accept_source_route # → 0
sysctl net.ipv4.ip_forward              # → 1  (WireGuard active)
sysctl dev.tty.ldisc_autoload           # → 0

# BPF — requires sudo
sudo sysctl net.core.bpf_jit_harden     # → 2

# Confirm log_martians persists after UFW reload
sudo ufw reload
sysctl net.ipv4.conf.all.log_martians net.ipv4.conf.default.log_martians
# → 1, 1 — if 0, check /etc/ufw/sysctl.conf
```

---

## Step 8 — AppArmor

### What was done
Additional profile packages installed to expand AppArmor coverage beyond
the OS defaults:

```bash
sudo apt install apparmor-utils apparmor-profiles apparmor-profiles-extra -y
```

| Package | Role | Profiles added to `/etc/apparmor.d/` |
|---|---|---|
| `apparmor-utils` | CLI tools (`aa-enforce`, `aa-status`, `aa-genprof`) | 0 — tools only |
| `apparmor-profiles` | Active profiles for common server daemons | ~19 (samba, syslog, dnsmasq…) |
| `apparmor-profiles-extra` | Active profiles + optional library | ~5 active + ~100 in `/usr/share/apparmor/extra-profiles/` |

Profiles in `/usr/share/apparmor/extra-profiles/` are not active by default —
they are a ready-to-use library. When Nginx, BIND9, or other daemons are
deployed in later steps, the relevant profile will be copied to
`/etc/apparmor.d/` and enforced with `aa-enforce`.

### Why
AppArmor implements Mandatory Access Control (MAC): each program has a profile
that defines exactly which files it can read/write, which syscalls it can use,
and which capabilities it holds. Even if an attacker exploits a vulnerability
in Nginx or BIND9, AppArmor confines the compromised process to what its
profile allows — preventing lateral movement regardless of what the process
itself attempts.

### Verification
```bash
# Summary of loaded profiles and confined processes
sudo aa-status

# Profile count varies by package version — the exact number is not
# meaningful. What matters: confirm loaded profiles increased after
# installation and that running services have enforce mode active.
# At this stage only system daemons (chronyd, rsyslogd) will appear
# as confined processes — application profiles are enabled per service
# as each one is deployed in later steps.

# No profile load errors
sudo dmesg | grep -i apparmor     # → no DENIED or error lines at boot

# Profiles available for future services
ls /usr/share/apparmor/extra-profiles/ | wc -l   # → ~100
```

---

## Step 9 — Attack Surface Reduction

### 9.1 — Services & Daemons

#### What was done
Unused services disabled to eliminate unnecessary code paths, listening
sockets, and privilege escalation vectors.

```bash
sudo systemctl disable --now ModemManager
sudo systemctl mask packagekit udisks2
```

> **`packagekit`** uses D-Bus socket activation and has no `[Install]` section —
> `disable` is a no-op and returns a warning. `mask` (symlink to `/dev/null`)
> is the correct action: it prevents activation via D-Bus, systemd dependency,
> or manual start. Same rationale applies to `udisks2`.

`udisks2` is masked rather than disabled — symlinked to `/dev/null`, it cannot
start manually or as a dependency. Complements the `usb_storage` kernel
blacklist in 9.3 by eliminating the D-Bus storage automation layer.

**apport** removed — Ubuntu's crash reporting daemon has no use case on a
server, and critically: it sets `fs.suid_dumpable = 2` at runtime, overriding
the hardened value `0` set in Step 7. With value `2`, SUID process memory
(passwords, private keys, session tokens) becomes readable via core dumps.

```bash
sudo apt purge apport apport-core-dump-handler apport-symptoms python3-apport -y
sudo apt autoremove --purge -y
```

> **EC2 — SSM Agent migration (required before purging snapd):** On EC2,
> `amazon-ssm-agent` ships pre-installed as a snap. Purging snapd without
> migrating the agent first permanently removes SSM Session Manager access —
> the only shell path that requires no open inbound port.
> Migrate to the apt package before proceeding:

```bash
# Remove snap IPC socket leftovers to prevent address-in-use errors on first start
sudo rm -rf /var/lib/amazon/ssm/ipc/

# Download and install the apt package — replaces the snap-managed agent
# ARM64 (Graviton):
wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb
# x86_64:
# wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb

sudo dpkg -i amazon-ssm-agent.deb
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent
rm amazon-ssm-agent.deb
```

> If `dpkg` aborts with *"installed by snap, please use snap to update or
> uninstall"*, snap metadata is still present. Remove it and retry:
> ```bash
> sudo rm -rf /var/lib/snapd
> sudo dpkg -i amazon-ssm-agent.deb
> ```

> Verify the agent is online before purging snapd:
> ```bash
> sudo systemctl status amazon-ssm-agent   # → active (running)
> # From local machine (AWS CLI required):
> aws ssm describe-instance-information \
>   --profile multi-lab-admin \
>   --query "InstanceInformationList[*].{ID:InstanceId,Status:PingStatus}"
> # → PingStatus: "Online"
> ```

**snapd** removed and pinned to prevent silent reinstallation as a future
package dependency:

```bash
sudo apt purge snapd -y
sudo apt autoremove --purge -y
rm -rf ~/snap /var/snap /var/lib/snapd
sudo apt-mark hold snapd
```

> **VM vs VPS:**
>
> | Service | VM (VMware) | VPS |
> |---|---|---|
> | open-vm-tools | Keep | Remove |
> | vgauth | Keep | Remove |
> | multipathd | Disable unless multi-path storage | Disable unless multi-path storage |
> | ModemManager | Disable | Disable unless mobile broadband |
> | snapd | Purge recommended — not required on server | Purge — no use case on a headless server |
>
> VirtualBox: use `virtualbox-guest-utils` instead of `open-vm-tools`.
> Target service count is ≤17 regardless of platform.

#### Why
Every running service is an attack surface — a listening socket, a privilege
boundary, or a code path that can be exploited. Removing services that will
never be used eliminates those vectors entirely rather than relying on
configuration alone to constrain them.

> **Evaluation criteria — disable/mask if the service falls into any of these categories:**
>
> | Category | Examples | Action |
> |---|---|---|
> | Hypervisor guest agents | `open-vm-tools`, `vboxguard` | Keep on VM — mask on VPS/EC2 |
> | Hardware abstraction | `udisks2`, `ModemManager`, `bluetooth` | Mask — no physical hardware |
> | Crash reporting / telemetry | `apport`, `ubuntu-advantage-esm-apps` | Purge |
> | D-Bus activated package managers | `packagekit`, `snapd` | Mask / purge |
> | Cloud provisioning agents | `cloud-init` | Keep on EC2 — evaluate elsewhere |
> | SSM Agent | `amazon-ssm-agent` | Migrate to apt before purging snapd — see block above |
>
> The target is the minimum set required to run the lab's services. No fixed number —
> any service not justified by a deployed component is a candidate for removal.

### Verification

```bash
# Audit running services — evaluate each against the lab's purpose
systemctl list-units --type=service --state=running --no-legend --no-pager \
  | awk '{print $1}' | sort

# For any unknown service:
#   systemctl cat <service>                    — what it does
#   systemctl show <service> -p WantedBy       — what depends on it

systemctl is-enabled udisks2        # → masked
systemctl status udisks2            # → masked; vendor preset: enabled

sudo sysctl --system                # → reload sysctl
sysctl fs.suid_dumpable             # → fs.suid_dumpable = 0
# sysctl --system reloads all files from /usr/lib/sysctl.d/, /run/sysctl.d/, and
# /etc/sysctl.d/ in order. Run it any time a package removal may have
# altered runtime kernel parameters — apport is a known example.

dpkg -l | grep apport               # → no output

apt-mark showhold | grep snapd      # → snapd
snap list 2>&1                      # → Command 'snap' not found

# SSM Agent — apt package active, snap gone
sudo systemctl is-active amazon-ssm-agent   # → active
dpkg -l | grep amazon-ssm-agent             # → ii  amazon-ssm-agent ...
```

---

### 9.2 — Filesystem & User Hardening

#### What was done
**File permissions** — more restrictive than Ubuntu defaults (Lynis FILE-7524):

```bash
sudo chmod 600 /etc/crontab
sudo chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly
sudo chmod 750 /etc/sudoers.d
```

**Default umask and password aging** — applied via `sed` to `/etc/login.defs`:

> `login.defs` is managed by the `passwd` package and may be overwritten on
> upgrades. All changes use `sed` — idempotent and upgrade-safe. Not versioned.

```bash
# Umask
sudo sed -i 's/^UMASK\s.*/UMASK\t\t027/' /etc/login.defs
sudo sed -i 's/^USERGROUPS_ENAB\s.*/USERGROUPS_ENAB\tno/' /etc/login.defs

# Password aging
sudo sed -i 's/^PASS_MAX_DAYS\s.*/PASS_MAX_DAYS\t90/' /etc/login.defs
sudo sed -i 's/^PASS_MIN_DAYS\s.*/PASS_MIN_DAYS\t1/' /etc/login.defs
sudo sed -i 's/^PASS_WARN_AGE\s.*/PASS_WARN_AGE\t14/' /etc/login.defs

# SHA512 rounds — required by both PAM and login.defs independently (AUTH-9229 / AUTH-9230)
sudo sed -i '/SHA_CRYPT_MIN_ROUNDS/s/.*/SHA_CRYPT_MIN_ROUNDS 65536/' /etc/login.defs
sudo sed -i 's/^#\?SHA_CRYPT_MAX_ROUNDS.*/SHA_CRYPT_MAX_ROUNDS 65536/' /etc/login.defs
```

> Password aging applies to new accounts only. Existing accounts require `chage`:
> ```bash
> sudo chage -M 90 -m 1 -W 14 <username>
> ```
> Re-encrypt existing passwords to apply the new SHA512 rounds to stored hashes:
> ```bash
> sudo passwd <username>
> ```

**Password policy (PAM):**

```bash
sudo apt install libpam-pwquality libpam-tmpdir -y
sudo cp modules/hardening/self-managed/configs/pam/common-password /etc/pam.d/common-password
sudo cp modules/hardening/self-managed/configs/pam/common-session /etc/pam.d/common-session
```

`libpam-tmpdir` gives each login session a private `$TMPDIR` under
`/tmp/user/<uid>` — isolated from other users, preventing symlink and race
condition attacks against the global `/tmp`.

> `common-password` and `common-session` are managed as static files —
> `pam-auth-update` is not called after deployment. Future `pam-auth-update`
> invocations (triggered by package installs) may overwrite these files.
> Re-apply the configs after any PAM package upgrade.

📄 [`configs/pam/common-password`](modules/hardening/self-managed/configs/pam/common-password)
📄 [`configs/pam/common-session`](modules/hardening/self-managed/configs/pam/common-session)

**Core dumps** — disabled at two independent layers:

| Layer | Mechanism | Where |
|---|---|---|
| Kernel | `fs.suid_dumpable = 0` | Step 7 — sysctl |
| PAM / shell | `pam_limits` hard+soft `core=0` | `configs/limits/limits.conf` |

```bash
sudo cp modules/hardening/self-managed/configs/limits/limits.conf /etc/security/limits.conf
```

> `limits.conf` applies to new login sessions only — verify in a freshly
> opened SSH session.

📄 [`configs/limits/limits.conf`](modules/hardening/self-managed/configs/limits/limits.conf)

#### Why
Restrictive permissions limit lateral movement if a process is compromised —
an attacker with access to a low-privilege process cannot read or modify
cron jobs or sudoers entries. Password policy and session isolation address
credential abuse and `/tmp`-based privilege escalation. Core dumps are
disabled at both kernel and shell level because neither layer alone is
sufficient: `sysctl` controls setuid dumps, `limits.conf` controls
user-initiated dumps.

### Verification

```bash
grep "^UMASK" /etc/login.defs            # → UMASK          027
grep "^USERGROUPS_ENAB" /etc/login.defs  # → USERGROUPS_ENAB        no
umask                                    # → 0027  — open a NEW SSH session first

stat -c "%n %a" /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly
# → 700 each
ls -la /etc/crontab                 # → 600
ls -la /etc/ | grep sudoers         # → sudoers.d 750

grep -E "PASS_MAX|PASS_MIN|PASS_WARN" /etc/login.defs  # → 90 / 1 / 14
sudo chage -l <username>            # → Maximum: 90 / Minimum: 1 / Warning: 14

grep "SHA_CRYPT" /etc/login.defs
# → SHA_CRYPT_MIN_ROUNDS 65536
# → SHA_CRYPT_MAX_ROUNDS 65536
sudo grep "^<username>:" /etc/shadow | cut -d: -f2 | cut -c1-3
# → $6$  (SHA512 — correct)
# If $y$ appears, run: sudo passwd <username>  to re-hash with the new policy

grep pam_pwquality /etc/pam.d/common-password   # → retry=3 minlen=12 ...
grep pam_unix /etc/pam.d/common-password        # → sha512 rounds=65536
grep pam_tmpdir /etc/pam.d/common-session       # → session optional pam_tmpdir.so
# Verify private TMPDIR — open a NEW SSH session first
echo $TMPDIR                                    # → /tmp/user/<uid>

# Core dumps — in a NEW SSH session
ulimit -c                                       # → 0

# Weak password rejected
sudo passwd <username>
# → BAD PASSWORD: The password contains less than 1 uppercase letters

# Account expiry — 365 days from setup date
sudo chage -E $(date -d "+365 days" +%Y-%m-%d) <username>
sudo chage -l <username>
# → Account expires: <date>
```

---

### 9.3 — Kernel Modules

#### What was done
Five kernel modules disabled — four unused network protocol stacks and USB
storage. None are required by this lab.

| Module | Reason |
|---|---|
| `dccp` | Datagram congestion control — CVE history, unused |
| `sctp` | Multi-stream transport (telecom origin) — CVE history, unused |
| `rds` | Low-latency cluster messaging — CVE history, unused |
| `tipc` | Dynamic cluster IPC — CVE-2021-43267 (remote code execution) |
| `usb_storage` | Blocks physical data exfiltration via USB |

```bash
sudo cp modules/hardening/self-managed/configs/modprobe/disable-unused-protocols.conf /etc/modprobe.d/disable-unused-protocols.conf
sudo update-initramfs -u
```

📄 [`configs/modprobe/disable-unused-protocols.conf`](modules/hardening/self-managed/configs/modprobe/disable-unused-protocols.conf)

#### Why
Unused protocol stacks are a direct kernel-level attack surface. Blacklisting
via `modprobe.d` prevents loading even if a process or user attempts it
explicitly — the module returns an error on load rather than simply being
absent from the default configuration.

### Verification

```bash
lsmod | grep -E "dccp|sctp|rds|tipc|usb_storage"   # → no output
sudo modprobe dccp 2>&1                            # → Invalid argument
```

---

### 9.4 — Monitoring & Forensics

#### What was done
Three complementary tools covering different detection scopes:

**rkhunter** — signature-based rootkit detection, complements AIDE (integrity
baseline) and auditd (real-time syscall events).

> **Installation prompt — Postfix (MTA):** `apt install rkhunter` triggers a
> Postfix configuration dialog because rkhunter supports email alerting.
>
> | Option | When to use |
> |---|---|
> | `No configuration` | **EC2 / VPS — select this.** No mail server in this lab. |
> | `Internet Site` | Only if a local MTA is configured and outbound SMTP is available. |
>
> Selecting `No configuration` skips Postfix setup entirely. rkhunter daily
> reports land in `/var/log/rkhunter.log` — reviewed via cron output or
> manually. Email alerting can be added later via `MAIL-ON-WARNING` in
> `/etc/rkhunter.conf` once an SMTP relay is available.

```bash
sudo apt install rkhunter -y
sudo sed -i 's/WEB_CMD="\/bin\/false"/WEB_CMD=""/' /etc/rkhunter.conf
sudo sed -i 's/UPDATE_MIRRORS=0/UPDATE_MIRRORS=1/' /etc/rkhunter.conf
sudo sed -i 's/MIRRORS_MODE=1/MIRRORS_MODE=0/' /etc/rkhunter.conf
sudo sed -i '/^#ALLOWHIDDENFILE=/a ALLOWHIDDENFILE=/etc/.updated' /etc/rkhunter.conf
sudo sed -i 's/CRON_DAILY_RUN=""/CRON_DAILY_RUN="true"/' /etc/default/rkhunter
sudo sed -i 's/CRON_DB_UPDATE=""/CRON_DB_UPDATE="true"/' /etc/default/rkhunter
sudo sed -i 's/APT_AUTOGEN="false"/APT_AUTOGEN="yes"/' /etc/default/rkhunter
sudo rkhunter --update
sudo rkhunter --propupd
```

**acct** — records every command executed by every user; essential for
post-incident forensics:

```bash
sudo apt install acct -y
sudo systemctl enable acct --now
```

**sysstat** — collects CPU/memory/I/O metrics every 10 minutes:

```bash
sudo sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
sudo systemctl enable sysstat --now
```

#### Why
Detection tools operate after a potential compromise — they answer *what
happened* rather than preventing it. rkhunter detects known rootkit signatures
that AIDE and auditd may not catch. acct provides an irrefutable command
history per user, independent of shell history. sysstat establishes a
performance baseline that makes anomalous resource consumption visible.

### Verification

```bash
sudo rkhunter --check --skip-keypress 2>&1 | tail -5 # → Normal frezze for a minute
grep -E "CRON_DAILY|CRON_DB|APT_AUTO" /etc/default/rkhunter
# → CRON_DAILY_RUN="true" / CRON_DB_UPDATE="true" / APT_AUTOGEN="yes"

sudo lastcomm | head -10 # Last commands executed 
sar -u 1 3 
```

---

## Step 10 — Audit Trail (auditd + AIDE)

### What was done
Two complementary layers covering different time dimensions: auditd records
events in real time at the syscall level; AIDE detects filesystem state
changes against a cryptographic baseline.

**auditd**

Rules cover the following monitoring areas:

| Key | What is monitored |
|---|---|
| `identity` | `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/sudoers{,.d}` |
| `pam_config` | `/etc/pam.d/` — authentication module stack |
| `sshd_config` | `/etc/ssh/sshd_config` |
| `privileged` | `su`, `sudo` execution |
| `network_config` | `/etc/netplan/`, `/etc/hosts` |
| `audit_config` | `/etc/audit/`, `auditctl`, `auditd` binaries |
| `mounts` | Mount syscalls — user-initiated only (`auid>=1000`) |
| `file_deletion` | Delete and rename syscalls — user-initiated only (`auid>=1000`) |
| `vpn_config` | `/etc/wireguard/` — conditional, only if Step 5 was deployed |
| `cron_config` | `/etc/crontab`, `/etc/cron.{d,daily,hourly,weekly,monthly}/` |
| `-e 2` | Immutable mode — rules cannot be modified without a reboot |

Deploy the rules file and load it:
```bash
sudo apt install auditd audispd-plugins -y
sudo systemctl enable auditd
sudo systemctl start auditd
sudo cp modules/hardening/self-managed/configs/audit/99-hardening.rules /etc/audit/rules.d/99-hardening.rules
sudo augenrules --load
```

> **`audispd-plugins`** provides the audit dispatcher — required to forward
> auditd events to rsyslog. Installed here; the integration is configured
> in Step 11.

> **Immutable mode conflict:** if auditd already has rules loaded with `-e 2`
> from a previous session, `augenrules --load` returns:
> `Error sending add rule request: Operation not permitted`
> Restart auditd to reset the ruleset before reloading:
> ```bash
> sudo systemctl restart auditd
> sudo augenrules --load
> ```

> **ARM64:** `unlink` and `rename` do not exist in the aarch64 ABI — the
> rules use `unlinkat`, `renameat`, `renameat2` only. On ARM64, auditd
> silently stops parsing at the first unknown syscall — everything after it,
> including `-e 2`, is not loaded. Verify active syscall names before deploying:
> ```bash
> ausyscall --dump | grep -E "unlink|rename"
> # ARM64 expected output — unlink/rename do NOT exist, only their *at variants:
> # 35   unlinkat
> # 38   renameat
> # 276  renameat2
> # x86_64 expected output — classic names present:
> # 87   unlink
> # 82   rename
> # 263  unlinkat
> # 316  renameat2
> ```
> On ARM64 (EC2 t4g/Graviton), the rules file uses unlinkat, renameat, 
> renameat2 only — unlink and rename do not exist in the aarch64 ABI
> and must not appear in the rules or auditd silently stops parsing.

📄 [`configs/audit/99-hardening.rules`](modules/hardening/self-managed/configs/audit/99-hardening.rules)

**AIDE**

Monitors critical system paths for any content, permission, or ownership change:
`/etc/ssh` · `/etc/sudoers{,.d}` · `/etc/pam.d` · `/etc/audit` · `/etc/sysctl.d` ·
`/etc/modprobe.d` · `/etc/fail2ban` · `/etc/wireguard` · `/bin` · `/sbin` ·
`/usr/bin` · `/usr/sbin` · `/usr/lib/systemd/system` · `/boot`

```bash
sudo apt install aide aide-common -y   # Postfix prompt → "No configuration"
sudo cp modules/hardening/self-managed/configs/aide/99-hardening /etc/aide/aide.conf.d/99-hardening
sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> The database must exist before running --check. --init builds the
> baseline snapshot of the filesystem — --check compares against it.
> Running --check without a database always fails with
> open failed for file '/var/lib/aide/aide.db': No such file or directory.

> `aide --init` exits with code 17 and emits warnings on continuously written
> files (`audit.log`, `pacct`) — expected. The database is generated correctly.

Enable daily automated check:
```bash
sudo sed -i 's/^#\?CRON_DAILY_RUN=.*/CRON_DAILY_RUN=yes/' /etc/default/aide
```

📄 [`configs/aide/99-hardening`](modules/hardening/self-managed/configs/aide/99-hardening)

### Why
auditd catches what an attacker does in real time — privilege escalation,
syscall abuse, identity file modifications. AIDE catches what changed between
checks — a modified binary, a tampered config, an injected cron job.
`-e 2` prevents an attacker with root from silencing auditd before acting.

The `mounts` and `file_deletion` rules are filtered to user-initiated events
(`auid>=1000`) to exclude routine system activity — `apt`, `logrotate`,
`systemd-tmpfiles` — which would otherwise saturate the audit log and
pressure the buffer under load.

### Verification

```bash
# auditd — confirm rules loaded (any output = correct, empty = rules not loaded)
sudo auditctl -l | grep -c "\-k"
# → 9  (one line per rule key — exact number may vary by architecture)

# auditd — immutable mode active (run AFTER loading rules)
sudo auditctl -s | grep enabled
# → enabled 2

# auditd — confirm all rule keys loaded
sudo auditctl -l | grep -oP '(?<=-k )\S+' | sort -u
# → audit_config, cron_config, file_deletion, identity,
#   mounts, network_config, privileged, sshd_config, vpn_config

# auditd — test identity rule (triggers on /etc/shadow read)
sudo cat /etc/shadow > /dev/null
sudo ausearch -k identity | tail -3
# → type=SYSCALL ... key="identity"

# auditd — test file_deletion (run as normal user, not root)
touch ~/audit-test && mv ~/audit-test ~/audit-test-renamed && rm ~/audit-test-renamed
sudo ausearch -k file_deletion --uid $(id -u) | tail -5
# → type=SYSCALL ... key="file_deletion" ... auid=1000

# auditd — test vpn_config
sudo touch /etc/wireguard/audit_test
sudo ausearch -k vpn_config | tail -3
# → type=SYSCALL ... key="vpn_config"
sudo rm /etc/wireguard/audit_test

# auditd — test cron_config
sudo touch /etc/cron.d/audit_test
sudo ausearch -k cron_config | tail -3
# → type=SYSCALL ... key="cron_config"
sudo rm /etc/cron.d/audit_test

# AIDE — database exists
sudo ls -lh /var/lib/aide/aide.db
# → -rw------- ... /var/lib/aide/aide.db

# AIDE — clean baseline check (no output = no changes = correct)
sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.

# AIDE — daily cron active (must not start with #)
grep CRON_DAILY_RUN /etc/default/aide
# → CRON_DAILY_RUN=yes

# AIDE — test detection
sudo touch /etc/ssh/aide_test
sudo aide --check --config /etc/aide/aide.conf 2>/dev/null | grep "aide_test"
# → f+++++++++++++++++: /etc/ssh/aide_test
# f+++++++++++++++++ — 17 + signs indicate a new file not present in
# the baseline database. The exact count varies by AIDE version and monitored
# attributes — grep by filename, not by + pattern, to avoid version-dependent
# mismatches.
# Expected changes on every --check (active logs, not a sign of compromise):
# /var/log/account/pacct · /var/log/audit/audit.log · /var/log/sysstat/sa<DD>
# /var/log/amazon/ssm/ — AWS EC2 only, SSM Agent kept active for emergency access

# AIDE — cleanup and regenerate baseline after test
sudo rm /etc/ssh/aide_test
sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

---

## Step 11 — Log Management (rsyslog + logrotate)

### What was done
rsyslog ships active on Ubuntu 24.04. The default `50-default.conf` already
routes `auth.*` and `kern.*` — the custom config adds only what is missing:
dedicated files for UFW and Fail2Ban events, with correct ownership and rotation.

Enable UFW logging — its own switch, independent of rsyslog:
```bash
sudo ufw logging on
```

Create log files before rsyslog starts. rsyslog runs as uid `syslog` — if a
file is owned by `root`, rsyslog writes to it silently fail with no error:
```bash
sudo install -m 640 -o syslog -g adm /dev/null /var/log/ufw.log
sudo install -m 640 -o syslog -g adm /dev/null /var/log/fail2ban.log
```

Deploy the configs and restart:
```bash
sudo cp modules/hardening/self-managed/configs/rsyslog/20-ufw.conf /etc/rsyslog.d/20-ufw.conf
sudo cp modules/hardening/self-managed/configs/rsyslog/99-hardening.conf /etc/rsyslog.d/99-hardening.conf
sudo cp modules/hardening/self-managed/configs/logrotate/hardening-logs /etc/logrotate.d/hardening-logs
sudo systemctl restart rsyslog
```

📄 Configs:
- [`configs/rsyslog/20-ufw.conf`](modules/hardening/self-managed/configs/rsyslog/20-ufw.conf)
- [`configs/rsyslog/99-hardening.conf`](modules/hardening/self-managed/configs/rsyslog/99-hardening.conf)
- [`configs/logrotate/hardening-logs`](modules/hardening/self-managed/configs/logrotate/hardening-logs)

### Why
auditd and rsyslog are complementary — auditd records syscall-level events
(file access, privilege escalation), rsyslog records service-level events
(SSH attempts, firewall blocks, bans). Dedicated files per service make
incident investigation faster than grepping a mixed syslog.

`postrotate` reloads rsyslog after each rotation. Without it rsyslog keeps
writing to the rotated file's old inode — new log entries appear to be missing
until the next service restart.

### Verification
```bash
# UFW logging active
sudo ufw status verbose | grep Logging
# → Logging: on (medium)

# Correct ownership on all log files
ls -lh /var/log/auth.log /var/log/ufw.log /var/log/fail2ban.log /var/log/kern.log
# auth.log     → syslog:adm
# ufw.log      → syslog:adm
# fail2ban.log → root:adm
# kern.log     → syslog:adm

# rsyslog config syntax clean
sudo rsyslogd -N1
# → End of config validation run. Bye.

# Generate a blocked UFW event — from any LAN host:
nc -zv <server-ip> 9999
# Confirm event landed in ufw.log, not only kern.log:
sudo tail -n 3 /var/log/ufw.log
# → [UFW BLOCK] SRC=<your-ip> DPT=9999

# Auth events appear exactly once — if doubled, check 99-hardening.conf for auth.* rules
sudo tail -n 6 /var/log/auth.log

# Fail2Ban events captured
sudo tail -n 3 /var/log/fail2ban.log
# → Jail 'sshd' started / Jail is in operation

# Logrotate dry-run — verify create owners per block
sudo logrotate --debug /etc/logrotate.d/hardening-logs 2>&1 | grep -E "create|rotating|considering"
# → considering log /var/log/ufw.log
# → considering log /var/log/fail2ban.log
# → rotating log ... (or: log does not need rotating)
```

---

## Step 12 — Security Audit Baseline (Lynis)

> Lynis maps its controls internally against CIS Benchmark Level 1, NIST SP 800-53,
> and ISO 27001 — a passing Lynis control corresponds to the equivalent CIS L1
> requirement being met at runtime, not only in configuration files.
> This is not a formal CIS audit; it is a verified runtime baseline using Lynis
> as the audit engine. The badge reflects alignment, not certification.
>
> **Hardening index: 88 (VM) · 90 (EC2)**
> EC2 suppresses two additional false positives not present in the VM
> environment — see `USB-1000` and `AUTH-9284` below.
>
> EC2 scores higher than the local VM not because additional controls are
> applied manually, but because AWS manages certain checks at the platform
> level (hypervisor isolation, hardware-backed key storage, instance metadata
> controls) that Lynis counts as present. The delta is infrastructure, not
> configuration — both environments apply identical hardening steps.

### What was done
Lynis 3.0.9 was run after completing all hardening steps to establish a
verified baseline. A custom profile suppresses intentional deviations from
CIS defaults — each skipped test is documented with its justification.

Install Lynis — version 3.0.9 is available in the Ubuntu 24.04 repositories
and matches the version used to establish the baseline score:

```bash
sudo apt install lynis -y
lynis show version   # → 3.0.9
```

Deploy the custom profile before running the audit:

```bash
sudo mkdir -p /etc/lynis
sudo cp modules/hardening/self-managed/configs/lynis/custom.prf /etc/lynis/custom.prf
sudo lynis audit system --profile /etc/lynis/custom.prf
```

📄 Custom profile → [`configs/lynis/custom.prf`](modules/hardening/self-managed/configs/lynis/custom.prf)

### Why
Running Lynis post-hardening serves two purposes: it validates that all
controls are active at runtime — not just in config files — and it
establishes a baseline to detect regressions. If a future package update
silently reverts a sysctl value or SSH directive, the next audit flags it.

A suppressed test with a documented justification is more valuable than a
passing test whose reason is unknown.

### Skips & Deviations

> No residual warnings. All Lynis observations are either passing controls
> or intentional deviations documented in
> [`configs/lynis/custom.prf`](configs/lynis/custom.prf).

| Control | Type | Justification |
|---|---|---|
| `PKGS-7388` | False positive | `noble-security` present in DEB822 format — Lynis only parses classic `.list` format |
| `DEB-0810` | False positive | `apt-listbugs` is Debian-specific — not available in Ubuntu repos |
| `AUTH-9328` | False positive | `UMASK 027` + `USERGROUPS_ENAB=no` → private user groups disabled, UMASK 027 is fully effective, finding does not apply |
| `FINT-4402` | False positive | AIDE macro `H` resolves to sha256+sha512 — Lynis does not expand macros |
| `NETW-3200` | False positive | Modules blacklisted via `modprobe.d` — Lynis checks availability, not blacklist status |
| `FIRE-4513` | False positive | UFW manages iptables via its own chain — Lynis reads raw iptables without UFW context |
| `HRDN-7222` | False positive | No compilers installed — control does not apply |
| `KRNL-6000` — `kernel.unprivileged_bpf_disabled` | Conscious deviation | Value `2` — intentionally stricter than CIS L1 minimum (`1`); see Step 7 |
| `KRNL-6000` — `kernel.modules_disabled` | Conscious deviation | Value `0` — WireGuard loads as a kernel module; see Step 7 |
| `KRNL-6000` — `net.ipv4.conf.all.forwarding` | Conscious deviation | Value `1` — required for WireGuard VPN routing; see Step 5 |
| `BOOT-5122` | VM-specific | GRUB password not set — hypervisor authentication covers physical boot access |
| `FILE-6310` | Architectural constraint | `/home`, `/tmp`, `/var` not on separate partitions — requires reinstall to resolve |
| `BOOT-5264` | Temporary | systemd unit hardening applied per service at end of each module — not applicable at OS baseline *(→ each service step)* |
| `NAME-4028` | Temporary | Internal DNS not deployed yet *(→ Module DNS)* |
| `LOGG-2154` | Temporary | No external log server — planned as a future module *(→ logging module)* |
| `TOOL-5002` | Temporary | No automation tool active — each module will ship an automation script *(→ automation phase)* |
| `USB-1000` | False positive | `usb_storage` blacklisted via `modprobe.d` — Lynis checks availability, not blacklist status. No physical USB on EC2. *(EC2 only)* |
| `AUTH-9284` | False positive | Ubuntu default service accounts with `!` in `/etc/shadow` — system-managed, not orphaned. *(EC2 only)* |
| `NAME-4404` | False positive | Private IP and hostname added to `/etc/hosts` — required for FQDN resolution in cloud environments without a local DNS. *(EC2 only)* |

### Verification
```bash
# Full audit with custom profile
sudo lynis audit system --profile /etc/lynis/custom.prf

# Target a specific control group
sudo lynis audit system --profile /etc/lynis/custom.prf --tests KRNL-6000

# Review hardening index from last run
grep hardening_index /var/log/lynis-report.dat
```

---

## Snapshot

Once hardening was complete, a `complete-hardening` snapshot was taken as
the base restore point for all subsequent configurations — every service
deployed on this lab builds on top of this secure baseline.

> **VM-specific:** applies to VMware Fusion / VirtualBox deployments.
> On VPS, use your provider's snapshot/backup mechanism
> before proceeding to service deployment.

---

