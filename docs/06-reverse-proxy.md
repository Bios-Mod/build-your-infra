# Multi-Lab Server — Reverse Proxy

**Ubuntu 24.04 LTS · VM / Bare metal / VPS**

---

## Introduction
This document covers the reverse proxy layer built on top of the hardened
OS baseline established in [`docs/01-os-hardening.md`](01-os-hardening.md)
and the Nginx HTTPS baseline defined in
[`docs/05-nginx-https.md`](05-nginx-https.md).

This phase extends the web layer from single-service publication to
centralized routing through Nginx.

---

## Scope

This module will cover:

- `proxy_pass` design
- Upstream service exposure
- Header forwarding policy
- TLS termination model
- Verification and troubleshooting

---

## Status

**Status:** Planned

This document will be completed after the service is deployed and validated
on the `complete-hardening` baseline snapshot.

---