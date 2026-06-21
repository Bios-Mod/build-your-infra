# Hardening — AWS Native Automation

**Terraform · AWS Security Controls · build-your-infra**

---

## Introduction

This document covers the Terraform module that brings the AWS-native hardening
controls under code management. Terraform manages the security layer: IAM roles
for EC2 and VPC Flow Logs, the default Security Group lockdown, VPC Flow Logs,
IMDSv2 account-level default, GuardDuty, Security Hub, and the CloudTrail S3
bucket policy and log validation setting.

All resources in this module were created manually and documented in
[aws-native.md](../aws-native.md). This module imports them into state, does
not recreate them.

> **Prerequisites:** AWS CLI configured with the `multi-lab-admin` profile.
> Terraform >= 1.5 installed locally. All steps in
> [aws-native.md](../aws-native.md) completed — resources must exist before
> import.

---

## Terraform file layout

```bash
modules/hardening/aws-native/automation/terraform/
├── main.tf.example            # provider + all resource blocks — rename to main.tf after import
├── outputs.tf.example         # security resource outputs — rename to outputs.tf after import
├── import.tf.example          # import blocks — copy to import.tf, fill in IDs, delete after apply
├── variables.tf               # all input declarations
└── terraform.tfvars.example   # copy to terraform.tfvars and fill in values
```

`main.tf`, `import.tf`, and `terraform.tfvars` are gitignored and never committed.

---

## Scope

| Resource | Terraform resource type |
|---|---|
| IAM role — EC2 instance profile | `aws_iam_role` · `aws_iam_instance_profile` · `aws_iam_role_policy_attachment` |
| IAM role — VPC Flow Logs delivery | `aws_iam_role` · `aws_iam_role_policy` |
| Default Security Group (empty) | `aws_default_security_group` |
| VPC Flow Logs | `aws_flow_log` |
| IMDSv2 account-level default | `aws_ec2_instance_metadata_defaults` |
| GuardDuty detector | `aws_guardduty_detector` |
| GuardDuty S3 Protection | `aws_guardduty_detector_feature` |
| Security Hub account | `aws_securityhub_account` |
| Security Hub — FSBP standard | `aws_securityhub_standards_subscription` |
| Security Hub — CIS Benchmark | `aws_securityhub_standards_subscription` |
| CloudTrail S3 bucket policy | `aws_s3_bucket_policy` |
| CloudTrail log validation | `aws_cloudtrail` |

**Out of scope:** SSM Session Manager has no Terraform resource — it is
functional via the instance profile. MFA Delete on the S3 bucket has no AWS
provider support — it requires root credentials via the S3 API directly.
IMDSv2 enforcement on the existing EC2 instance is managed in the self-managed
stack (`aws_instance` resource) — this module manages only the account-level
default.

---

## Phase 1 — Import existing infrastructure

Steps 1–5 run once, the first time the module is brought under Terraform
control. The goal is to absorb all pre-existing security resources into state
without modifying them.

---

## Step 1 — Collect existing resource IDs

### What was done

All resources in this module were created manually. Before writing any HCL,
query the AWS API to collect the exact ID of every resource Terraform will
absorb. Record each value — they are the inputs for `import.tf`.

```bash
# IAM role — EC2 instance profile
aws iam get-role \
  --role-name multi-lab-ec2-role \
  --query "Role.RoleName" \
  --output text --profile multi-lab-admin

# → multi-lab-ec2-role

# IAM role — VPC Flow Logs
aws iam get-role \
  --role-name multi-lab-vpc-flow-logs-role \
  --query "Role.RoleName" \
  --output text --profile multi-lab-admin

# → multi-lab-vpc-flow-logs-role

# Default Security Group ID (the default SG of multi-lab-vpc)
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=<multi-lab-vpc-id>" \
             "Name=group-name,Values=default" \
  --query "SecurityGroups.GroupId" \
  --output text --profile multi-lab-admin

# → sg-xxxxxxxxxxxxxxxxx

# VPC Flow Log ID
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=<multi-lab-vpc-id>" \
  --query "FlowLogs.FlowLogId" \
  --output text --profile multi-lab-admin

# → fl-xxxxxxxxxxxxxxxxx

# GuardDuty Detector ID
aws guardduty list-detectors \
  --query "DetectorIds" \
  --output text --profile multi-lab-admin

# → xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Security Hub Hub ARN
aws securityhub describe-hub \
  --query "HubArn" \
  --output text --profile multi-lab-admin

# → arn:aws:securityhub:eu-west-1:<account-id>:hub/default

# Security Hub standards subscription ARNs
aws securityhub get-enabled-standards \
  --query "StandardsSubscriptions[*].StandardsSubscriptionArn" \
  --output text --profile multi-lab-admin

# → two ARNs — FSBP and CIS Benchmark

# CloudTrail trail ARN
aws cloudtrail get-trail \
  --name multi-lab-trail \
  --query "Trail.TrailARN" \
  --output text --profile multi-lab-admin

# → arn:aws:cloudtrail:eu-west-1:<account-id>:trail/multi-lab-trail

# CloudTrail S3 bucket name (for aws_s3_bucket_policy import — import ID is bucket name)
aws cloudtrail get-trail \
  --name multi-lab-trail \
  --query "Trail.S3BucketName" \
  --output text --profile multi-lab-admin

# → multi-lab-cloudtrail-<account-id>
```

