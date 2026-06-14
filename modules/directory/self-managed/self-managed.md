# Directory — Self-Managed

**Ubuntu 24.04 LTS · VM / VPS (EC2)**

---

## Introduction

This document covers the deployment of Samba 4 as an Active Directory Domain
Controller on top of the hardened OS baseline established in
[`modules/hardening/self-managed/self-managed.md`](../../hardening/self-managed/self-managed.md).

The directory service introduces domain authentication, LDAP, Kerberos, and
integrated DNS into the lab. Samba 4 in DC mode replaces standalone file-level
access control with a full AD DS stack — the same protocol surface exposed by
Windows Server AD, implemented entirely on Linux.

> **Prerequisite — DNS:** the `dns` module must be fully deployed and validated
> before provisioning Samba 4. Samba AD DS requires a functioning DNS
> infrastructure to register SRV records, resolve DC names, and support
> Kerberos ticket exchange. Review [`modules/dns/self-managed/self-managed.md`](../../dns/self-managed/self-managed.md)
> before proceeding.
>
> **Prerequisite — Hardening:** the [`hardening`](../../hardening/self-managed/self-managed.md) module must be fully deployed.
> The firewall rules, AppArmor enforcement, auditd, and AIDE baseline extended
> here all depend on the hardening configuration.

> **Additive configs:** the configuration files in [`configs/`](../self-managed/configs/) publish only the
> block or full file added by this module. Each config references the repo path
> directly — never inlined. Apply patterns are either `sudo cp` (full-file
> replace) or `sudo tee -a` (block append), as specified per step.

---

## Environment

| Parameter        | Value                                            |
|------------------|--------------------------------------------------|
| Domain           | multilab.internal                                |
| NetBIOS name     | MULTILAB                                         |
| DC hostname      | dc01                                             |
| DC FQDN          | dc01.multilab.internal                           |
| DC IP            | 10.0.1.112 (EC2 subnet privada)                  |
| DNS backend      | SAMBA_INTERNAL                                   |
| Kerberos realm   | MULTILAB.INTERNAL                                |
| Forest/Domain FL | 2016                                             |
| Samba version    | 4.x (Ubuntu 24.04 repositories)                  |
| Admin password   | Set during provisioning — store in a vault       |

---

## Step 1 — Pre-Provision: System Preparation

### What was done

Before provisioning Samba, the system must meet three hard requirements: a static hostname matching the DC FQDN, a local `/etc/hosts` entry so the host resolves without DNS, and removal of any conflicting DNS stub resolver that would compete with BIND9 on port 53.

> **Important:** add the `/etc/hosts` entry before removing `/etc/resolv.conf`. If the hostname is not locally resolvable, `sudo` will emit `unable to resolve host` warnings during the remaining commands in this step.

```bash
# Set the DC hostname
sudo hostnamectl set-hostname dc01.multilab.internal

# Add a local hostname mapping so sudo and system tools can resolve the host
sudo tee -a /etc/hosts << 'EOF'
127.0.0.1   dc01.multilab.internal dc01
EOF

# Disable and stop systemd-resolved (conflicts with BIND9 on port 53)
sudo systemctl disable --now systemd-resolved

# Remove the stub resolver file before creating the BIND9-backed resolver config
sudo rm -f /etc/resolv.conf

# Point resolver at BIND9 (already running from the dns module)
sudo cp ~/build-your-infra/modules/directory/self-managed/configs/resolv.conf /etc/resolv.conf

# Lock the file against NetworkManager/cloud-init overwriting it
sudo chattr +i /etc/resolv.conf
```

📄 [`configs/resolv.conf`](configs/resolv.conf) — replace `/etc/resolv.conf`

### Why

Samba 4 AD DS requires that the DC resolve its own FQDN to its primary IP before provisioning begins — `samba-tool domain provision` validates this at startup and exits if the check fails. The `/etc/hosts` entry prevents early hostname-resolution failures before DNS is fully available. [cite:3]

