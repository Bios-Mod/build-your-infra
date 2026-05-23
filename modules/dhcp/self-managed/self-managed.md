# Multi-Lab Server — DHCP

**Ubuntu 24.04 LTS · VM / Bare metal**

---

> **Deployment scope:** This service runs exclusively on the local VM deployment
> (VMware Fusion). DHCP has no use case in a cloud environment — AWS manages
> address assignment at the VPC layer. This module does not apply to the
> EC2 deployment.

## Introduction
This document covers the DHCP deployment phase on top of the hardened OS
baseline established in [`docs/01-os-hardening.md`](01-os-hardening.md).

This service is intentionally planned after DNS so that address assignment,
naming and lease design follow an already defined network model.

---

## Scope

This module will cover:

- DHCP service deployment
- Scope and lease policy
- Reservations
- DNS interaction
- Verification and rollback notes

---

## Status

**Status:** Planned

This document will be completed after the service is deployed and validated
on the `complete-hardening` baseline snapshot.

---