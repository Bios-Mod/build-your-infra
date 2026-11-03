# Hardening Automation Analysis — Ansible Implementation

This document provides the technical analysis and architectural blueprint for automating the self-managed hardening baseline (`modules/hardening/self-managed/hardening-self-managed.md`) using Ansible, as defined in `context/ansible-implementation.md` (Phase 1).

---

## 1. Step-by-Step Automation Mapping

The manual hardening baseline consists of 13 primary sections (Steps 0 through 12, plus Step 3.1).

| Step | Name | Configs Used | Application Method | Host Destination | Classification | Candidate Ansible Module | Required Handler |
|---|---|---|---|---|---|---|---|
| **0** | Admin User Setup | None | `adduser`, `usermod`, `passwd`, `ssh-copy-id` (VM) / `cp` (EC2) | `/home/<user>/.ssh/authorized_keys`, `/etc/passwd`, `/etc/group` | Automatable (Lockout risk) | `ansible.builtin.user`, `ansible.builtin.group`, `ansible.builtin.authorized_key` | None |
| **1** | System Update & Automated Security Upgrades | `unattended-upgrades/50unattended-upgrades`, `unattended-upgrades/20auto-upgrades` | `apt update && full-upgrade`, `apt install`, `sed`, `cp` | `/etc/apt/apt.conf.d/50unattended-upgrades`, `/etc/apt/apt.conf.d/20auto-upgrades`, `/etc/default/debsums` | Automatable | `ansible.builtin.apt`, `ansible.builtin.lineinfile`, `ansible.builtin.copy` | `restart unattended-upgrades` |
| **2** | Static IP Configuration (VM only) | `netplan/00-installer-config.yaml`, `netplan/no-dhcp.conf` | `cp`, `netplan apply`, `mkdir`, `systemctl daemon-reload && restart` | `/etc/netplan/00-installer-config.yaml`, `/etc/systemd/network/10-netplan-<iface>.network.d/no-dhcp.conf` | Automatable (Lockout risk, VM only) | `ansible.builtin.template`, `ansible.builtin.copy`, `ansible.builtin.systemd_service`, `ansible.builtin.command` (`netplan apply`) | None |
| **3** | SSH Hardening | `ssh/sshd_config`, `ssh/issue.net.template` | `cp`, `chmod 600`, `rm` (RSA/ECDSA keys), `sshd -t`, `systemctl enable && restart` | `/etc/ssh/sshd_config`, `/etc/issue.net`, `/etc/issue` | Automatable (Lockout risk) | `ansible.builtin.template` (for `AllowUsers`), `ansible.builtin.copy`, `ansible.builtin.file` (`state: absent`), `ansible.builtin.systemd_service` | `restart sshd` |
| **3.1** | EC2 SSM Session Manager Access | None | AWS CLI / console / instance profile | EC2 instance profile / metadata | Out of Ansible (EC2 only) | Out of scope for Ansible role (managed via Terraform IAM and AWS CLI) | None |
| **4** | UFW (Firewall) | `ufw/sysctl.conf` | `ufw default`, `ufw limit 22222/tcp`, `ufw logging medium`, `ufw enable`, `cp` | `/etc/ufw/sysctl.conf`, `/etc/default/ufw` | Automatable (Lockout risk) | `community.general.ufw`, `ansible.builtin.copy` | `reload ufw` |
| **5** | WireGuard VPN | `wireguard/wg0.conf`, `wireguard/client-template.conf`, `sysctl/99-wireguard.conf` | `apt install`, `wg genkey`, `cp`, `wg-quick up`, `systemctl enable`, `ufw allow 51820/udp`, `ufw allow in on wg0 to 22222`, `ufw delete limit 22222`, `ufw route allow`, `sysctl --system` | `/etc/wireguard/wg0.conf`, `/etc/sysctl.d/99-wireguard.conf` | Automatable (Lockout risk) | `ansible.builtin.apt`, `ansible.builtin.command` (`wg genkey`), `ansible.builtin.template`, `ansible.builtin.copy`, `community.general.ufw`, `ansible.posix.sysctl`, `ansible.builtin.systemd_service` | `restart wireguard`, `reload ufw` |
| **6** | Fail2Ban | `fail2ban/jail.local`, `fail2ban/fail2ban.d/allowipv6.conf` | `apt install`, `cp`, `mkdir`, `systemctl enable && restart` | `/etc/fail2ban/jail.local`, `/etc/fail2ban/fail2ban.d/allowipv6.conf` | Automatable | `ansible.builtin.apt`, `ansible.builtin.template` (for `ignoreip`), `ansible.builtin.copy`, `ansible.builtin.systemd_service` | `restart fail2ban` |
| **7** | Kernel Hardening (sysctl) | `sysctl/99-z-hardening.conf` | `cp`, `sysctl --system` | `/etc/sysctl.d/99-z-hardening.conf` | Automatable | `ansible.builtin.copy`, `ansible.builtin.command` (`sysctl --system`) | `reload sysctl` |
| **8** | AppArmor | None | `apt install` | `/etc/apparmor.d/`, `/usr/share/apparmor/extra-profiles/` | Automatable | `ansible.builtin.apt` | None |
| **9.1** | Attack Surface: Services & Daemons | None | `systemctl disable --now`, `systemctl mask`, `apt purge apport* snapd*`, `apt-mark hold` | Systemd service units, APT package database | Automatable | `ansible.builtin.systemd_service`, `ansible.builtin.apt` (`state: absent`, `purge: true`), `ansible.builtin.dpkg_selections` | None |
| **9.2** | Attack Surface: Filesystem & User Hardening | `pam/common-password`, `pam/common-session`, `limits/limits.conf` | `chmod`, `sed` on `/etc/login.defs`, `apt install libpam-pwquality libpam-tmpdir`, `cp` | `/etc/crontab`, `/etc/cron.*`, `/etc/sudoers.d`, `/etc/login.defs`, `/etc/pam.d/common-password`, `/etc/pam.d/common-session`, `/etc/security/limits.conf` | Automatable | `ansible.builtin.file`, `ansible.builtin.lineinfile`, `ansible.builtin.apt`, `ansible.builtin.copy` | None |
| **9.3** | Attack Surface: Kernel Modules Blacklist | `modprobe/disable-unused-protocols.conf` | `cp`, `update-initramfs -u` | `/etc/modprobe.d/disable-unused-protocols.conf` | Automatable | `ansible.builtin.copy`, `ansible.builtin.command` (`update-initramfs -u`) | `update-initramfs` |
| **9.4** | Monitoring & Forensics | None | `apt install rkhunter acct sysstat`, `sed`, `systemctl enable --now`, `rkhunter --update --propupd` | `/etc/rkhunter.conf`, `/etc/default/rkhunter`, `/etc/default/sysstat` | Automatable | `ansible.builtin.apt`, `ansible.builtin.lineinfile`, `ansible.builtin.systemd_service`, `ansible.builtin.command` | None |
| **10** | Audit Trail (auditd + AIDE) | `audit/99-hardening.rules`, `aide/99-hardening` | `apt install auditd audispd-plugins aide aide-common`, `cp`, `augenrules --load`, `aide --init`, `mv` database, `sed` | `/etc/audit/rules.d/99-hardening.rules`, `/etc/aide/aide.conf.d/99-hardening`, `/var/lib/aide/aide.db`, `/etc/default/aide` | Automatable (Lockout / idempotence risk with `-e 2` and `--init`) | `ansible.builtin.apt`, `ansible.builtin.copy`, `ansible.builtin.command` (`augenrules --load`, `aide --init`), `ansible.builtin.lineinfile`, `ansible.builtin.systemd_service` | `restart auditd` |
| **11** | Log Management (rsyslog + logrotate) | `rsyslog/20-ufw.conf`, `rsyslog/99-hardening.conf`, `logrotate/hardening-logs` | `ufw logging on`, `install -m 640`, `cp`, `systemctl restart rsyslog` | `/var/log/ufw.log`, `/var/log/fail2ban.log`, `/etc/rsyslog.d/20-ufw.conf`, `/etc/rsyslog.d/99-hardening.conf`, `/etc/logrotate.d/hardening-logs` | Automatable | `community.general.ufw`, `ansible.builtin.file`, `ansible.builtin.copy`, `ansible.builtin.systemd_service` | `restart rsyslog` |
| **12** | Security Audit Baseline (Lynis) | `lynis/custom.prf` | `apt install lynis`, `mkdir`, `cp`, `lynis audit system` | `/etc/lynis/custom.prf` | Automatable | `ansible.builtin.apt`, `ansible.builtin.file`, `ansible.builtin.copy`, `ansible.builtin.command` (`lynis audit system`) | None |