`systemd-resolved`'s stub listener on `127.0.0.53:53` conflicts with both BIND9 and Samba's DNS port binding. Removing it and pointing `/etc/resolv.conf` at `127.0.0.1` gives BIND9 exclusive control of the local resolver before Samba registers its SRV records. [cite:3][cite:1]

### Verification

```bash
hostname -f
# → dc01.multilab.internal

getent hosts dc01.multilab.internal
# → 127.0.0.1 dc01.multilab.internal dc01

cat /etc/resolv.conf
# → search multilab.internal
# → nameserver 127.0.0.1

# systemd-resolved must be inactive
sudo systemctl is-active systemd-resolved
# → inactive
```

---

## Step 2 — Install Samba and Dependencies

### What was done

Samba 4 and its AD DS dependencies are installed from the Ubuntu 24.04
repositories. The `winbind` and `krb5-user` packages are included for
Kerberos ticket management and domain membership tooling.

```bash
sudo apt update
sudo apt install -y \
  samba \
  winbind \
  krb5-user \
  smbclient \
  ldb-tools \
  dnsutils

# Stop and disable the default smbd/nmbd/winbind services —
# in DC mode, Samba runs as a single samba process, not as separate daemons
sudo systemctl stop smbd nmbd winbind
sudo systemctl disable smbd nmbd winbind
```

### Why

The Ubuntu Samba package ships with the traditional member-server daemons
(`smbd`, `nmbd`) enabled by default. In AD DC mode, `samba-tool` provisions
the `samba` binary directly — a single process that runs all AD services
(LDAP, Kerberos, DNS, NetBIOS) as one unit. Running both concurrently causes
port conflicts and config divergence. Disabling them before provisioning
eliminates this risk.

### Verification

```bash
dpkg -l samba | grep ^ii
# → ii  samba  2:4.x.x+dfsg-x  ... Samba SMB/CIFS file, print, and login server

sudo systemctl is-enabled smbd nmbd winbind
# → disabled
# → disabled
# → disabled

samba --version
# → Version 4.x.x
```

---

## Step 3 — Domain Provisioning

### What was done

Samba 4 is provisioned as an AD Domain Controller using `samba-tool domain
provision`. The BIND9 DLZ (Dynamically Loadable Zone) backend is selected so
that Samba registers AD DNS records (SRV, A, CNAME) directly into BIND9
rather than running its own internal DNS server.

> **Destructive operation:** `samba-tool domain provision` overwrites
> `/etc/samba/smb.conf` and creates the AD database under `/var/lib/samba/`.
> If a previous Samba installation exists, remove `/etc/samba/smb.conf` and
> `/var/lib/samba/` before running this command.

```bash
# Remove any prior Samba config and database (clean slate)
sudo rm -f /etc/samba/smb.conf
sudo rm -rf /var/lib/samba/*

sudo samba-tool domain provision \
  --use-rfc2307 \
  --realm=MULTILAB.INTERNAL \
  --domain=MULTILAB \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --adminpass='<AdminPassword>'
```

After provisioning, `samba-tool` generates:
- `/etc/samba/smb.conf` — the AD DC configuration
- `/var/lib/samba/bind-dns/` — the BIND9 DLZ zone data files
- `/var/lib/samba/private/` — Kerberos keytab, AD database (LDB), TLS certs

📄 [`configs/samba/smb.conf`](configs/samba/smb.conf) — review only; `samba-tool` generates this file automatically. The config in `configs/` is the post-provision reference copy.

### Why

`--dns-backend=SAMBA_INTERNAL` delegates AD domain DNS management to the samba
process directly. On Ubuntu 24.04, the BIND9_DLZ backend has a structural
permissions issue — samba-ad-dc resets the LDB permissions under bind-dns/dns/
to root:root 600 on every service start, and the bind9 package AppArmor profile
ships with the DLZ rules outside the closing brace of the named profile block.
SAMBA_INTERNAL eliminates this friction layer: samba listens for DNS on the DC
primary IP (10.0.1.112:53) while BIND9 remains active on 127.0.0.1:53 for
lab.internal and upstream resolution. Both instances coexist without conflict
because they bind to different IP addresses.