### Why

Import blocks require the exact provider-specific ID for each resource type,
not the AWS name tag. The ID format varies by resource — some use ARNs, some
use AWS-generated IDs, some use names. Collecting them upfront prevents
mismatches between import blocks and live state. These IDs are not committed
to the repo.

---

## Step 2 — Prepare import.tf and terraform.tfvars

### What was done

Copy both example files and fill in the values collected in Step 1:

```bash
cd modules/hardening/aws-native/automation/terraform/
cp import.tf.example import.tf
cp terraform.tfvars.example terraform.tfvars
```

Edit `import.tf` and replace every placeholder with the real resource ID.
Edit `terraform.tfvars` and fill in the values for your environment.

📄 [`modules/hardening/aws-native/automation/terraform/import.tf.example`](terraform/import.tf.example)
📄 [`modules/hardening/aws-native/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)

### Why

`import.tf` and `terraform.tfvars` contain real account IDs and ARNs —
both are gitignored and never committed. The `.example` files are the
versionable contract: they document every required input without exposing
real values. `import.tf` holds the provider block at this phase — `main.tf`
does not exist yet, which prevents Terraform from attempting to plan or apply
resource changes before the import cycle is complete.

---

## Step 3 — Initialize the working directory

### What was done

With `import.tf` in place, initialize the AWS provider and set up the local
state backend.

```bash
cd modules/hardening/aws-native/automation/terraform/
terraform init
```

### Why

`terraform init` reads the `required_providers` block in `import.tf` and
downloads the matching provider version into `.terraform/`. State is kept
local — no remote backend in this lab. In a team or production context,
state would live in S3 with DynamoDB locking.

### Verification

```bash
terraform init
# → Terraform has been successfully initialized!
# → provider registry.terraform.io/hashicorp/aws v5.x.x
```

---

## Step 4 — Generate resource configuration

### What was done

With `import.tf` and `terraform init` complete, generate the HCL resource
blocks by reading the live attributes of every imported resource from the
AWS API.

```bash
terraform plan -generate-config-out=generated.tf
```

### Why

Import blocks require the target resource to be declared in the configuration.
`-generate-config-out` produces `generated.tf` with valid HCL built from the
real resource attributes, satisfying that requirement without writing resource
blocks manually at this stage. `generated.tf` is a working artifact — it is
deleted after the import apply completes.

> **`generated.tf` is not committed to the repo.** It is gitignored.

### Fix generated.tf before applying (expected issues)

The config generator is experimental. Review and correct `generated.tf`
before applying — several resource types produce incomplete or conflicting
attributes.

#### Known issues

| Resource | Issue | Fix |
|---|---|---|
| `aws_iam_role_policy` (flow logs inline policy) | `policy` attribute may be generated as escaped JSON string | Verify it is valid JSON — reformat if malformed |
| `aws_guardduty_detector_feature` | May not be generated — generator does not always handle nested features | Add the block manually (see below) |
| `aws_securityhub_account` | Generator may produce extra attributes not accepted by the provider | Remove any attribute not in the provider schema |
| `aws_cloudtrail` | Generates all trail attributes — many are read-only or default | Remove `arn`, `home_region`, `id` — keep only settable attributes |
| `aws_s3_bucket_policy` | `policy` generated as escaped JSON string | Verify formatting — provider accepts both escaped and heredoc |

#### Add missing aws_guardduty_detector_feature block

If the generator does not produce `aws_guardduty_detector_feature` for S3
Protection, add the block manually to `generated.tf`:

```hcl
resource "aws_guardduty_detector_feature" "s3_protection" {
  detector_id = "<your-detector-id>"
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}
```

### Verification

```bash
terraform plan
# → Plan: N to import, 0 to add, 0 to change, 0 to destroy.
# Exactly 0 to change — if not, reconcile diverging attributes in generated.tf
# before applying.
```

---

## Step 5 — Apply import

### What was done

Run `terraform apply` to absorb all pre-existing security resources into the
state file. No resources are created or modified — Terraform reads their
current attributes from the AWS API and writes them to state.

```bash
terraform apply
# When prompted, type: yes
```

### Why

`terraform apply` with only import blocks and no resource blocks performs
a pure import — it maps each AWS resource to a Terraform address in state
without touching the actual infrastructure. This is the correct boundary:
state is populated, infra is untouched.

### Verification

```bash
terraform state list
# aws_cloudtrail.main
# aws_default_security_group.default
# aws_ec2_instance_metadata_defaults.main
# aws_flow_log.main
# aws_guardduty_detector.main
# aws_guardduty_detector_feature.s3_protection
# aws_iam_instance_profile.ec2
# aws_iam_role.ec2
# aws_iam_role.vpc_flow_logs
# aws_iam_role_policy.vpc_flow_logs
# aws_iam_role_policy_attachment.ec2_ssm
# aws_s3_bucket_policy.cloudtrail
# aws_securityhub_account.main
# aws_securityhub_standards_subscription.fsbp
# aws_securityhub_standards_subscription.cis
```

---

## Step 6 — Finalize state and activate main.tf

### What was done

Delete `import.tf` and `generated.tf`, then rename `main.tf.example` to
`main.tf`. Run a plan to confirm state matches the configuration exactly.

```bash
rm import.tf generated.tf
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf

terraform plan -out hardening.tfplan
terraform fmt
terraform validate
terraform apply "hardening.tfplan"
```

📄 [`modules/hardening/aws-native/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`modules/hardening/aws-native/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)

### Why

Deleting `import.tf` removes the import blocks and the provider block that
lived there during Phase 1. `main.tf` takes over as the single source of
truth — it contains the provider block and all resource definitions.
A clean plan at this point confirms the import cycle is complete: Terraform's
desired state matches the live security configuration with zero drift.

If the plan shows diffs, reconcile the diverging attributes in `main.tf`
and re-run `plan` until the output is clean.

---

## Phase 2 — Ongoing operations

Steps 7–8 cover normal operation after the import cycle is complete.
`main.tf` and `terraform.tfvars` are in place. `import.tf` does not exist.

---

## Step 7 — Destroy

### What was done

Tear down all security controls managed by this module.

> **Warning:** destroying this module disables GuardDuty, Security Hub, and
> VPC Flow Logs, and removes the IAM roles required for EC2 and Flow Logs
> operation. Do not run destroy in a production account.

```bash
terraform destroy -auto-approve
```

### Why

`terraform destroy` reads the state file and deletes every resource in the
correct dependency order — standards subscriptions before Security Hub account,
detector features before GuardDuty detector, flow log before IAM role, instance
profile attachment before IAM role. No orphaned resources remain after destroy
completes.

### Verification

```bash
terraform destroy -auto-approve
# → Destroy complete! Resources: N destroyed.

terraform show
# → The state file is empty. No resources.
```

---

## Step 8 — Redeploy

### What was done

After destroy, reprovision all security controls from the `main.tf` definition.

```bash
terraform plan -out hardening.tfplan
terraform apply hardening.tfplan
```

### Why

Unlike the self-managed stack (which restores from an AMI snapshot), this
module creates security control resources from their Terraform definition.
The `plan -out` step produces a deterministic apply artifact — what is
reviewed in plan is exactly what is applied, with no risk of state drift
between the two commands.

> **GuardDuty:** redeploying creates a new detector. If the 30-day free trial
> was consumed on the original detector, the new one does not restart the trial.
> Billing applies immediately on redeploy.

> **`hardening.tfplan` is gitignored** (`*.tfplan`) and never committed.

### Verification

```bash
terraform state list
# → same N resources as after initial import

aws guardduty list-detectors \
  --query "DetectorIds" \
  --output text --profile multi-lab-admin
# → new detector ID
```