---

## 2. Definitive Mapping of Steps 6–12, Fail2Ban Location, and Phase 2 Blocks

### Fail2Ban Location: Placement in Block 2B
In `context/ansible-implementation.md`, Fail2Ban (Step 6) was placed provisionally between Block 2B and Block 2C.
**Definitive Decision:** **Fail2Ban belongs in Block 2B.**
- **Technical Rationale:** Fail2Ban uses `banaction = ufw` and targets port `22222`. In `jail.local`, `ignoreip` whitelists `127.0.0.1/8 ::1` and the WireGuard VPN subnet `172.16.0.0/24`. Configuring Fail2Ban immediately after UFW (Step 4) and WireGuard (Step 5) ensures that the network perimeter and intrusion prevention rules are tightly coupled. Furthermore, any connection testing over WireGuard can verify that the admin IP is not blocked before proceeding to general system configuration.

### Block Decomposition:

```
┌────────────────────────────────────────────────────────────────────────┐
│ Block 2A — Preparation (Low Risk)                                      │
│ • Step 0: Admin user setup, authorized_keys, sudo escalation           │
│ • Step 1: APT system updates, unattended-upgrades, debsums             │
│ • Step 2: Static IP via Netplan + systemd-networkd drop-in (VM only)   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Gate: 0 changed on second run)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Block 2B — Access Chain (High Lockout Risk)                             │
│ • Step 3: SSH hardening (port 22222, key-only, disable root, host keys)│
│ • Step 4: UFW initial configuration (default deny, rate-limit 22222)   │
│ • Step 5: WireGuard VPN (keys, wg0, UFW 51820 allow, 22222 on wg0 only)│
│ • Step 6: Fail2Ban (aggressive mode, banaction=ufw, ignoreip VPN subnet)│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Gate: active WireGuard tunnel & SSH via wg0)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Block 2C — Remaining System Layers                                     │
│ • Step 7: Kernel sysctl (99-z-hardening.conf, verify log_martians)     │
│ • Step 8: AppArmor utilities and profiles expansion                    │
│ • Step 9: Attack surface reduction (services, umask, PAM, modprobe)   │
│ • Step 10: Audit trail (auditd with -e 2, AIDE baseline initialization)│
│ • Step 11: Log management (rsyslog dedicated logs, logrotate)          │
│ • Step 12: Security audit baseline (Lynis run, score 88 VM / 90 EC2)   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Gate: Lynis target score & 0 changed)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Block 2D — Hardening on EC2                                            │
│ • Apply 2A, 2B, and 2C to EC2 host (multi-lab-vps)                     │
│ • Initial bootstrap over port 22 (connection_mode: pre)                │
│ • Switch to WireGuard port 22222 (connection_mode: post)               │
│ • Close bootstrap port 22 in Terraform security group                   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. VM vs. EC2 Differences by Step and Variable Control

| Step | Area | Local VM (`multi-lab-local`) | EC2 Self-Managed (`multi-lab-vps`) | Controlling Variable |
|---|---|---|---|---|
| **0** | Initial SSH User | Install user (e.g. `localuser`) | Default AMI user `ubuntu` | `ansible_user` (via `connection_mode`) |
| **0** | SSH Key Injection | `ssh-copy-id` from local machine | Injected at launch by AWS into `/home/ubuntu/.ssh/authorized_keys`; copied to admin user | `is_cloud: false` vs `true` |
| **2** | Netplan & Static IP | Deployed (`00-installer-config.yaml` + `no-dhcp.conf`) | **Skipped.** Handled by VPC DHCP and Elastic IP; modifying Netplan risks network detachment. | `when: not is_cloud` |
| **3.1** | SSM Session Manager | N/A (local hypervisor) | Available via IAM instance profile (`multi-lab-ec2-role`) and AWS CLI | Out of Ansible |
| **4 & 5** | Security Group vs Firewall | Only local UFW applies | Hypervisor Security Group must allow port 22 during bootstrap, port `51820/udp`, and revoke port 22 post-WireGuard | Terraform variable `bootstrap_ssh_cidr` |
| **5** | WireGuard Endpoint & Topology | Local LAN IP (`192.168.X.X:51820`); peer in split tunnel | Static Elastic IP (`<EIP>:51820`); EC2 acts as hub for Mac and VM | `wireguard_endpoint`, `is_cloud` |
| **6** | Fail2Ban `ignoreip` | Includes LAN subnet (`192.168.X.0/24`) and VPN (`172.16.0.0/24`) | Includes only `127.0.0.1/8 ::1` and `172.16.0.0/24` (no dynamic home IPs) | `lan_trusted_cidr` |
| **9.1** | Hypervisor / Cloud Tools | `open-vm-tools` kept | `open-vm-tools` absent; `cloud-init` kept; `amazon-ssm-agent` migrated to apt if snapd purged | `is_cloud` |
| **9.1** | `snapd` Purge | Safe to purge completely | On EC2, `amazon-ssm-agent` ships as snap. Purging snapd requires installing deb package first, or keeping snapd. | `is_cloud` |
| **10** | Syscall ABI (Auditd) | Uses `unlinkat`/`renameat`/`renameat2` on ARM64 | Uses `unlinkat`/`renameat`/`renameat2` on ARM64 (Graviton t4g.micro) | Architecture check (`ansible_architecture == "aarch64"`) |
| **12** | Lynis Baseline Index | Target score: **88** | Target score: **90** (AWS platform controls suppress `USB-1000`, `AUTH-9284`, `NAME-4404`) | Audit threshold variable |

---

## 4. Placeholder Inventory in Configuration Files

The repository's `configs/` directory contains template placeholders that must be resolved at deployment time without modifying the raw files in git:

| Config File | Placeholder | Context in File | Proposed Inventory Variable | Default / Scope |
|---|---|---|---|---|
| `ssh/sshd_config` | `<username>` | `AllowUsers <username>` | `admin_username` | `group_vars/all.yml` (e.g. `admin`) |
| `fail2ban/jail.local` | `192.168.X.X/X` | `ignoreip = 127.0.0.1/8 192.168.X.X/X 172.16.0.0/24` | `lan_trusted_cidr` | `group_vars/vm.yml` (`192.168.1.0/24`), empty string in `ec2.yml` |
| `netplan/00-installer-config.yaml` | `192.168.X.X/X` | `addresses: [192.168.X.X/X]` | `vm_static_ip` | `group_vars/vm.yml` |
| `netplan/00-installer-config.yaml` | `192.168.X.1` | `routes: - via: 192.168.X.1` | `vm_gateway` | `group_vars/vm.yml` |
| `netplan/00-installer-config.yaml` | `<your-mac-address>` | `# match: macaddress: <your-mac-address>` | `vm_mac_address` | Optional / commented in `group_vars/vm.yml` |
| `netplan/00-installer-config.yaml` | `enp2s0` / `ens160` | Network interface name | `vm_interface` | `group_vars/vm.yml` (e.g. `ens160`) |
| `wireguard/wg0.conf` | `<server-private-key>` | `[Interface] PrivateKey = <server-private-key>` | Auto-generated on target host | Stored in `/etc/wireguard/server_private.key` (0600) |
| `wireguard/wg0.conf` | `<mac-public-key>` | `[Peer] PublicKey = <mac-public-key>` | `wireguard_mac_public_key` | `host_vars/multi-lab-local.yml` or vault |
| `wireguard/wg0.conf` | `<device-public-key>` | `[Peer] PublicKey = <device-public-key>` | `wireguard_peer_public_keys` | List in host/group vars |
| `wireguard/client-template.conf`| `<client-private-key>` | `[Interface] PrivateKey = ...` | Local client generated | Client device only |
| `wireguard/client-template.conf`| `<server-public-key>` | `[Peer] PublicKey = ...` | Auto-generated on target host | Derived from server private key |
| `wireguard/client-template.conf`| `<server-ip-or-domain>` | `[Peer] Endpoint = <server-ip-or-domain>:51820` | `wireguard_endpoint` | `group_vars/vm.yml` (LAN IP) / `group_vars/ec2.yml` (EIP) |

