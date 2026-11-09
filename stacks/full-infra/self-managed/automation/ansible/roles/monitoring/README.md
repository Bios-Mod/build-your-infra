# Role: monitoring

This role automates Steps 1–5 of [`modules/monitoring/self-managed/monitoring-self-managed.md`](../../../../../../../modules/monitoring/self-managed/monitoring-self-managed.md) on Ubuntu Server 24.04 LTS (ARM64 / x86_64): pull-based host metrics collection with `node_exporter`, Prometheus scraping across the WireGuard tunnel, synthetic probing with `blackbox_exporter`, Grafana OSS provisioning, UFW scoping over `wg0`, auditd config watches, and AIDE integrity monitoring.

---

## Target Environments & Prerequisites

- **Targets:**
  - `monitoring_targets` (`multi-lab-local` VM + `multi-lab-vps` EC2): deploys `prometheus-node-exporter` and AIDE integrity drop-ins (plus EC2 `wg-quick@wg0` ordering and UFW `9100/tcp` from the VM WireGuard IP).
  - `monitoring_servers` (`multi-lab-local` VM only): deploys Prometheus, `blackbox_exporter`, Grafana OSS (bound to `172.16.0.3:3000` over `wg0`), UFW `3000/tcp` on `wg0`, and auditd watch rules.
- **Prerequisites:**
  - `hardening` deployed on both targets with active WireGuard `wg0` tunnel (`172.16.0.1` hub on EC2, `172.16.0.3` peer on VM, OpenSSH on port `22222`).
  - `dns` and `web-server` running so `blackbox-dns`, `blackbox-http`, and `blackbox-tcp` synthetic probes pass.

---

## Role Variables & Inputs

### Conditional Inventory Variables (`host_vars`)

| Variable | Description |
|---|---|
| `monitoring_auditd_reboot` | Boolean flag controlling automatic reboot when auditd rules change on `monitoring_servers` while `hardening_auditd_immutable_mode` is `true`. Required only when `hardening_auditd_immutable_mode` is active; set to `false` in `inventories/host_vars/multi-lab-local.yml`. |

### Inherited Group Variables & Runtime Prompts

| Input | Source | Purpose |
|---|---|---|
| `wireguard_vm_vpn_ip`, `wireguard_server_vpn_ip`, `is_cloud` | `group_vars/all.yml`, `vm.yml`, `ec2.yml` | Automatically derive VM/EC2 `wg0` IPs and per-host `node_exporter` bind addresses. |
| `monitoring_grafana_admin_password` | `playbooks/monitoring.yml` `vars_prompt` | Sets built-in Grafana `admin` password via `--password-from-stdin` only when `/var/lib/grafana/grafana.db` does not exist yet (leave empty on already-provisioned hosts). |

### Role Defaults (`defaults/main.yml`)

| Variable | Default Value | Purpose |
|---|---|---|
| `monitoring_configs_dir` | `{{ configs_root }}/monitoring/self-managed/configs` | Path to source monitoring configuration files. |
| `hardening_ssh_port` | `{{ ssh_hardened_port \| default(22222) }}` | Hardened OpenSSH port checked during pre-flight verification. |
| `hardening_auditd_immutable_mode` | `true` | Auditd immutable kernel mode baseline. |
| `monitoring_server_wg_ip` | `{{ wireguard_vm_vpn_ip \| default('172.16.0.3') }}` | VM WireGuard IP for Grafana bind and EC2 UFW source allow rule. |
| `monitoring_ec2_wg_ip` | `{{ wireguard_server_vpn_ip \| default('172.16.0.1') }}` | EC2 WireGuard hub IP for `node_exporter` bind and Prometheus scrape target. |
| `monitoring_node_exporter_port` | `9100` | HTTP port exposed by `prometheus-node-exporter`. |
| `monitoring_node_exporter_listen` | `127.0.0.1:9100` (VM) / `172.16.0.1:9100` (EC2) | Per-host listen address substituted into `/etc/default/prometheus-node-exporter`. |
| `monitoring_ec2_scrape_target` | `{{ monitoring_ec2_wg_ip }}:{{ monitoring_node_exporter_port }}` | EC2 target substituted into `/etc/prometheus/prometheus.yml`. |
| `monitoring_prometheus_port` | `9090` | Prometheus loopback HTTP port. |
| `monitoring_blackbox_port` | `9115` | `blackbox_exporter` loopback HTTP port. |
| `monitoring_grafana_port` | `3000` | Grafana WireGuard HTTP port. |
| `monitoring_grafana_apt_key_url` | `https://apt.grafana.com/gpg.key` | Official Grafana APT repository GPG signing key URL. |
| `monitoring_grafana_apt_key_fingerprint` | `B53AE77BADB630A683046005963FA27710458545` | Verified primary GPG fingerprint checked before configuring APT sources. |
| `monitoring_grafana_admin_password` | `""` | Default empty placeholder overridden by `vars_prompt` during initial setup. |
| `monitoring_expected_targets` | `8` | Total `up` series across all 5 jobs defined in `prometheus.yml`. |
| `monitoring_expected_probes` | `5` | Total `probe_success` series across the 3 `blackbox-*` jobs in `prometheus.yml`. |

