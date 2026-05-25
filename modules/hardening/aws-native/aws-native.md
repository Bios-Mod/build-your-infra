# Hardening — AWS Native

Applies the AWS-native security baseline to the account, network, and
compute layer. Requires the base environment defined in
[aws-native-setup.md](../../../environments/aws-native/aws-native-setup.md)
to be completed first.

---

## Scope

| Level | Controls |
|---|---|
| Account & IAM | Root locked · MFA on operator account · EC2 instance profiles · no credentials on disk |
| Network | Security Groups default-deny · no public SSH · VPC Flow Logs |
| Instance | IMDSv2 enforced · SSM Session Manager · encrypted EBS |
| Detection & audit | GuardDuty · Inspector · CloudTrail hardening · AWS Config rules · Security Hub |

---

## Relationship to Self-Managed

| Self-managed | AWS Native |
|---|---|
| UFW | Security Groups |
| SSH key-only + port 22222 | SSM Session Manager — no open SSH port |
| WireGuard (remote access) | SSM Session Manager + private subnets |
| sysctl / AppArmor | IMDSv2 + instance profile scoping |
| auditd | CloudTrail (API layer) |
| Lynis | AWS Config conformance packs (CIS AWS Foundations) |
| Fail2Ban + rkhunter | GuardDuty (ML threat detection) |
| debsums / apt CVE tracking | AWS Inspector (CVE scanning) |
| rsyslog aggregation | Security Hub (finding aggregation) |

---

## Step 1 — Harden CloudTrail S3 bucket

### What was done
Enabled Block Public Access on the CloudTrail bucket, applied a bucket policy
that denies object deletion by any principal, and enabled CloudTrail log file
validation.

**Console**

The S3 bucket created during setup stores all API audit logs. Protecting it
prevents log tampering or silent deletion.

S3 → Buckets → `multi-lab-cloudtrail-<account-id>`:

1. **Block Public Access:** Permissions → Block public access → enable all four options → Save.
2. **Bucket policy — deny delete:** Permissions → Bucket policy → add:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLogDeletion",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": "arn:aws:s3:::multi-lab-cloudtrail-<account-id>/AWSLogs/*"
    }
  ]
}
```

3. **Log file validation:** CloudTrail → Trails → `multi-lab-trail` → Edit → enable *Log file validation*.

**MFA Delete (optional — root only):**

> MFA Delete requires the **root account** to enable — it cannot be set by
> any IAM user, including `AdministratorAccess`. Evaluate based on your
> tolerance for using root credentials for a one-time configuration step.

```bash
# Enable versioning first — MFA Delete requires versioning to be active
aws s3api put-bucket-versioning \
  --bucket multi-lab-cloudtrail-<account-id> \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::<account-id>:mfa/root-account-mfa-device <MFA-token>" \
  --profile multi-lab
```

Once enabled, object deletion requires the root MFA token on every
`DeleteObject` call — no IAM policy can override this constraint.

### Why
CloudTrail logs are only useful as an audit trail if they cannot be tampered
with. Block Public Access prevents accidental or misconfigured public exposure.
The deny-delete bucket policy ensures logs cannot be erased even by the
operator account — any deletion attempt is itself logged. Log file validation
generates a digest file signed by AWS for each log delivery, allowing
cryptographic verification that logs have not been modified after delivery.
MFA Delete adds a physical second factor to any deletion operation — even
a fully compromised `AdministratorAccess` account cannot erase logs without
the root MFA device. The root-only restriction is intentional by AWS design:
it prevents any automation or scripting from bypassing the control.

### Verification

**Console**

S3 → `multi-lab-cloudtrail-<account-id>` → Permissions → Block public access: all four *On*.

**CLI**
```bash
aws s3api get-bucket-policy \
  --bucket multi-lab-cloudtrail-<account-id> \
  --profile multi-lab
# → returns policy JSON with DenyLogDeletion statement

aws cloudtrail get-trail \
  --name multi-lab-trail \
  --profile multi-lab \
  --query "Trail.LogFileValidationEnabled"
# → true

# MFA Delete status (if enabled)
aws s3api get-bucket-versioning \
  --bucket multi-lab-cloudtrail-<account-id> \
  --profile multi-lab