*Note on non-deployment placeholders:*
- In `limits/limits.conf`: `<domain>`, `<type>`, `<item>`, `<value>` are explanatory syntax comments in the template header. They do not represent deployment values.
- In `sysctl/99-z-hardening.conf`: `<parameter>` is in a syntax comment.

---

## 5. Dependencies and Step Ordering

1. **User before SSH (Step 0 → Step 3):**
   `sshd_config` sets `AllowUsers <username>` and disables password authentication. If the admin user and its authorized key are not verified before restarting sshd, permanent lockout occurs.
2. **Access switchover (Step 3 → Step 4 → Step 5):**
   - Step 3 shifts SSH daemon listening port from `22` to `22222`.
   - Step 4 enables UFW with `limit 22222/tcp` across all interfaces so SSH is temporarily reachable over the primary IP on port 22222.
   - Step 5 activates `wg0`, allows `51820/udp`, allows TCP `22222` strictly `in on wg0`, and then **deletes** the rule `limit 22222/tcp`.
   - Result: Port 22222 is only reachable through the encrypted WireGuard tunnel (`172.16.0.1`).
3. **Sysctl evaluation order (`/etc/ufw/sysctl.conf` vs. `/etc/sysctl.d/`):**
   - Ubuntu loads `/etc/sysctl.d/*.conf` during boot via `systemd-sysctl.service`.
   - However, whenever UFW starts or reloads (`ufw reload`, `systemctl restart ufw`), UFW explicitly evaluates `/etc/ufw/sysctl.conf` **after** the system sysctl files, overriding matching parameters.
   - Specifically, standard UFW defaults set `net/ipv4/conf/all/log_martians=0`.
   - **Crucial fix:** `/etc/ufw/sysctl.conf` must have `net/ipv4/conf/all/log_martians=1` (and `default`) so that UFW reloads do not undo the Step 7 kernel hardening baseline.
