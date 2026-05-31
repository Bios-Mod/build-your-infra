# File Transfer — Self-Managed

**Ubuntu 24.04 LTS · VM / VPS**

---

## Introduction

This document covers the deployment of a hardened SFTP server using the
OpenSSH internal subsystem — no additional packages required. SFTP is
isolated via a dedicated system user with no shell access, a chroot jail,
and a `Match User` block appended to the existing `sshd_config`.

The subsystem entry (`Subsystem sftp internal-sftp`) declared in `sshd_config`
uses the SFTP implementation built into the SSH binary — no external process or
system binaries are required inside the chroot. This step activates SFTP access
by adding the `Match User` block and the required filesystem structure.

> **Prerequisite:** the `hardening` module must be fully deployed before
> applying this module. The SFTP user and chroot directory created here
> integrate with the existing AppArmor, auditd, and UFW configuration.

> **Security context:** this service runs on top of the baseline established
> in `modules/hardening/`. The relevant active layers for SFTP are:
> WireGuard perimeter, UFW `allow in on wg0`,
> AppArmor enforcement, auditd monitoring.

> **Additive configs:** the configuration files in `configs/` publish only the
> block added by this module — they do not replace the full file. Each config
> must be appended to the existing baseline from the module listed under
> `Requires:` in its header. Applying them standalone will result in an
> incomplete configuration.

---

## Environment

| Parameter    | Value                                                 |
|--------------|-------------------------------------------------------|
| Protocol     | SFTP over SSH (internal-sftp subsystem)               |
| Port         | 22222 (shared with SSH — no additional port required) |
| Auth         | Ed25519 key-based only — no password path             |
| Access scope | VPN only (`wg0`) — enforced by existing UFW rules     |
| Chroot root  | `/srv/sftp/sftpuser/`                                 |

---

## Step 1 — Dedicated SFTP User

### What was done

A dedicated user with no login shell is created. The home directory at
`/home/sftpuser` is used exclusively for key management — the SFTP session
root is the chroot directory defined in Step 2.

```bash
sudo adduser sftpuser --shell /usr/sbin/nologin --gecos ""
sudo passwd sftpuser
# Set a strong password — required even though password SSH auth is disabled.
# Same rationale as the admin user in hardening Step 0.
```

### Why

A dedicated user with `nologin` shell cannot open an interactive session
even if key authentication were misconfigured — `ForceCommand internal-sftp`
in the `Match User` block provides a second enforcement layer. Isolating
SFTP to its own account limits the blast radius of a compromised session:
the account has no sudo, no shell, and no access outside its chroot.


### Verification

```bash
getent passwd sftpuser
# → sftpuser:x:...:...:/usr/sbin/nologin

# Shell must be nologin — interactive login must fail
su - sftpuser
# → This account is currently not available.
```

---

## Step 2 — Chroot Directory Structure

### What was done

The chroot root and writable upload directory are created with strict
ownership. OpenSSH enforces that every component of the `ChrootDirectory`
path is owned by `root` and not writable by any other user — failure to
meet this condition silently prevents login.

```bash
sudo mkdir -p /srv/sftp/sftpuser/uploads
sudo chown root:root /srv/sftp/sftpuser          # chroot root — must be root:root
sudo chmod 755 /srv/sftp/sftpuser                # readable but not writable by sftpuser
sudo chown sftpuser:sftpuser /srv/sftp/sftpuser/uploads
sudo chmod 750 /srv/sftp/sftpuser/uploads
```

> **Chroot ownership rule:** `ChrootDirectory` and every parent directory
> in its path must be owned by `root` with no group/world write bits. This is
> an OpenSSH security requirement, not a convention — any deviation returns
> `fatal: bad ownership or modes for chroot directory` and the session is
> dropped before authentication completes.

### Why

The chroot jail confines the SFTP session to `/srv/sftp/sftpuser/` — the
user cannot traverse above it regardless of what paths they request. The
separation between the chroot root (`root:root`, non-writable) and the
uploads directory (`sftpuser:sftpuser`, writable) means the user can only
write inside `uploads/`, not overwrite or inject files at the chroot root
level.

### Verification

```bash
# Chroot root — must be root:root, 755
stat -c "%U %G %a %n" /srv/sftp/sftpuser
# → root root 755 /srv/sftp/sftpuser

# Uploads — must be sftpuser:sftpuser, 750
stat -c "%U %G %a %n" /srv/sftp/sftpuser/uploads
# → sftpuser sftpuser 750 /srv/sftp/sftpuser/uploads
```

