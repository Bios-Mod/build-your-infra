# Snapshots

Point-in-time restore points taken before each major service deployment.
Named to reflect the exact server state at capture time.

---

## VM Snapshots — VMware Fusion (Apple Silicon)

| # | Name | Taken after | State |
|---|------|-------------|-------|
| 1 | `ubuntu-base-install` | Fresh OS installation — no configuration applied | Retained |
| 2 | `complete-hardening` | Full OS hardening completed — CIS Level 1 baseline (Lynis 88). See [`docs/01-os-hardening.md`](../docs/01-os-hardening.md). Permanent base restore point for all service deployments. | Retained |

---

## AWS AMI Snapshots — EC2 (eu-west-1)

In AWS, instance snapshots are created as **AMIs** (Amazon Machine Images).
An AMI is a bootable image of the instance at a specific point in time,
backed by an **EBS snapshot** of the root volume. It serves the same role
as a VM snapshot: a rollback point before major changes.

### How AMIs and EBS Snapshots relate

Creating an AMI from a running or stopped instance automatically creates
an EBS snapshot of every attached volume. The AMI is the launchable image
(metadata + block device mapping); the EBS snapshot is the actual data on
disk. Both must be explicitly deleted when no longer needed — deregistering
an AMI does **not** delete its underlying snapshot.

**To create an AMI:**
EC2 → Instances → `multi-lab-aws` → Actions → Image and templates → Create image.
Stop the instance first for a consistent, filesystem-coherent image.

**To delete an AMI and free storage:**
1. EC2 → AMIs → select AMI → Actions → Deregister AMI
2. EC2 → Snapshots → select the associated snapshot → Actions → Delete snapshot

EBS snapshots are **incremental**: the first snapshot copies all used blocks;
subsequent snapshots store only blocks that changed since the previous one.
A 20 GiB volume with ~4 GiB of actual data compresses and deduplicates
significantly — real storage billed is typically well under the volume size.

### Cost

EBS snapshot storage is billed at ~$0.05/GB-month (eu-west-1) on the
actual compressed, deduplicated size — not the volume size. This is outside
the EC2 Free Tier. With 2–3 active snapshots of this lab, expect ~$0.20–0.40/month.

**Policy:** keep only `base-install` and the most recent stable state.
Delete intermediate snapshots once the subsequent step is confirmed stable.

### Snapshot log

| # | AMI Name | Taken after | State |
|---|----------|-------------|-------|
| 1 | `multi-lab-aws-base-install` | Fresh Ubuntu 24.04 ARM64 — first `apt upgrade` only | Retained |
| 2 | `multi-lab-aws-complete-hardening` | Full OS hardening completed — CIS Level 1 baseline confirmed (Lynis 90). Taken immediately before SFTP deployment (Step 02). Permanent base restore point. | Retained |

---

## Policy

- A snapshot is taken **before** deploying each new service
- Named to reflect the exact state of the server at that point
- Outdated snapshots are deleted once the subsequent service is confirmed stable
- The `complete-hardening` snapshot/AMI is the **permanent base restore point** — never deleted