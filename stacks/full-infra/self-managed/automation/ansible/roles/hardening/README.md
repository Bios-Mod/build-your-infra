# Role: hardening

This role automates the self-managed operating system hardening baseline on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the controls documented in [`modules/hardening/self-managed/hardening-self-managed.md`](../../../../../../modules/hardening/self-managed/hardening-self-managed.md).

---

## Scope & Target Environments

- **Targets:**
  - `vm` (`multi-lab-local`): Local virtual machine (VMware Fusion, VirtualBox).
  - `ec2` (`multi-lab-vps`): AWS EC2 self-managed instance (t4g.micro Graviton2).
- **Hardening Index Target:**
  - Lynis ≥ **88** on local VM.
  - Lynis ≥ **90** on AWS EC2.

---

## Role Variables

Variables are declared with sensible defaults in `defaults/main.yml` (prefixed with `hardening_` to adhere to Ansible namespace standards) and can be customized or overridden via inventory group variables (`group_vars/all.yml`, `group_vars/vm.yml`, `group_vars/ec2.yml`):

| Variable | Default (Fallback) | Description |
|---|---|---|
| `hardening_admin_username` | `admin_username` (`"admin"`) | Name of the dedicated non-root administrator account. |
| `hardening_ssh_hardened_port` | `ssh_hardened_port` (`22222`) | Hardened TCP listening port for OpenSSH daemon. |
| `hardening_wireguard_port` | `wireguard_port` (`51820`) | UDP listening port for WireGuard VPN service. |
| `hardening_wireguard_vpn_subnet` | `wireguard_vpn_subnet` (`"10.8.0.0/24"`) | Dedicated non-conflicting VPN CIDR. |
| `hardening_wireguard_server_vpn_ip` | `wireguard_server_vpn_ip` (`"10.8.0.1/24"`) | Gateway VPN IP assigned to `wg0`. |
| `hardening_auditd_immutable_mode` | `true` | Enforces immutable auditd rules (`-e 2`) in Step 10 (overridden to `false` in `vm.yml` during development). |
| `hardening_lynis_min_score` | `88` | Minimum Lynis Hardening Index threshold (88 for VM, 90 for EC2). |
| `hardening_lynis_enforce` | `false` | Whether to fail execution if Lynis score is below threshold (`false`: record & warn). |
| `is_cloud` | `false` (in `vm.yml`) / `true` (in `ec2.yml`) | Distinguishes hypervisor/bare-metal from AWS cloud platform. |
| `connection_mode` | `"pre"` | Connection phase toggle (`pre` = port 22, `post` = port 22222 on wg0). |
| `tls_mode` | `"self_signed"` (VM) / `"letsencrypt"` (EC2) | Certificate strategy per target platform. |

---

## Planned Execution Blocks & Tags

Execution is structured into three progressive gate blocks according to `context/ansible-implementation.md`:

- **Block 2A — Preparation (Tag: `hardening_2a`):**
  - Admin user provisioning and sudo authorization (Step 0).
  - APT updates and automated security upgrades (Step 1).
  - Static Netplan configuration (Step 2, VM only).
- **Block 2B — Access Chain (Tag: `hardening_2b`):**
  - OpenSSH lockdown to port 22222, key-only auth, host keys cleanup (Step 3).
  - UFW default-deny policy and rate-limited access (Step 4).
  - WireGuard cryptographic perimeter and interface routing (Step 5).
  - Fail2Ban intrusion prevention and ignoreip whitelist (Step 6).
- **Block 2C — System Hardening (Tag: `hardening_2c`):**
  - Kernel sysctl parameters with `99-z-` load order guarantee (Step 7).
  - AppArmor profile expansion (Step 8).
  - Attack surface reduction: service masking, umask, PAM, modprobe (Step 9).
  - Auditd syscall rules with immutable mode and AIDE baseline (Step 10).
  - Rsyslog dedicated logging and logrotate policies (Step 11).
  - Lynis security audit verification (Step 12).

---

## Shared Files Notice

- `/etc/ssh/sshd_config`: Owned by this role. The downstream `file-transfer` (SFTP) module must append its `Match Group` subsystem blocks without altering the baseline SSH security directives established here.