# → "Status": "Enabled", "MFADelete": "Enabled"
```

---

## Step 2 — EC2 instance profile (IAM role for instances)

### What was done
Created IAM role `multi-lab-ec2-role` with `AmazonSSMManagedInstanceCore`
policy, configured as an EC2 instance profile.

**Console**

No EC2 instance should carry user credentials. An instance profile provides
temporary, auto-rotated credentials scoped to what the instance actually needs.

IAM → Roles → Create role:
- Trusted entity: AWS service → EC2
- Permissions: `AmazonSSMManagedInstanceCore` (required for SSM Session Manager)
- Role name: `multi-lab-ec2-role`

IAM → Roles → `multi-lab-ec2-role` → Trust relationships — confirm:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "ec2.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

> Additional policies are attached per module as needed (e.g., S3 read for
> file-transfer). This role is the base — least privilege per module on top.

**Associate the instance profile to the EC2 instance:**

**Console**

EC2 → Instances → `multi-lab-aws` → Actions → Security →
Modify IAM role → select `multi-lab-ec2-role` → Update IAM role.

**CLI**
```bash
# Get the instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=multi-lab-aws" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text \
  --profile multi-lab

# Associate the instance profile
aws ec2 associate-iam-instance-profile \
  --instance-id <instance-id> \
  --iam-instance-profile Name=multi-lab-ec2-role \
  --profile multi-lab
```

### Why
Attaching user access keys to an instance (via `~/.aws/credentials` or
environment variables) creates long-lived credentials that cannot be
automatically rotated and are exposed to any process running on the instance.
An instance profile issues temporary STS credentials (valid 1–6 hours,
auto-rotated by the EC2 metadata service) scoped only to what the role allows.
`AmazonSSMManagedInstanceCore` is the minimum permission set for SSM Session
Manager — it grants the SSM agent the ability to register with the service
and receive session commands.

### Verification

**CLI**
```bash
aws iam get-instance-profile \
  --instance-profile-name multi-lab-ec2-role \
  --profile multi-lab \
  --query "InstanceProfile.Roles.RoleName"
# → "multi-lab-ec2-role"

# Confirm instance profile is attached
aws ec2 describe-instances \
  --instance-id <instance-id> \
  --query "Reservations[*].Instances[*].IamInstanceProfile.Arn" \
  --profile multi-lab
# → "arn:aws:iam::<account-id>:instance-profile/multi-lab-ec2-role"
```

---

## Step 3 — Default Security Group lockdown

### What was done
Removed all inbound and outbound rules from the default Security Group of
`multi-lab-vpc`.

**Console**

The default Security Group in every VPC allows all traffic between members
of the same group. It must be locked down to prevent accidental use.

VPC → Security Groups → filter by `multi-lab-vpc` → select the *default* SG:
- Inbound rules → Edit → delete all rules → Save.
- Outbound rules → Edit → delete all rules → Save.

> Never assign the default SG to any resource. Each module defines its own
> SG with explicit allow rules. The default SG being empty enforces this —
> any resource accidentally assigned to it loses all connectivity immediately,
> making the misconfiguration visible.

### Why
Security Groups are stateful allow-lists — there is no explicit deny rule,
only absence of allow. The default SG ships with a rule allowing all traffic
from other members of the same group, which means two resources accidentally
sharing the default SG can communicate freely regardless of intent. Clearing
it forces every resource to use an explicitly defined SG, making network
policy visible and auditable.

### Verification

**CLI**
```bash
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=<multi-lab-vpc-id>" \
             "Name=group-name,Values=default" \
  --query "SecurityGroups.{Inbound:IpPermissions,Outbound:IpPermissionsEgress}" \
  --profile multi-lab
# → Inbound: [], Outbound: []
```

---

## Step 4 — VPC Flow Logs

### What was done
Enabled VPC Flow Logs on `multi-lab-vpc` capturing all traffic (accepted and
rejected), delivered to CloudWatch Logs at `/aws/vpc/multi-lab-vpc`.

**Console**

VPC → Your VPCs → `multi-lab-vpc` → Flow logs → Create flow log:

| Parameter | Value |
|---|---|
| Filter | All (accept + reject) |
| Destination | CloudWatch Logs |
| Log group | `/aws/vpc/multi-lab-vpc` |
| IAM role | `multi-lab-vpc-flow-logs-role` (create below) |
| Log format | Default |

**Create the IAM role for Flow Logs delivery:**

IAM → Roles → Create role:
- Trusted entity: Custom trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "vpc-flow-logs.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

- Permissions: inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ],
    "Resource": "*"
  }]
}
```

- Role name: `multi-lab-vpc-flow-logs-role`

