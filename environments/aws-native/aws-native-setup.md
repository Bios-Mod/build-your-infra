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
- IAM admin user `multi-lab-admin` created with `AdministratorAccess`, console
  access, and MFA.
- Named AWS CLI profile `multi-lab` configured with access keys for this user.

**Console**

AWS root account credentials must not be used for day-to-day operations.

**Enable MFA on root:**
IAM → Dashboard → Security recommendations → Add MFA for root → follow the wizard.

**Create an IAM admin user:**
1. IAM → Users → Create user.
2. Username: `multi-lab-admin`.
3. Skip "Provide user access to the AWS Management Console" — console access
   is enabled separately after creation (see below).
4. Attach policy directly:
   - Policy name: `AdministratorAccess`
   - Type: AWS managed — job function
   - ARN: `arn:aws:iam::aws:policies/AdministratorAccess`

> When searching for the policy, several results appear with `AdministratorAccess`
> in the name (e.g. `AdministratorAccess-Amplify`). Select the one named
> `AdministratorAccess` exactly — type **AWS managed — job function**.
> AWS managed policies are maintained by AWS and scoped to a service or job
> function. Job function policies (like this one) are designed for human
> operators, not service roles.

> `AdministratorAccess` is used here for the lab operator account only.
> Service-level permissions are scoped down via IAM roles attached to each
> AWS service (e.g., the role Transfer Family uses to write to S3, or the
> instance profile SSM uses). Those roles are defined in each module, not here.

**Enable console access:**

Console access is not active by default when creating an IAM user — it must
be enabled explicitly after creation.

IAM → Users → `multi-lab-admin` → Security credentials →
Console sign-in → Enable console access → set a password → save it.

> This is the only time the password is shown. Store it in a password manager.

**Retrieve your Account ID:**

The console login for IAM users requires the 12-digit Account ID (or alias).

AWS Management Console → top-right account menu → Account ID (12 digits).

Optionally create a human-readable alias: IAM → Dashboard →
AWS Account → Create account alias (e.g. `multi-lab`).
The login URL becomes: `https://multi-lab.signin.aws.amazon.com/console`

**Enable MFA on `multi-lab-admin`:**
IAM → Users → `multi-lab-admin` → Security credentials → Assign MFA device →
follow the wizard. MFA is required as second factor after password on every
console login.

**Enable IAM access to Billing:**

By default, Billing and Cost Explorer are only accessible to the root account,
regardless of IAM permissions. This must be explicitly activated once from root.

> Do this while still logged in as root — it cannot be done from the IAM user.

Account menu (top-right) → Account → IAM user and role access to Billing
information → Edit → ✅ Activate IAM Access → Update.

Once activated, `multi-lab-admin` can access Billing, Cost Explorer, and usage
data with no additional policy changes — `AdministratorAccess` already covers it.

**Sign in as `multi-lab-admin`:**

Go to `https://<account-id-or-alias>.signin.aws.amazon.com/console` and
provide:
- Account ID or alias
- IAM username: `multi-lab-admin`
- Password (set above)
- MFA code (prompted after password)

> The console defaults to the last region used by root, which may differ from
> the lab region. After login, confirm the region selector (top-right) shows
> **EU (Ireland) eu-west-1**. All lab resources are scoped to this region —
> resources in other regions will not be visible.

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
Root credentials cannot be scoped or rotated safely — any compromise is a
full account compromise. The IAM user with MFA provides an auditable identity
for all operations. AWS separates console access (password) from programmatic
access (access keys) at creation time — both must be enabled explicitly.
`AdministratorAccess` is intentional for the operator account; scoped-down
permissions apply to service roles, defined per module. The named CLI profile
prevents accidental operations against unintended accounts. Billing requires
a separate one-time root activation — `AdministratorAccess` alone does not
grant it.

### Verification

**Console**
IAM → Users → `multi-lab-admin` → Security credentials — confirm MFA device
assigned, console access enabled, and access key active.

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
| VPC endpoints       | S3 Gateway         |
| DNS hostnames       | Enabled            |
| DNS resolution      | Enabled            |

> **Single AZ:** sufficient for lab purposes. Multi-AZ adds redundancy cost
> (second NAT Gateway, cross-AZ data transfer) without adding learning value
> at this stage.

> **VPC endpoints:** S3 Gateway is free and required for S3 reachability from private 
> subnets without NAT — CloudTrail and Config depend on this.

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
Passive observability baseline enabled at the account level: CloudTrail
(all-region trail), and GuardDuty. AWS Config is documented as a reference
only — see substep 5.2.

---

