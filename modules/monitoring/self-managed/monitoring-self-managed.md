# Monitoring — Self-Managed

**Ubuntu 24.04 LTS · Local VM + EC2**

---

## Introduction

This document covers the deployment of a pull-based observability stack
built with Prometheus, `node_exporter`, `blackbox_exporter`, and Grafana on top
of the hardened OS baseline established in
[`modules/hardening/self-managed/hardening-self-managed.md`](../../hardening/self-managed/hardening-self-managed.md).

Prometheus, `blackbox_exporter`, and Grafana run exclusively on the local VM
(`multi-lab-local`, `172.16.0.3` over WireGuard). No new AWS instance or cloud
monitoring service is provisioned: Prometheus scrapes host metrics locally and
pulls EC2 (`multi-lab-vps`, `172.16.0.1`) telemetry across the existing
encrypted WireGuard tunnel. Scope is telemetry collection, synthetic endpoint
probing, and visualization — alerting pipelines are outside this module.

> **Prerequisite — Hardening & WireGuard:** the `hardening` module must be
> deployed on both VM and EC2 with the `wg0` WireGuard tunnel active
> (`172.16.0.1` hub on EC2, `172.16.0.3` peer on VM, `172.16.0.2` Mac peer,
> and `ufw route allow in on wg0 out on wg0` enabled on EC2). Without `wg0`,
> Prometheus cannot scrape EC2 and Grafana is unreachable from the Mac
> workstation.

> **Prerequisite — DNS & Web Server targets:** [`modules/dns/self-managed/dns-self-managed.md`](../../dns/self-managed/dns-self-managed.md)
> (`lab.internal` on `172.16.0.1:53`) and
> [`modules/web-server/self-managed/web-server-self-managed.md`](../../web-server/self-managed/web-server-self-managed.md)
> (Nginx HTTPS on VM and EC2) must be running before verifying the synthetic
> probes in Steps 3 and 6.

> **No AWS infrastructure changes:** neither EC2 Security Groups nor Terraform
> definitions are modified. All cross-host monitoring traffic stays inside the
> existing UDP `51820` WireGuard tunnel and is filtered by UFW on `wg0`.

> **Additive and file-based configs:** configuration files in `configs/` are
> deployed directly via `sudo cp` (full-file replace) or `sudo tee -a` (block
> append) from the repository path — never inserted inline.

---

## Environment

| Component | Host | Listen address | Access scope |
| --- | --- | --- | --- |
| `prometheus` | VM (`multi-lab-local`) | `127.0.0.1:9090` | Loopback only (UI and HTTP API) |
| `prometheus-blackbox-exporter` | VM (`multi-lab-local`) | `127.0.0.1:9115` | Loopback only (queried by Prometheus) |
| `prometheus-node-exporter` (VM) | VM (`multi-lab-local`) | `127.0.0.1:9100` | Loopback only (scraped by Prometheus) |
| `prometheus-node-exporter` (EC2) | EC2 (`multi-lab-vps`) | `172.16.0.1:9100` | UFW `wg0` from `172.16.0.3` only |
| `grafana-server` | VM (`multi-lab-local`) | `172.16.0.3:3000` | Mac workstation over `wg0` (HTTP) |

Three explicit placeholders appear in the committed config files and are
substituted on the deployed copy under `/etc/` so the local git working tree
remains clean:

- `<listen_address>` in `configs/node-exporter/prometheus-node-exporter`: `127.0.0.1:9100` on VM (`multi-lab-local`), `172.16.0.1:9100` on EC2 (`multi-lab-vps`)
- `<ec2_scrape_target>` in `configs/prometheus/prometheus.yml`: `172.16.0.1:9100`
- `<vm_wg_ip>` in `configs/grafana/grafana-override.conf`: `172.16.0.3`

---

## Step 1 — Install and Configure node_exporter

### What was done

`prometheus-node-exporter` is installed from the Ubuntu 24.04 LTS APT
repositories on both the local VM and EC2 so Prometheus can collect CPU,
memory, filesystem, load, and network counters from each host.

> **EC2 boot ordering:** `wg0` is brought up asynchronously by
> `wg-quick@wg0.service` during boot. Because EC2 binds `node_exporter`
> specifically to `172.16.0.1:9100`, Linux refuses the `bind()` call if the
> exporter starts before `wg0` owns that IP. The systemd drop-in enforces
> `After=wg-quick@wg0.service` and `Wants=wg-quick@wg0.service`.

