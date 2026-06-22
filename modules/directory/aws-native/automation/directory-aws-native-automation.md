# Terraform AWS Directory Service — build-your-infra

This document covers the Terraform module that brings the AWS Directory Service
resources under code management. Terraform manages the second private subnet,
the directory security group, the Managed AD directory, the DHCP Options Set,
and its VPC association. All resources in this module were created manually
and documented in aws-native.md. This module imports the persistent resources
into state and manages the on-demand directory via apply/destroy.

**Prerequisites:** AWS CLI configured with the `multi-lab-admin` profile.
Terraform 1.5 installed locally. All steps in `aws-native.md` completed —
resources must exist before import.

---

## Terraform file layout

```bash
modules/directory/aws-native/automation/terraform/
  main.tf.example      # provider, data source, all resource blocks — rename to main.tf after import
  outputs.tf.example   # directory resource outputs — rename to outputs.tf after import
  import.tf.example    # import blocks — copy to import.tf, fill in IDs, delete after apply
  variables.tf         # all input declarations
  terraform.tfvars.example  # copy to terraform.tfvars and fill in values
```

`main.tf`, `import.tf`, and `terraform.tfvars` are gitignored and never committed.

---

## Scope

| Resource | Terraform resource type |
|---|---|
| Second private subnet (AZ-b) | `aws_subnet` |
| Directory security group | `aws_security_group` |
| Managed AD directory | `aws_directory_service_directory` |
| DHCP Options Set | `aws_vpc_dhcp_options` |
| DHCP VPC association | `aws_vpc_dhcp_options_association` |
| SNS topic — directory alerts | `aws_sns_topic` |

**Out of scope:** The VPC `multi-lab-vpc` is referenced via a data source — it is
managed by the hardening module and not owned here. The Route 53 PHZ and DHCP
Options Set teardown/restore cycle are documented in `aws-native.md` Steps 4
and 7 — when the DHCP association is restored to `AmazonProvidedDNS` before
teardown, skip importing `aws_vpc_dhcp_options_association` and omit it from
`main.tf`; re-create it on the next active session via `terraform apply`.

**Deploy-on-demand pattern:** The Managed AD directory bills at ~$0.10/hour
from creation. The directory, DHCP Options Set, and DHCP association follow
the same lifecycle — created on `terraform apply`, deleted on `terraform destroy`.
The security group and second subnet are persistent and imported once. Billing
stops only at deletion; there is no pause option.

---

## Phase 1 — Import existing infrastructure

> **Import not executed for this module.** All resources were deleted during
> the `aws-native.md` Step 7 teardown before this automation phase was
> implemented. There was no existing infrastructure to absorb into state.
> Terraform provisioned all resources from scratch in Step 6.
>
> Steps 1–5 are documented here as reference for any future scenario where
> directory resources exist prior to bringing this module under Terraform
> control — for example, if a directory session is active when the automation
> phase is initiated. `import.tf.example` contains all corresponding import
> blocks, commented out.

---

### Step 1 — Collect existing resource IDs

#### What was done

If directory resources exist before the import cycle, query the AWS API to
collect the exact ID of every resource Terraform will absorb. Record each
value — they are the inputs for `import.tf`.

```bash
# Second private subnet ID
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=multi-lab-private-2" \
  --query "Subnets.SubnetId" --output text \
  --profile multi-lab-admin

# Directory security group ID
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=multi-lab-directory-sg" \
  --query "SecurityGroups.GroupId" --output text \
  --profile multi-lab-admin

# Managed AD directory ID (empty if torn down)
aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions[?Name=='multi-lab.internal'].DirectoryId" \
  --output text

# DHCP Options Set ID (empty if deleted)
aws ec2 describe-dhcp-options \
  --filters "Name=tag:Name,Values=multi-lab-ad-dhcp" \
  --query "DhcpOptions.DhcpOptionsId" --output text \
  --profile multi-lab-admin

# SNS topic ARN
aws sns list-topics \
  --profile multi-lab-admin \
  --query "Topics[?contains(TopicArn,'multi-lab-directory-alerts')].TopicArn" \
  --output text
```

#### Why

Import blocks require the exact provider-specific ID for each resource type.
The directory uses an AWS-generated `d-` prefixed ID, the DHCP options set
uses a `dopt-` prefixed ID, and the SNS topic uses its ARN. Collecting all
IDs before writing HCL prevents mismatches between import blocks and live
state. These values are not committed to the repo.

---

### Step 2 — Prepare `import.tf` and `terraform.tfvars`

#### What was done

Copy both example files and fill in the values collected in Step 1.

