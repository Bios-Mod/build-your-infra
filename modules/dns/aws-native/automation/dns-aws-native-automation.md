# DNS — AWS Native Automation

**Terraform · Route 53 Private Hosted Zone · build-your-infra**

---

## Introduction

This document covers the Terraform module that brings the Route 53 DNS
resources under code management. Terraform manages the Private Hosted Zone,
the A record for the EC2 instance, the Resolver Query Log configuration,
its VPC association, and the CloudWatch log group that receives DNS query logs.

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
modules/dns/aws-native/automation/terraform/
├── main.tf.example            # provider + data source + all resource blocks — rename to main.tf after import
├── outputs.tf.example         # DNS resource outputs — rename to outputs.tf after import
├── import.tf.example          # import blocks — copy to import.tf, fill in IDs, delete after apply
├── variables.tf               # all input declarations
└── terraform.tfvars.example   # copy to terraform.tfvars and fill in values
```

`main.tf`, `import.tf`, and `terraform.tfvars` are gitignored and never committed.

---

## Scope

| Resource | Terraform resource type |
|---|---|
| Route 53 Private Hosted Zone | `aws_route53_zone` |
| A record — `ec2.multi-lab.internal` | `aws_route53_record` |
| Resolver Query Log config | `aws_route53_resolver_query_log_config` |
| CloudWatch log group | `aws_cloudwatch_log_group` |
| Resolver Query Log — VPC association | `aws_route53_resolver_query_log_config_association` — created on first apply, not imported |

**Out of scope:** The NS and SOA records created automatically by Route 53 on
zone creation are not managed by Terraform — they are read-only records owned
by the service. The VPC (`multi-lab-vpc`) is referenced via a `data` source —
it is managed by the hardening module and not owned here.

> **Resolver Query Logging — teardown state:** Step 4 of
> [aws-native.md](../aws-native.md) disassociates the VPC from the query log
> config to stop variable billing between sessions. If the association was
> removed before this import cycle, skip importing
> `aws_route53_resolver_query_log_config_association` and omit that block
> from `main.tf`. Re-create the association on the next active session via
> `terraform apply`.

---

## Phase 1 — Import existing infrastructure

Steps 1–5 run once, the first time the module is brought under Terraform
control. The goal is to absorb all pre-existing DNS resources into state
without modifying them.

---

## Step 1 — Collect existing resource IDs

### What was done

All resources in this module were created manually. Before writing any HCL,
query the AWS API to collect the exact ID of every resource Terraform will
absorb. Record each value — they are the inputs for `import.tf`.

```bash
# Hosted Zone ID
aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='multi-lab.internal.'].Id" \
  --output text | awk -F'/' '{print $NF}'

# → Z0XXXXXXXXXXXXXXXXX

# → Z0XXXXXXXXXXXXXXXXX_ec2.multi-lab.internal_A
```

### Why

Import blocks require the exact provider-specific ID for each resource type.
The Route 53 record import ID is a compound string built from the zone ID,
the fully qualified domain name, and the record type — not an AWS-generated
identifier. Collecting all IDs before writing HCL prevents mismatches between
import blocks and live state.

---

## Step 2 — Prepare import.tf and terraform.tfvars

### What was done

Copy both example files and fill in the values collected in Step 1:

```bash
cd modules/dns/aws-native/automation/terraform/
cp import.tf.example import.tf
cp terraform.tfvars.example terraform.tfvars
```

Edit `import.tf` and replace every placeholder with the real resource ID.
Edit `terraform.tfvars` and fill in the values for your environment.

📄 [`modules/dns/aws-native/automation/terraform/import.tf.example`](terraform/import.tf.example)
📄 [`modules/dns/aws-native/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)

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
cd modules/dns/aws-native/automation/terraform/
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
# → provider registry.terraform.io/hashicorp/aws v5.x.x
```

---

## Step 4 — Generate resource configuration

### What was done

With `import.tf` and `terraform init` complete, generate the HCL resource
blocks by reading the live attributes of every imported resource from the
AWS API.

> **Before running:** open `import.tf` and replace the two placeholders with
> the real IDs collected in Step 1 — the zone ID and the compound A record ID.
> `terraform plan` will fail if any placeholder value remains.

```bash
terraform fmt
terraform validate
terraform plan -generate-config-out=generated.tf
```

### Why

Import blocks require the target resource to be declared in the configuration.
`-generate-config-out` produces `generated.tf` with valid HCL built from the
real resource attributes without writing resource blocks manually at this
stage. `generated.tf` is a working artifact deleted after the import apply
completes.

> **`generated.tf` is not committed to the repo.** It is gitignored.

### Fix generated.tf before applying (expected issues)

| Resource | Issue | Fix |
|---|---|---|
| `aws_route53_zone` | Generator may include read-only attributes (`zone_id`, `name_servers`, `primary_name_server`) | Remove read-only attributes — keep `name`, `comment`, `vpc` block |
| `aws_route53_record` | `records` attribute may be generated as a set literal | Verify it matches the actual A record IP |

### Verification

```bash
terraform plan
# → Plan: N to import, 0 to add, N to change, 0 to destroy.
# Exactly 0 to change — if not, reconcile diverging attributes in generated.tf
# before applying.
```

---

## Step 5 — Apply import

### What was done

Run `terraform apply` to absorb all pre-existing DNS resources into the
state file. No resources are created or modified — Terraform reads their
current attributes from the AWS API and writes them to state.

```bash
terraform apply
# When prompted, type: yes
```

### Why

`terraform apply` with only import blocks and no resource blocks performs
a pure import — it maps each AWS resource to a Terraform address in state
without touching the actual infrastructure.

### Verification

```bash
terraform state list
# aws_route53_record.ec2
# aws_route53_zone.internal
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

