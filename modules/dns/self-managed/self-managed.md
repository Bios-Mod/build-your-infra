# DNS — Self-Managed

**Ubuntu 24.04 LTS · VM / VPS**

---

## Introduction

This document covers the deployment of an internal authoritative DNS server
using BIND9 on the EC2 instance. The server resolves names within the
`lab.internal` domain and handles reverse lookups for the lab network.

BIND9 runs exclusively on EC2 — the WireGuard hub. All other lab hosts
(local VM, additional peers) resolve `lab.internal` over the tunnel by
pointing their system resolver to `172.16.0.1`. No DNS server is installed
on client nodes.

> **Prerequisite:** the `hardening` module must be fully deployed before
> applying this module. BIND9 integrates with the existing AppArmor,
> auditd, UFW, and AIDE configuration established in that baseline.

> **Directory module dependency:** BIND9 must be operational before
> provisioning the `directory` module. Samba 4 AD DC manages its own
> internal DNS subsystem — the integration path (delegation vs coexistence)
> will be evaluated at directory module provisioning time.

> **Additive configs:** the configuration files in `configs/` publish only the
> block or file added by this module. `Requires:` in each header specifies the
> mandatory prior baseline.

---

## Environment

| Parameter      | Value                                              |
|----------------|----------------------------------------------------|
| Software       | BIND9 (bind9 package, Ubuntu 24.04)                |
| Domain         | `lab.internal`                                     |
| Network        | 10.0.0.0/8 (lab ACL — covers VM LAN + WireGuard)  |
| Listen address | `127.0.0.1` · WireGuard interface IP               |
| Forwarders     | `1.1.1.1` · `8.8.8.8` (external, fallback only)   |
| Zone type      | Authoritative primary — forward + reverse          |
| AppArmor       | `usr.sbin.named` — enforce mode (Ubuntu default)   |

---

## Step 1 — Install BIND9

### What was done

BIND9 and its utilities are installed. `bind9utils` provides `named-checkconf`
and `named-checkzone`, used in every subsequent verification step.
`bind9-doc` is skipped — documentation is available online and adds no
runtime value.

```bash
sudo apt update && sudo apt install -y bind9 bind9utils
```

### Why

`bind9` ships with AppArmor confinement enabled by default on Ubuntu 24.04 —
`usr.sbin.named` is in enforce mode immediately after installation. No
additional AppArmor configuration is required for the baseline deployment.

### Verification

```bash
named -v
# → BIND 9.18.x (Ubuntu)

sudo systemctl is-active named
# → active

sudo aa-status | grep -A1 "named"
# →    named
# →    /usr/sbin/named (<PID>) named
```

---
## Step 2 — Configure named.conf.options

### What was done

The global BIND9 options block is replaced with a hardened configuration.
Replace `<SERVER_IP>` with the WireGuard (ec2) and primary interface IP (local) of this server before applying.

```bash
sudo cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak

sudo tee /etc/bind/named.conf.options < ~/build-your-infra/modules/dns/self-managed/configs/bind/named.conf.options

sudo named-checkconf
sudo systemctl reload named
```

📄 [`configs/bind/named.conf.options`](configs/bind/named.conf.options) — replaces `/etc/bind/named.conf.options`

### Why

The `lab-net` ACL restricts recursion and queries to trusted lab addresses —
loopback, the WireGuard subnet, and the VPC CIDR. This is the primary
protection against open resolver abuse and DNS amplification attacks.

Listening on `any` rather than a fixed IP makes the configuration portable
across AMI redeployments — the primary interface IP changes every time a new
EC2 instance is launched from a snapshot. Binding to a hardcoded IP would
require manual intervention after every redeploy. Security is not weakened
by this: `listen-on` controls which interfaces BIND9 binds to, but
`allow-query` and `allow-recursion` in the `lab-net` ACL enforce who can
actually use the resolver, regardless of which interface received the query.
External hosts reaching port 53 will receive `REFUSED`.

### Verification

```bash
sudo named-checkconf
# → (no output — clean config)

sudo ss -ulnp | grep named
# → UNCONN ... 127.0.0.1:53 ... named
# → UNCONN ... <WG_SERVER_IP>:53 ... named

# Recursion from loopback must work
dig @127.0.0.1 google.com +short
# → <valid IP>

# Query from outside lab-net must be refused
# Run from a host outside the lab ACL:
dig @<PUBLIC_IP> google.com
# → REFUSED
```

