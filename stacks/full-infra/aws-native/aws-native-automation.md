# AWS Native Full Stack — Automation

**Terraform · AWS Native · build-your-infra**

---

## Introduction

This document covers the Terraform stack that composes all five aws-native
modules into a single deployable unit: hardening, dns, file-transfer,
web-server, and directory. Each module is declared as a `module` source
block pointing to its individual `automation/terraform/` folder. The
full-stack does not own any resources directly — it wires module outputs
to module inputs and provides a single entry point for greenfield
provisioning and full teardown.

The full-stack is a greenfield deploy. All individual module states have
been cleared via `terraform destroy` before this stack is used. No import
cycle is needed.

> **Prerequisites:** AWS CLI configured with the `multi-lab-admin` profile.
> Terraform `>= 1.15.6` installed locally. ACM certificate for the domain
> issued in `us-east-1` and in `ISSUED` state before apply.

---

## Terraform file layout

```bash
stacks/full-infra/aws-native/automation/terraform/
├── main.tf.example            # provider + all module blocks — rename to main.tf
├── outputs.tf.example         # stack-level outputs aggregated from modules — rename to outputs.tf
├── variables.tf               # all input declarations
└── terraform.tfvars.example   # copy to terraform.tfvars and fill in values
```

`main.tf` and `terraform.tfvars` are gitignored and never committed.

---

## Module scope

| Module | Resources owned |
|---|---|
| hardening | VPC, subnets, IGW, route tables, security groups, IAM roles, GuardDuty, CloudTrail, VPC Flow Logs, IMDSv2 defaults |
| dns | Route 53 Private Hosted Zone, A record, Resolver query logging |
| file-transfer | S3 transfer bucket, IAM role, Transfer Family server and user, SSH key |
| web-server | S3 origin bucket, CloudFront distribution + OAC, Route 53 public records |
| directory | Second private subnet, directory security group, Managed AD, DHCP Options Set, SNS topic |

> **Billing:** The Managed AD directory (`$0.10/h`) and Transfer Family
> server (`$0.30/h`) accrue charges from the moment `terraform apply`
> completes. Run `terraform destroy` immediately when the session ends.

---

## Phase 1 — Greenfield provisioning

---

## Step 1 — Prepare terraform.tfvars

### What was done

Copy the example file and fill in all values before any Terraform command.

```bash
cd stacks/full-infra/aws-native/automation/terraform
cp terraform.tfvars.example terraform.tfvars

# ── COMMAND 1: RETRIEVE OPERATOR PUBLIC IP (CIDR FORMAT) ──
# Fetches your current public IP natively from AWS endpoint
echo "$(curl -s https://checkip.amazonaws.com/)/32"

# ── COMMAND 2: DISCOVER ROUTE 53 PUBLIC HOSTED ZONE ID ──
# Filters by your apex domain name and strips the system prefix '/hostedzone/'
aws route53 list-hosted-zones-by-name \
  --dns-name "buildyourinfra.click" \
  --profile multi-lab-admin \
  --query "HostedZones[0].Id" \
  --output text | cut -d'/' -f3

# ── COMMAND 3: LOCATE PERSISTENT ELASTIC IP ALLOCATION ID ──
# Resolves the logical AllocationId using the standardized multi-lab resource tag
aws ec2 describe-addresses \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --filters "Name=tag:Name,Values=multi-lab-transfer-eip" \
  --query "Addresses[0].AllocationId" \
  --output text
```

Edit `terraform.tfvars` and supply every variable. The ACM certificate ARN,
domain name, SFTP public key, and AD admin password require out-of-band
lookup before apply.

