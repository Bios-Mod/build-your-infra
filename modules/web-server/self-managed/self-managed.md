# Web Server — Self-Managed

**Ubuntu 24.04 LTS · VM / VPS**

---

## Introduction

This document covers the deployment of Nginx with HTTPS and a reverse proxy
layer on top of the hardened OS baseline established in
`modules/hardening/self-managed/self-managed.md`.

The web server layer introduces the first public-facing service in the lab.
It terminates TLS at the Nginx level, enforces HTTPS-only access, and routes
upstream traffic via `proxy_pass` to internal services. The certificate
strategy differs by environment — self-signed for the local VM, Let's Encrypt
for the EC2 instance.

> **Prerequisite:** the `hardening` module must be fully deployed before
> applying this module. The firewall rules, AppArmor enforcement, auditd, and
> AIDE baseline extended here all depend on the hardening configuration.

> **Additive configs:** the configuration files in `configs/` publish only the
> block or full file added by this module. Each config references the repo path
> directly — never inlined. Apply patterns are either `sudo cp` (full-file
> replace) or `sudo tee -a` (block append), as specified per step.

---

## Environment

| Parameter     | Value                                                          |
|---------------|----------------------------------------------------------------|
| Web server    | Nginx                                                          |
| TLS — VM      | Self-signed certificate (`openssl req -x509`, 397-day limit)  |
| TLS — EC2     | Let's Encrypt via Certbot (auto-renewal enabled)              |
| HTTPS port    | 443                                                            |
| HTTP redirect | Port 80 → 443 (permanent 301)                                 |
| Reverse proxy | `proxy_pass` to upstream on localhost                         |
| Access scope  | Public (EC2) / LAN (VM)                                       |

---

## Step 1 — Install Nginx and Open Firewall

### What was done

Nginx is installed from the Ubuntu default repositories. The UFW application
profile `Nginx Full` is added to the existing hardening ruleset to allow
inbound traffic on ports 80 and 443. Port 80 is required temporarily during
Let's Encrypt certificate issuance (EC2) and permanently for the HTTP redirect.

```bash
sudo apt install nginx -y
sudo systemctl enable nginx

# Allow web traffic through the firewall
sudo ufw allow 'Nginx Full'
sudo ufw status
```

### Why

`Nginx Full` opens both port 80 and 443 in a single rule. Port 80 must be
reachable for the Certbot ACME HTTP-01 challenge on EC2 — blocking it would
cause certificate issuance to fail. On the VM, port 80 is only used to serve
the redirect to HTTPS. Using the named UFW profile keeps the ruleset readable
and avoids hardcoded port numbers.

### Verification

```bash
nginx -v
# → nginx version: nginx/1.x.x

sudo systemctl is-active nginx
# → active

sudo ufw status
# → Nginx Full   ALLOW IN   Anywhere

# Default page — HTTP should respond (will be replaced in Step 4)
curl -I http://localhost
# → HTTP/1.1 200 OK
```

---

## Step 2 — TLS Certificate

### What was done

Certificate provisioning differs by environment. Run only the block that
matches your deployment target.

**VM (local) — Self-signed certificate**

A self-signed certificate valid for 397 days is generated directly on the
server. The 397-day limit is the maximum accepted by modern browsers before
they flag the certificate regardless of the trust anchor.

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 397 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/nginx-selfsigned.key \
  -out /etc/nginx/ssl/nginx-selfsigned.crt \
  -subj "/CN=multi-lab-local/O=multi-lab/C=ES"

sudo chmod 600 /etc/nginx/ssl/nginx-selfsigned.key
sudo chmod 644 /etc/nginx/ssl/nginx-selfsigned.crt
```

**EC2 — Let's Encrypt via Certbot**

Certbot requires a domain name pointing to the instance public IP. With an
Elastic IP assigned, the domain mapping is stable and auto-renewal works
without intervention. Replace `buildyourinfra.click` with the actual domain or
`sslip.io` alias (e.g. `1-2-3-4.sslip.io`).

```bash
sudo apt install certbot python3-certbot-nginx -y

# Issue certificate — Certbot modifies the Nginx config automatically
sudo certbot --nginx -d buildyourinfra.click

# Verify auto-renewal timer
sudo systemctl status certbot.timer
# → active (waiting)