> **Placeholder substitution:** substitute `<listen_address>` with `sed` on
> the deployed copy `/etc/default/prometheus-node-exporter`, never in the
> repository file. Use a distinct value per host: `127.0.0.1:9100` on VM
> (`multi-lab-local`) and `172.16.0.1:9100` on EC2 (`multi-lab-vps`).

**VM (`multi-lab-local`) — bind to loopback only:**

```bash
uname -m
# → aarch64  (or x86_64 — confirm architecture matches package selection)

sudo apt update
sudo apt install -y prometheus-node-exporter

sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/node-exporter/prometheus-node-exporter /etc/default/prometheus-node-exporter
sudo sed -i 's/<listen_address>/127.0.0.1:9100/' /etc/default/prometheus-node-exporter

sudo systemctl restart prometheus-node-exporter
sudo systemctl enable prometheus-node-exporter
```

**EC2 (`multi-lab-vps`) — bind to WireGuard hub IP, enforce boot ordering, and restrict UFW:**

```bash
uname -m
# → aarch64  (AWS Graviton2)

sudo apt update
sudo apt install -y prometheus-node-exporter

sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/node-exporter/prometheus-node-exporter /etc/default/prometheus-node-exporter
sudo sed -i 's/<listen_address>/172.16.0.1:9100/' /etc/default/prometheus-node-exporter

sudo mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/node-exporter/wg0-ordering.conf /etc/systemd/system/prometheus-node-exporter.service.d/wg0-ordering.conf

sudo systemctl daemon-reload
sudo systemctl restart prometheus-node-exporter
sudo systemctl enable prometheus-node-exporter

# Permit scrapes on 9100/tcp exclusively from the VM WireGuard peer (172.16.0.3)
sudo ufw allow in on wg0 from 172.16.0.3 to any port 9100 proto tcp comment 'node_exporter from VM over wg0'
sudo ufw reload
```

📄 [`configs/node-exporter/prometheus-node-exporter`](configs/node-exporter/prometheus-node-exporter) — replace `/etc/default/prometheus-node-exporter` (VM and EC2)

📄 [`configs/node-exporter/wg0-ordering.conf`](configs/node-exporter/wg0-ordering.conf) — create `/etc/systemd/system/prometheus-node-exporter.service.d/wg0-ordering.conf` (EC2 only)

### Why

Binding `node_exporter` on the VM to `127.0.0.1:9100` keeps host telemetry off
the LAN segment entirely since Prometheus runs on the same machine. On EC2,
binding to `172.16.0.1:9100` plus a UFW rule restricted to source
`172.16.0.3` on `wg0` prevents `9100/tcp` from ever listening on or accepting
packets from the public interface, removing any need to open metrics ports in
AWS Security Groups.

### Verification

**VM (`multi-lab-local`):**

```bash
prometheus-node-exporter --version
# → node_exporter, version ... (branch: debian/sid, ...)

sudo systemctl is-active prometheus-node-exporter
# → active

ss -tlnp | grep 9100
# → LISTEN ... 127.0.0.1:9100 ...

# Local endpoint responds
curl -sf http://127.0.0.1:9100/metrics | head -n 5
# → # HELP go_gc_duration_seconds ...

# Cross-tunnel reachability to EC2 node_exporter over wg0
curl -sf http://172.16.0.1:9100/metrics | head -n 5
# → # HELP go_gc_duration_seconds ...
```

**EC2 (`multi-lab-vps`):**

```bash
prometheus-node-exporter --version
# → node_exporter, version ...

sudo systemctl is-active prometheus-node-exporter
# → active

ss -tlnp | grep 9100
# → LISTEN ... 172.16.0.1:9100 ...

sudo systemctl cat prometheus-node-exporter | grep -A2 wg-quick@wg0
# → After=wg-quick@wg0.service
# → Wants=wg-quick@wg0.service

sudo ufw status | grep 9100
# → 9100/tcp on wg0          ALLOW IN    172.16.0.3
```

---

## Step 2 — Install and Configure Prometheus

### What was done

