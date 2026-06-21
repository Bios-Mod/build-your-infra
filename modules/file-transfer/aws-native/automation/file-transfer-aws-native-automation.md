# File Transfer — AWS Native Automation

**Terraform · AWS Transfer Family · build-your-infra**

---

## Introduction

This document covers the Terraform module that brings the AWS Transfer Family
file transfer stack under code management. Terraform manages the persistent
layer — S3 bucket, IAM role, Security Group, and CloudWatch log group — and
the deploy-on-demand layer — the Transfer Family server, logical user, and
SSH key.

All resources in this module were created manually and documented in
[aws-native.md](../aws-native.md). This module imports the persistent
resources into state and manages the on-demand resources via apply/destroy.

> **Prerequisites:** AWS CLI configured with the `multi-lab-admin` profile.
> Terraform >= 1.5 installed locally. All steps in
> [aws-native.md](../aws-native.md) completed — resources must exist before
> import.

---

## Terraform file layout

```bash
modules/file-transfer/aws-native/automation/terraform/
├── main.tf.example            # provider + all resource blocks — rename to main.tf after import
├── outputs.tf.example         # Transfer Family resource outputs — rename to outputs.tf after import
├── import.tf.example          # import blocks — copy to import.tf, fill in IDs, delete after apply
├── variables.tf               # all input declarations
└── terraform.tfvars.example   # copy to terraform.tfvars and fill in values
```

`main.tf`, `import.tf`, and `terraform.tfvars` are gitignored and never committed.

---

## Scope

| Resource | Terraform resource type |
|---|---|
| S3 bucket | `aws_s3_bucket` |
| S3 Block Public Access | `aws_s3_bucket_public_access_block` |
| S3 versioning | `aws_s3_bucket_versioning` |
| IAM role — Transfer Family | `aws_iam_role` |
| IAM inline policy — S3 access | `aws_iam_role_policy` |
| Security Group | `aws_security_group` |
| CloudWatch log group | `aws_cloudwatch_log_group` |
| Transfer Family server | `aws_transfer_server` |
| Transfer Family logical user | `aws_transfer_user` |
| Transfer Family SSH key | `aws_transfer_ssh_key` |

**Out of scope:** The Elastic IP associated with the Transfer Family server
endpoint is not managed here — it is provisioned and released per session
as documented in [aws-native.md](../aws-native.md) Steps 4 and 7. S3
server access logging and CloudTrail S3 data events are managed by the
hardening module.

> **Deploy-on-demand pattern:** the Transfer Family server is billed at
> $0.30/hour from creation. The server, logical user, and SSH key follow
> the same lifecycle: created on `terraform apply`, deleted on
> `terraform destroy`. The persistent layer (S3, IAM, SG, CloudWatch) is
> imported and retained between sessions at no continuous cost.

---

## Phase 1 — Import existing infrastructure

Steps 1–6 run once, the first time the module is brought under Terraform
control. The goal is to absorb all pre-existing resources into state
without modifying them.

---

## Step 1 — Collect existing resource IDs

### What was done

All resources in this module were created manually. Before writing any HCL,
query the AWS API to collect the exact ID of every resource Terraform will
absorb. Record each value — they are the inputs for `import.tf`.

```bash
# S3 bucket name
aws s3api list-buckets \
  --profile multi-lab-admin \
  --query "Buckets[?starts_with(Name, 'multi-lab-transfer')].Name" \
  --output text

# → multi-lab-transfer-<account-id>

# IAM role name
aws iam get-role \
  --role-name multi-lab-transfer-role \
  --profile multi-lab-admin \
  --query "Role.RoleName" \
  --output text

# → multi-lab-transfer-role

# IAM inline policy name (import ID format: role-name:policy-name)
aws iam list-role-policies \
  --role-name multi-lab-transfer-role \
  --profile multi-lab-admin \
  --query "PolicyNames" \
  --output text

# → multi-lab-transfer-s3-policy

# Security Group ID
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=multi-lab-transfer-sg" \
  --query "SecurityGroups.GroupId" \
  --output text --profile multi-lab-admin

# → sg-xxxxxxxxxxxxxxxxx

# CloudWatch log group name
aws logs describe-log-groups \
  --log-group-name-prefix /aws/transfer/multi-lab-transfer \
  --profile multi-lab-admin \
  --query "logGroups.logGroupName" \
  --output text

# → /aws/transfer/multi-lab-transfer

# Transfer Family server ID (skip if the server was deleted — it will be created on apply)
aws transfer list-servers \
  --profile multi-lab-admin \
  --query "Servers[*].ServerId" \
  --output text

# → s-xxxxxxxxxxxxxxxxx  (or empty if already torn down)
```

