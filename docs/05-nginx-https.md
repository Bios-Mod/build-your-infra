# Multi-Lab Server — Nginx + HTTPS

**Ubuntu 24.04 LTS · VM / Bare metal / VPS**

---

## Introduction
This document covers the deployment of Nginx with HTTPS on top of the
hardened OS baseline established in [`docs/01-os-hardening.md`](01-os-hardening.md).

This phase introduces the first web-facing service layer in the project and
builds directly on the DNS groundwork planned earlier in the lab.

---

## Scope

This module will cover:

- Nginx installation and virtual host structure
- HTTPS-only baseline (HTTP → HTTPS redirect)
- TLS certificate strategy per environment
- Verification and operational checks

---

## Certificate Strategy

TLS certificate type differs by deployment environment:

| Environment | Certificate type | Tool | Why |
|---|---|---|---|
| VM (local) | Self-signed | `openssl req -x509` | No public domain — LAN access only |
| EC2 (cloud) | CA-signed (Let's Encrypt) | Certbot | Public-facing — valid cert required for browser trust |

**EC2 prerequisite:** Let's Encrypt requires a domain name pointing to the
server's public IP. A registered domain or a free DNS service (e.g., `sslip.io`
— maps `1-2-3-4.sslip.io` to IP `1.2.3.4`) is sufficient.

With an Elastic IP assigned (see [`docs/00-aws-deployment.md`](00-aws-deployment.md)),
the domain mapping is stable and Certbot auto-renewal works without intervention.

> **This module will be completed after Step 03 (BIND9)** — the DNS baseline
> is deployed before the web layer. The EC2 path requires a domain mapping
> confirmed before Certbot can issue the certificate.

---

## Status

**Status:** Planned

This document will be completed after the service is deployed and validated
on the `complete-hardening` baseline snapshot.

---