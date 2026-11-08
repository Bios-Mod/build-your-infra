# Role: file-transfer

This role automates the deployment of a hardened SFTP service using OpenSSH's internal subsystem (`internal-sftp`) on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the security controls documented in [`modules/file-transfer/self-managed/file-transfer-self-managed.md`](../../../../../../../modules/file-transfer/self-managed/file-transfer-self-managed.md).

---

## Target Environments & Prerequisites

- **Targets:**
  - `ec2` (`multi-lab-vps`): AWS EC2 self-managed instance (t4g.micro Graviton2).
  - `vm` (`multi-lab-local`): Local virtual machine (VMware Fusion / VirtualBox).
- **Prerequisite:** The `hardening` role must be fully deployed before applying `file-transfer`. The pre-flight assertions verify that OpenSSH listens on the hardened port (`22222`).

---

## Role Variables & Inputs

### Mandatory Inventory Variable (defined in `host_vars/<host>.yml`)

| Variable | Description | Target |
|---|---|---|
| `file_transfer_sftp_public_key_file` | Path on control node to dedicated SFTP Ed25519 public key file (e.g. `~/.ssh/id_ed25519_sftp.pub`). No default value. | Both |
| `file_transfer_auditd_reboot` | Controls automated host reboot when audit rules are updated in immutable mode (`-e 2`). Required when `hardening_auditd_immutable_mode` is true. No default value. | Both |

### Role Defaults (`defaults/main.yml`)

| Variable | Default Value | Purpose |
|---|---|---|
| `file_transfer_user` | `sftpuser` | Dedicated system account for SFTP access with `nologin` shell. Must match `configs/ssh/sshd_config`. |
| `file_transfer_chroot_dir` | `/srv/sftp/sftpuser` | Root directory for the SFTP chroot jail. Must match `configs/ssh/sshd_config`. |
| `file_transfer_configs_dir` | `{{ configs_root }}/file-transfer/self-managed/configs` | Path to static file-transfer source configuration files. |
| `hardening_ssh_port` | `{{ ssh_hardened_port \| default(22222) }}` | Hardened OpenSSH listening port verified in pre-flight assertions. |
| `hardening_admin_username` | `{{ admin_username \| default('admin') }}` | Non-root administrative user verified during OpenSSH effective configuration checks. |
| `hardening_auditd_immutable_mode` | `true` | Indicates whether the host runs auditd in immutable mode (`-e 2`), determining whether audit rules require a reboot or can be loaded dynamically. |

---

## Tasks & Tags

Execution can be targeted via Ansible tags:

| Tag | Scope | Description |
|---|---|---|
| `file_transfer` | Complete Role | Executes pre-flight assertions, user provisioning, chroot setup, SSH key installation, sshd drop-in, auditd drop-in, AIDE drop-in, handler flush, and verification tasks. |
| `file_transfer_verify` | Verification Only | Executes only the assertions defined in `tasks/verify.yml` (account shell, chroot permissions, OpenSSH effective queries, auditd rules, and AIDE drop-in validation). |

---

## Shared Files Notice

- **/etc/ssh/sshd_config:** Owned exclusively by the `hardening` role. The `file-transfer` role does not modify this file. Instead, it deploys a modular drop-in at `/etc/ssh/sshd_config.d/50-file-transfer.conf`. Because hardening defines a global `AllowUsers` directive that restricts login to the administrative account, `50-file-transfer.conf` appends `AllowUsers sftpuser` directly inside the `Match User sftpuser` block, allowing SFTP access while preserving global administrative restrictions.
- **/etc/audit/rules.d/:** Hardening deploys `/etc/audit/rules.d/99-hardening.rules`. The `file-transfer` role deploys an independent drop-in at `/etc/audit/rules.d/99-zz-file-transfer.rules` to monitor `/srv/sftp/` with key `sftp_activity` without altering the hardening ruleset. On hosts running immutable auditd (`-e 2`), loading the rule triggers an automated reboot when `file_transfer_auditd_reboot: true`.
- **/etc/aide/aide.conf.d/:** Hardening deploys `/etc/aide/aide.conf.d/99-hardening`. The `file-transfer` role deploys an independent drop-in at `/etc/aide/aide.conf.d/98-file-transfer` to monitor `/srv/sftp/sftpuser` and exclude the writable `uploads/` directory without altering existing hardening rules.

---

## Non-Automated Procedures & Accepted Deviations

1. **Step 7 (Client SSH Configuration):** Configuring the client alias `Host multi-lab-sftp` in `~/.ssh/config` and performing interactive file transfers occur on the operator's workstation and are executed manually.
2. **Dedicated Key Generation:** The dedicated Ed25519 keypair (`~/.ssh/id_ed25519_sftp`) is generated out-of-band on the client machine before deployment; only its public key is supplied to Ansible via `file_transfer_sftp_public_key_file`.