Prometheus is installed on the local VM (`multi-lab-local`) from the Ubuntu
24.04 LTS APT repositories. Daemon arguments in `/etc/default/prometheus`
restrict HTTP access to `127.0.0.1:9090` and set TSDB retention to `15d` while
preserving the Ubuntu package's compiled-in defaults
(`--config.file=/etc/prometheus/prometheus.yml` and
`--storage.tsdb.path=/var/lib/prometheus/metrics2/`).

`/etc/prometheus/prometheus.yml` configures a `15s` scrape interval and five
jobs: `prometheus`, `node`, `blackbox-dns`, `blackbox-http`, and `blackbox-tcp`.

> **Placeholder substitution:** substitute `<ec2_scrape_target>`
> (`172.16.0.1:9100`) with `sed` on the deployed copy
> `/etc/prometheus/prometheus.yml` — never in the repository file — before
> validating with `promtool check config`. Apply this on the VM
> (`multi-lab-local`) only; Prometheus runs exclusively there and EC2 has no
> `prometheus.yml`.

**VM (`multi-lab-local`):**

```bash
sudo apt update
sudo apt install -y prometheus
prometheus --version
# → prometheus, version 2.x.x ...

sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/prometheus/prometheus /etc/default/prometheus
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/prometheus/prometheus.yml /etc/prometheus/prometheus.yml
sudo sed -i 's/<ec2_scrape_target>/172.16.0.1:9100/' /etc/prometheus/prometheus.yml

promtool check config /etc/prometheus/prometheus.yml
# → Checking /etc/prometheus/prometheus.yml
# →  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

sudo systemctl restart prometheus
sudo systemctl enable prometheus
```

📄 [`configs/prometheus/prometheus`](configs/prometheus/prometheus) — replace `/etc/default/prometheus`

📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — replace `/etc/prometheus/prometheus.yml`

### Why

Prometheus exposes an unauthenticated web UI and TSDB query API by default.
Binding strictly to `127.0.0.1:9090` prevents LAN peers from querying metrics
or hitting administrative endpoints directly, while allowing Grafana on the
same host to proxy queries cleanly. Setting `--storage.tsdb.retention.time=15d`
bounds disk usage on the VM. In `prometheus.yml`, `blackbox-http` sets a
default `params.module` (`http_2xx_tls`) and rewrites `__param_module` via
`relabel_configs` for `https://127.0.0.1` (`http_2xx_insecure`), keeping both
HTTPS probes under a single job (`blackbox-http`) for unified dashboard queries.

### Verification

**VM (`multi-lab-local`):**

```bash
sudo systemctl is-active prometheus
# → active

ss -tlnp | grep 9090
# → LISTEN ... 127.0.0.1:9090 ...

curl -sf http://127.0.0.1:9090/-/ready
# → Prometheus Server is Ready.

curl -sf http://127.0.0.1:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"

# → blackbox-* targets remain "down" until blackbox_exporter starts in Step 3
# → prometheus multi-lab-local up
# → node multi-lab-local up
# → node multi-lab-vps up

```

---

## Step 3 — Install and Configure blackbox_exporter

### What was done

`prometheus-blackbox-exporter` is installed on the local VM (`multi-lab-local`)
from the Ubuntu 24.04 LTS APT repositories and bound to `127.0.0.1:9115`.
`/etc/prometheus/blackbox.yml` defines four probe modules:

- `dns_lab_soa`: sends a UDP `SOA` query for `lab.internal` over IPv4 (`172.16.0.1:53`).
- `http_2xx_insecure`: probes VM self-signed HTTPS (`https://127.0.0.1`), accepts HTTP `200` and `502`, disables redirect following, and skips CA verification.
- `http_2xx_tls`: probes EC2 Let's Encrypt HTTPS (`https://buildyourinfra.click`), accepts HTTP `200` and `502`, and verifies the full public certificate chain and expiration timestamp.
- `tcp_connect`: performs IPv4 TCP handshake checks against SSH (`22222/tcp`) on both VM loopback and EC2 `wg0`.

**VM (`multi-lab-local`):**

```bash
sudo apt update
sudo apt install -y prometheus-blackbox-exporter
prometheus-blackbox-exporter --version
# → blackbox_exporter, version ...

sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/blackbox/prometheus-blackbox-exporter /etc/default/prometheus-blackbox-exporter
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/blackbox/blackbox.yml /etc/prometheus/blackbox.yml

sudo prometheus-blackbox-exporter --config.file=/etc/prometheus/blackbox.yml --config.check
# → ... msg="Config check successful"

sudo systemctl restart prometheus-blackbox-exporter
sudo systemctl enable prometheus-blackbox-exporter
```