4. **Sysctl alphanumeric order (`99-z-hardening.conf`):**
   - The package `/usr/lib/sysctl.d/99-protect-links.conf` sets `fs.protected_fifos = 1`.
   - A file named `/etc/sysctl.d/99-hardening.conf` ties with it and systemd may apply the package default last.
   - Naming the file `99-z-hardening.conf` ensures it is lexicographically the final file processed.

---

## 6. Idempotence and Lockout Risks with Mitigations

| Risk | Impact | Step | Cause | Mitigation in Ansible |
|---|---|---|---|---|
| **Auditd immutable mode (`-e 2`)** | Playbook failure / Error 1 | Step 10 | Once `-e 2` is sent to the kernel audit subsystem, no further rules can be loaded with `augenrules --load`. Attempting to load rules returns `Operation not permitted`. | In Ansible, check `auditctl -s`. If `enabled 2`, do not run `augenrules --load` directly; notify the `restart auditd` handler instead or reboot to change rules. |
| **AIDE database reinitialization** | High CPU, clobbered baseline | Step 10 | `aide --init` regenerates `/var/lib/aide/aide.db.new`. Running it on every execution takes minutes and overwrites the initial baseline. | Use `creates: /var/lib/aide/aide.db`. Only initialize if the database does not exist. |
| **WireGuard key regeneration** | Tunnel destruction / disconnect | Step 5 | Re-running `wg genkey` creates new keys, invalidating peer connections and client configurations. | Use `creates: /etc/wireguard/server_private.key`. Generate server keys once only. |
| **Host key deletion idempotence** | Failure on repeated runs | Step 3 | `rm /etc/ssh/ssh_host_*` fails on second run if using raw shell. | Use declarative `ansible.builtin.file: path: ... state: absent`. |
| **SSH Port Lockout (22 → 22222)** | Loss of Ansible control connection | Step 3 & 5 | Daemon changes port while Ansible connection plugin is still using port 22. | Use `meta: flush_handlers`, validate config with `sshd -t`, and handle the transition using `connection_mode` and `meta: reset_connection` with `wait_for_connection`. |
| **UFW rule deletion lockout** | Loss of access during switch | Step 4 & 5 | Deleting port 22222 limit rule before WireGuard tunnel is active. | Add `51820/udp` and `in on wg0 to 22222` rules BEFORE deleting `limit 22222/tcp`. |
| **Apport overriding `suid_dumpable`** | Security regression | Step 9.1 | Apport sets `fs.suid_dumpable = 2` on service start. | Purge apport packages completely and trigger `sysctl --system` to re-assert `fs.suid_dumpable = 0`. |
| **`login.defs` duplicate entries** | File corruption | Step 9.2 | Re-running `sed` can duplicate or fail to match modified lines. | Use `ansible.builtin.lineinfile` with exact regex anchors (`^UMASK\s+`). |

