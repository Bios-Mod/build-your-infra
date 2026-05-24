# AWS Native — Base Setup

Prerequisites for all `modules/*/aws-native/` deployments.
Complete this guide once before applying any aws-native module.

---

## Environment

| Parameter          | Value                     |
|--------------------|---------------------------|
| Provider           | AWS                       |
| Region             | Your choice (see note)    |
| Account            | Single account · IAM user |

> **Region choice:** this lab uses `eu-west-1` (Europe — Ireland) as reference,
> chosen for low latency from Spain and Free Tier availability. Any region
> with Free Tier support works — pick the one closest to you.
> All service names, console paths, and CLI commands are region-agnostic
> except where explicitly noted.

---

## Step 1 — Billing alerts

### What was done
Enabled Free Tier usage alerts and created a zero-spend budget that triggers
an email notification on any billable charge.

**Console**

Before provisioning any resource:

1. **Free Tier alert:** Billing and Cost Management → Billing Preferences → Alert Preferences → enable *Free Tier usage alerts*.
2. **Zero-spend budget:** Billing and Cost Management → Budgets → Create budget → select *Zero spend budget* template → confirm.

### Why
An unattended resource accrues cost silently. These two controls are the
minimum safety net before provisioning anything — the zero-spend budget fires
on the first cent charged, regardless of cause.

### Verification
Billing and Cost Management → Budgets — confirm budget status shows *OK* and
alert email address is correct.

---

## Step 2 — IAM base

### What was done
- MFA enabled on root account.
- IAM admin user `multi-lab-admin` created with `AdministratorAccess` and MFA.
- Named AWS CLI profile `multi-lab` configured with access keys for this user.

**Console**

AWS root account credentials must not be used for day-to-day operations.

**Enable MFA on root:**
IAM → Dashboard → Security recommendations → Add MFA for root → follow the wizard.

**Create an IAM admin user:**
1. IAM → Users → Create user.
2. Username: `multi-lab-admin`.
3. Attach policy directly: `AdministratorAccess`.
4. Enable MFA on this user: IAM → Users → `multi-lab-admin` → Security credentials → Assign MFA device.

> `AdministratorAccess` is used here for the lab operator account only.
> Service-level permissions are scoped down via IAM roles attached to each
> AWS service (e.g., the role Transfer Family uses to write to S3, or the
> instance profile SSM uses). Those roles are defined in each module, not here.

**AWS CLI setup (if using CLI or Terraform):**

**CLI**

```bash
aws configure --profile multi-lab
# AWS Access Key ID:     <key generated in IAM → Users → multi-lab-admin → Security credentials>
# AWS Secret Access Key: <secret>
# Default region name:   eu-west-1
# Default output format: json
```

> Never hardcode credentials in scripts or config files. Use the named profile
> (`--profile multi-lab`) for all CLI and Terraform operations. Add
> `~/.aws/credentials` to `.gitignore` if the home directory is under version
> control. Access keys for automation tasks (Terraform, Ansible) must use
> dedicated IAM roles with scoped policies — defined in the automation phase.

### Why
Root credentials cannot be scoped, audited per-action, or rotated safely —
any compromise is a full account compromise. The IAM user with MFA provides
an auditable identity for all operations. `AdministratorAccess` is intentional
at this stage: the lab operator needs unrestricted access to deploy each module.
Scoped-down permissions apply to **service roles** (what AWS services can do),
not to the operator account. The named CLI profile prevents accidental
operations against unintended accounts when multiple AWS profiles coexist.

### Verification

**Console**
IAM → Users → `multi-lab-admin` → Security credentials — confirm MFA device assigned and access key active.

**CLI**
```bash
aws sts get-caller-identity --profile multi-lab
# → "UserId": "...", "Account": "<account-id>", "Arn": "arn:aws:iam::<account-id>:user/multi-lab-admin"
```

---

## Step 3 — Delete default VPC

### What was done
Deleted the default VPC in the working region (`eu-west-1`) and any additional
region that will be used in this lab.

**Console**

> Perform this step before creating the custom VPC.

1. VPC → Your VPCs → filter by *default VPC*.
2. Note: repeat for every region you plan to use. The default VPC exists in all regions.
3. Select default VPC → Actions → Delete VPC → confirm.

### Why
The default VPC has permissive settings by design (public subnets, all traffic
allowed by default Security Group). Leaving it active creates an accidental
deployment surface — a misconfigured service or a console click in the wrong
subnet could expose resources unintentionally. Deleting it forces all
deployments into the explicitly configured `multi-lab-vpc`, where every
network decision is deliberate. This mirrors production hygiene where default
VPCs are removed as a baseline control.

### Verification

**Console**
VPC → Your VPCs — confirm no VPC with *Default: Yes* exists in the working region.

---

## Step 4 — Custom VPC

### What was done
Created custom VPC `multi-lab-vpc` with one public and one private subnet,
Internet Gateway, and route tables. Both `DNS hostnames` and `DNS resolution`
explicitly enabled.

**Console**

VPC → Create VPC → select *VPC and more*.