> **Before applying:** open `terraform.tfvars` and replace `ec2_private_ip`
> with the actual private IP of `multi-lab-aws`. The apply will fail if the
> placeholder value remains.

terraform plan -out dns.tfplan
terraform fmt
terraform validate
terraform apply "dns.tfplan"
```

📄 [`modules/dns/aws-native/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`modules/dns/aws-native/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)

### Why

### Why

Deleting `import.tf` removes the import blocks and the provider block that
lived there during Phase 1. `main.tf` takes over as the single source of
truth — it contains the provider block, the `data` source for the VPC, and
all resource definitions. A clean plan at this point confirms the import
cycle is complete.

> **Expected plan output:** `2 to import, 3 to add, 0 to change, 0 to destroy.`
> The two imported resources (zone and A record) are absorbed from existing
> state. The three logging resources (CloudWatch log group, Resolver Query Log
> config, and VPC association) do not exist in AWS — Terraform creates them
> on this apply. This is the expected outcome given the teardown executed in
> [aws-native.md](../aws-native.md) Step 4.

---

## Phase 2 — Ongoing operations

Steps 7–8 cover normal operation after the import cycle is complete.
`main.tf` and `terraform.tfvars` are in place. `import.tf` does not exist.

---

## Step 7 — Destroy

### What was done

Tear down all DNS resources managed by this module.

> **Warning:** destroying this module deletes the Private Hosted Zone and
> all records. Internal name resolution (`ec2.multi-lab.internal`) will
> stop working immediately. All modules that depend on DNS (web-server,
> directory) will lose internal name resolution. The zone carries a
> fixed cost of $0.50/month — destroying and recreating it does not reset
> billing.

```bash
terraform destroy -auto-approve
```

### Why

`terraform destroy` reads the state file and deletes resources in the
correct dependency order — the VPC association and records are removed
before the hosted zone itself, preventing Route 53 API errors on
non-empty zone deletion.

### Verification

```bash
terraform show
# → The state file is empty. No resources.

aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='multi-lab.internal.'].Name"
# → []
```

---

## Step 8 — Redeploy

### What was done

After destroy, reprovision all DNS resources from the `main.tf` definition.

```bash
terraform plan -out dns.tfplan
terraform apply dns.tfplan
```

### Why

Redeploy creates a new Private Hosted Zone with a new zone ID and
re-registers it against `multi-lab-vpc`. Route 53 assigns new NS servers —
these are internal AWS endpoints and have no public significance. All records
(`ec2.multi-lab.internal`) and the Resolver Query Logging config are also
re-created.

> **New zone ID:** the new Hosted Zone ID will differ from the original.
> Update `terraform.tfvars` if any variable references the old zone ID
> directly (not applicable with the current variable set, but check
> `stacks/full-infra/aws-native/` if the stack module references it).

> **`dns.tfplan` is gitignored** (`*.tfplan`) and never committed.

### Verification

```bash
terraform state list
# → same resources as after initial import

# Confirm zone is active and associated with the VPC
ZONE_ID=$(aws route53 list-hosted-zones \
>   --profile multi-lab-admin \
>   --query "HostedZones[?Name=='multi-lab.internal.'].Id | [0]" \
>   --output text | awk -F'/' '{print $NF}' | tee /dev/stderr)

aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='multi-lab.internal.'].{ID:Id,Private:Config.PrivateZone}"
# → "Private": true

# Confirm A record
aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile multi-lab-admin \
  --query "ResourceRecordSets[?Type=='A'].{Name:Name, IP:ResourceRecords[0].Value}" \
  --output table

# Confirm resolver query logging (if re-associated)
aws route53resolver list-resolver-query-log-config-associations \
  --profile multi-lab-admin \
  --query "ResolverQueryLogConfigAssociations[*].{VPC:ResourceId,Status:Status}"
  
# → "Status": "ACTIVE"
```