`--use-rfc2307` enables POSIX attribute storage (UID/GID) in the AD schema,
which is required for Linux clients to map AD accounts to local UIDs without
a secondary ID mapping backend.

### Verification

```bash
# smb.conf must reference BIND9_DLZ and the correct realm
grep -E "realm|dns backend" /etc/samba/smb.conf
# → realm = MULTILAB.INTERNAL
# → dns backend = BIND9_DLZ

# AD database directories must exist
ls /var/lib/samba/private/
# → krb5.conf  sam.ldb  secrets.ldb  ...

ls /var/lib/samba/bind-dns/
# → dns.keytab  named.conf  ...

sudo systemctl status samba-ad-dc bind9 --no-pager
# running

sudo named-checkconf
# no output
```

---

## Step 4 — DNS Coexistence: Samba + BIND9

### What was done

With `SAMBA_INTERNAL`, Samba manages DNS for `multilab.internal` on its own
process listening on `10.0.1.112:53`. BIND9 remains active on `127.0.0.1:53`
for `lab.internal` and upstream resolution. No changes to `named.conf.local`
are required.

The resolver on the DC is updated to query Samba DNS first so that Kerberos
and AD tooling can resolve `multilab.internal` records before provisioning
Kerberos.

```bash
sudo chattr -i /etc/resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
search multilab.internal
nameserver 10.0.1.112
nameserver 127.0.0.1
EOF
sudo chattr +i /etc/resolv.conf
```

📄 [`configs/resolv.conf`](configs/resolv.conf) — replace `/etc/resolv.conf`

### Why

Samba's internal DNS process binds to the EC2 primary IP, not to loopback.
`/etc/resolv.conf` pointing at `127.0.0.1` only reaches BIND9, which has no
knowledge of `multilab.internal` — causing Kerberos `kinit` to fail with
"Cannot find KDC for realm" even when the DC is fully provisioned. Adding
`10.0.1.112` as the first nameserver gives the AD tooling a direct path to
the Samba DNS without removing BIND9 from the resolver chain.

### Verification

```bash
dig multilab.internal SOA
# → multilab.internal. ... IN SOA dc01.multilab.internal. ...

dig _kerberos._tcp.multilab.internal SRV
# → _kerberos._tcp.multilab.internal. ... IN SRV 0 100 88 dc01.multilab.internal.
```

---

## Step 5 — Kerberos Configuration

### What was done

The Kerberos client configuration is replaced with the file generated by
`samba-tool domain provision`. The provisioner writes a valid `krb5.conf`
to `/var/lib/samba/private/krb5.conf` — this is copied to the system location.

```bash
sudo cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
```

📄 [`configs/krb5/krb5.conf`](configs/krb5/krb5.conf) — replace `/etc/krb5.conf` (reference copy; the authoritative source is `/var/lib/samba/private/krb5.conf`)

### Why

`samba-tool` generates a `krb5.conf` that matches the realm, KDC address, and
default ticket policy it configured during provisioning. Using any other
Kerberos configuration risks mismatched realm names or KDC pointers — both
cause silent ticket failures that are time-consuming to diagnose. The system
`/etc/krb5.conf` is what `kinit`, `smbclient`, and `wbinfo` read — it must be
identical to what Samba expects.

### Verification

```bash
cat /etc/krb5.conf | grep -E "default_realm|kdc"
# → default_realm = MULTILAB.INTERNAL
# → kdc = dc01.multilab.internal

# Obtain a Kerberos ticket for the domain Administrator account
kinit Administrator@MULTILAB.INTERNAL
# (prompts for password — use the adminpass set in Step 3)

klist
# → Credentials cache: API:...
# → Principal: Administrator@MULTILAB.INTERNAL
# → Valid starting ... Expires ...

# Destroy test ticket
kdestroy
```

---

## Step 6 — Start Samba AD DC Service

### What was done