# Dry-run renewal test
sudo certbot renew --dry-run
```

> **EC2 prerequisite:** port 80 and 443 must be open in **both** UFW (done in
> Step 1) and the EC2 **Security Group** before running `certbot`. The ACME
> HTTP-01 challenge originates from Let's Encrypt infrastructure — it is not
> inside the WireGuard perimeter and will never reach the instance if the
> Security Group blocks inbound TCP/80 from `0.0.0.0/0`.
>
> In `multi-lab-sg` → Inbound rules, verify these two rules exist before
> proceeding:
>
> | Type  | Protocol | Port | Source    |
> |-------|----------|------|-----------|
> | HTTP  | TCP      | 80   | 0.0.0.0/0 |
> | HTTPS | TCP      | 443  | 0.0.0.0/0 |
>
> The ACME challenge fails with `Timeout during connect` if either layer
> is missing — UFW alone is not sufficient.

### Why

Self-signed certificates are sufficient for a LAN-only VM where the operator
controls the trust anchor — there is no public CA validation path. For the
EC2 instance, a publicly trusted certificate is mandatory: without it,
browsers reject the connection and tools like `curl` require `-k` to proceed,
which defeats the purpose of HTTPS in a production-equivalent lab. Let's
Encrypt provides a free, automated, 90-day renewable certificate that removes
this friction entirely.

### Verification

**VM:**
```bash
ls -la /etc/nginx/ssl/
# → nginx-selfsigned.crt  (644)
# → nginx-selfsigned.key  (600)

openssl x509 -in /etc/nginx/ssl/nginx-selfsigned.crt -noout -subject -dates
# → subject=CN=multi-lab-local, O=multi-lab, C=ES
# → notAfter=<date ~397 days from now>
```

**EC2:**
```bash
sudo certbot certificates
# → Certificate Name: buildyourinfra.click
# → Expiry Date: <date> (VALID: xx days)
# → Certificate Path: /etc/letsencrypt/live/buildyourinfra.click/fullchain.pem

sudo systemctl is-active certbot.timer
# → active
```

---

## Step 3 — Nginx HTTPS Virtual Host

### What was done

The default Nginx site is disabled and replaced with a dedicated virtual host
configuration. The config file is deployed as a full-file replace into
`/etc/nginx/sites-available/` and then symlinked into `sites-enabled/`.
Two variants exist in `configs/` — deploy the one that matches the environment.

```bash
# Disable the default site
sudo rm -f /etc/nginx/sites-enabled/default

# VM — self-signed variant
sudo cp ~/build-your-infra/modules/web-server/self-managed/configs/nginx/multi-lab-vm.conf \
  /etc/nginx/sites-available/multi-lab.conf

# EC2 — Let's Encrypt variant (replace buildyourinfra.click inline before deploying)
sudo cp ~/build-your-infra/modules/web-server/self-managed/configs/nginx/multi-lab-ec2.conf \
  /etc/nginx/sites-available/multi-lab.conf

# Enable the site
sudo ln -s /etc/nginx/sites-available/multi-lab.conf /etc/nginx/sites-enabled/multi-lab.conf

sudo nginx -t
# nginx: configuration file /etc/nginx/nginx.conf test is successful

sudo systemctl reload nginx
```

📄 [`configs/nginx/multi-lab-vm.conf`](configs/nginx/multi-lab-vm.conf) — replace `/etc/nginx/sites-available/multi-lab.conf` (VM)

📄 [`configs/nginx/multi-lab-ec2.conf`](configs/nginx/multi-lab-ec2.conf) — replace `/etc/nginx/sites-available/multi-lab.conf` (EC2)

**Deploy the lab index page**

```bash
sudo cp ~/build-your-infra/modules/web-server/html/index.html /var/www/html/index.html

sudo chmod 644 /var/www/html/index.html
```

📄 [`html/index.html`](../html/index.html) — replace `/var/www/html/index.html`

### Why

Disabling the default site removes the Nginx version disclosure page and
ensures only the explicitly configured virtual host responds. Using
`sites-available/` + symlink into `sites-enabled/` follows the Nginx Debian
convention — it allows toggling a site without deleting the config. A single
named config per server makes it immediately clear what is active.

### Verification

```bash
# Config syntax — must return no errors
sudo nginx -t
# → nginx: configuration file /etc/nginx/nginx.conf test is successful

ls -la /etc/nginx/sites-enabled/
# → multi-lab.conf -> /etc/nginx/sites-available/multi-lab.conf
# → (no default)

# HTTPS response — VM (expect SSL warning, self-signed)
curl -k -I https://localhost
# → HTTP/1.1 502 Bad Gateway  (expected — no upstream running yet)

# HTTPS response — EC2 (valid cert, no -k needed)
curl -I https://buildyourinfra.click
# → HTTP/1.1 502 Bad Gateway  (expected — no upstream running yet)

