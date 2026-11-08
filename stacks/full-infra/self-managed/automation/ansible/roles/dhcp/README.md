# Role: dhcp

This role automates the deployment of Kea DHCPv4 on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the security controls and network configuration documented in [`modules/dhcp/self-managed/dhcp-self-managed.md`](../../../../../../../modules/dhcp/self-managed/dhcp-self-managed.md).

---

## Target Environments & Prerequisites

- **Targets:**
  - `vm` (`multi-lab-local` / `dhcp_servers`): Local VM on bridged LAN segment serving dynamic and static IPv4 configurations to local clients.
- **Prerequisites:**
  - The `hardening` role must be fully deployed before applying `dhcp`. Pre-flight assertions verify that OpenSSH listens on the hardened port (`22222`).

---

## Role Variables & Inputs

### Mandatory Inventory Variables

| Variable | Description |
|---|---|
| `vm_interface` | Primary network interface name on the local VM (e.g., `ens160`, `enp2s0`). Pre-flight assertions verify existence on the host and IPv4 assignment within `192.168.1.0/24`. |
| `dhcp_reservations` | List of static host reservations (`hw_address`, `ip_address`, `hostname`). Reserved IPs must be in `192.168.1.201–254` (outside dynamic pool `.100–200`). Set to `[]` if no static reservations are required. |
| `dhcp_auditd_reboot` | Boolean flag controlling automatic reboot when auditd rules are updated on immutable kernels (`-e 2`). Required when `hardening_auditd_immutable_mode` is true. |

### Role Defaults (`defaults/main.yml`)

| Variable | Default Value | Purpose |
|---|---|---|
| `dhcp_configs_dir` | `{{ configs_root }}/dhcp/self-managed/configs` | Path to static DHCP source configuration files. |
| `hardening_ssh_port` | `{{ ssh_hardened_port \| default(22222) }}` | Hardened OpenSSH listening port verified in pre-flight assertions. |
| `hardening_auditd_immutable_mode` | `true` | Auditd immutable kernel mode baseline. |

---

## Tasks & Tags

Execution can be targeted via Ansible tags:

| Tag | Scope | Description |
|---|---|---|
| `dhcp` | Complete Role | Executes pre-flight assertions, package installation (`kea-dhcp4-server`, `nmap`), configuration deployment (`/etc/kea/kea-dhcp4.conf`), service enablement, lease file wait, auditd drop-in, AIDE drop-in, handler flush, and verification assertions. |
| `dhcp_verify` | Verification Only | Executes only the assertions defined in `tasks/verify.yml` (service active and enabled, `kea-dhcp4 -t` syntax check, socket listener on UDP port 67, configuration content and reservations, lease database presence, auditd watch rule, AIDE drop-in and syntax, and nmap broadcast discovery probe). |

---

## Shared Files & Firewall Notice

- **No UFW Rules:** Kea DHCP is configured with `"dhcp-socket-type": "raw"`. AF_PACKET raw sockets capture DHCP broadcast packets directly from the network interface driver before Linux netfilter and the UFW packet filter chain evaluate them. As in the manual documentation, no UFW rules are configured for DHCP.
- **/etc/audit/rules.d/:** Deploys an independent drop-in at `/etc/audit/rules.d/99-zz-dhcp.rules` (mode `0640`) monitoring write operations on `/var/lib/kea/kea-leases4.csv` with key `dhcp_lease`. Deployed after verifying the lease database file exists on disk.
- **/etc/aide/aide.conf.d/:** Deploys an independent drop-in at `/etc/aide/aide.conf.d/99-zz-dhcp` (mode `0644`) ordered alphabetically after `99-hardening` (which defines `CONTENTEX`), covering `/etc/kea` while explicitly excluding `/var/lib/kea/kea-leases4.csv` to avoid false positives on dynamic lease issuance.

---

## Non-Automated Procedures & Accepted Deviations

1. **Step 6 (End-to-End Verification via nmap script):** In Step 6 of the manual documentation, client verification is conducted using `nmap --script broadcast-dhcp-discover -e {{ vm_interface }}` from the VM itself rather than configuring a separate physical client machine on the bridged network. This non-intrusively verifies that Kea responds with a DHCPOFFER delivering the full option set (Server Identifier, Router, DNS, Domain Name, Subnet Mask, Lease Time, Offered IP) without requiring external hardware.
2. **Raw Sockets & Absence of UFW Rules:** Kea DHCP utilizes raw sockets (`"dhcp-socket-type": "raw"`), bypassing the OS firewall stack. No UFW rules are added or required for DHCP operations.
3. **Auditd Rule Deployment Ordering:** Kernel `auditctl` rejects file watches on paths that do not exist on the filesystem. The role enables and starts Kea first, waits for `/var/lib/kea/kea-leases4.csv` to be created, and only then deploys the auditd watch rule.
4. **Hypervisor Snapshots:** Creating VM hypervisor snapshots remains a manual operational step outside Ansible.
5. **Post-Deployment Configuration Validation:** Using Ansible's `copy` module `validate:` parameter is not viable because `kea-dhcp4 -t` restricts configuration file loading to `/etc/kea/` and rejects temporary files outside that directory (such as Ansible's temporary staging files in `/tmp` or `/home`) with `Unable to open file`. The role validates the deployed `/etc/kea/kea-dhcp4.conf` immediately after writing it and before handlers trigger a service restart, preventing broken configurations from reaching the running daemon.
