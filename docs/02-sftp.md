# Multi-Lab Server — SFTP

**Ubuntu 24.04 LTS · VM / EC2**

---

## Introduction

This document covers the deployment of a hardened SFTP server using the
OpenSSH internal subsystem — no additional packages required. SFTP is
isolated via a dedicated system user with no shell access, a chroot jail,
and a `Match User` block appended to the existing `sshd_config`.

The subsystem entry (`Subsystem sftp /usr/lib/openssh/sftp-server`) was
already placed in `sshd_config` during Step 03 — this step activates it
by adding the access control block and the required filesystem structure.

> **Prerequisite:** Steps 01–05 (OS hardening, SSH hardening, UFW, WireGuard)
> must be complete before deploying SFTP. The SFTP user and chroot directory
> created here integrate with the existing AppArmor and auditd configuration.

---

## Environment

| Parameter    | Value                                                 |
|--------------|-------------------------------------------------------|
| Protocol     | SFTP over SSH (internal-sftp subsystem)               |
| Port         | 22222 (shared with SSH — no additional port required) |
| Auth         | Ed25519 key-based only — no password path             |
| Access scope | VPN only (`wg0`) — enforced by existing UFW rules     |
| Chroot root  | `/srv/sftp/<sftpuser>/`                               |

---

## Step 1 — Dedicated SFTP User

### What was done

A system user with no login shell is created. No home directory under `/home`
— the chroot directory serves as the user's root.

```bash
sudo adduser sftpuser --shell /usr/sbin/nologin --gecos ""
sudo passwd sftpuser
# Set a strong password — required for sudo privilege escalation even though
# password SSH auth is disabled. Same rationale as the admin user in Step 00.
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
sudo -u sftpuser /bin/bash
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
The authorized key is placed inside the chroot — note that OpenSSH
resolves `AuthorizedKeysFile` paths relative to the chroot when the
path is relative, but uses the real filesystem when absolute. An
absolute path outside the chroot is used here to avoid ambiguity and
keep key management consistent with the admin user.

```bash
# On the client machine (Mac/Linux) — generate a dedicated key for SFTP
ssh-keygen -t ed25519 -C "sftp-multi-lab" -f ~/.ssh/id_ed25519_sftp

# Copy the public key to the server
ssh-copy-id -i ~/.ssh/id_ed25519_sftp.pub -p 22222 <username>@10.0.0.1

sudo mkdir -p /home/sftpuser/.ssh
sudo cp ~/.ssh/<your_key>.pub /home/sftpuser/.ssh/authorized_keys
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
step — the rest of the hardening baseline from Step 03 is unchanged.

```bash
sudo tee -a /etc/ssh/sshd_config > /dev/null << 'EOF'

# ── SFTP — Step 02 ────────────────────────────────────────────────────────────
# Isolates the sftpuser account to the internal SFTP subsystem.
# AllowTcpForwarding no and X11Forwarding no are already set globally —
# repeated here for explicitness within the Match block scope.
Match User sftpuser
    ForceCommand internal-sftp
    ChrootDirectory /srv/sftp/%u
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication no
EOF

sudo sshd -t
sudo systemctl reload ssh
```

📄 [`configs/ssh/sshd_config`](../configs/ssh/sshd_config)

> **`AllowTcpForwarding no` compatibility:** this directive is set globally
> in Step 03 and does not affect the SFTP subsystem — SFTP runs over the
> standard SSH channel, not a TCP forward. The `Match User` block repeats it
> explicitly for scope clarity; no conflict arises.

> **`%u` in ChrootDirectory:** OpenSSH expands `%u` to the authenticated
> username at login time — `/srv/sftp/sftpuser` in this case. This makes
> the block reusable for additional SFTP users without modifying the path.

### Why

`ForceCommand internal-sftp` overrides any shell or command the user might
attempt — even with a valid key, the session is always dropped into the
internal SFTP process. `ChrootDirectory` jails the session at the filesystem
level. Together they provide two independent enforcement layers: process
isolation and filesystem confinement.

`internal-sftp` (built into the SSH binary) is preferred over
`/usr/lib/openssh/sftp-server` (the external binary declared in `Subsystem`)
for chrooted sessions — it runs in-process without requiring system binaries
like `ls` or `sh` inside the chroot.

### Verification

