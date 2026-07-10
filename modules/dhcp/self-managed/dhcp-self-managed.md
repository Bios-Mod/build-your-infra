# DHCP — Self-Managed

**Ubuntu 24.04 LTS · Local VM only**

---

## Introduction

This document covers the deployment of a Kea DHCP server on the local VM.
Kea is ISC's modern replacement for ISC DHCP — it uses a JSON-based
configuration format, supports hot-reload without service restart, and
exposes a REST control API that is used for lease inspection throughout this
guide.

DHCP is deployed after DNS so that address assignment, naming, and lease
policy are designed against an already defined network model. The DNS server
running on the EC2 instance (`172.16.0.1` over WireGuard) provides the
resolver reference used in the DHCP lease options.

> **Prerequisite:** the `hardening` module must be fully deployed before
> applying this module. The Kea process integrates with the existing auditd
> and AIDE configuration.

> **Deployment scope:** this service runs exclusively on the local VM.
> DHCP has no use case in a cloud environment — AWS manages address
> assignment at the VPC layer. This module does not apply to the EC2
> deployment.

> **Network assumption:** the local VM is on a bridged LAN segment.
> The server assigns addresses to physical and virtual machines on that
> segment. The WireGuard interface (`wg0`) is excluded from the DHCP
> scope — VPN peers use static WireGuard addresses.

---

## Environment

| Parameter | Value |
|---|---|
| Service | Kea DHCP v2 (kea-dhcp4) |
| Listening interface | `ens160` (bridged LAN — adjust to match your VM adapter) |
| Subnet | `192.168.1.0/24` |
| Pool | `192.168.1.100` – `192.168.1.200` |
| Router (option 3) | `192.168.1.1` |
| DNS (option 6) | `172.16.0.1` (EC2 BIND9 over WireGuard) |
| Domain name (option 15) | `lab.internal` |
| Lease time | 43200 s (12 h) |
| Reservations | By MAC address |
| Control socket | `/run/kea/kea4-ctrl-socket` |

> **Interface name:** `ens160` is the typical bridged adapter name under
> VMware Fusion. Verify with `ip link` before applying the config —
> Kea will fail to start if the interface does not exist.

---

## Step 1 — Install Kea DHCP

### What was done

Kea DHCP is installed from the Ubuntu 24.04 LTS default repositories.
Only the `kea-dhcp4` component is installed — DHCPv6 and the DDNS daemon
are not required for this lab scope.

```bash
sudo apt update
sudo apt install -y kea-dhcp4-server

```

### Why

`kea-dhcp4` is the ISC-supported successor to `isc-dhcp-server`, which
reached end-of-life in 2022. It ships in Ubuntu 24.04 LTS repos and provides
a JSON configuration format with hot-reload support and a built-in REST
control socket — no external tooling required for lease inspection.

### Verification

```bash
sudo systemctl status kea-dhcp4-server
# → Active: active (running) or Active: failed (expected before config is applied)

kea-dhcp4 -v
# → Kea 2.x.x
```

---

## Step 2 — Configure Kea DHCP

### What was done

The default Kea configuration is replaced with a purpose-built configuration
that defines the subnet scope, address pool, lease time, DNS options, and
the control socket used by the REST API.

```bash
sudo cp ~/build-your-infra/modules/dhcp/self-managed/configs/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf

sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
# → INFO  DHCPSRV_CFGMGR_NEW_SUBNET4 ... 192.168.1.0/24 with params: t1=21600, t2=37800, valid-lifetime=43200
# → INFO  DHCPSRV_CFGMGR_ADD_IFACE listening on interface enp2s0
# → WARN  DHCPSRV_MT_DISABLED_QUEUE_CONTROL (expected with multi-threading enabled)
# → no ERROR lines

sudo systemctl restart kea-dhcp4-server
sudo systemctl enable kea-dhcp4-server
```

📄 [`configs/kea/kea-dhcp4.conf`](configs/kea/kea-dhcp4.conf) — replace `/etc/kea/kea-dhcp4.conf`

> **Interface binding:** the config binds Kea to `ens160`. If your bridged
> adapter has a different name, edit `"interface": "ens160"` in the config
> before applying. Run `ip link` to confirm the correct name.

> **`-t` flag:** performs a configuration syntax check without starting the
> daemon. Always run this before restarting the service.

### Why

Replacing the default configuration (which is a heavily commented example
file with no active subnet) provides a clean, minimal baseline that is
readable and auditable. The control socket at `/run/kea/kea4-ctrl-socket`
enables lease inspection and statistics queries via `kea-shell` without
requiring a service restart.

### Verification

```bash
# Config syntax — must return no errors
sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
# → (no output = valid)

# Service running
sudo systemctl status kea-dhcp4-server
# → Active: active (running)

# Listening on the correct interface
sudo ss -ulnp | grep kea
# → UNCONN ... 0.0.0.0:67 ... kea-dhcp4

sudo journalctl -u kea-dhcp4-server --no-pager | grep SUBNET4
# → DHCPSRV_CFGMGR_NEW_SUBNET4 ... 192.168.1.0/24 with params: t1=21600, t2=37800, valid-lifetime=43200
```

---

## Step 3 — Static Reservations

### What was done

MAC-based reservations are added directly in `kea-dhcp4.conf` under the
`reservations` array of the subnet block. Kea supports hot-reload — no
service restart required after editing reservations.

> The reservations array in kea-dhcp4.conf contains a placeholder entry that must be 
> replaced with real values before applying. Edit the config file in the repo first — 
> then copy and restart.
> 
> To get the MAC address of the host to reserve:
> ip link show enp2s0
> → link/ether 00:0c:29:0c:8c:62  ← use this value as hw-address 
> Reserved IPs must be outside the dynamic pool (192.168.1.100–200). Use .201 onwards.