---

## Step 3 — SSH Key for SFTP User

### What was done

SFTP authentication uses the same Ed25519 key infrastructure as SSH.
`AuthorizedKeysFile` in `sshd_config` is set to `.ssh/authorized_keys` — a
relative path that OpenSSH resolves against the user's home directory on the
**real filesystem**, not the chroot. For `sftpuser`, this resolves to
`/home/sftpuser/.ssh/authorized_keys`, which sits outside the chroot jail and
is therefore not reachable by the confined session.

```bash
# ── On the CLIENT machine (Mac/Linux) ─────────────────────────────────────────

# Generate a dedicated keypair for SFTP
ssh-keygen -t ed25519 -C "sftp-multi-lab" -f ~/.ssh/id_ed25519_sftp

# Display the public key — copy this output
cat ~/.ssh/id_ed25519_sftp.pub

# Set correct permissions — SSH rejects private keys accessible by others
chmod 600 ~/.ssh/id_ed25519_sftp
chmod 644 ~/.ssh/id_ed25519_sftp.pub

ls -la ~/.ssh/id_ed25519_sftp*
# → -rw-------  id_ed25519_sftp
# → -rw-r--r--  id_ed25519_sftp.pub

# ── On the SERVER ─────────────────────────────────────────────────────────────

# Create the .ssh directory for sftpuser
sudo mkdir -p /home/sftpuser/.ssh

# Paste the public key from the step above
sudo tee /home/sftpuser/.ssh/authorized_keys > /dev/null << 'EOF'
ssh-ed25519 AAAA... sftp-multi-lab
EOF

# Set correct ownership and permissions
sudo chown -R sftpuser:sftpuser /home/sftpuser/.ssh
sudo chmod 700 /home/sftpuser/.ssh
sudo chmod 600 /home/sftpuser/.ssh/authorized_keys
```

> **Key reuse vs dedicated key:** using a separate Ed25519 keypair per
> service (one for SSH admin, one for SFTP) is the recommended approach
> for a production environment — it limits the impact of a key compromise
> to a single service. For a lab context, reusing the existing key is
> acceptable.

### Verification

```bash
ls -la /home/sftpuser/.ssh/
# → drwx------  .ssh            sftpuser:sftpuser
# → -rw-------  authorized_keys sftpuser:sftpuser
```

---

## Step 4 — sshd_config: Match User Block

### What was done

A `Match User` block is appended to the existing `sshd_config`. This is
the only modification to a previously deployed configuration file in this
module — the rest of the hardening baseline is unchanged.

```bash
sudo tee -a /etc/ssh/sshd_config < ~/build-your-infra/modules/file-transfer/self-managed/configs/ssh/sshd_config

sudo sshd -t
sudo systemctl reload ssh
```

📄 [`configs/ssh/sshd_config`](modules/file-transfer/self-managed/configs/ssh/sshd_config) — append to `/etc/ssh/sshd_config`

> **`AllowTcpForwarding no` and `X11Forwarding no`:** both are already set
> globally by the hardening baseline. They are repeated inside the `Match User`
> block for explicit scope clarity — no conflict arises.

> **`ForceCommand internal-sftp -l VERBOSE`:** the `-l VERBOSE` flag enables
> per-operation logging to syslog. Each file transfer, directory listing, and
> rename is recorded — useful for audit correlation with the auditd rule added
> in Step 5.

### Why

`ForceCommand internal-sftp` overrides any shell or command the user might
attempt — even with a valid key, the session is always dropped into the
internal SFTP process. `ChrootDirectory` jails the session at the filesystem
level. Together they provide two independent enforcement layers: process
isolation and filesystem confinement.

### Verification

```bash
# Config syntax — must return no output
sudo sshd -t

# Match block active in effective config
sudo sshd -T -C user=sftpuser | grep -E "forcecommand|chrootdirectory|allowtcpforwarding|passwordauthentication"
# → forcecommand internal-sftp -l VERBOSE
# → chrootdirectory /srv/sftp/sftpuser
# → allowtcpforwarding no
# → passwordauthentication no
```

---

## Step 5 — auditd: SFTP Activity Rule

### What was done

A dedicated audit rule monitors file operations under the SFTP chroot path.
The rule is appended to the existing hardening ruleset and then loaded.

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules < ~/build-your-infra/modules/file-transfer/self-managed/configs/audit/99-hardening.rules

