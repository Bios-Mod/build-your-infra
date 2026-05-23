# AWS Native — Base Setup

Prerequisites for all `modules/*/aws-native/` deployments.
Complete this guide once before applying any aws-native module.

---

## Environment

| Parameter  | Value                     |
|------------|---------------------------|
| Provider   | AWS                       |
| Region     | Your choice (see note)    |
| Account    | Single account · IAM user |

> **Region choice:** this lab uses `eu-west-1` (Europe — Ireland) as reference,
> chosen for low latency from Spain and Free Tier availability. Any region
> with Free Tier support works — pick the one closest to you.
> All service names, console paths, and CLI commands are region-agnostic
> except where explicitly noted.

---

## Step 1 — Billing alerts

Before provisioning any resource:

1. **Free Tier alert:** AWS Billing → Billing Preferences → Alert Preferences → enable Free Tier usage alerts.
2. **Zero-spend budget:** Billing → Budgets → Create budget → use the "Zero spend budget" template.

An unattended resource accrues cost silently without these alerts.

---

## Step 2 — IAM base

AWS root account credentials must not be used for day-to-day operations.

**Create an IAM admin user:**
1. IAM → Users → Create user.
2. Attach policy: `AdministratorAccess` (scoped down per service in each module).
3. Enable MFA on both the root account and this IAM user.
4. Generate access keys only if AWS CLI is needed — treat them as credentials.

**Enable MFA on root:**
IAM → Dashboard → Security recommendations → Add MFA for root.

> **IAM Identity Center (SSO)** is the recommended approach for multi-account
> organizations. For this single-account lab, an IAM user with MFA is sufficient
> and avoids the added complexity of SSO configuration.

---

## Step 3 — Custom VPC

Do not use the default VPC for this lab. A custom VPC makes network
boundaries explicit and mirrors real-world deployments.

**VPC → Create VPC → VPC and more**

| Parameter         | Value                    |
|-------------------|--------------------------|
| Name              | `multi-lab-vpc`          |
| IPv4 CIDR         | `10.0.0.0/16`            |
| Availability zones | 1                       |
| Public subnets    | 1 (`10.0.1.0/24`)        |
| Private subnets   | 1 (`10.0.2.0/24`)        |
| NAT Gateway       | None (not needed for lab)|
| DNS hostnames     | Enabled                  |

This creates the VPC, subnets, Internet Gateway, and route tables automatically.

> Modules that require internet-facing resources use the public subnet.
> Modules that do not (e.g. Directory Service, private DNS) use the private subnet.

---

## Step 4 — Base security services

Enable once at the account level. These run passively and incur minimal cost
within Free Tier limits.

**CloudTrail:**
CloudTrail → Create trail → apply to all regions → S3 bucket: `multi-lab-cloudtrail-<account-id>`.
Logs every API call in the account — the equivalent of `auditd` at the cloud layer.

**AWS Config:**
Config → Get started → record all resources → same S3 bucket or a new one.
Tracks resource configuration history and detects drift.

**GuardDuty:**
GuardDuty → Get started → Enable GuardDuty.
Threat detection based on VPC Flow Logs, DNS logs, and CloudTrail events.
30-day free trial on first enable per account.

> These three services are the aws-native equivalent of the self-managed
> hardening baseline. Each aws-native module builds on top of this foundation.

---

## Post-Setup Checklist

- [ ] Free Tier alert and zero-spend budget active
- [ ] IAM admin user created with MFA enabled
- [ ] MFA enabled on root account
- [ ] Custom VPC `multi-lab-vpc` created — subnets, IGW, and route tables confirmed
- [ ] CloudTrail enabled — trail active across all regions
- [ ] AWS Config enabled — recording all resources
- [ ] GuardDuty enabled

**Next:** [`modules/hardening/aws-native/aws-native.md`](../../modules/hardening/aws-native/aws-native.md) — apply aws-native hardening baseline.