The Samba AD DC `samba` service is enabled and started. The service manages
all AD components — LDAP on port 389, Kerberos on port 88, DNS updates, and
the netlogon pipe — as a single unit.

```bash
sudo systemctl enable samba-ad-dc
sudo systemctl start samba-ad-dc
```

> **Service name:** on Ubuntu 24.04 the unit is `samba-ad-dc`, not `samba`.
> If the unit is masked, unmask it first:
> `sudo systemctl unmask samba-ad-dc`

### Why

The `samba-ad-dc` systemd unit is the correct service unit for DC mode on
Debian-family systems. Enabling it ensures the DC starts automatically on
reboot — critical in a lab where the EC2 instance may be stopped and started
without a manual intervention step.

### Verification

```bash
sudo systemctl is-active samba-ad-dc
# → active

sudo systemctl is-enabled samba-ad-dc
# → enabled

# DC must list itself as a domain controller
sudo samba-tool domain level show
# → Domain and forest function level for domain 'DC=multilab,DC=internal'
# → Forest function level: (Windows) 2016
# → Domain function level: (Windows) 2016
# → Lowest function level of a DC: (Windows) 2016

# Open ports — Kerberos (88), LDAP (389), SMB (445), RPC (135)
sudo ss -tlnp | grep -E ':88|:389|:445|:135'
# → LISTEN  0  ... 0.0.0.0:88   ... samba
# → LISTEN  0  ... 0.0.0.0:389  ... samba
# → LISTEN  0  ... 0.0.0.0:445  ... samba
```

---

## Step 7 — Firewall Rules

### What was done

UFW rules are added to allow AD DS protocol traffic inbound. The rules permit
the minimum required ports for domain clients on the WireGuard subnet
(`172.16.0.0/24`) to authenticate and query the DC.

```bash
# Kerberos
sudo ufw allow from 172.16.0.0/24 to any port 88 proto tcp comment 'AD Kerberos TCP'
sudo ufw allow from 172.16.0.0/24 to any port 88 proto udp comment 'AD Kerberos UDP'

# LDAP
sudo ufw allow from 172.16.0.0/24 to any port 389 proto tcp comment 'AD LDAP'

# LDAPS
sudo ufw allow from 172.16.0.0/24 to any port 636 proto tcp comment 'AD LDAPS'

# SMB / NetLogon
sudo ufw allow from 172.16.0.0/24 to any port 445 proto tcp comment 'AD SMB/NetLogon'

# RPC endpoint mapper
sudo ufw allow from 172.16.0.0/24 to any port 135 proto tcp comment 'AD RPC endpoint'

# Global Catalog
sudo ufw allow from 172.16.0.0/24 to any port 3268 proto tcp comment 'AD Global Catalog'

sudo ufw reload
sudo ufw status numbered
```

### Why

All AD DS rules are scoped to the WireGuard subnet (`172.16.0.0/24`) — the
internal overlay network that connects the VM and EC2 lab nodes. This prevents
the LDAP and RPC ports from being reachable from the public internet while
still allowing the local VM client peer to join the domain, authenticate, and
run queries through the tunnel. On EC2, the Security Group adds a second
perimeter — but defense in depth requires the UFW layer to also be correctly
scoped.

### Verification

```bash
sudo ufw status | grep -E '88|389|445|135|636|3268'
# → 88/tcp   ALLOW IN   172.16.0.0/24
# → 88/udp   ALLOW IN   172.16.0.0/24
# → 389/tcp  ALLOW IN   172.16.0.0/24
# → 445/tcp  ALLOW IN   172.16.0.0/24
# → 135/tcp  ALLOW IN   172.16.0.0/24
# → 636/tcp  ALLOW IN   172.16.0.0/24
# → 3268/tcp ALLOW IN   172.16.0.0/24
```

---

## Step 8 — Administrative Validation

### What was done

The AD domain is validated end-to-end: DNS resolution of SRV records, Samba
internal DNS check, LDAP query of the domain base DN, and smbclient
authentication as the domain Administrator.