sudo systemctl restart auditd
sudo augenrules --load
sudo reboot now
```

> **Immutable mode:** if auditd is running with `-e 2`, restart it before
> reloading the ruleset — the reboot at the end of this step handles this.

📄 [`configs/audit/99-hardening.rules`](modules/file-transfer/self-managed/configs/audit/99-hardening.rules) — append to `/etc/audit/rules.d/99-hardening.rules`

### Why

The SFTP path is network-accessible and writable by design. This rule adds a
dedicated event trail for file changes under `/srv/sftp/`, complementing the
baseline audit coverage already applied by the hardening module. The `sftp_activity`
key allows filtering SFTP events independently from the rest of the audit log.

### Verification

```bash
sudo auditctl -l | grep sftp_activity
# → -w /srv/sftp/ -p rwa -k sftp_activity

# Test — create a file as sftpuser and verify the event appears
sudo touch /srv/sftp/sftpuser/uploads/audit_test
sudo ausearch -k sftp_activity | tail -3
# → type=PATH ... name="audit_test" ... key="sftp_activity"
sudo rm /srv/sftp/sftpuser/uploads/audit_test
```

---

## Step 6 — AIDE: Extend Baseline

### What was done

The SFTP chroot root is added to the AIDE monitoring scope. The writable
`uploads/` directory is explicitly excluded to prevent expected transfer
activity from generating constant false positives.

```bash
sudo tee -a /etc/aide/aide.conf.d/99-hardening < ~/build-your-infra/modules/file-transfer/self-managed/configs/aide/99-hardening

sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> **`!` prefix:** explicitly excludes a path from AIDE monitoring — changes
> inside `uploads/` are expected and must not generate false positives.

> **Baseline regeneration:** after extending the AIDE scope, regenerate the
> database so the current SFTP structure becomes the new trusted baseline.

📄 [`configs/aide/99-hardening`](modules/file-transfer/self-managed/configs/aide/99-hardening) — append to `/etc/aide/aide.conf.d/99-hardening`

### Why

The chroot root must remain root-owned and non-writable — this is an OpenSSH
enforcement requirement documented in Step 2. Monitoring it with AIDE makes
permission or ownership drift immediately visible. Excluding `uploads/` avoids
noise from normal SFTP transfers while keeping the security-critical paths
under integrity control.

### Verification

```bash
# Confirm the chroot root is in scope
grep sftp /etc/aide/aide.conf.d/99-hardening

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
# Expected warnings — see hardening self-managed.md Step 10.
```

---

## Step 7 — Client Connection

### What was done

Add a dedicated `Host` block to `~/.ssh/config` on the client machine. The
alias `multi-lab-sftp` is used for SFTP to keep it visually distinct from
the admin SSH alias (`multi-lab-vps` or `multi-lab-local`).

── On the CLIENT machine (~/.ssh/config) ─────────────────────────────────────
```bash
Host multi-lab-sftp
  HostName 172.16.0.1
  User sftpuser
  Port 22222
  IdentityFile ~/.ssh/id_ed25519_sftp
```

> After this, `sftp multi-lab-sftp` is the only command needed.

### Why

The `Host` block eliminates all explicit flags from the `sftp` command —
`sftp multi-lab-sftp` is the only command needed after this. The dedicated
alias also makes it impossible to accidentally connect with the wrong user
or key.

### Verification

```bash
# SFTP — with ~/.ssh/config Host block defined (recommended)
sftp multi-lab-sftp

# SFTP — explicit flags (no config block required)
sftp -i ~/.ssh/id_ed25519_sftp -P 22222 -o "StrictHostKeyChecking=accept-new" sftpuser@172.16.0.1

# Verify chroot confinement — must not be able to traverse above uploads/
sftp> cd /
sftp> ls
# → uploads/   (only — no system paths visible)

# End-to-end transfer test
echo "sftp-test" > /tmp/sftp_test.txt
sftp multi-lab-sftp
sftp> put /tmp/sftp_test.txt uploads/
sftp> ls uploads/
# → sftp_test.txt
sftp> rm uploads/sftp_test.txt
sftp> bye

# Cleanup client
rm /tmp/sftp_test.txt
```

---

## Snapshot

SFTP is the first deployed service on top of the hardened OS baseline.
Take a snapshot before proceeding to the next module — this preserves the
verified state: hardened OS + SFTP, no additional services.

---