### Why

Import blocks require the exact provider-specific ID for each resource type.
The S3 bucket uses its name, the IAM inline policy uses a compound
`role-name:policy-name` string, and the Transfer Family user uses
`server-id/username`. Collecting all IDs before writing HCL prevents
mismatches between import blocks and live state. These values are not
committed to the repo.

---

## Step 2 — Prepare import.tf and terraform.tfvars

### What was done

Copy both example files and fill in the values collected in Step 1:

```bash
cd modules/file-transfer/aws-native/automation/terraform/
cp import.tf.example import.tf
cp terraform.tfvars.example terraform.tfvars
```

Edit `import.tf` and replace every placeholder with the real resource ID.
Edit `terraform.tfvars` and fill in the values for your environment.

📄 [`modules/file-transfer/aws-native/automation/terraform/import.tf.example`](terraform/import.tf.example)
📄 [`modules/file-transfer/aws-native/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)

### Why

`import.tf` and `terraform.tfvars` contain real account IDs and resource
identifiers — both are gitignored and never committed. The `.example` files
are the versionable contract: they document every required input without
exposing real values. `import.tf` holds the provider block at this phase —
`main.tf` does not exist yet, which prevents Terraform from attempting to
plan or apply resource changes before the import cycle is complete.

---

## Step 3 — Initialize the working directory

### What was done

With `import.tf` in place, initialize the AWS provider and set up the local
state backend.

```bash
cd modules/file-transfer/aws-native/automation/terraform/
terraform init
```

### Why

`terraform init` reads the `required_providers` block in `import.tf` and
downloads the matching provider version into `.terraform/`. State is kept
local — no remote backend in this lab.

### Verification

```bash
terraform init
# → Terraform has been successfully initialized!
# → provider registry.terraform.io/hashicorp/aws v6.x.x
```

---

## Step 4 — Generate resource configuration

### What was done

With `import.tf` and `terraform init` complete, generate the HCL resource
blocks by reading the live attributes of every imported resource from the
AWS API.

> **Before running:** open `import.tf` and replace every placeholder with
> the real IDs collected in Step 1. `terraform plan` will fail if any
> placeholder value remains.

```bash
terraform fmt
terraform validate
terraform plan -generate-config-out=generated.tf
```

### Why

Import blocks require the target resource to be declared in the
configuration. `-generate-config-out` produces `generated.tf` with valid
HCL built from the real resource attributes without writing resource blocks
manually at this stage. `generated.tf` is a working artifact deleted after
the import apply completes.

> **`generated.tf` is not committed to the repo.** It is gitignored.

### Fix generated.tf before applying (expected issues)

| Resource | Issue | Fix |
|---|---|---|
| `aws_s3_bucket` | Generator may include read-only attributes (`bucket_domain_name`, `hosted_zone_id`, `region`) | Remove read-only attributes — keep `bucket`, `tags` |
| `aws_s3_bucket_versioning` | `versioning_configuration` block may omit `mfa_delete` | Add `mfa_delete = "Disabled"` explicitly |
| `aws_iam_role` | `assume_role_policy` generated as escaped JSON string | Verify it is valid JSON — reformat if malformed |
| `aws_iam_role_policy` | `policy` attribute may be escaped JSON | Verify formatting — provider accepts both escaped and heredoc |
| `aws_security_group` | May include `name_prefix` conflicting with `name` | Keep `name` only, remove `name_prefix` |
| `aws_transfer_server` | Generates all server attributes including read-only `endpoint` and `arn` | Remove `arn`, `endpoint`, `id` — keep only settable attributes |

---

## Step 5 — Apply import

### What was done

Run `terraform apply` to absorb all pre-existing resources into the state
file. No resources are created or modified — Terraform reads their current
attributes from the AWS API and writes them to state.

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

# aws_iam_role.transfer
# aws_iam_role_policy.transfer_s3
# aws_transfer_server.main        (only if the server existed at import time)
# aws_transfer_user.sftpuser      (only if the server existed at import time)
# aws_transfer_ssh_key.sftpuser   (only if the server existed at import time)
```

---

## Step 6 — Finalize state and activate main.tf

### What was done

Delete `import.tf` and `generated.tf`, then copy `main.tf.example` to
`main.tf`. Run a plan to confirm state matches the configuration exactly.

```bash
rm import.tf generated.tf
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf

terraform fmt
terraform validate
terraform plan -out file-transfer.tfplan
terraform apply "file-transfer.tfplan"
```

📄 [`modules/file-transfer/aws-native/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`modules/file-transfer/aws-native/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)

### Why

Deleting `import.tf` removes the import blocks and the provider block that
lived there during Phase 1. `main.tf` takes over as the single source of
truth — it contains the provider block and all resource definitions.
A clean plan at this point confirms the import cycle is complete: Terraform's
desired state matches the live configuration with zero drift.

If the plan shows diffs, reconcile the diverging attributes in `main.tf`
and re-run `plan` until the output is clean.

> **Expected plan output if the server was torn down before import:** the
> persistent layer (S3, IAM, SG, CloudWatch) shows `0 to change`. The
> Transfer Family server, user, and SSH key show `3 to add` — they will be
> created on this apply.

### Verification

```bash
terraform state list

# aws_cloudwatch_log_group.transfer
# aws_iam_role.transfer
# aws_iam_role_policy.transfer_s3
# aws_s3_bucket.transfer
# aws_s3_bucket_public_access_block.transfer
# aws_s3_bucket_versioning.transfer
# aws_security_group.transfer
# aws_transfer_server.main
# aws_transfer_ssh_key.sftpuser
# aws_transfer_user.sftpuser
```

---

## Phase 2 — Ongoing operations

Steps 7–8 cover normal operation after the import cycle is complete.
`main.tf` and `terraform.tfvars` are in place. `import.tf` does not exist.

---

## Step 7 — Destroy

### What was done

Tear down all resources managed by this module to stop Transfer Family
billing.

> **Warning:** `terraform destroy` deletes the Transfer Family server
> immediately — billing stops at the next hourly boundary. The S3 bucket,
> IAM role, Security Group, and CloudWatch log group are also destroyed.
> Do not run destroy if the S3 bucket contains data you intend to keep —
> Terraform cannot delete a non-empty versioned bucket. Empty it first
> using the commands in [aws-native.md](../aws-native.md) Step 7.

```bash
terraform destroy -auto-approve
```

### Why

`terraform destroy` reads the state file and deletes resources in the
correct dependency order — Transfer Family user and SSH key before the
server, server before the Security Group and IAM role, S3 objects before
the bucket. No orphaned resources remain after destroy completes.

> **Elastic IP:** Terraform does not manage the EIP for this module. Release
> it manually from the EC2 console after the server is destroyed, as
> documented in [aws-native.md](../aws-native.md) Step 7.

### Verification

```bash
terraform show
# → The state file is empty. No resources.

aws transfer list-servers \
  --profile multi-lab-admin \
  --query "Servers[*].ServerId"
# → [] (empty — server deleted)
```

---

## Step 8 — Redeploy

### What was done

After destroy, reprovision all resources from the `main.tf` definition.

> **Before applying:** allocate a new Elastic IP from the EC2 console and
> update `terraform.tfvars` with the new `eip_allocation_id`. The apply
> will fail if the placeholder value remains or references a released EIP.

```bash
terraform plan -out file-transfer.tfplan
terraform apply file-transfer.tfplan
```

### Why

Redeploy creates a new Transfer Family server with a new server ID and
endpoint address. Update `~/.ssh/config` on the client machine with the
new `HostName` value after apply completes. The S3 bucket, IAM role,
Security Group, and CloudWatch log group are re-created from the `main.tf`
definition — the bucket name is deterministic (`multi-lab-transfer-<account-id>`)
so no client configuration changes are required for those resources.

> **`file-transfer.tfplan` is gitignored** (`*.tfplan`) and never committed.

### Verification

```bash
terraform state list
# → same resources as after initial import

aws transfer list-servers \
  --profile multi-lab-admin \
  --query "Servers[*].{ID:ServerId,State:State}"
# → State: "ONLINE"

# Confirm the new server endpoint
aws transfer describe-server \
  --server-id <new-server-id> \
  --profile multi-lab-admin \
  --query "Server.EndpointDetails"
  
# → VpcEndpointId and new EIP confirmed

# Update SSH config and re-run the connection test from aws-native.md Step 6
```