---

## 7. Config Files Verification

- **Configs in `modules/hardening/self-managed/configs/` not referenced by any step:**
  **None.** All 22 configuration files are explicitly referenced and explained in `hardening-self-managed.md`.
- **References in steps to missing configuration files:**
  **None.** Every file referenced by a `cp` or `tee -a` command exists in the repository.

---

## 8. Open Questions for the Author

1. **EC2 SSM Agent vs. Snapd Purge:**
   In Step 9.1, purging `snapd` on EC2 requires downloading and installing `amazon-ssm-agent.deb` via apt before removing snapd to preserve SSM Session Manager access. Should the Ansible role implement this deb migration automatically when `is_cloud: true`, or should snapd removal be skipped on EC2?
2. **WireGuard Client Key Management:**
   Server keys can be generated idempotently on the target host. For client peers (e.g. Mac operator), should the role accept an inventory list of existing client public keys (`wireguard_peer_public_keys`), or should the role generate the client keypairs on the server and fetch them back to the control node?
3. **Auditd Immutable Mode in CI / Idempotence Testing:**
   In test runs, once `-e 2` is enabled, rule modifications fail without a full OS reboot. For automated testing on the same host, should an inventory variable (e.g. `auditd_immutable: true/false`) allow disabling `-e 2` during development and enabling it only for the final verification gate?
4. **Admin Sudo Password Handling:**
   Step 0 sets a password for `<username>`. In Ansible, passwords should be passed as password hashes (`password: "{{ admin_password_hash }}"`). Should this variable be supplied via `--ask-become-pass` / `group_vars` with a placeholder hash?