# Browser test — navigate to the server IP or domain
# VM:  https://<VM-IP>  → browser shows SSL warning (self-signed) — accept and proceed
# EC2: https://your.domain  → loads directly, no warning (Let's Encrypt)
```

---

## Step 4 — HTTP → HTTPS Redirect

### What was done

The virtual host configuration deployed in Step 3 already includes the
redirect block — this step verifies it is active and behaving correctly.
No additional config is deployed here.

> This step is a verification-only step. If Step 3 was applied correctly,
> HTTP requests are already being redirected to HTTPS with a 301.

### Why

A permanent 301 redirect ensures that any bookmark, crawler, or script that
reaches port 80 is immediately upgraded to HTTPS without user interaction.
This eliminates mixed-content scenarios and prevents accidental plaintext
exposure of request paths or cookies.

### Verification

```bash
# HTTP request must return 301 Moved Permanently pointing to HTTPS
curl -I http://localhost
# → HTTP/1.1 301 Moved Permanently
# → Location: https://localhost/

# Follow redirect — lands on HTTPS, 502 expected until upstream is running
curl -Lk -I http://localhost
# → HTTP/2 502
```

---

## Step 5 — auditd: Web Server Activity Rule

### What was done

A dedicated audit rule monitors write and attribute-change operations on
the Nginx configuration directory and the TLS certificate paths. The rule
is appended to the existing hardening ruleset and reloaded.

```bash
sudo tee -a /etc/audit/rules.d/99-hardening.rules \
  < ~/build-your-infra/modules/web-server/self-managed/configs/audit/99-hardening.rules

sudo systemctl restart auditd
sudo augenrules --load
sudo reboot now
```

> **Immutable mode:** if auditd is running with `-e 2`, restart it before
> reloading the ruleset — the reboot at the end of this step handles this.

📄 [`configs/audit/99-hardening.rules`](configs/audit/99-hardening.rules) — append to `/etc/audit/rules.d/99-hardening.rules`

### Why

The Nginx config directory and the TLS key path are high-value targets: a
modification to either can redirect traffic, strip TLS, or expose private key
material. Monitoring them with auditd ensures any change — whether automated
(Certbot renewal) or unauthorized — generates an auditable event traceable
to a UID and process. The `nginx_config` key allows filtering these events
independently from the rest of the audit log.

### Verification

```bash
sudo auditctl -l | grep nginx_config
# → -w /etc/nginx/ -p wa -k nginx_config
# → -w /etc/nginx/ssl/ -p wa -k nginx_config

# Trigger a test event
sudo touch /etc/nginx/audit_test && sudo rm /etc/nginx/audit_test
sudo ausearch -k nginx_config | tail -5
# → type=PATH ... name="audit_test" ... key="nginx_config"
```

---

## Step 6 — AIDE: Extend Baseline

### What was done

The Nginx configuration directory and TLS certificate paths are added to the
AIDE monitoring scope. The AIDE database is regenerated to include the new
paths as the trusted baseline.

```bash
sudo tee -a /etc/aide/aide.conf.d/99-hardening \
  < ~/build-your-infra/modules/web-server/self-managed/configs/aide/99-hardening

sudo aide --init --config /etc/aide/aide.conf
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

> **Baseline regeneration:** after extending the AIDE scope, regenerate the
> database so the current Nginx and certificate state becomes the new trusted
> baseline. Running `aide --check` before regeneration will report differences
> — this is expected and not an error.

📄 [`configs/aide/99-hardening`](configs/aide/99-hardening) — append to `/etc/aide/aide.conf.d/99-hardening`

### Why

Nginx configuration files and TLS private keys are integrity-critical: an
undetected modification could silently redirect traffic or expose credentials.
AIDE detects file content, permission, and ownership changes between baseline
snapshots. Monitoring these paths complements the auditd real-time alerting added in Step 5 — auditd tells you when a change happened, AIDE confirms what
changed and whether the filesystem state matches the known-good baseline.

### Verification

```bash
# Confirm paths are in scope
grep -E "nginx|ssl" /etc/aide/aide.conf.d/99-hardening

sudo aide --check --config /etc/aide/aide.conf
# → AIDE found no differences between database and filesystem.
```

---

## Reverse Proxy

TLS terminates at Nginx. The upstream service communicates with Nginx over
localhost in plaintext — no certificate required on the backend. The
forwarding headers (`X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`) give
the upstream service accurate client information. `Host` passthrough preserves
virtual hosting compatibility if the upstream is itself a multi-tenant service.

The `proxy_pass` block is already active in the virtual host deployed in
Step 3. Requests return `502 Bad Gateway` until an upstream service is
listening on the configured port — this is expected behavior, not a
configuration error.

### Verification

```bash
sudo nginx -T | grep proxy_pass
# → proxy_pass http://127.0.0.1:<upstream_port>/;

# Once upstream is running
curl -Lk https://localhost
# → <response from upstream service>
```

---

## Snapshot

Nginx HTTPS and reverse proxy are deployed on top of the hardened OS baseline.
Take a snapshot before proceeding to the next module — this preserves the
verified state: hardened OS + SFTP + web server, no additional services.

---