```bash
# After editing reservations in configs/kea/kea-dhcp4.conf:
sudo cp ~/build-your-infra/modules/dhcp/self-managed/configs/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf

sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf

sudo systemctl restart kea-dhcp4-server
```

> **Reservation format:** each reservation requires `hw-address` (MAC) and
> `ip-address`. The reserved IP must fall inside the subnet but can be
> outside the dynamic pool — placing reservations outside the pool prevents
> accidental assignment to a different host.

### Why

MAC-based reservations are the standard mechanism for deterministic IP
assignment in a lab — no client-side configuration required. Keeping
reservations in the same config file as the subnet definition avoids
split-config drift and makes the full DHCP policy readable in one place.

### Verification

```bash
# Reservation present in the active config file
grep -A3 "hw-address" /etc/kea/kea-dhcp4.conf
# → "hw-address": "00:0c:29:0c:8c:62",
# → "ip-address":  "192.168.1.201",
# → "hostname":    "multi-lab"

# Service restarted cleanly with reservation loaded
sudo journalctl -u kea-dhcp4-server --no-pager | grep -E "SUBNET4|IFACE|ERROR"
# → DHCPSRV_CFGMGR_NEW_SUBNET4 ... 192.168.1.0/24 ...
# → DHCPSRV_CFGMGR_ADD_IFACE listening on interface enp2s0
# → no ERROR lines

# Lease file path exists and is writable
sudo ls -lh /var/lib/kea/kea-leases4.csv
# → -rw-r--r-- ... /var/lib/kea/kea-leases4.csv
```

---

## Step 4 — auditd: DHCP Activity Rule

### What was done

A dedicated audit rule watches the Kea lease database file for write
operations. The rule is appended to the existing hardening ruleset.

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules < ~/build-your-infra/modules/dhcp/self-managed/configs/audit/99-hardening.rules

sudo systemctl restart auditd
sudo augenrules --load
sudo reboot now
```

> **Immutable mode:** if auditd is running with `-e 2`, the reboot at the
> end of this step is required to reload the ruleset.

📄 [`configs/audit/99-hardening.rules`](configs/audit/99-hardening.rules) — append to `/etc/audit/rules.d/99-hardening.rules`

### Why

The Kea lease database (`kea-leases4.csv`) is the authoritative record of
all address assignments on the segment. Any unexpected write to that file
outside of normal DHCP operations is a signal worth capturing. The
`dhcp_lease` key allows independent filtering of DHCP events in the audit log.

### Verification

```bash
sudo auditctl -l | grep dhcp_lease
# → -w /var/lib/kea/kea-leases4.csv -p wa -k dhcp_lease

# Trigger a lease event and verify
sudo ausearch -k dhcp_lease | tail -5
# → type=PROCTITLE ... kea-dhcp4 ...
```

---

## Step 5 — AIDE: Extend Baseline

### What was done

The Kea configuration directory is added to the AIDE monitoring scope.
The lease database file is explicitly excluded — it changes on every lease
assignment and would generate constant false positives.

```bash
sudo tee -a /etc/aide/aide.conf.d/99-hardening < ~/build-your-infra/modules/dhcp/self-managed/configs/aide/99-hardening

sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> **`!` prefix:** explicitly excludes a path from AIDE monitoring. The lease
> database changes on every assignment — excluding it avoids noise while
> keeping the configuration files under integrity control.

> **Baseline regeneration:** after extending the AIDE scope, regenerate the
> database so the Kea config directory becomes part of the trusted baseline.

📄 [`configs/aide/99-hardening`](configs/aide/99-hardening) — append to `/etc/aide/aide.conf.d/99-hardening`

### Why

The Kea configuration file defines the entire address assignment policy —
subnet, pool, DNS options, reservations, and the control socket path.
Unauthorized modification of `kea-dhcp4.conf` could redirect DNS resolution
or add rogue reservations. AIDE integrity monitoring makes any such change
immediately visible.

### Verification

```bash
# Confirm config dir is in scope and lease db is excluded
grep kea /etc/aide/aide.conf.d/99-hardening

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
```

---

## Step 6 — End-to-End Verification

### What was done

A DHCP probe is sent from the server itself using `nmap`'s
`broadcast-dhcp-discover` script. This verifies that Kea responds to
DHCPDISCOVER broadcasts and that all configured options are delivered
correctly — without modifying the network configuration of any client.

```bash
sudo apt install -y nmap

sudo nmap --script broadcast-dhcp-discover -e ens160
```

### Why

Testing from a real client would require a second machine on the same
bridged segment and introduces network configuration scope outside this
module. The `broadcast-dhcp-discover` script sends a DHCPDISCOVER and
captures the DHCPOFFER response — it validates the full option set
(pool, router, DNS, domain name) in a single command with no side effects.

### Verification

```bash
sudo nmap --script broadcast-dhcp-discover -e ens160
# → Response 1 of 2 — Kea (Server Identifier: 192.168.1.10)
# →   IP Offered:          192.168.1.100        (within pool .100-.200)
# →   DHCP Message Type:   DHCPOFFER
# →   Subnet Mask:         255.255.255.0
# →   Router:              192.168.1.1
# →   Domain Name Server:  172.16.0.1           (EC2 BIND9 over WireGuard)
# →   Domain Name:         lab.internal
# →   IP Address Lease Time: 12h00m00s
# → Response 2 of 2 — home router (expected in bridged lab environment)
```

---

## Snapshot

Kea DHCP is the last service module before the Automation phase.
Take a snapshot before proceeding — this preserves the verified state:
hardened OS + all service modules deployed.

---