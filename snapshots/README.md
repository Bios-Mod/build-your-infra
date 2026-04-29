# Snapshots

VM snapshots are taken before each major service deployment to allow
safe rollback during testing. All snapshots are managed in VMware Fusion
on the Apple Silicon host.

---

## Snapshot Log

| # | Name | Taken after | State |
|---|------|-------------|-------|
| 1 | `ubuntu-base-install` | Fresh OS installation — no configuration applied | ✅ Retained |
| 2 | `complete-hardening` | Full OS hardening completed — CIS Level 1 baseline. See [`docs/01-os-hardening.md`](../docs/01-os-hardening.md). This snapshot is the base restore point for all service deployments. | ✅ Retained |

---

## Policy

- A snapshot is taken **before** deploying each new service
- Snapshots are named to reflect the exact state of the server at that point
- Outdated snapshots are deleted once the subsequent service is confirmed stable
- The `complete-hardening` snapshot is the **permanent base restore point** — it is never deleted

> **Lab context:** Snapshots represent the state of this specific lab build on
> Ubuntu Server 24.04 LTS. They are restore points for iterative service deployment,
> not guaranteed-reproducible artifacts — exact service counts, AppArmor profile
> coverage and package versions reflect the state of the system at snapshot time.
> **VPS users:** VM snapshots map to provider-level instance snapshots or volume
> backups — AWS AMI, Hetzner Snapshot, DigitalOcean Droplet Snapshot, etc. The
> policy and naming convention above apply regardless of the mechanism. Create a
> snapshot equivalent before each major service deployment.