---

## Tasks & Tags

| Tag | Scope | Description |
|---|---|---|
| `monitoring` | Complete Role | Runs pre-flight checks, manual `99-hardening` cleanup, `node_exporter`, UFW rules, Prometheus, `blackbox_exporter`, Grafana repo/password/provisioning, AIDE drop-in, VM auditd drop-in, handler flush, and verification. |
| `monitoring_verify` | Verification Only | Runs read-only assertions in `tasks/verify.yml` across systemd units, socket bindings, `node_exporter` HTTP metrics, UFW rules, Prometheus API target/probe counts, Grafana health/DB/provisioning permissions, AIDE syntax, and auditd rules. |

---

## Shared Files & Firewall Notice

- **UFW Rules:** Opens `9100/tcp` inbound on `wg0` from `monitoring_server_wg_ip` on EC2, and `3000/tcp` inbound on `wg0` on `monitoring_servers`.
- **APT Keyring & Repo:** Downloads Grafana's key as ASCII-armored `/etc/apt/keyrings/grafana.asc` (explicit mode `0644`), writes `/etc/apt/sources.list.d/grafana.list` pointing to `grafana.asc`, and removes any legacy `/etc/apt/keyrings/grafana.gpg`.
- **/etc/aide/aide.conf.d/:** Deploys `/etc/aide/aide.conf.d/99-zz-monitoring` (`0644`) ordered after `99-hardening` on both VM and EC2.
- **/etc/audit/rules.d/:** Deploys `/etc/audit/rules.d/99-zz-monitoring.rules` (`0640`) watching `/etc/prometheus/` and `/etc/grafana/` on `monitoring_servers` only.
- **Cleanup of Manual Appends:** Idempotently removes active monitoring lines appended to `/etc/audit/rules.d/99-hardening.rules` and `/etc/aide/aide.conf.d/99-hardening` by manual deployment while leaving header comments and hardening rules intact.

---

## Non-Automated Procedures & Accepted Deviations

1. **Manual Step 6 Fault Injection & Step 7 Browser Access:** Controlled `named` stop/start fault injection (manual Step 6) and interactive Grafana UI login/dashboard verification from the Mac workstation (manual Step 7) remain manual procedures outside Ansible.
2. **ASCII-Armored Key (`grafana.asc`) Replaces Manual `grafana.gpg`:** Downloads `gpg.key` to `/etc/apt/keyrings/grafana.asc` (`0644`) without `gpg --dearmor`, updates `/etc/apt/sources.list.d/grafana.list` to reference `grafana.asc`, and removes any pre-existing `grafana.gpg`.
3. **EC2 `auditd` Exclusion:** No `monitoring` auditd drop-in is deployed on EC2 because EC2 runs auditd in immutable mode (`-e 2`), which would force a kernel reboot and drop the WireGuard hub.
4. **Idempotent Cleanup of Hardening Drop-Ins:** The role removes monitoring-specific lines written to `/etc/audit/rules.d/99-hardening.rules` and `/etc/aide/aide.conf.d/99-hardening` during manual deployment so `augenrules --load` does not fail with `Rule exists` when `99-zz-monitoring.rules` is loaded. Hardening-owned rules and comments remain untouched.