### Why
VPC Flow Logs are the network-layer equivalent of `ufw` logging + rsyslog.
They record source IP, destination IP, port, protocol, and accept/reject
decision for every network flow through the VPC. This is the primary data
source for GuardDuty network threat detection — without Flow Logs, GuardDuty
cannot detect port scanning, lateral movement, or C2 beaconing at the network
layer. Capturing both accepted and rejected traffic is essential: rejected
traffic reveals reconnaissance and attack attempts; accepted traffic provides
the baseline for anomaly detection.

### Verification

**Console**

VPC → Your VPCs → `multi-lab-vpc` → Flow logs — confirm one flow log with status *Active*.

**CLI**
```bash
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=<multi-lab-vpc-id>" \
  --query "FlowLogs.{Status:FlowLogStatus,Destination:LogDestination,Filter:TrafficType}" \
  --profile multi-lab
# → Status: "ACTIVE", Filter: "ALL"
```

---

## Step 5 — IMDSv2 enforcement

### What was done
Set IMDSv2 as required at the account level and enforced `HttpTokens: required`
on all existing instances.

**Console — account-level default**

EC2 → Settings (under Account Attributes) → Data protection and security →
IMDSv2 default: set to *Required* → Save.

> This sets the account-level default. Any new EC2 instance launched after
> this point will have IMDSv2 required unless explicitly overridden.
> Existing instances must be updated individually (see CLI below).

**CLI — enforce on existing instances**

```bash
# List all instances in the region
aws ec2 describe-instances \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text \
  --profile multi-lab

# This lab runs a single instance. For multi-instance environments,
# pipe describe-instances output into a loop.
aws ec2 modify-instance-metadata-options \
  --instance-id <instance-id> \
  --http-tokens required \
  --http-endpoint enabled \
  --profile multi-lab
```

### Why
The EC2 Instance Metadata Service (IMDS) at `169.254.169.254` serves
temporary IAM credentials to the instance. IMDSv1 responds to any HTTP GET
from any process on the instance — including a web application exploited via
SSRF. An attacker with SSRF can retrieve the instance role credentials and
pivot to any AWS resource the role can access. IMDSv2 requires a PUT request
with a session token before any metadata can be read — a two-step flow that
SSRF cannot complete because SSRF typically allows only GET requests or
cannot follow the required HTTP method sequence.

### Verification

**CLI**
```bash
aws ec2 describe-instances \
  --query "Reservations[*].Instances[*].{ID:InstanceId,HttpTokens:MetadataOptions.HttpTokens}" \
  --profile multi-lab
# → HttpTokens: "required" for all instances
```

---

## Step 6 — SSM Session Manager

### What was done
Verified SSM agent is active and instance profile `multi-lab-ec2-role` is
attached. Documented VPC endpoint requirements for private subnet instances.

**Console**

Verify the SSM Agent is active on the instance

EC2 → Instances → select instance → Actions → Security → Modify IAM role →
assign `multi-lab-ec2-role` if not already attached.

> For instances in the **private subnet**, SSM requires VPC endpoints to reach
> the SSM service without internet access. Create the following Interface
> endpoints in VPC → Endpoints → Create endpoint:
> - `com.amazonaws.eu-west-1.ssm`
> - `com.amazonaws.eu-west-1.ssmmessages`
> - `com.amazonaws.eu-west-1.ec2messages`
>
> Associate them with the private subnet and the instance's Security Group.
> Public subnet instances with an Internet Gateway do not require these endpoints.

**Start a session:**

**CLI**
```bash
aws ssm start-session \
  --target <instance-id> \
  --profile multi-lab
# → opens an interactive shell session via SSM — no SSH port required
```

### Why
SSM Session Manager provides authenticated, audited shell access without
exposing port 22. Every session is logged to CloudTrail (`StartSession` event)
and optionally to CloudWatch Logs or S3. This eliminates the attack surface of
an open SSH port, removes the need to manage SSH key pairs per instance, and
integrates access control with IAM — session access is granted by IAM policy,
not by key distribution. This is the direct operational replacement for
`ssh -p 22222` used in the self-managed environment.

### Verification

**Console**

Systems Manager → Session Manager → Sessions — confirm session history appears
after starting a session.

**CLI**
```bash
aws ssm describe-instance-information \
  --profile multi-lab \
  --query "InstanceInformationList[*].{ID:InstanceId,PingStatus:PingStatus,AgentVersion:AgentVersion}"
# → PingStatus: "Online" for target instance
```

---

## Step 7 — GuardDuty data sources

### What was done
Confirmed GuardDuty foundational data sources are active (VPC Flow Logs,
CloudTrail, DNS logs) and enabled S3 Protection.

**Console**

GuardDuty → Settings → Protection plans:
- S3 Protection: **Enable**
- EC2 Malware Protection: **Enable** (optional — uses on-demand EBS scanning)

