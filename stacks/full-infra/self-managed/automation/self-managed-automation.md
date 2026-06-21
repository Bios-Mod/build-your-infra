# Self-Managed Stack — Automation

**Terraform · EC2 · Ubuntu 24.04 LTS ARM64 · build-your-infra**

---

## Introduction

This document covers the Terraform stack that provisions the EC2 host for the
self-managed lab. Terraform manages the infrastructure layer: VPC, subnet,
internet gateway, route table, security group, key pair, Elastic IP, and EC2
instance launched from the active-directory AMI snapshot.

The configuration layer — OS hardening, SFTP, DNS, web server, Samba AD DC —
was applied manually and is documented per module. Terraform does not touch
the OS. The boundary between layers is explicit and intentional.

> **Prerequisites:** AWS CLI configured with the `multi-lab-admin` profile.
> Terraform >= 1.5 installed locally. The `multi-lab-aws-active-directory` AMI
> available in `eu-west-1`.

---

## Terraform file layout

```bash
stacks/full-infra/self-managed/automation/terraform/
├── main.tf.example            # provider + all resource blocks — rename to main.tf after import
├── outputs.tf.example         # instance outputs — rename to outputs.tf after import
├── import.tf.example          # import blocks — copy to import.tf, fill in IDs, delete after apply
├── variables.tf               # all input declarations
└── terraform.tfvars.example   # copy to terraform.tfvars and fill in values
```

`main.tf`, `import.tf`, and `terraform.tfvars` are gitignored and never committed.

---

## Phase 1 — Import existing infrastructure

Steps 1–5 run once, the first time the stack is brought under Terraform
control. The goal is to absorb all pre-existing AWS resources into state
without modifying them.

---

## Step 1 — Collect existing resource IDs

### What was done

All resources in this stack were created manually. Before writing any HCL,
query the AWS API to collect the real ID of every resource Terraform will
absorb. Each query uses the most reliable available filter for that resource
type. Record each ID — they are the values used in `import.tf`.

### Why

Import blocks require the exact provider-specific ID of each resource, not
the AWS name tag. Collecting IDs upfront before writing any HCL prevents
mismatches between import blocks and the actual state of the account.
These IDs are not committed to the repo.

### Verification

```bash
# Query VPC ID
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=multi-lab-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text --profile multi-lab-admin

# Query Subnet ID (use the last output here)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXX" "Name=cidr-block,Values=10.0.1.0/24" \
  --query "Subnets[0].SubnetId" \
  --output text --profile multi-lab-admin

# Query Internet Gateway ID
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=vpc-XXXXXXXX" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text --profile multi-lab-admin

# Query Route Table ID
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-XXXXXXXXXX" \
  --query "RouteTables[*].RouteTableId" \
  --output text \
  --profile multi-lab-admin

# Query Route Table Association ID
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxxxxxxxxxxx" "Name=tag:Name,Values=multi-lab-vpc-rtb-public" \
  --query "RouteTables[0].Associations[0].RouteTableAssociationId" \
  --output text --profile multi-lab-admin

# Query Security Group ID
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXX" "Name=group-name,Values=multi-lab-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text --profile multi-lab-admin

# Query EC2 Instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=multi-lab-aws" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --profile multi-lab-admin

# Query Elastic IP Allocation ID
aws ec2 describe-addresses \
  --filters "Name=domain,Values=vpc" \
  --query "Addresses[0].AllocationId" \
  --output text --profile multi-lab-admin

# EIP Association ID
aws ec2 describe-addresses \
  --filters "Name=allocation-id,Values=eipalloc-xxxxxxxxxxxxxxxxx" \
  --query "Addresses[0].AssociationId" \
  --output text --profile multi-lab-admin

# Query Custom AMI ID (multi-lab-aws-active-directory)
aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=multi-lab-aws-active-directory" \
  --query "Images[0].ImageId" \
  --output text --profile multi-lab-admin --region eu-west-1
```

---

## Step 2 — Prepare import.tf and terraform.tfvars

### What was done

Copy both example files and fill in the values collected in Step 1:

```bash
cp import.tf.example import.tf
cp terraform.tfvars.example terraform.tfvars
```

Edit `import.tf` and replace every placeholder with the real resource ID.
Edit `terraform.tfvars` and fill in the values for your environment —
`ami_id` must match the `multi-lab-aws-active-directory` AMI ID in `eu-west-1`.

📄 [`stacks/full-infra/self-managed/automation/terraform/import.tf.example`](terraform/import.tf.example)
📄 [`stacks/full-infra/self-managed/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)

### Why

`import.tf` and `terraform.tfvars` contain real account IDs and values —
both are gitignored and never committed. The `.example` files are the
versionable contract: they document every required input without exposing
real values. `import.tf` holds the provider block at this phase — `main.tf`
does not exist yet, which prevents Terraform from attempting to plan or apply
resource changes before the import cycle is complete.

---

## Step 3 — Initialize the working directory

### What was done

With `import.tf` in place, Terraform can now download the AWS provider plugin
and set up the local state backend.

```bash
cd stacks/full-infra/self-managed/automation/terraform/
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

With `import.tf` and `terraform init` complete, generate the resource blocks
by reading the live attributes of every imported resource directly from the
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

### Fix generated.tf before applying (expected errors)

The config generator is experimental. `generated.tf` cannot be applied as-is —
it produces conflicting or incomplete attributes that the AWS provider rejects.
**This is expected. Edit `generated.tf` manually before proceeding.**

#### Lines to delete

| Resource | Remove this line | Why |
|---|---|---|
| `aws_subnet.public` | `availability_zone_id = ...` | Conflicts with `availability_zone` |
| `aws_subnet.public` | `enable_lni_at_device_index = 0` | Invalid outside AWS Outposts |
| `aws_subnet.public` | `map_customer_owned_ip_on_launch = ...` | Requires `outpost_arn` — not applicable |
| `aws_vpc.main` | `ipv6_ipam_pool_id = ...` | Requires `ipv6_netmask_length` — remove both |
| `aws_vpc.main` | `ipv6_netmask_length = ...` | Remove if not using IPv6 IPAM |
| `aws_instance.main` | `primary_network_interface { ... }` block | Conflicts with `associate_public_ip_address` |
| `aws_instance.main` | `ipv6_address_count = ...` | Conflicts with `ipv6_addresses` — remove both |
| `aws_instance.main` | `ipv6_addresses = ...` | Remove both if not using IPv6 |
| `aws_eip_association.main` | `network_interface_id = ...` | Conflicts with `instance_id` — keep `instance_id` |

#### Line to add

`aws_key_pair.main` will be missing `public_key`. Add a placeholder — the value
is never sent to AWS during import:

```hcl
resource "aws_key_pair" "main" {
  # ... generated attributes ...
  public_key = "" # Required by provider schema — not applied during import
}
```

#### Add missing resource block

The generator fails to produce `aws_route_table_association` because the import
ID format is not a standard AWS resource ID. Add the block manually to
`generated.tf`:

```hcl
resource "aws_route_table_association" "public" {
  subnet_id      = "subnet-XXXXXXXXXX"   # your subnet ID
  route_table_id = "rtb-XXXXXXXXXX"      # your route table ID
}
```

Both IDs are already present in `generated.tf` — `subnet_id` from
`aws_subnet.public` and `route_table_id` from `aws_route_table.public`.

#### Fix aws_route_table.public

The generator produces `route = []`, ignoring existing routes. It also generates
incorrect tag values. Replace the block with the correct content:

```hcl
resource "aws_route_table" "public" {
  propagating_vgws = []
  region           = "eu-west-1"
  route = [{
    cidr_block                 = "0.0.0.0/0"
    gateway_id                 = "igw-XXXXXXXXXX"   # your IGW ID
    carrier_gateway_id         = null
    core_network_arn           = null
    destination_prefix_list_id = null
    egress_only_gateway_id     = null
    instance_id                = null
    ipv6_cidr_block            = null
    local_gateway_id           = null
    nat_gateway_id             = null
    network_interface_id       = null
    odb_network_arn            = null
    transit_gateway_id         = null
    vpc_endpoint_id            = null
    vpc_peering_connection_id  = null
  }]
  tags = {
    Name = "multi-lab-vpc-rtb-public"   # verify against AWS console
  }
  tags_all = {
    Name = "multi-lab-vpc-rtb-public"
  }
  vpc_id = "vpc-XXXXXXXXXX"   # your VPC ID
}
```

> **Verify the tag value** against the AWS console — the generator sometimes
> copies the wrong name. A tag mismatch causes a `1 to change` in the plan.

### Verification

```bash
terraform plan
# → Plan: 10 to import, 0 to add, 0 to change, 0 to destroy.
# Exactly 0 to change — if not, check tags and route blocks before applying.
```

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
# aws_eip.main
# aws_eip_association.main
# aws_instance.main
# aws_internet_gateway.main
# aws_key_pair.main
# aws_route_table.public
# aws_route_table_association.public
# aws_security_group.main
# aws_subnet.public
# aws_vpc.main
```

---

## Step 6 — Finalize state and activate main.tf

### What was done

Delete `import.tf` and rename `main.tf.example` to `main.tf`. Run a plan
to confirm state matches the configuration exactly.

```bash
rm import.tf generated.tf
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf

terraform plan
# → Plan: 1 to add, 1 to change, 1 to destroy.
```

> **Expected.** `main.tf` is the intended state, not a copy of the imported state.
> - **replace** `aws_key_pair` — placeholder `public_key = ""` replaced with real key.
> Instance access unaffected.
> - **change** `aws_eip` — adds name tag.

📄 [`stacks/full-infra/self-managed/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`stacks/full-infra/self-managed/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)

```bash
terraform apply -auto-approve
```

### Why

Deleting `import.tf` removes the import blocks and the provider block that
lived there during Phase 1. `main.tf` takes over as the single source of
truth — it contains the provider block and all resource definitions.
A clean plan at this point confirms the import cycle is complete: Terraform's
desired state matches the live infrastructure with zero drift.

If the plan shows diffs, reconcile the diverging attributes in `main.tf`
and re-run `plan` until the output is clean.

### Verification

```bash
terraform output
# → instance_public_ip = "X.X.X.X"
# → instance_id        = "i-xxxxxxxxxxxxxxxxx"
```

---

## Phase 2 — Ongoing operations

Steps 6–7 cover normal operation after the import cycle is complete.
`main.tf` and `terraform.tfvars` are in place. `import.tf` does not exist.

---

## Step 7 — Redeploy and Destroy

### What was done

Two operations share this step — both start with `terraform destroy`.

**Destroy only — tear down the full lab:**

```bash
terraform destroy -auto-approve
# Type: yes
```

**Redeploy from snapshot — reprovision from a known-good AMI:**

Update `ami_id` in `terraform.tfvars` to the target snapshot, then:

```bash
terraform plan -out self-managed.tfplan
terraform apply self-managed.tfplan
```

### Why

`terraform destroy` reads the state file and deletes every resource in the
correct dependency order — instance, EIP association, EIP, security group,
key pair, route table association, route table, subnet, internet gateway, VPC.
No orphaned resources remain in the account after destroy completes.

The redeploy path launches a new EC2 instance from the target AMI. The
`multi-lab-aws-active-directory` AMI already contains the full OS configuration
— hardening, SFTP, DNS, web server, Samba AD DC. Terraform provisions the
surrounding infrastructure and the OS comes up fully configured on first boot.
No post-boot provisioning is needed because the configuration layer lives in
the AMI.

> **Elastic IP:** after `terraform destroy` the EIP allocation is released. On
> re-apply a new EIP is allocated and associated. Any DNS records pointing to
> the old IP must be updated manually.

> **`self-managed.tfplan` is gitignored** (`*.tfplan`) and never committed.

### Verification

```bash
# Destroy
terraform destroy -auto-approve
# → Destroy complete! Resources: 10 destroyed.

terraform show
# → The state file is empty. No resources.
```