📄 [`configs/blackbox/prometheus-blackbox-exporter`](configs/blackbox/prometheus-blackbox-exporter) — replace `/etc/default/prometheus-blackbox-exporter`

📄 [`configs/blackbox/blackbox.yml`](configs/blackbox/blackbox.yml) — replace `/etc/prometheus/blackbox.yml`

### Why

Host metrics confirm kernel and process health, whereas synthetic probes verify
real service availability from a client perspective. Accepting both `200` and
`502` on HTTP matches the Nginx reverse-proxy baseline deployed in
`modules/web-server/`: Nginx terminates TLS and returns `502 Bad Gateway` when
no upstream application daemon is running behind `proxy_pass`. Splitting
`http_2xx_insecure` (self-signed VM) from `http_2xx_tls` (Let's Encrypt EC2)
monitors public certificate trust and renewal status (`probe_ssl_earliest_cert_expiry`)
without relaxing TLS verification on the public endpoint.

### Verification

**VM (`multi-lab-local`):**

```bash
sudo systemctl is-active prometheus-blackbox-exporter
# → active

ss -tlnp | grep 9115
# → LISTEN ... 127.0.0.1:9115 ...

# Probe BIND9 SOA for lab.internal on EC2 over WireGuard
curl -sf 'http://127.0.0.1:9115/probe?target=172.16.0.1:53&module=dns_lab_soa' | grep '^probe_success'
# → probe_success 1

# Probe VM Nginx self-signed HTTPS
curl -sf 'http://127.0.0.1:9115/probe?target=https://127.0.0.1&module=http_2xx_insecure' | grep '^probe_success'
# → probe_success 1

# Probe EC2 Nginx Let's Encrypt HTTPS + inspect TLS expiry metric
curl -sf 'http://127.0.0.1:9115/probe?target=https://buildyourinfra.click&module=http_2xx_tls' | grep -E '^probe_(success|ssl_earliest_cert_expiry)'
# → probe_ssl_earliest_cert_expiry ...
# → probe_success 1

# Probe SSH TCP sockets on VM loopback and EC2 WireGuard IP
curl -sf 'http://127.0.0.1:9115/probe?target=127.0.0.1:22222&module=tcp_connect' | grep '^probe_success'
# → probe_success 1

curl -sf 'http://127.0.0.1:9115/probe?target=172.16.0.1:22222&module=tcp_connect' | grep '^probe_success'
# → probe_success 1
```

---

## Step 4 — Install, Provision, and Expose Grafana

### What was done

Grafana OSS is not shipped in Ubuntu 24.04 LTS default repositories, so it is
installed from Grafana's official APT repository (`https://apt.grafana.com`).
A systemd override binds Grafana HTTP (`3000/tcp`) exclusively to the VM's
WireGuard address (`172.16.0.3` via `<vm_wg_ip>`) and orders startup after
`wg-quick@wg0.service`. UFW permits inbound `3000/tcp` on `wg0` only, and
file-based provisioning registers the local Prometheus datasource and the custom
`Lab Overview` dashboard (`lab-overview.json`) automatically on boot.

> **GPG key verification:** verify the downloaded Grafana repository signing
> key fingerprint (`B53AE77BADB630A683046005963FA27710458545`) before writing
> `/etc/apt/sources.list.d/grafana.list`. Abort if the fingerprint does not match.

> **Interactive credential handling:** set the `admin` password via `read -rsp`
> piped to `grafana-cli ... --password-from-stdin` and unset the variable
> afterward. Never commit passwords to the repository or pass them as plaintext
> CLI flags visible in shell history or `ps`.

> **Placeholder substitution:** substitute `<vm_wg_ip>` (`172.16.0.3`) with
> `sed` on the deployed copy
> `/etc/systemd/system/grafana-server.service.d/override.conf` — never in
> the repository file. Apply on the VM (`multi-lab-local`) only.

> **Restrictive umask:** on the hardened VM, files created with `sudo tee` or `sudo cp` default to mode `600` (root-only). APT reads the repository key and source list as the `_apt` user, and Grafana reads its provisioning files as the `grafana` user, so unreadable files cause `NO_PUBKEY` errors or a failed service start. Set `644` explicitly on every file a non-root service must read.

**VM (`multi-lab-local`):**

```bash
sudo apt update
sudo apt install -y apt-transport-https wget gnupg

sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
gpg --show-keys --with-fingerprint /etc/apt/keyrings/grafana.gpg
# → Key fingerprint = B53A E77B ADB6 30A6 8304  6005 963F A277 1045 8545

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
sudo chmod 644 /etc/apt/keyrings/grafana.gpg /etc/apt/sources.list.d/grafana.list
sudo apt update
sudo apt install -y grafana
grafana-server -v
# → Version 

# Bind Grafana to wg0 (172.16.0.3:3000) and order after wg-quick@wg0.service
sudo mkdir -p /etc/systemd/system/grafana-server.service.d
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/grafana/grafana-override.conf /etc/systemd/system/grafana-server.service.d/override.conf
sudo sed -i 's/<vm_wg_ip>/172.16.0.3/' /etc/systemd/system/grafana-server.service.d/override.conf

# Allow Grafana UI solely over WireGuard (never open on LAN)
sudo ufw allow in on wg0 to any port 3000 proto tcp comment 'Grafana UI over WireGuard'
sudo ufw reload

# Provision Prometheus datasource and Lab Overview dashboard
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/grafana/provisioning/datasources/prometheus.yml /etc/grafana/provisioning/datasources/prometheus.yml
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/grafana/provisioning/dashboards/lab.yml /etc/grafana/provisioning/dashboards/lab.yml
sudo chmod 644 /etc/grafana/provisioning/datasources/prometheus.yml /etc/grafana/provisioning/dashboards/lab.yml
sudo install -d -m 755 -o root -g grafana /var/lib/grafana/dashboards
sudo cp ~/build-your-infra/modules/monitoring/self-managed/configs/grafana/dashboards/lab-overview.json /var/lib/grafana/dashboards/lab-overview.json
sudo chmod 644 /var/lib/grafana/dashboards/lab-overview.json

# Set Grafana admin password interactively before exposing the service
read -rsp "New Grafana admin password: " GRAFANA_PASS && echo
printf '%s\n' "$GRAFANA_PASS" | sudo grafana-cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password --password-from-stdin
unset GRAFANA_PASS
sudo chown -R grafana:grafana /var/lib/grafana /var/log/grafana

sudo systemctl daemon-reload
sudo systemctl enable --now grafana-server
sudo systemctl restart grafana-server
```

📄 [`configs/grafana/grafana-override.conf`](configs/grafana/grafana-override.conf) — create `/etc/systemd/system/grafana-server.service.d/override.conf`

📄 [`configs/grafana/provisioning/datasources/prometheus.yml`](configs/grafana/provisioning/datasources/prometheus.yml) — replace `/etc/grafana/provisioning/datasources/prometheus.yml`

📄 [`configs/grafana/provisioning/dashboards/lab.yml`](configs/grafana/provisioning/dashboards/lab.yml) — replace `/etc/grafana/provisioning/dashboards/lab.yml`

📄 [`configs/grafana/dashboards/lab-overview.json`](configs/grafana/dashboards/lab-overview.json) — create `/var/lib/grafana/dashboards/lab-overview.json`

### Why

Grafana is the only new port reachable from outside the VM (`3000/tcp` on `wg0`).
Serving Grafana over HTTP inside WireGuard relies on the tunnel's WireGuard
encryption end-to-end from the Mac (`172.16.0.2`) through the EC2 hub (`ufw route allow in on wg0 out on wg0`) to the VM (`172.16.0.3`), matching SSH, DNS,
and SFTP without introducing another self-signed browser warning. Overriding
`GF_SERVER_HTTP_ADDR` and `GF_SERVER_HTTP_PORT` via a systemd drop-in leaves
the package-managed `/etc/grafana/grafana.ini` untouched for clean APT upgrades,
and provisioning the datasource and `lab-overview.json` from files ensures the
dashboard comes up identically on every rebuild without importing third-party
community JSON. Because `grafana-cli` executes as `root` before Grafana's first
startup, it creates and initializes `/var/lib/grafana/grafana.db` (and touches
log paths) under root ownership; running
`sudo chown -R grafana:grafana /var/lib/grafana /var/log/grafana` before
starting `grafana-server` ensures the unprivileged `grafana` service user can
read and write its database, dashboards, and log directory.

### Verification

**VM (`multi-lab-local`):**

```bash
ls -l /etc/apt/keyrings/grafana.gpg /etc/grafana/provisioning/datasources/prometheus.yml
# → -rw-r--r-- ...

sudo systemctl is-active grafana-server
# → active

# Diagnostic — run only if grafana-server is not active
sudo journalctl -u grafana-server -n 20 --no-pager
# → ... HTTP Server Listen address=172.16.0.3:3000 ...

ss -tlnp | grep 3000
# → LISTEN ... 172.16.0.3:3000 ...

sudo ufw status | grep 3000
# → 3000/tcp on wg0          ALLOW IN    Anywhere

curl -sf http://172.16.0.3:3000/api/health
# → { "database": "ok", ... }

# Confirm available RAM headroom alongside Prometheus and Grafana (4 GB lab VM)
free -m
# → Mem:   39xx   ...   available: ...
```

**Mac workstation (with WireGuard tunnel active):**

```bash
curl -sI http://172.16.0.3:3000/login | head -n 5
# → HTTP/1.1 200 OK
```

---

## Step 5 — Hardening Integration (auditd + AIDE)

### What was done

Auditd watch rules (`/etc/prometheus/` and `/etc/grafana/`) are appended to
`/etc/audit/rules.d/99-hardening.rules` on the local VM only (`-k monitoring_config`).
AIDE integrity scopes are extended and re-initialized on both the local VM and
EC2 (`node_exporter` defaults and systemd drop-in).

> **Conscious deviation — EC2 (`multi-lab-vps`) auditd exclusion:** no auditd
> rule is appended on EC2. EC2 runs auditd in immutable mode (`-e 2`), so
> reloading rules requires rebooting the EC2 instance — which drops the
> WireGuard hub (`wg0`) and disconnects all lab peers. Because EC2 runs only
> `node_exporter` (whose binary `/usr/bin/prometheus-node-exporter` and unit
> under `/usr/lib/systemd/system/` are already monitored by the hardening AIDE
> baseline, and whose config/drop-in are added to AIDE below), skipping
> auditd on EC2 avoids an unnecessary hub outage.

> **VM immutable mode (`-e 2`):** if auditd on the VM has immutable mode
> disabled (`sudo auditctl -s | grep enabled` returns `enabled 1`),
> `sudo augenrules --load` applies the appended rules immediately with no
> reboot. If immutable mode (`enabled 2`) is active in
> `/etc/audit/rules.d/99-hardening.rules`, `augenrules --load` fails with
> `Operation not permitted`: ensure `-e 2` remains the final line and run
> `sudo reboot now` to load the updated ruleset.

> **AIDE directory prerequisite (VM):** `aide/99-hardening` monitors
> `/etc/systemd/system/prometheus-node-exporter.service.d` on the VM so
> unexpected override drop-ins are detected even though `wg0-ordering.conf` is
> EC2-only. Ensure the directory exists (`sudo mkdir -p`) before running
> `aide --init` so AIDE does not emit missing-directory warnings.

**VM (`multi-lab-local`):**

```bash
# auditd — watch Prometheus and Grafana configuration directories (VM only)
sudo tee -a /etc/audit/rules.d/99-hardening.rules < ~/build-your-infra/modules/monitoring/self-managed/configs/audit/99-hardening.rules
sudo augenrules --load

# AIDE — ensure drop-in dir exists, extend integrity scope, and rebuild baseline
sudo mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
sudo tee -a /etc/aide/aide.conf.d/99-hardening < ~/build-your-infra/modules/monitoring/self-managed/configs/aide/99-hardening
sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

**EC2 (`multi-lab-vps`):**

```bash
# AIDE — cover node_exporter defaults and wg0 systemd drop-in, then rebuild baseline
sudo tee -a /etc/aide/aide.conf.d/99-hardening < ~/build-your-infra/modules/monitoring/self-managed/configs/aide/99-hardening-node-exporter
sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

📄 [`configs/audit/99-hardening.rules`](configs/audit/99-hardening.rules) — append to `/etc/audit/rules.d/99-hardening.rules` (VM only)

📄 [`configs/aide/99-hardening`](configs/aide/99-hardening) — append to `/etc/aide/aide.conf.d/99-hardening` (VM)

📄 [`configs/aide/99-hardening-node-exporter`](configs/aide/99-hardening-node-exporter) — append to `/etc/aide/aide.conf.d/99-hardening` (EC2)

### Why

Watching `/etc/prometheus/` and `/etc/grafana/` with auditd captures unauthorized
modifications to scrape targets, probe definitions, or provisioned datasources.
In AIDE, monitoring configuration directories and `/etc/default/*` daemon flags
while explicitly excluding `/var/lib/prometheus` and `/var/lib/grafana` catches
silent tampering without generating daily false positives from TSDB block
compaction or Grafana SQLite runtime writes.

### Verification

**VM (`multi-lab-local`):**

```bash
sudo auditctl -l | grep monitoring_config
# → -w /etc/prometheus -p wa -k monitoring_config
# → -w /etc/grafana -p wa -k monitoring_config

grep prometheus /etc/aide/aide.conf.d/99-hardening
# → /etc/prometheus ...
# → !/var/lib/prometheus

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
```

**EC2 (`multi-lab-vps`):**

```bash
grep node-exporter /etc/aide/aide.conf.d/99-hardening
# → /etc/default/prometheus-node-exporter ...
# → /etc/systemd/system/prometheus-node-exporter.service.d ...

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
```

---

## Step 6 — End-to-End Verification and Fault Injection

### What was done

Verify via `promtool query instant` that Prometheus is ready, all eight scrape
targets across the five jobs in `prometheus.yml` report `up == 1`, and all
five synthetic probes return `probe_success == 1`. Then execute a brief
controlled failure by stopping `named` (BIND9) on EC2 to verify end-to-end
probe failure detection and recovery.

> **Temporary service disruption:** stopping `named` on EC2 suspends
> `lab.internal` DNS resolution across WireGuard peers for ~30 seconds while
> the failure transition is recorded. Restart `named` immediately after
> observing `probe_success == 0`.

**VM (`multi-lab-local`) — inspect target and probe series:**

```bash
# List scrape status (1 = up) for all 8 targets across all 5 jobs
promtool query instant http://127.0.0.1:9090 'up'
# → up{host="multi-lab-local", instance="127.0.0.1:9090", job="prometheus"} => 1 @[...] (8 series total, all => 1)

# List synthetic probe status (1 = pass) for all 5 probes across the 3 blackbox jobs
promtool query instant http://127.0.0.1:9090 'probe_success'
# → probe_success{host="multi-lab-vps", instance="172.16.0.1:53", job="blackbox-dns"} => 1 @[...] (5 series total, all => 1)
```

**EC2 (`multi-lab-vps`) + VM (`multi-lab-local`) — fault injection test:**

```bash
# 1. EC2 · multi-lab-vps — stop BIND9 temporarily
sudo systemctl stop named
```

Wait 30 seconds (two `15s` scrape cycles), then verify on the VM:

```bash
# 2. VM · multi-lab-local — confirm blackbox-dns probe records the DNS outage (0)
promtool query instant http://127.0.0.1:9090 'probe_success{job="blackbox-dns"}'
# → probe_success{host="multi-lab-vps", instance="172.16.0.1:53", job="blackbox-dns"} => 0 @[...]
```

Restart `named` immediately on EC2 and confirm recovery on the VM after 30
seconds (two `15s` scrape cycles):

```bash
# 3. EC2 · multi-lab-vps — restore BIND9
sudo systemctl start named
sudo systemctl is-active named
# → active
```

```bash
# 4. VM · multi-lab-local — confirm blackbox-dns probe recovers to 1
promtool query instant http://127.0.0.1:9090 'probe_success{job="blackbox-dns"}'
# → probe_success{host="multi-lab-vps", instance="172.16.0.1:53", job="blackbox-dns"} => 1 @[...]
```

### Why

Checking `up == 1` alone confirms metrics endpoints answer HTTP GET requests.
Injecting an actual DNS outage validates the complete end-to-end loop —
service stops on EC2 → `blackbox_exporter` SOA check fails over `wg0` →
Prometheus flips `probe_success{job="blackbox-dns"}` from `1` to `0` →
restarting `named` restores `1`.

### Verification

**VM · multi-lab-local:**

```bash
# Confirm Prometheus HTTP API readiness
curl -sf http://127.0.0.1:9090/-/ready
# → Prometheus Server is Ready.

# Confirm total configured scrape targets
promtool query instant http://127.0.0.1:9090 'count(up)'
# → {} => 8 @[...]

# Confirm zero down targets
promtool query instant http://127.0.0.1:9090 'count(up == 0) or vector(0)'
# → {} => 0 @[...]

# Confirm total configured synthetic probes
promtool query instant http://127.0.0.1:9090 'count(probe_success)'
# → {} => 5 @[...]

# Confirm zero failed synthetic probes
promtool query instant http://127.0.0.1:9090 'count(probe_success == 0) or vector(0)'
# → {} => 0 @[...]

# Run only if any check above does not return the expected value (no output when healthy; lists failing series otherwise)
promtool query instant http://127.0.0.1:9090 'up == 0 or probe_success == 0'
# → (no output)
```

The expected totals `8` and `5` derive from the 5 jobs defined in
`prometheus.yml` (`prometheus`: 1, `node`: 2, `blackbox-dns`: 1,
`blackbox-http`: 2, `blackbox-tcp`: 2).

---

## Step 7 — Access Grafana from the Mac

### What was done

With the WireGuard tunnel active on the Mac control node (`172.16.0.2`), verify
connectivity to the VM (`172.16.0.3`) across the EC2 WireGuard hub, sign in
to Grafana, and review the `Lab Overview` dashboard.

**Mac · control node (with WireGuard tunnel active):**

```bash
# Confirm Layer 3 reachability to the VM over WireGuard via the EC2 hub
ping -c 2 172.16.0.3
# → 2 packets transmitted, 2 packets received, 0.0% packet loss

# Confirm Grafana health endpoint reports database ok
curl -s http://172.16.0.3:3000/api/health
# → { "database": "ok", ... }

# Confirm Grafana login page responds over HTTP
curl -sI http://172.16.0.3:3000/login | head -n 1
# → HTTP/1.1 200 OK
```

> **Troubleshooting connectivity:** if `ping` fails, check `wg show` on both
> the Mac and the EC2 hub (`multi-lab-vps`), verify `net.ipv4.ip_forward = 1`
> on EC2, and confirm `ufw route allow in on wg0 out on wg0` is enabled on EC2.
> If `ping` succeeds but `curl` hangs, check the UFW rule allowing `3000/tcp` on
> `wg0` on the VM (`multi-lab-local`).

**Browser verification (Mac with WireGuard active):**

1. Open `http://172.16.0.3:3000` and sign in as `admin` using the password set in Step 4.
2. Go to **Connections → Data sources → Prometheus** and click **Test** — confirm Grafana reports that it successfully queried the Prometheus API.
3. Go to **Dashboards → Lab → Lab Overview**, set the time range to **Last 1 hour**, and set the `host` variable to **All**.
4. Check every panel:
   - `Targets Up`: `8` targets showing `UP`.
   - `Blackbox Probes`: `5` probes showing `OK`.
   - `Host Uptime`: one value per host (`multi-lab-local`, `multi-lab-vps`).
   - `SSL Certificate Expiry`: remaining days for both HTTPS targets (`https://127.0.0.1` and `https://buildyourinfra.click`).
   - `CPU Usage (%)`, `Memory Usage (%)`, `Root Filesystem Usage (%)`, `Load Average (1m)`, and `Network Traffic (RX / TX)`: one series per host (`multi-lab-local`, `multi-lab-vps`).
   - `Probe Duration`: one series per probe.
5. Change `host` to a single value and confirm all panels filter accordingly.

### Why

Grafana listens only on `172.16.0.3` and UFW permits `3000/tcp` on `wg0` only,
so access from outside the VMs depends on peer-to-peer routing through the EC2
hub (confirmed by `ping` and `curl`). Grafana runs over HTTP without its own
TLS certificate because WireGuard encrypts the traffic end-to-end, matching SSH,
DNS, and SFTP in this lab.

### Verification

CLI target and probe checks are covered in
[Step 6](#step-6--end-to-end-verification-and-fault-injection). This step is
complete when the WireGuard connectivity checks above pass and all five checks
in the [browser verification list](#step-7--access-grafana-from-the-mac)
succeed (`Prometheus` datasource test passes, `Lab Overview` shows `8` targets
`UP` and `5` probes `OK` across all 10 panels, and `$host` filtering works).