### Step 5.1 — CloudTrail

**Console**

CloudTrail → Create trail:

**5.1.1 — Trail settings**
- Trail name: `multi-lab-trail`
- Storage location: Create new S3 bucket → `multi-lab-cloudtrail-<account-id>`
- Log file validation: **Enabled**
- Log file SSE-KMS encryption: **disabled** at this stage — applied in the hardening module.
- Enable for all accounts in organization: N/A (single account).

**5.1.2 — Event types**

> Only Management events are enabled. Data events, Insights events, and
> Network activity events are **not enabled** — all three generate additional
> charges. Management events on the first trail are free permanently.

- Event type: **Management events** only
  - Data events: **off**
  - Insights events: **off**
  - Network activity events: **off**

**5.1.3 — Management event configuration**
- API activity: **Read** ✓ · **Write** ✓
- Exclude AWS KMS events: **enabled** — KMS generates high-volume read events
  that add noise without diagnostic value at this lab scale.
- Exclude Amazon RDS Data API events: **enabled** — RDS not in scope for this lab.

**5.1.4 — Review and create**

Verify on the review screen before confirming:
- Trail name: `multi-lab-trail`
- Multi-region: **Yes**
- S3 bucket: `multi-lab-cloudtrail-<account-id>`
- Event types: Management events only (Read + Write)
- Additional charges: **None** — first copy of management events is free.

→ Click **Create trail**.

---

### Step 5.2 — AWS Config (Reference Only — Not Deployed)

> ⚠️ AWS Config has no free tier. Enabling it incurs cost from the first
> configuration item recorded ($0.003/item · $0.001/rule evaluation).
> The steps below are **not executed** in this lab and are documented as a
> reference only. Apply them in environments where cost is not a constraint.

Config → Get started:
- Record all resources supported in this region: **Yes**
- Include global resources (IAM): **Yes**
- S3 bucket: `multi-lab-cloudtrail-<account-id>` (reuse existing)
- Delivery frequency: 24 hours (default)

Managed rules to enable:
- `restricted-ssh` — flags Security Groups allowing port 22 from 0.0.0.0/0
- `s3-bucket-public-read-prohibited` — flags publicly readable buckets
- `ec2-imdsv2-check` — flags instances not enforcing IMDSv2
- `root-account-mfa-enabled` — flags root account without MFA

---

### Step 5.3 — GuardDuty

> **Region warning:** The AWS Console automatically switches the active region
> when navigating between certain global services (IAM, Billing, CloudFront).
> Before enabling GuardDuty, confirm the region selector (top-right corner)
> shows **eu-west-1 (Ireland)**. Enabling GuardDuty in the wrong region
> (commonly us-east-1) creates a billable detector with no value for this lab.
> If this happens: navigate to the incorrect region → GuardDuty → Settings →
> Disable GuardDuty → confirm. Then return to eu-west-1 and enable it there.

GuardDuty → Get started → **Enable GuardDuty**. 

No additional configuration required at this stage. VPC Flow Logs activation
and GuardDuty data source configuration are covered in
[`modules/hardening/aws-native/aws-native.md`](../../modules/hardening/aws-native/aws-native.md).

> GuardDuty includes a 30-day free trial on first enable per account per
> region. After the trial, cost is based on volume of CloudTrail management
> events, VPC Flow Logs, and DNS logs analyzed. For a single-instance lab
> with minimal activity, post-trial cost is typically under $3/month.
> **Disable GuardDuty before the 30-day trial expires** if continued cost
> is not acceptable — reactivation restarts the trial in a new account.

---

### Why
Passive observability baseline — no ongoing configuration after enabling.

CloudTrail is the API-level audit log (equivalent to `auditd` at the OS layer).
All-regions is required to capture IAM and STS events, which are global.
GuardDuty performs ML-based threat detection over CloudTrail, VPC Flow Logs,
and DNS from day one. AWS Config would add continuous compliance drift
detection — excluded due to cost constraints, documented in 5.2 as reference.
S3 bucket hardening and GuardDuty data source configuration are applied in
the hardening module.

### Verification

**Console**
- CloudTrail → Trails → `multi-lab-trail` — Status: *Logging*
- GuardDuty → Summary — Status: *Enabled*

**CLI**
```bash
aws cloudtrail get-trail-status --name multi-lab-trail --profile multi-lab
# → "IsLogging": true

aws guardduty list-detectors --profile multi-lab
# → "DetectorIds": ["<detector-id>"]
```

---

**Next:** [`modules/hardening/aws-native/aws-native.md`](../../modules/hardening/aws-native/aws-native.md)