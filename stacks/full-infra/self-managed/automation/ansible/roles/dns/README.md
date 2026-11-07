# Role: dns

This role automates the deployment of an authoritative internal BIND9 DNS server for `lab.internal` on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the security controls documented in [`modules/dns/self-managed/dns-self-managed.md`](../../../../../../../modules/dns/self-managed/dns-self-managed.md).

---

## Target Environments & Prerequisites

- **Targets:**
  - `ec2` (`multi-lab-vps` / `dns_servers`): AWS EC2 self-managed instance (t4g.micro Graviton2) acting as the central WireGuard VPN hub (`172.16.0.1`).
- **Prerequisite:** The `hardening` role must be fully deployed before applying `dns`. The pre-flight assertions verify that OpenSSH listens on the hardened port (`22222`).

---

## Role Variables & Inputs

### Mandatory Inventory Variables

None required. All network ranges and baseline paths are inherited from `group_vars/all.yml` or defaults.

### Role Defaults (`defaults/main.yml`)

| Variable | Default Value | Purpose |
|---|---|---|
| `dns_configs_dir` | `{{ configs_root }}/dns/self-managed/configs` | Path to static DNS source configuration files. |
| `hardening_ssh_port` | `{{ ssh_hardened_port \| default(22222) }}` | Hardened OpenSSH listening port verified in pre-flight assertions. |
| `dns_vpc_domain` | `compute.internal` | Internal AWS VPC DNS domain forwarded to VPC resolver and excluded from DNSSEC validation. |
| `dns_vpc_reverse_domain` | `10.in-addr.arpa` | Reverse lookup zone for 10.0.0.0/16 VPC network forwarded to VPC resolver and excluded from DNSSEC validation. |
| `dns_vpc_resolver` | `10.0.0.2` | Amazon VPC DNS resolver IP used as upstream forwarder for internal VPC queries. |

---

## Tasks & Tags

Execution can be targeted via Ansible tags:

| Tag | Scope | Description |
|---|---|---|
| `dns` | Complete Role | Executes pre-flight assertions, package installation, options and zone configuration, named-checkconf validation, service enablement, UFW rules, AIDE drop-in, Netplan overlay, handler flush, and verification tasks. |
| `dns_verify` | Verification Only | Executes only the assertions defined in `tasks/verify.yml` (service active, named-checkconf -z, socket bindings, forward/reverse dig lookups, external recursion, UFW rules, Netplan resolvectl settings, VPC host IP PTR query status (NOERROR), active DNS server verification, system resolver lookup, and AIDE drop-in validation). |

---

## Shared Files Notice

- **/etc/ufw/user.rules:** Managed via `community.general.ufw` module. Adds targeted rules for incoming port 53 UDP and TCP on `wg0` without modifying other firewall rules. Port 53 is never exposed on the public interface.
- **/etc/aide/aide.conf.d/:** Hardening deploys `/etc/aide/aide.conf.d/99-hardening`. The `dns` role deploys an independent drop-in at `/etc/aide/aide.conf.d/99-zz-dns` (ordered after `99-hardening`, which defines the `CONTENTEX` group) covering `/etc/bind` and `/etc/bind/zones` while excluding `/var/cache/bind`. Configuration syntax is verified with `aide --config-check` before flushing handlers to regenerate the baseline database.
- **/etc/netplan/:** Deploys an independent overlay at `/etc/netplan/51-dns-lab.yaml` with mode `0600`, preserving `/etc/netplan/50-cloud-init.yaml` untouched to prevent conflict with cloud-init.

---

## Non-Automated Procedures & Accepted Deviations

1. **Step 5 (auditd `dns_config` rule):** In the manual implementation, an audit rule is appended to `/etc/audit/rules.d/99-hardening.rules`. In the automated baseline, hardening deploys rules with immutable mode enabled (`-e 2`) and rule flushing (`-D`). Attempting to append audit rules at runtime without a full reboot or kernel-level audit restart fails. This step is executed manually. Note that the manually added audit rule lives in `99-hardening.rules`, owned by hardening: if Step 10 of hardening is re-run, the file is restored and the `dns_config` rule disappears, so it must be added again.
2. **Step 7 (WireGuard Peers DNS):** Configuring `DNS = 172.16.0.1` in `/etc/wireguard/wg0.conf` on WireGuard peers (such as the local VM) is maintained manually because the `hardening` role owns `wg0.conf` on those peers and would revert peer modifications on subsequent runs.
3. **Step 8 (Pre-AMI Cleanup):** Pre-AMI sanitization of `/etc/resolv.conf` is excluded from Ansible automation because the infrastructure workflow is greenfield (Terraform and Ansible rebuild from base OS), eliminating dependency on golden AMIs.
4. **Package `bind9-dnsutils`:** Installed alongside `bind9` and `bind9utils` to provide the `dig` diagnostic utility required for automated post-deploy verification assertions.
5. **System Resolver Selection After Reboot:** After rebooting the host, if `resolvectl status ens5` shows `Current DNS Server: 10.0.0.2`, execute `sudo systemctl restart systemd-resolved` (the role only restarts it when applying the Netplan overlay). This recovery command should also be executed once if the role is applied on a host where `systemd-resolved` has already fallen back to `10.0.0.2`.
6. **Role additions to the manual configs:** When deploying `named.conf.options` and `named.conf.local`, the role adds on the fly `validate-except { "compute.internal"; "10.in-addr.arpa"; };` and two `forward only` zones (`compute.internal` and `10.in-addr.arpa`) pointing to `10.0.0.2`. Without these additions, queries for internal VPC names (e.g. `*.eu-west-1.compute.internal`) and reverse PTR lookups for VPC host IPs fail DNSSEC validation via external forwarders with `SERVFAIL`, causing `systemd-resolved` to mark `127.0.0.1` defective and fall back permanently to `10.0.0.2` (which returns `NXDOMAIN` for `lab.internal`).