GuardDuty → Settings → confirm VPC Flow Logs, CloudTrail, and DNS Logs
show as *Enabled* under Foundational data sources.

> These data sources are activated automatically when GuardDuty is enabled.
> This step confirms they are active and extends coverage to S3.

### Why
GuardDuty's default foundational sources cover network and API-layer threats.
S3 Protection adds detection for suspicious data access patterns (e.g.,
anomalous GetObject from an unusual IP, or PutObject from a compromised
credential). Without S3 Protection, a credential compromise leading to data
exfiltration from S3 would not generate a GuardDuty finding.

### Verification

**CLI**
```bash
DETECTOR=$(aws guardduty list-detectors --query "DetectorIds" --output text --profile multi-lab)

aws guardduty get-detector \
  --detector-id $DETECTOR \
  --profile multi-lab \
  --query "DataSources"
# → CloudTrail.Status: "ENABLED", DNSLogs.Status: "ENABLED",
#   FlowLogs.Status: "ENABLED", S3Logs.Status: "ENABLED"
```

---

## Step 8 — AWS Config rules

### What was done
Added seven AWS Config managed rules covering IAM, EC2, VPC, CloudTrail,
and S3 baseline compliance checks.

**Console**

Config → Rules → Add rule — add the following managed rules:

| Rule | What it checks |
|---|---|
| `mfa-enabled-for-iam-console-access` | IAM users with console access have MFA |
| `root-account-mfa-enabled` | Root account has MFA active |
| `ec2-imdsv2-check` | All EC2 instances have IMDSv2 required |
| `vpc-flow-logs-enabled` | VPC Flow Logs active on all VPCs |
| `cloud-trail-enabled` | CloudTrail trail active |
| `s3-bucket-public-access-prohibited` | No S3 bucket allows public access |
| `ec2-instance-no-public-ip` | Instances in private subnet have no public IP |

> Config rules evaluate continuously. Any deviation from the above triggers
> a *NON_COMPLIANT* finding visible in Config → Rules and aggregated in
> Security Hub (Step 9).

### Why
AWS Config rules are the automated equivalent of a Lynis audit — they
continuously evaluate resource configuration against defined controls and flag
deviations without manual inspection. These seven rules codify the controls
applied in the previous steps: if any future change breaks the baseline (e.g.,
an instance is launched without IMDSv2, or a bucket accidentally becomes
public), Config flags it immediately rather than waiting for a manual audit.

### Verification

**Console**

Config → Rules — all rules show *Compliant* once resources are configured
per this guide. *NON_COMPLIANT* findings indicate a gap to investigate.

**CLI**
```bash
aws configservice describe-compliance-by-config-rule \
  --profile multi-lab \
  --query "ComplianceByConfigRules[*].{Rule:ConfigRuleName,Status:Compliance.ComplianceType}"
# → all rules: "COMPLIANT"
```

---

## Step 9 — Security Hub

### What was done
Enabled Security Hub with AWS Foundational Security Best Practices and CIS
AWS Foundations Benchmark standards active.

**Console**

Security Hub → Go to Security Hub → Enable Security Hub.

Standards to enable:
- **AWS Foundational Security Best Practices** — enable.
- **CIS AWS Foundations Benchmark** — enable.

> Security Hub aggregates findings from GuardDuty, Inspector, and Config into
> a single normalized view. Enabling it after the previous steps means findings
> from all sources are immediately visible. The two standards above run
> automated checks against the controls configured in this guide and score
> overall security posture as a percentage.

### Why
GuardDuty, Inspector, and Config each produce findings in their own consoles
with different formats. Security Hub normalizes all findings into the ASFF
(Amazon Security Finding Format) and provides a unified dashboard with a
security score. This is the operational equivalent of a SIEM aggregation
layer — it replaces the need to monitor three separate services and provides
a single pane to triage, prioritize, and track remediation. CIS AWS Foundations
Benchmark provides an industry-standard compliance baseline relevant for
demonstrating security posture to auditors or potential employers.

### Verification

**Console**

Security Hub → Summary — security score visible, findings from GuardDuty and
Config populated within a few minutes of enablement.

**CLI**
```bash
aws securityhub describe-hub --profile multi-lab
# → "HubArn": "arn:aws:securityhub:eu-west-1:<account-id>:hub/default",
#   "AutoEnableControls": true
```

---

**Next:** [`modules/file-transfer/aws-native/aws-native.md`](../../modules/file-transfer/aws-native/aws-native.md)