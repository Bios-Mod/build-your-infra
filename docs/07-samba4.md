# Multi-Lab Server — Samba 4 AD DC

**Ubuntu 24.04 LTS · VM / Bare metal / VPS**

---

## Introduction
This document covers the deployment of Samba 4 as an Active Directory
Domain Controller on top of the hardened OS baseline established in
[`docs/01-os-hardening.md`](01-os-hardening.md).

This is the most complex service module in the lab and depends on stable
networking, naming and prior DNS design decisions.

---

## Scope

This module will cover:

- Samba 4 AD DC provisioning
- Domain naming decisions
- DNS interaction model
- Administrative validation
- Rollback and verification notes

---

## Status

**Status:** Planned

This document will be completed after the service is deployed and validated
on the `complete-hardening` baseline snapshot.

---