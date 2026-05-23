# Multi-Lab Server — DNS (BIND9)

**Ubuntu 24.04 LTS · VM / Bare metal / VPS**

---

## Introduction
This document covers the deployment of BIND9 on top of the hardened OS
baseline established in [`docs/01-os-hardening.md`](01-os-hardening.md).

DNS is the first core infrastructure service in the lab and becomes a
dependency for later modules such as HTTPS and Samba 4.

---

## Scope

This module will cover:

- BIND9 installation
- Forward and reverse zones
- ACLs and recursion policy
- Service exposure and validation
- Notes for future Samba 4 integration

---

## Status

**Status:** Planned

This document will be completed after the service is deployed and validated
on the `complete-hardening` baseline snapshot.

---