```bash
cd modules/directory/aws-native/automation/terraform
cp import.tf.example import.tf
cp terraform.tfvars.example terraform.tfvars
```

Edit `import.tf` and replace every placeholder with the real resource ID.
Edit `terraform.tfvars` and fill in the values for your environment.

📄 [`modules/directory/aws-native/automation/terraform/import.tf.example`](terraform/import.tf.example)
📄 [`modules/directory/aws-native/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)


#### Why

`import.tf` and `terraform.tfvars` contain real account IDs and resource
identifiers — both are gitignored and never committed. The `.example` files
are the versionable contract — they document every required input without
exposing real values. `import.tf` holds the provider block at this phase —
`main.tf` does not exist yet, which prevents Terraform from attempting to
plan or apply resource changes before the import cycle is complete.

---

### Step 3 — Initialize the working directory

#### What was done

With `import.tf` in place, initialize the AWS provider and set up the local
state backend.

```bash
cd modules/directory/aws-native/automation/terraform
terraform init
```

#### Why

`terraform init` reads the `required_providers` block in `import.tf` and
downloads the matching provider version into `.terraform`. State is kept
local — no remote backend in this lab.

#### Verification

```bash
terraform init
# Terraform has been successfully initialized!
# provider registry.terraform.io/hashicorp/aws v6.x.x
```

---

### Step 4 — Generate resource configuration

#### What was done

With `import.tf` and `terraform init` complete, generate the HCL resource
blocks by reading the live attributes of every imported resource from the
AWS API. Before running, open `import.tf` and replace every placeholder with
the real IDs collected in Step 1. `terraform plan` will fail if any
placeholder value remains.

```bash
terraform fmt
terraform validate
terraform plan -generate-config-out=generated.tf
```

#### Why

Import blocks require the target resource to be declared in the configuration.
`-generate-config-out` produces `generated.tf` with valid HCL built from the
real resource attributes without writing resource blocks manually at this stage.
`generated.tf` is a working artifact — deleted after the import apply completes.
`generated.tf` is not committed to the repo — it is gitignored.

#### Fix `generated.tf` before applying — expected issues

| Resource | Issue | Fix |
|---|---|---|
| `aws_subnet` | Generator may include read-only attributes (`arn`, `id`, `owner_id`) | Remove read-only attributes — keep `vpc_id`, `cidr_block`, `availability_zone`, `tags` |
| `aws_security_group` | May include `name_prefix` conflicting with `name` | Keep `name` only, remove `name_prefix` |
| `aws_security_group` | `ingress` blocks may not fully serialize UDP+TCP pairs | Verify all 14 inbound rules are present |
| `aws_directory_service_directory` | Generates read-only attributes (`security_group_id`, `dns_ip_addresses`) | Remove read-only attributes — keep `name`, `short_name`, `size`, `vpc_settings`, `tags` |
| `aws_directory_service_directory` | `password` is write-only — generator cannot read it | Add `password = var.ad_admin_password` manually |
| `aws_vpc_dhcp_options` | May include `owner_id` | Remove `owner_id` — keep `domain_name`, `domain_name_servers`, `tags` |

#### Verification

```bash
terraform plan
# Plan: N to import, 0 to add, 0 to change, 0 to destroy.
# Exactly 0 to change — if not, reconcile diverging attributes in generated.tf before applying.
```

---

### Step 5 — Apply import

#### What was done

Run `terraform apply` to absorb all pre-existing directory resources into the
state file. No resources are created or modified — Terraform reads their
current attributes from the AWS API and writes them to state.

```bash
terraform apply
# When prompted, type yes
```

#### Why

`terraform apply` with only import blocks and no resource blocks performs a
pure import — it maps each AWS resource to a Terraform address in state
without touching the actual infrastructure. This is the correct boundary:
state is populated, infra is untouched.

#### Verification

```bash
terraform state list
# aws_directory_service_directory.main   ← only if directory existed at import time
# aws_security_group.directory
# aws_sns_topic.directory_alerts
# aws_subnet.private_2
# aws_vpc_dhcp_options.ad              ← only if DHCP options existed at import time
# aws_vpc_dhcp_options_association.ad  ← only if association was active at import time
```

---

### Step 6 — Finalize state and activate `main.tf`

#### What was done

Delete `import.tf` and `generated.tf`, then copy `main.tf.example` to
`main.tf`. Run a plan to confirm state matches the configuration exactly.

```bash
terraform init

rm import.tf generated.tf
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf
terraform fmt
terraform validate
terraform plan -out directory.tfplan
terraform apply directory.tfplan
```

📄 [`modules/directory/aws-native/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`modules/directory/aws-native/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)


#### Why

Deleting `import.tf` removes the import blocks and the provider block that
lived there during Phase 1. `main.tf` takes over as the single source of
truth — it contains the provider block, the data source for the VPC, and all
resource definitions. A clean plan at this point confirms the import cycle is
complete.

Expected plan output — if the directory was torn down before import: the
persistent layer (subnet, security group, SNS topic) shows `0 to change`.
The Managed AD directory, DHCP Options Set, and DHCP association show `3 to
add` — they will be created on this apply. This is the expected outcome
given the teardown executed in `aws-native.md` Step 7.

> **Billing starts on apply.** The directory begins accruing charges
> (~$0.10/hour) immediately when `terraform apply` creates it.

#### Verification

```bash
terraform state list

# aws_directory_service_directory.main
# aws_security_group.directory
# aws_sns_topic.directory_alerts
# aws_subnet.private_2
# aws_vpc_dhcp_options.ad
# aws_vpc_dhcp_options_association.ad

aws ds describe-directories \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --query "DirectoryDescriptions[*].{Name:Name,Stage:Stage,DNS:join(', ', DnsIpAddrs)}" \
  --output table

# Stage: Active
```

---

## Phase 2 — Ongoing operations

Steps 7–8 cover normal operation after the import cycle is complete.
`main.tf` and `terraform.tfvars` are in place. `import.tf` does not exist.

---

### Step 7 — Destroy

#### What was done

Tear down all directory resources managed by this module to stop Managed AD
billing.

> **Warning:** `terraform destroy` deletes the Managed AD directory immediately —
> billing stops at the next hourly boundary. The DHCP association is removed
> and the VPC reverts to `AmazonProvidedDNS` as part of the destroy sequence.
>
> **Note:** If you are running `terraform destroy` on a fresh greenfield deployment 
> where no EC2 instances have been domain-joined yet, you can safely skip the 
> `realm leave` command and proceed directly with the teardown.

```bash
# On multi-lab-aws — leave the domain before destroying the directory
sudo realm leave multi-lab.internal

# Destroy all module resources
terraform destroy -auto-approve
```

#### Why

`terraform destroy` reads the state file and deletes resources in the correct
dependency order — DHCP association before DHCP Options Set, directory before
security group. The `aws_vpc_dhcp_options_association` removal automatically
restores the VPC to `AmazonProvidedDNS`, eliminating the manual CLI step
documented in `aws-native.md` Step 7.2. The subnet and security group are
also destroyed — they are re-created on redeploy from the `main.tf` definition.

#### Verification

```bash
terraform show
# The state file is empty. No resources.

aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions[*].{Name:Name,Stage:Stage}"

# → []  (empty — directory deleted or in Deleting state)

# Confirm DNS restored on multi-lab-aws
resolvectl status | grep "DNS Servers"
# → DNS Servers: 169.254.169.253   ← AmazonProvidedDNS
```

---

### Step 8 — Redeploy

#### What was done

After destroy, reprovision all resources from the `main.tf` definition.

```bash
terraform plan -out directory.tfplan
terraform apply directory.tfplan
```

#### Why

Redeploy creates a new Managed AD directory with a new directory ID and new
DC IP addresses. The DHCP Options Set is re-created with the new DC IPs —
`terraform.tfvars` must not hardcode the DC IPs directly; they are read from
`aws_directory_service_directory.main.dns_ip_addresses` as a Terraform reference
in `main.tf`. The second subnet and security group are also re-created from
their definitions — CIDR and AZ assignments are deterministic, so no
post-deploy configuration changes are required.

`directory.tfplan` is gitignored (`.tfplan`) and never committed.

#### Verification

```bash
terraform state list
# aws_directory_service_directory.main
# aws_security_group.directory
# aws_sns_topic.directory_alerts
# aws_subnet.private_2
# aws_vpc_dhcp_options.ad
# aws_vpc_dhcp_options_association.ad

aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions.{Name:Name,Stage:Stage,DNS:DnsIpAddrs,Edition:Edition}" \
  --output table
# Stage: Active  Edition: Standard  DNS: [new DC IPs]

# Verify DHCP options updated on VPC
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=multi-lab-vpc" \
  --query "Vpcs.{VPC:VpcId,DHCP:DhcpOptionsId}" \
  --profile multi-lab-admin
# → DhcpOptionsId matches new DHCP options set

# Verify DNS on multi-lab-aws after DHCP lease renewal
sudo dhcpcd -n ens5
resolvectl status | grep "DNS Servers"
# → DNS Servers: <new-DC-IP-1> <new-DC-IP-2>
```