```bash
# Samba internal DNS check
sudo samba-tool dns serverinfo 127.0.0.1 -U Administrator
# (prompts for password)

# List domain users
sudo samba-tool user list
# → Administrator
# → Guest
# → krbtgt

# LDAP query — domain base DN
sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "DC=multilab,DC=internal" "(objectClass=domain)" dn

# → dn: DC=multilab,DC=internal
```

### Why

Each tool in this step validates a different protocol layer independently:
`samba-tool dns` confirms the DLZ integration is responding to DNS queries,
`samba-tool user list` confirms the AD database is readable, `ldbsearch`
directly queries the LDB database (bypassing the network stack), and
`smbclient` validates full end-to-end SMB+Kerberos authentication. A failure
at any layer points to a specific component without ambiguity.

### Verification

```bash
# All four commands above must return output without errors.
# Additional spot-check:
sudo samba-tool domain level show
# → Forest function level: (Windows) 2016
# → Domain function level: (Windows) 2016
```

---

## Step 9 — auditd: Directory Service Activity Rule

### What was done

A dedicated audit rule monitors write and attribute-change operations on the
Samba configuration directory, the AD private database path, and the BIND9
DLZ keytab. The rule is appended to the existing hardening ruleset and
reloaded.

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules \
  < ~/build-your-infra/modules/directory/self-managed/configs/audit/99-hardening.rules

sudo systemctl restart auditd
sudo augenrules --load
sudo reboot now
```

> **Immutable mode:** if auditd is running with `-e 2`, restart it before
> reloading the ruleset — the reboot at the end of this step handles this.

📄 [`configs/audit/99-hardening.rules`](configs/audit/99-hardening.rules) — append to `/etc/audit/rules.d/99-hardening.rules`

### Why

The Samba private directory contains the AD database (`sam.ldb`), the domain
secrets (`secrets.ldb`), and the Kerberos keytab. Any modification to these
files — whether by an operator or an attacker — is a high-severity event.
The `dns.keytab` is equally sensitive: it authorizes DNS updates. Monitoring
these paths with auditd ensures every file-level operation generates an
auditable trail with a UID and process name.

### Verification

```bash
sudo auditctl -l | grep samba
# → -w /etc/samba/ -p wa -k samba_config
# → -w /var/lib/samba/private/ -p wa -k samba_db
# → -w /var/lib/samba/bind-dns/dns.keytab -p rwa -k samba_keytab

# Trigger a test event
sudo touch /etc/samba/audit_test && sudo rm /etc/samba/audit_test
sudo ausearch -k samba_config | tail -5
# → type=PATH ... name="audit_test" ... key="samba_config"
```

---

## Step 10 — AIDE: Extend Baseline

### What was done

The Samba configuration directory and AD private database paths are added to
the AIDE monitoring scope. The AIDE database is regenerated to include the new
paths as the trusted baseline.

```bash
sudo tee -a /etc/aide/aide.conf.d/99-hardening \
  < ~/build-your-infra/modules/directory/self-managed/configs/aide/99-hardening

sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> **Baseline regeneration:** after extending the AIDE scope, regenerate the
> database so the current Samba state becomes the new trusted baseline. Running
> `aide --check` before regeneration will report differences — this is expected.

📄 [`configs/aide/99-hardening`](configs/aide/99-hardening) — append to `/etc/aide/aide.conf.d/99-hardening`

### Why

AIDE detects file content, permission, and ownership changes between snapshot
intervals. The Samba private database and `smb.conf` are integrity-critical:
an undetected modification to `sam.ldb` or the keytab could escalate
privileges or compromise the Kerberos realm. AIDE complements auditd — auditd
captures the real-time event, AIDE confirms the delta at the file-system level
on the next scheduled check.

### Verification

```bash
grep -E "samba|bind-dns" /etc/aide/aide.conf.d/99-hardening

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
```

---

## Snapshot

Samba 4 AD DC is deployed and validated on top of the hardened OS baseline.
Take a snapshot before proceeding to the next module — this preserves the
verified state: hardened OS + SFTP + DNS + web server + directory service,
no additional services.