# Role: web-server

This role automates the deployment of an Nginx HTTPS web server with reverse proxy routing on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the security controls documented in [`modules/web-server/self-managed/web-server-self-managed.md`](../../../../../../../modules/web-server/self-managed/web-server-self-managed.md).

---

## Target Environments & Prerequisites

- **Targets:**
  - `vm` (`multi-lab-local`): Local VMware / VirtualBox environment utilizing a self-signed TLS certificate valid for 397 days.
  - `ec2` (`multi-lab-vps`): AWS EC2 self-managed instance utilizing a publicly trusted Let's Encrypt certificate obtained via Certbot.
- **Prerequisites:**
  - The `hardening` role must be fully deployed before applying `web-server`. Pre-flight assertions verify that OpenSSH listens on the hardened port (`22222`).
  - For EC2 Let's Encrypt TLS, the public Route 53 hosted zone and registrar nameserver delegation are a one-time setup performed beforehand. The DNS A record pointing to the Elastic IP is provisioned via Terraform (`route53_zone_name`).

---

## Role Variables & Inputs

### Mandatory Inventory Variables

Defined in `inventories/host_vars/multi-lab-local.yml` and `multi-lab-vps.yml`:

| Variable | Scope | Description |
|---|---|---|
| `tls_mode` | Mandatory (both) | Certificate strategy: `self_signed` (VM) or `letsencrypt` (EC2). |
| `web_server_upstream_port` | Mandatory (both) | Local TCP port of internal service proxied by Nginx (e.g. `8080`). |
| `web_server_domain` | Mandatory (`letsencrypt`) | Fully qualified domain name pointing to EC2 Elastic IP (e.g. `buildyourinfra.click`). |
| `web_server_certbot_email` | Mandatory (`letsencrypt`) | Administrative email for Let's Encrypt certificate registration and renewal notices. |
| `web_server_certbot_staging` | Mandatory (`letsencrypt`) | Boolean flag: `true` for Let's Encrypt staging environment, `false` for production issuance. |
| `web_server_auditd_reboot` | Mandatory (when immutable) | Boolean flag: controls whether to reboot the host when audit rules change in immutable mode (`-e 2`). |

### Role Defaults (`defaults/main.yml`)

| Variable | Default Value | Purpose |
|---|---|---|
| `web_server_configs_dir` | `{{ configs_root }}/web-server/self-managed/configs` | Path to static web-server source configuration files. |
| `web_server_html_src` | `{{ configs_root }}/web-server/html/index.html` | Path to static index page deployed to document root. |
| `hardening_ssh_port` | `{{ ssh_hardened_port \| default(22222) }}` | Hardened OpenSSH listening port verified in pre-flight assertions. |
| `web_server_verify_renewal` | `false` | Opt-in boolean flag enabling live Certbot renewal dry-run test in verify tasks. |

---

## Tasks & Tags

Execution can be targeted via Ansible tags:

| Tag | Scope | Description |
|---|---|---|
| `web-server` | Complete Role | Executes pre-flight assertions, Nginx installation, TLS provisioning, virtual host deployment, UFW configuration, AIDE drop-in, auditd drop-in, handler flush, and verification tasks. |
| `web-server_verify` | Verification Only | Executes only the assertions defined in `tasks/verify.yml` (service active, UFW rules, certificate files and subject/lineage, configuration syntax test, proxy_pass port, loopback 301 redirect, loopback HTTPS 502/200, auditd loaded rules, and AIDE drop-in validation). |

---

## Shared Files Notice

- **/etc/ufw/user.rules:** Managed via `community.general.ufw` module. Adds rule for profile `Nginx Full` (allowing inbound TCP ports 80 and 443) without modifying existing hardening rules.
- **/etc/nginx/sites-enabled/default:** Removed to prevent default welcome page exposure and information disclosure.
- **/etc/nginx/sites-available/multi-lab.conf:** Deployed as the primary virtual host configuration and symlinked into `/etc/nginx/sites-enabled/multi-lab.conf`.
- **/etc/aide/aide.conf.d/:** Hardening deploys `/etc/aide/aide.conf.d/99-hardening`. The `web-server` role deploys an independent drop-in at `/etc/aide/aide.conf.d/99-zz-web-server` (ordered after `99-hardening`, which defines the `CONTENTEX` group) covering `/etc/nginx` and `/etc/nginx/ssl`. Configuration syntax is verified with `aide --config-check` before flushing handlers to regenerate the baseline database.
- **/etc/audit/rules.d/:** Deploys an independent drop-in at `/etc/audit/rules.d/99-zz-web-server.rules` (ordered after `99-hardening.rules`) with non-ASCII comments stripped to monitor `/etc/nginx` and `/etc/nginx/ssl`. Rules are loaded via `augenrules --load` or controlled reboot if the kernel runs in immutable mode (`-e 2`).

---

## Non-Automated Procedures & Accepted Deviations

1. **DNS Zone and Nameservers Setup:** The Route 53 public hosted zone and registrar nameserver delegation are a one-time prerequisite configured outside Ansible. The A record pointing to the Elastic IP is automated via Terraform.
2. **Certbot Authenticator (`certonly --nginx`):** Certbot is invoked with `certonly --nginx` rather than `--nginx` installer mode. This allows Ansible to maintain declarative source-of-truth ownership over `/etc/nginx/sites-available/multi-lab.conf` without Certbot rewriting configuration files dynamically.
3. **Upstream Reverse Proxy Target:** No backend service is provisioned in this module. Requests to the reverse proxy endpoint return `502 Bad Gateway`, which is verified and documented as expected behavior until backend services are deployed.