---

## Step 3 — Zone Configuration (Forward + Reverse)

### What was done

Both zones are declared in `named.conf.local` and their zone files created.
`named.conf.local` is applied once with both zone declarations — forward
(`lab.internal`) and reverse (`172.16.0.0/24`). Adjust A and PTR records
to match actual WireGuard tunnel IPs before applying.

The reverse zone file is named `db.172.16.0` — BIND9 convention uses the
network address in forward order without the `.in-addr.arpa` suffix.

```bash
sudo mkdir -p /etc/bind/zones

sudo tee -a /etc/bind/named.conf.local < ~/build-your-infra/modules/dns/self-managed/configs/bind/named.conf.local

sudo tee /etc/bind/zones/db.lab.internal < ~/build-your-infra/modules/dns/self-managed/configs/bind/zones/db.lab.internal

sudo tee /etc/bind/zones/db.172.16.0 < ~/build-your-infra/modules/dns/self-managed/configs/bind/zones/db.172.16.0

sudo named-checkzone lab.internal /etc/bind/zones/db.lab.internal
sudo named-checkzone 0.16.172.in-addr.arpa /etc/bind/zones/db.172.16.0
sudo systemctl reload named
```

📄 [`configs/bind/named.conf.local`](configs/bind/named.conf.local) — replace `/etc/bind/named.conf.local`
📄 [`configs/bind/zones/db.lab.internal`](configs/bind/zones/db.lab.internal) — create at `/etc/bind/zones/db.lab.internal`
📄 [`configs/bind/zones/db.172.16.0`](configs/bind/zones/db.172.16.0) — create at `/etc/bind/zones/db.172.16.0`

> **Serial number format:** `YYYYMMDDnn` — increment the last two digits on
> every zone change within the same day. BIND9 will not reload zone data if
> the serial is not incremented.

### Why

A dedicated internal zone avoids any dependency on external DNS for lab
hostname resolution — hostnames remain stable regardless of IP changes.
Reverse DNS is required for SSH login latency reduction and Samba AD health
checks. PTR records consistent with forward A records also prevent false
positives in security scanners and audit log entries.

### Verification

```bash
sudo named-checkzone lab.internal /etc/bind/zones/db.lab.internal
# → zone lab.internal/IN: loaded serial YYYYMMDDnn
# → OK

sudo named-checkzone 0.16.172.in-addr.arpa /etc/bind/zones/db.172.16.0
# → zone 0.16.172.in-addr.arpa/IN: loaded serial YYYYMMDDnn
# → OK

dig @127.0.0.1 ns1.lab.internal A +short
# → 172.16.0.1

dig @127.0.0.1 vps.lab.internal A +short
# → 172.16.0.1

dig @127.0.0.1 -x 172.16.0.1 +short
# → ns1.lab.internal.
# → vps.lab.internal.
```

---

## Step 4 — UFW: Allow DNS

### What was done

DNS queries (UDP and TCP port 53) are allowed from the WireGuard interface.
TCP is required for zone transfers and truncated UDP responses — both are
uncommon in a lab but the rule is correct practice.

```bash
# Allow DNS from WireGuard peers
sudo ufw allow in on wg0 to any port 53 proto udp comment "DNS — WireGuard"
sudo ufw allow in on wg0 to any port 53 proto tcp comment "DNS — WireGuard TCP"

sudo ufw status numbered
# Confirm the new rules appear
```

> **No public interface rule:** port 53 must not be opened on the public
> interface (`eth0` / `ens5`). The `listen-on` restriction in Step 2 already
> prevents BIND9 from binding to the public IP — this UFW rule adds a second
> enforcement layer at the network level.

### Why

The existing `allow in on wg0` rule from the hardening module covers SSH but
not DNS. Adding explicit port 53 rules makes the intent visible in `ufw status`
and ensures the policy is correct even if the interface name changes.

### Verification

```bash
sudo ufw status verbose | grep 53
# → 53/udp ... ALLOW IN ... wg0
# → 53/tcp ... ALLOW IN ... wg0

# Query from a WireGuard peer must resolve
dig @172.16.0.1 ns1.lab.internal A +short
# → 172.16.0.1
```

---