| Parameter           | Value              |
|---------------------|--------------------|
| Name                | `multi-lab-vpc`    |
| IPv4 CIDR           | `10.0.0.0/16`      |
| Availability zones  | 1                  |
| Public subnets      | 1 (`10.0.1.0/24`)  |
| Private subnets     | 1 (`10.0.2.0/24`)  |
| NAT Gateway         | None               |
| DNS hostnames       | Enabled            |
| DNS resolution      | Enabled            |

> **Single AZ:** sufficient for lab purposes. Multi-AZ adds redundancy cost
> (second NAT Gateway, cross-AZ data transfer) without adding learning value
> at this stage.

> The wizard creates the VPC, subnets, Internet Gateway, and route tables
> automatically. DNS resolution (enableDnsSupport) is required for Route 53
> Private Hosted Zones and SSM Session Manager — confirm it is enabled after
> creation.

Modules that require internet-facing resources use the public subnet (`10.0.1.0/24`).
Modules that do not (e.g. Directory Service, private DNS) use the private subnet (`10.0.2.0/24`).

### Why
The default VPC (now deleted) had no explicit network boundaries. A custom VPC
makes every routing decision intentional and mirrors real-world deployments
where network segmentation is a baseline requirement. `DNS hostnames` assigns
resolvable names to instances with public IPs. `DNS resolution` enables the
AWS internal resolver (169.254.169.253) — without it, Route 53 Private Hosted
Zones and SSM Session Manager will fail to resolve endpoints inside the VPC.
No NAT Gateway is provisioned: private subnet resources that need outbound
internet access will use VPC endpoints (defined per module) — cheaper and
more secure than a NAT Gateway for this use case.

### Verification

**Console**
VPC → Your VPCs → `multi-lab-vpc`:
- State: *Available*
- DNS hostnames: *Enabled*
- DNS resolution: *Enabled*

VPC → Subnets — confirm `10.0.1.0/24` (public) and `10.0.2.0/24` (private) exist and are associated to `multi-lab-vpc`.

**CLI**
```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=multi-lab-vpc" \
  --query "Vpcs.{ID:VpcId,DNS_Hostnames:EnableDnsHostnames,DNS_Resolution:EnableDnsSupport,CIDR:CidrBlock}" \
  --profile multi-lab
# → DNS_Hostnames: true, DNS_Resolution: true, CIDR: "10.0.0.0/16"
```

---

## Step 5 — Base audit services

### What was done
- CloudTrail trail `multi-lab-trail` enabled across all regions, logging to S3.
- AWS Config enabled, recording all resources including global (IAM).
- GuardDuty enabled.

**Console**

Enable once at the account level. These run passively and incur minimal or no
cost within Free Tier limits.

**CloudTrail:**
CloudTrail → Create trail:
- Trail name: `multi-lab-trail`
- Apply to all regions: **Yes** — captures global service events (IAM, STS, Route 53).
- S3 bucket: create new → `multi-lab-cloudtrail-<account-id>`
- Log file SSE-KMS encryption: optional at this stage, applied in the hardening module.
- Enable for all accounts in organization: N/A (single account).

**AWS Config:**
Config → Get started:
- Record all resources supported in this region: **Yes**
- Include global resources (IAM): **Yes**
- S3 bucket: `multi-lab-cloudtrail-<account-id>` (reuse) or create a dedicated bucket.
- Delivery frequency: 24 hours (default).

**GuardDuty:**
GuardDuty → Get started → Enable GuardDuty.

> GuardDuty has a 30-day free trial on first enable per account. After the
> trial, cost is based on the volume of CloudTrail events, VPC Flow Logs, and
> DNS logs analyzed. For a lab with minimal activity, cost is negligible.
> VPC Flow Logs activation and GuardDuty data source configuration are covered
> in [`modules/hardening/aws-native/aws-native.md`](../../modules/hardening/aws-native/aws-native.md).

### Why
These three services form the passive observability baseline — they require no
ongoing configuration and begin collecting data immediately. CloudTrail is the
API-level audit log (equivalent to `auditd` at the OS layer): every Create,
Delete, and Modify call against any AWS service is recorded. AWS Config tracks
resource state over time and detects configuration drift against defined rules.
GuardDuty performs ML-based threat detection over CloudTrail, DNS, and (once
enabled) VPC Flow Logs. Enabling them at setup ensures no events are missed
from the first provisioning action. **CloudTrail is applied to all regions**
to capture IAM and STS events, which are global — a single-region trail misses
them. S3 bucket hardening (Block Public Access, MFA Delete, KMS encryption) is
applied in the hardening module.

### Verification

**Console**
- CloudTrail → Trails → `multi-lab-trail` — Status: *Logging*.
- Config → Settings — Recording: *On*, global resources included.
- GuardDuty → Summary — Status: *Enabled*.

**CLI**
```bash
aws cloudtrail get-trail-status --name multi-lab-trail --profile multi-lab
# → "IsLogging": true

aws configservice describe-configuration-recorders --profile multi-lab
# → "recordingGroup": { "allSupported": true, "includeGlobalResourceTypes": true }

aws guardduty list-detectors --profile multi-lab
# → "DetectorIds": ["<detector-id>"]
```

---

**Next:** [`modules/hardening/aws-native/aws-native.md`](../../modules/hardening/aws-native/aws-native.md)