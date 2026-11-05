# Role: hardening

This role automates the operating system hardening baseline on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the security controls documented in [`modules/hardening/self-managed/hardening-self-managed.md`](../../../../../../modules/hardening/self-managed/hardening-self-managed.md).

---

## Target Environments & Execution Order

- **Targets:**
  - `ec2` (`multi-lab-vps`): AWS EC2 self-managed instance (t4g.micro Graviton2). Deployed first as the WireGuard VPN hub (`172.16.0.1`).
  - `vm` (`multi-lab-local`): Local virtual machine (VMware Fusion / VirtualBox). Deployed second as a WireGuard VPN peer (`172.16.0.3`).
- **Target Lynis Hardening Index:**
  - Lynis ≥ **90** on AWS EC2 (`group_vars/ec2.yml`).
  - Lynis ≥ **88** on Local VM (`defaults/main.yml`).

---

## Connection Modes (`connection_mode`)

Host connectivity evolves across three progressive phases controlled by `connection_mode` in each host's `host_vars` file (`inventories/host_vars/multi-lab-vps.yml` or `inventories/host_vars/multi-lab-local.yml`):

| Mode | Port | User | Transport | Target Stage |
|---|---|---|---|---|
| `pre` | `22` | `initial_user` (`ubuntu` on EC2, installer user on VM) | Direct public IPv4 (Elastic IP on EC2, LAN IP on VM) | Initial bootstrap (Step 0) and baseline updates (Step 1) |
| `hardened` | `22222` | `admin_username` (`admin`) | Direct public IPv4 (Security Group port 22222 allowed on EC2) | Post-SSH hardening (Step 3) through UFW (Step 4) |
| `wg` | `22222` | `admin_username` (`admin`) | WireGuard VPN tunnel (`172.16.0.1` for EC2, `172.16.0.3` for VM) | Post-WireGuard lockdown (Step 5) and permanent operations |

---

## Role Variables & Inputs

### 1. Mandatory Inventory Variables (defined in `host_vars/<host>.yml`)

| Variable | Description | Target |
|---|---|---|
| `ansible_host` | Public Elastic IP (EC2) or LAN IP (VM). | Both |
| `initial_user` | Default AMI user (`ubuntu` on EC2) or OS install user (`localuser` on VM). | Both |
| `admin_public_key_file` | Path on control node to administrator Ed25519 public key (default: `~/.ssh/id_ed25519.pub`). | Both |
| `ansible_ssh_private_key_file` | Path on control node to administrator SSH private key (default: `~/.ssh/id_ed25519`). | Both |
| `connection_mode` | Active connection state (`pre`, `hardened`, or `wg`). | Both |
| `wireguard_peer_public_keys` | Dictionary of peer public keys (`mac`, `local_vm` on EC2 hub; `mac` on VM). | Both |
| `wireguard_endpoint` | Static WireGuard endpoint address (`<elastic-ip>:51820` on EC2; LAN IP on VM). | Both |
| `wireguard_hub_public_key` | Public key of the EC2 hub. | VM only |
| `vm_interface` | Target network interface name (e.g. `enp2s0`). | VM only |
| `vm_static_ip` | Static IPv4 CIDR assigned to VM interface (e.g. `192.168.1.X/24`). | VM only |
| `vm_gateway` | Default gateway IPv4 on VM local subnet (e.g. `192.168.1.1`). | VM only |

### 2. Runtime Prompts

- `hardening_admin_password`: Interactive secret prompt in `playbooks/bootstrap.yml`. Hashed dynamically at runtime via `password_hash('sha512', rounds=65536)`. No cleartext passwords or hashes are committed.

### 3. Role Defaults (`defaults/main.yml`) & Overrides

