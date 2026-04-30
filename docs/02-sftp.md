# Multi-Lab Server — SFTP

**Ubuntu 24.04 LTS · VM / Bare metal / VPS**

---

## Introduction
This document covers the SFTP deployment phase on top of the hardened OS
baseline established in [`docs/01-os-hardening.md`](01-os-hardening.md).

SFTP in this lab will be implemented through the OpenSSH subsystem already
present on the server, keeping the design simple and aligned with the
existing SSH hardening model.

---

## Scope

This module will cover:

- SFTP subsystem validation
- Transfer-only access model
- Optional chroot design
- Permissions and ownership
- Verification and rollback notes

---

## Status

**Status:** Planned

This document will be completed after the service is deployed and validated
on the `complete-hardening` baseline snapshot.

---