## Step 5 — auditd: Zone File Monitoring

### What was done

An audit rule is added to monitor write operations on the BIND9 configuration
and zone directories. Zone file tampering is a high-value attack vector —
auditd provides an independent record of any modification.

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules < ~/build-your-infra/modules/dns/self-managed/configs/audit/99-hardening.rules

sudo augenrules --load
sudo systemctl restart auditd
```

📄 [`configs/audit/99-hardening.rules`](configs/audit/99-hardening.rules) — append to `/etc/audit/rules.d/99-hardening.rules`

> **Immutable mode:** if auditd is running with `-e 2`, a reboot is required
> after loading new rules. The restart above handles this for non-immutable
> configurations.

### Why

BIND9 zone files are plain text — a write to `db.lab.internal` is not
distinguishable from a legitimate admin edit without an independent audit
trail. The `dns_config` key enables targeted filtering in `ausearch` without
scanning the full audit log.

### Verification

```bash
sudo reboot now

sudo auditctl -l | grep dns_config
# → -w /etc/bind/ -p wa -k dns_config
# → -w /var/lib/bind/ -p wa -k dns_config

# Trigger a test event
sudo touch /etc/bind/test_audit && sudo rm /etc/bind/test_audit
sudo ausearch -k dns_config | tail -5
# → type=PATH ... name="test_audit" ... key="dns_config"
```

---

## Step 6 — AIDE: Extend Baseline

### What was done

BIND9 configuration and zone directories are added to the AIDE monitoring
scope. The cache directory is excluded to prevent expected runtime writes
from generating false positives.

```bash
sudo tee -a /etc/aide/aide.conf.d/99-hardening < ~/build-your-infra/modules/dns/self-managed/configs/aide/99-hardening

sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

📄 [`configs/aide/99-hardening`](configs/aide/99-hardening) — append to `/etc/aide/aide.conf.d/99-hardening`

> **Baseline regeneration:** the database must be regenerated after every
> intentional configuration change (e.g. adding a new DNS record). Failing
> to do so will report legitimate changes as integrity violations.

### Why

Zone files and `named.conf` are the authoritative source of truth for name
resolution in the lab. Any unauthorized modification — even a single altered
IP in a PTR record — would redirect traffic silently. AIDE detects changes
between known-good states independently of auditd.

### Verification

```bash
grep -E "bind|cache/bind" /etc/aide/aide.conf.d/99-hardening
# → /etc/bind      CONTENT_EX
# → /etc/bind/zones  CONTENT_EX
# → !/var/cache/bind

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
```

---

## Step 7 — Point System Resolver to BIND9

### What was done

The system resolver is updated to use BIND9 for all DNS queries. The target
address differs by host:

- **EC2 (DNS server):** resolves via loopback — `127.0.0.1`
- **Any WireGuard peer (local VM, additional clients):** resolves via tunnel — `172.16.0.1`

On Ubuntu 24.04 with `systemd-resolved`, apply the drop-in config that
matches the host role.

**EC2:**

On EC2, `systemd-resolved` receives DNS from the VPC DHCP server at the
interface level — a drop-in in `resolved.conf.d/` is overridden by the DHCP
lease on `ens5`. The correct configuration point is Netplan.

Deploy a Netplan overlay that adds BIND9 and preserves the VPC resolver as
fallback — `50-cloud-init.yaml` is left untouched:

```bash
sudo cp ~/build-your-infra/modules/dns/self-managed/configs/netplan/51-dns-lab.yaml /etc/netplan/51-dns-lab.yaml
sudo chmod 600 /etc/netplan/51-dns-lab.yaml
sudo netplan apply
```

📄 [`configs/netplan/51-dns-lab.yaml`](modules/dns/self-managed/configs/netplan/51-dns-lab.yaml) — create at `/etc/netplan/51-dns-lab.yaml`

**WireGuard peers (local VM and additional clients):**

Edit `DNS` in the `[Interface]` block of each peer's `/etc/wireguard/wg0.conf`,
replacing the Quad9 value set at hardening time:

```bash
# Replace DNS values from previous states 
sudo sed -i 's/^DNS\s*=.*/DNS = 172.16.0.1/' /etc/wireguard/wg0.conf

sudo wg-quick down wg0 && sudo wg-quick up wg0
```