📄 [`stacks/full-infra/aws-native/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)

### Why

`terraform.tfvars` contains account IDs, key material, and secrets. It is
gitignored and never committed. The `.example` file is the versionable
contract without sensitive values.

### Verification

```bash
grep -c "REPLACE_ME" terraform.tfvars
# 0 — no placeholders remaining
```

---

## Step 2 — Activate main.tf and outputs.tf

### What was done

There is no import cycle in the greenfield path. Activate both files
before running `terraform init`.

```bash
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf
```

📄 [`stacks/full-infra/aws-native/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`stacks/full-infra/aws-native/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)

### Why

Unlike the individual module docs where `main.tf.example` is activated
after an import cycle, the greenfield full-stack path activates `main.tf`
before the first apply. All module states are empty — there is nothing
to absorb. `main.tf` is the single source of truth from first apply.

> **Provider note:** `main.tf` declares two provider configurations — a
> default alias for `eu-west-1` and a `us_east_1` alias required by the
> web-server module. CloudFront requires ACM certificates to exist in
> `us-east-1` regardless of the primary region — this is an AWS
> platform constraint, not a design choice.

---

## Step 3 — Initialize the working directory

### What was done

```bash
terraform init
```

### Why

`terraform init` reads `required_providers` in `main.tf` and downloads
the AWS provider. Both provider aliases (`default` and `us_east_1`) are
registered in a single pass. State is kept local — no remote backend in
this lab.

### Verification

```bash
terraform init
# Terraform has been successfully initialized!
# provider registry.terraform.io/hashicorp/aws v6.x.x
```

---

## Step 4 — Plan

### What was done

```bash
terraform fmt
terraform validate
terraform plan -out aws-native.tfplan
```

### Why

`terraform plan` resolves all cross-module references before touching AWS.
The hardening module outputs (`vpc_id`, `public_subnet_id`,
`private_subnet_id`) are consumed by dns, file-transfer, web-server, and
directory. A clean plan confirms all variable bindings resolve correctly
before any resource is created.

The directory module is commented out in `main.tf` by default. Validate
the first four modules with a clean plan before enabling it.

> **ACM dependency:** the web-server module reads the ACM certificate via
> a `data` source — it must be in `ISSUED` state before plan or it will
> fail. Verify in the `us-east-1` console before proceeding.

> **`aws-native.tfplan` is gitignored** (`*.tfplan`) and never committed.

### Verification

```bash
terraform plan -out aws-native.tfplan
# Plan: N to add, 0 to change, 0 to destroy.
# Review the resource count — expected: all resources from all active modules.
```

---

## Step 5 — Apply

### What was done

```bash
terraform apply aws-native.tfplan
```

### Why

Apply creates all resources in dependency order. The hardening module
provisions the VPC and network topology first. The directory module is
last and has the longest provisioning time (~30 minutes). The `depends_on`
chain in `main.tf` enforces this order explicitly.

### Verification

```bash
terraform state list | wc -l
# Count matches the sum of all active module resource counts.

terraform output
# All stack-level outputs populated.

# Confirm CloudFront distribution deployed:
aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query 'DistributionList.Items[?Comment==`multi-lab-cf`].[DomainName,Status]' \
  --output table
# Status: Deployed

# Confirm Transfer Family server online:
aws transfer list-servers \
  --profile multi-lab-admin \
  --query 'Servers[*].[ServerId,State]' \
  --output table
# State: ONLINE
```

---

## Step 6 — Enable directory module

### What was done

Uncomment the `module "directory"` block in `main.tf`, then plan and apply.

```bash
terraform plan -out aws-native.tfplan
terraform apply aws-native.tfplan
```

### Why

The Managed AD directory is separated into a second apply to allow the
first four modules to be validated independently. Once the rest of the
stack is confirmed healthy, enabling the directory module adds the
remaining resources in a single targeted apply.

> **Billing starts immediately** on apply — Managed AD charges `$0.10/h`
> from creation regardless of usage.

### Verification

```bash
# Confirm Managed AD is Active (~30 min after apply):
aws ds describe-directories \
  --profile multi-lab-admin \
  --query 'DirectoryDescriptions[?Name==`multi-lab.internal`].[Name,Stage]' \
  --output table
# Stage: Active
```

---

## Phase 2 — Ongoing operations

---

## Step 7 — Destroy

### What was done

```bash
terraform destroy -auto-approve
```

### Why

`terraform destroy` reads the state file and deletes all resources in the
correct dependency order — directory and Transfer Family server before
their security groups and IAM roles, CloudFront before the S3 origin
bucket, subnets before the VPC. No orphaned resources remain after
destroy completes.

> **Warning:** `terraform destroy` deletes the Managed AD directory
> immediately. If any instance is domain-joined, leave the domain first:
>
> ```bash
> # On multi-lab-aws — if domain-joined:
> sudo realm leave multi-lab.internal
> ```

### Verification

```bash
terraform show
# The state file is empty. No resources.

aws ds describe-directories \
  --profile multi-lab-admin \
  --query 'DirectoryDescriptions[?Name==`multi-lab.internal`].[Name,Stage]' \
  --output text
# Empty — directory deleted or in Deleting state.
```

---

## Step 8 — Redeploy

### What was done

After destroy, reprovision the full stack from the `main.tf` definition.

```bash
terraform plan -out aws-native.tfplan
terraform apply aws-native.tfplan
```

### Why

All resource definitions are deterministic — bucket names, CIDR blocks,
AD domain, and CloudFront aliases are derived from variables. Redeploy
produces the same logical topology as the initial apply. Resources with
account-ID-suffixed names remain stable across destroy/redeploy cycles
because the account ID variable does not change.

### Verification

```bash
terraform state list | wc -l
# Same resource count as after Step 5 (or Step 6 with directory enabled).

terraform output
# All outputs repopulated.
```