```bash
# Config syntax — must return no output
sudo sshd -t

# Match block active in effective config
sudo sshd -T -C user=sftpuser | grep -E "forcecommand|chrootdirectory|allowtcpforwarding"
# → forcecommand internal-sftp
# → chrootdirectory /srv/sftp/sftpuser
# → allowtcpforwarding no
```

---

## Step 5 — auditd: SFTP Activity Rule

### What was done

A dedicated audit rule monitors file operations performed under the SFTP
chroot. Added to the existing rules file and reloaded.

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules > /dev/null << 'EOF'
# SFTP — Step 02: file operations inside the SFTP chroot
-w /srv/sftp/ -p rwxa -k sftp_activity
EOF

sudo augenrules --load
```

> **Immutable mode:** if auditd was loaded with `-e 2`, restart it before
> reloading rules: `sudo systemctl restart auditd && sudo augenrules --load`

📄 [`configs/audit/99-hardening.rules`](../configs/audit/99-hardening.rules)

### Why

The SFTP chroot is a writable path accessible from the network. Auditing
file operations inside it provides an event trail of every upload, rename,
and deletion — independent of SFTP session logs. Paired with the `identity`
and `sshd_config` rules already active from Step 10, this closes the logging
gap for SFTP-specific activity.

### Verification

```bash
sudo auditctl -l | grep sftp_activity
# → -w /srv/sftp/ -p rwxa -k sftp_activity

# Test — create a file as sftpuser and verify the event appears
sudo touch /srv/sftp/sftpuser/uploads/audit_test
sudo ausearch -k sftp_activity | tail -3
# → type=PATH ... name="audit_test" ... key="sftp_activity"
sudo rm /srv/sftp/sftpuser/uploads/audit_test
```

---

## Step 6 — AIDE: Extend Baseline

### What was done

The SFTP chroot root is added to the AIDE monitoring scope. The `uploads/`
directory is intentionally excluded — it is a writable data directory and
would generate false positives on every file transfer.

```bash
sudo tee -a /etc/aide/aide.conf.d/99-hardening << 'EOF'
# SFTP chroot root — monitors ownership and permission changes
# uploads/ excluded: writable data directory, changes are expected
/srv/sftp/[^u]  PERMS+sha512
EOF

sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> **Baseline regeneration is required** after any structural change to a
> monitored path. Regenerate any time a new service modifies files under
> an existing AIDE-monitored directory.

📄 [`configs/aide/99-hardening`](../configs/aide/99-hardening)

### Why

Monitoring the chroot root detects unauthorized ownership or permission
changes — for example, if `sftpuser` were somehow granted write access to
the chroot root, AIDE would flag it at the next daily check before the
misconfiguration can be exploited.

### Verification

```bash
sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.

# Confirm the chroot root is in scope
grep srv/sftp /etc/aide/aide.conf.d/99-hardening
```

---

## Connect

```bash
# SFTP — with ~/.ssh/config Host block defined (recommended)
sftp multi-lab-sftp

# SFTP — explicit flags
sftp -i ~/.ssh/<your_key> -P 22222 -o "StrictHostKeyChecking=accept-new" sftpuser@10.0.0.1

# Verify chroot confinement — must not be able to traverse above uploads/
sftp> cd /
sftp> ls
# → uploads/   (only — no system paths visible)
```

> **`-P` not `-p`:** SFTP uses uppercase `-P` for port (unlike `ssh -p`).
> `-i` specifies the private key — the same one whose public counterpart
> is in `authorized_keys`. You never transmit or reference the public key
> at connection time; the client signs the server's challenge with the
> private key and the server verifies against the stored public key.

> **`~/.ssh/config` block — eliminates all flags:**
> ```
> Host multi-lab-sftp
>     HostName 10.0.0.1
>     User sftpuser
>     Port 22222
>     IdentityFile ~/.ssh/<your_key>
> ```
> After this, `sftp multi-lab-sftp` is the only command needed.

> **Security context:** This service runs on top of the baseline established
> in `01-os-hardening.md`. The relevant active layers for SFTP are:
> WireGuard perimeter (Step 5), UFW `allow in on wg0` (Step 5),
> AppArmor enforcement (Step 8), auditd monitoring (Step 10).

---

## Snapshot

SFTP represents the first deployed service on top of the hardened OS baseline.
Take a snapshot before proceeding to the next module — this captures the
minimal, verified state: hardened OS + SFTP, no additional services.

---