The `Domains=lab.internal` scope is handled automatically by `systemd-resolved`
on Linux peers via the tunnel's DNS — no additional config required.
On macOS, `lab.internal` resolves as long as the tunnel is active and
`DNS = 172.16.0.1` is set.

> **macOS DNS fallback:** WireGuard on macOS does not fall back to the system
> resolver if the configured DNS is unreachable. On Mac clients where the EC2
> server may be offline, remove the `DNS =` line from `wg0.conf` — `lab.internal`
> resolution is then only available when the tunnel is active and the server
> is reachable, but internet access is never affected by server state.
> Linux peers handle this correctly via interface-level DNS priority and fall
> back to the physical interface resolver automatically.

> **Tunnel dependency:** `lab.internal` resolution on client nodes requires
> an active WireGuard tunnel. If the tunnel is down, only external DNS
> (via the system fallback resolver) remains available — `lab.internal`
> names will not resolve.

### Why

Pointing the EC2 resolver to `127.0.0.1` ensures that `lab.internal` names
resolve correctly for all local processes on the server itself — SSH, auditd,
rsyslog, and any future service that performs hostname lookups. Configuring
`DNS =` in the WireGuard client extends the same resolution to all peers
without installing any additional software on client nodes.

### Verification

**EC2 — from the server (`multi-lab-vps`):**

```bash
resolvectl status ens5 | grep -E "DNS Servers|DNS Domain"
# → DNS Servers: 127.0.0.1 10.0.0.2
# → DNS Domain:  lab.internal eu-west-1.compute.internal

dig ns1.lab.internal +short
# → 172.16.0.1

dig google.com +short
# → <valid IP>
```

**WireGuard peer — from the client (tunnel active):**

```bash
resolvectl status | grep -E "DNS Servers|DNS Domain"
# → DNS Servers: 172.16.0.1
# → DNS Domain:  lab.internal

dig vps.lab.internal +short
# → 172.16.0.1

dig google.com +short
# → <valid IP>
```

---

## Step 8 — Pre-AMI cleanup (EC2 only)

### What was done

Before taking the AMI snapshot, sanitize `/etc/resolv.conf` to remove any
VPC-assigned nameserver IPs written during the current instance lifecycle.
These IPs are subnet-specific — freezing them into the AMI causes DNS
timeouts when the image is launched into a new instance with a different
internal IP.

Unlock, sanitize, and re-lock:

```bash
sudo chattr -i /etc/resolv.conf
sudo sed -i '/nameserver 10\./d' /etc/resolv.conf
sudo chattr +i /etc/resolv.conf
```

The AMI is created with `/etc/resolv.conf` unlocked intentionally — locking
it before the snapshot would freeze an empty or partial state. The lock must
be re-applied after the first boot of any instance launched from this image.

**Re-apply the lock after first SSH into a new instance:**

```bash
sudo chattr +i /etc/resolv.conf
```

> **Terraform automation:** when deploying this AMI via the self-managed
> Terraform stack, this command can be added to `user_data` to apply
> automatically on first boot — eliminating the manual step entirely.

### Why

`/etc/resolv.conf` is locked with `chattr +i` as part of the hardening
baseline — it is required for the Lynis score. Creating an AMI from a
running instance bakes the current file state into the image, including
the VPC DHCP-assigned nameserver. On the next launch, `systemd-resolved`
and Netplan apply their configuration on top — but the stale IP must not
be present in the file before that process runs. Removing it pre-snapshot
ensures every instance launched from this AMI starts with a clean resolver
state. The `chattr +i` lock is re-applied immediately after first boot to
restore the full hardening baseline.

### Verification

```bash
# Confirm stale VPC nameservers are gone
cat /etc/resolv.conf
# → no nameserver 10.x.x.x lines

# Confirm file is unlocked before taking the AMI
sudo lsattr /etc/resolv.conf
# → ------------------- /etc/resolv.conf

# After first boot of a new instance — confirm lock is restored
sudo lsattr /etc/resolv.conf
# → ----i-------------- /etc/resolv.conf
```

---

## Snapshot

BIND9 is now operational as the authoritative internal resolver for
`lab.internal`. Take a snapshot before proceeding to the next module —
this preserves the verified state: hardened OS + SFTP + DNS.

For EC2: create an AMI or EBS snapshot from the AWS console or CLI before
continuing.