| Variable | Default Value | Defined / Overridden In | Purpose |
|---|---|---|---|
| `hardening_admin_username` | `admin` | `defaults/main.yml`, `group_vars/all.yml` | Dedicated non-root administrator account name. |
| `hardening_admin_groups` | `['sudo', 'adm', 'admin']` | `defaults/main.yml` | Supplementary groups for privilege escalation. |
| `hardening_ssh_port` | `22222` | `defaults/main.yml`, `group_vars/all.yml` | Target hardened OpenSSH listening port (`ssh_hardened_port`). |
| `hardening_wireguard_port` | `51820` | `defaults/main.yml`, `group_vars/all.yml` | WireGuard UDP service port (`wireguard_port`). |
| `hardening_wireguard_subnet` | `172.16.0.0/24` | `defaults/main.yml`, `group_vars/all.yml` | Isolated VPN subnet CIDR (`wireguard_vpn_subnet`). |
| `hardening_wireguard_hub_vpn_ip` | `172.16.0.1` | `defaults/main.yml`, `group_vars/all.yml` | Gateway VPN IP assigned to `wg0` hub (`wireguard_server_vpn_ip`). |
| `hardening_wireguard_vm_vpn_ip` | `172.16.0.3` | `defaults/main.yml`, `group_vars/all.yml` | Peer VPN IP assigned to local VM (`wireguard_vm_vpn_ip`). |
| `hardening_auditd_immutable_mode` | `true` | `defaults/main.yml` (overridden to `false` in `group_vars/vm.yml` during development) | Enforces immutable kernel audit rules (`-e 2`). Enabled in final convergence. |
| `hardening_lynis_min_score` | `88` | `defaults/main.yml` (overridden to `90` in `group_vars/ec2.yml`) | Lynis Hardening Index threshold; emits advisory warning if score drops. |
| `hardening_wg_close_public_ssh` | `false` | `defaults/main.yml` | Set to `true` on EC2 to delete rate-limited public port 22222 after tunnel verification. |
| `hardening_lan_trusted_cidr` | `""` | `defaults/main.yml` (`group_vars/vm.yml` sets LAN subnet, `ec2.yml` leaves empty) | Whitelisted CIDR for Fail2Ban `ignoreip`. |

---

## Tasks & Tags

Execution is structured into three progressive gate blocks. Each task file maps 1:1 to the manual hardening specification:

| Manual Step | Task File (`tasks/`) | Block Tag | Step Tag | Targets | Description |
|---|---|---|---|---|---|
| Step 0 | `step_00_admin_user.yml` | `hardening_2a` | `hardening_step0` | Both | Provision admin account, authorized_keys, sudoers |
| Step 1 | `step_01_updates.yml` | `hardening_2a` | `hardening_step1` | Both | APT system updates, unattended-upgrades, debsums |
| Step 2 | `step_02_static_ip.yml` | `hardening_2a` | `hardening_step2` | VM only | Static IP via Netplan + systemd-networkd drop-in |
| Step 3 | `step_03_ssh.yml` | `hardening_2b` | `hardening_step3` | Both | SSH hardening (port 22222, key-only, host keys) |
| Step 4 | `step_04_ufw.yml` | `hardening_2b` | `hardening_step4` | Both | UFW firewall baseline (default deny, rate-limit 22222) |
| Step 5 | `step_05_wireguard.yml` | `hardening_2b` | `hardening_step5` | Both | WireGuard VPN (EC2 hub, VM peer, UFW tunnel rules) |
| Step 6 | `step_06_fail2ban.yml` | `hardening_2b` | `hardening_step6` | Both | Fail2Ban intrusion prevention, UFW banaction |
| Step 7 | `step_07_sysctl.yml` | `hardening_2c` | `hardening_step7` | Both | Kernel sysctl hardening (`99-z-hardening.conf`) |
| Step 8 | `step_08_apparmor.yml` | `hardening_2c` | `hardening_step8` | Both | AppArmor utilities and enforce mode profiles |
| Step 9.1 | `step_09_1_services.yml` | `hardening_2c` | `hardening_step9_1` | Both | Attack surface: services masking, snapd purge, SSM |
| Step 9.2 | `step_09_2_users_fs.yml` | `hardening_2c` | `hardening_step9_2` | Both | Filesystem permissions, umask 027, PAM pwquality |
| Step 9.3 | `step_09_3_modprobe.yml` | `hardening_2c` | `hardening_step9_3` | Both | Unused network protocols blacklist in modprobe.d |
| Step 9.4 | `step_09_4_monitoring.yml` | `hardening_2c` | `hardening_step9_4` | Both | Security monitoring: rkhunter, acct, sysstat |
| Step 10 | `step_10_audit.yml` | `hardening_2c` | `hardening_step10` | Both | Audit trail: auditd syscall rules and AIDE baseline |
| Step 11 | `step_11_logging.yml` | `hardening_2c` | `hardening_step11` | Both | Log management: rsyslog isolation and logrotate |
| Step 12 | `step_12_lynis.yml` | `hardening_2c` | `hardening_step12` | Both | Lynis security compliance audit |

---

## Shared Files Notice

- `/etc/ssh/sshd_config`: Owned exclusively by this role. Downstream modules (`file-transfer` / SFTP) must append `Match Group` configuration blocks without modifying the global OpenSSH directives established by `step_03_ssh.yml`.
