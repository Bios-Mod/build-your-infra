# Web Server — AWS Native Automation

**Terraform · S3 · CloudFront · ACM · build-your-infra**

---

## Introduction

This document covers the Terraform module that brings the web server stack
under code management. Terraform manages the full delivery chain: ACM
certificate in `us-east-1`, S3 origin bucket with OAC bucket policy, and
the CloudFront distribution with its Route 53 Alias records.

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
modules/web-server/aws-native/automation/terraform/
├── main.tf.example            # provider aliases + data sources + all resource blocks — rename to main.tf after import
├── outputs.tf.example         # web server resource outputs — rename to outputs.tf after import
├── import.tf.example          # import blocks — copy to import.tf, fill in IDs, delete after apply
├── variables.tf               # all input declarations
└── terraform.tfvars.example   # copy to terraform.tfvars and fill in values
```

`main.tf`, `import.tf`, and `terraform.tfvars` are gitignored and never committed.

---

## Scope

| Resource | Terraform resource type |
|---|---|
| ACM certificate — `buildyourinfra.click` + `www` | `aws_acm_certificate` |
| S3 origin bucket | `aws_s3_bucket` |
| S3 Block Public Access | `aws_s3_bucket_public_access_block` |
| S3 bucket policy — OAC | `aws_s3_bucket_policy` |
| CloudFront distribution | `aws_cloudfront_distribution` |
| Route 53 Alias — apex | `aws_route53_record` |
| Route 53 Alias — www | `aws_route53_record` |

**Out of scope:** The Route 53 Public Hosted Zone and domain registration are
not managed here — they were created during the DNS module and domain setup.
The Zone is referenced via a `data` source. CloudFront built-in metrics are
automatic — no Terraform resource required.

> **Provider aliasing — mandatory context:** ACM certificates for CloudFront
> must be in `us-east-1`. This module declares two provider aliases:
> `aws` (default) for `eu-west-1` resources, and `aws.us_east_1` for the
> ACM certificate. Every resource block that targets ACM must include
> `provider = aws.us_east_1`. This is the defining complexity of this module.

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
# ACM certificate ARN (us-east-1 — required for CloudFront)
aws acm list-certificates \
  --region us-east-1 \
  --profile multi-lab-admin \
  --query "CertificateSummaryList[?DomainName=='buildyourinfra.click'].CertificateArn" \
  --output text

# → arn:aws:acm:us-east-1:<account-id>:certificate/<uuid>

# S3 origin bucket name
aws s3api list-buckets \
  --profile multi-lab-admin \
  --query "Buckets[?contains(Name, 'multi-lab')].Name" \
  --output text

# → multi-lab-web-origin-<account-id>

# CloudFront distribution ID
aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items[?Aliases.Items=='buildyourinfra.click'].Id" \
  --output text

# → EXXXXXXXXXXXX

# Route 53 Public Hosted Zone ID (for compound record import IDs)
aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='buildyourinfra.click.'].Id" \
  --output text | awk -F'/' '{print $NF}'

# → ZXXXXXXXXXXXXXXXXX

# Verify apex A record exists (import ID: <ZONE_ID>_buildyourinfra.click_A)
aws route53 list-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --profile multi-lab-admin \
  --query "ResourceRecordSets[?Type=='A'].Name" \
  --output table

# → buildyourinfra.click.
# → www.buildyourinfra.click.

# OAC ID
aws cloudfront list-origin-access-controls \
  --profile multi-lab-admin \
  --query "OriginAccessControlList.Items[*].{ID:Id,Name:Name}" \
  --output table
```

### Why

Import blocks require the exact provider-specific ID for each resource type.
ACM uses the certificate ARN, S3 resources use the bucket name, CloudFront
uses the distribution ID, and Route 53 records use a compound string
(`ZONE_ID_FQDN_TYPE`). The ACM certificate must be queried from `us-east-1`
explicitly — it is invisible to the default `eu-west-1` API endpoint.
Collecting all IDs before writing HCL prevents mismatches between import
blocks and live state.

---

## Step 2 — Prepare import.tf and terraform.tfvars

### What was done

Copy both example files and fill in the values collected in Step 1:

```bash
cd modules/web-server/aws-native/automation/terraform/
cp import.tf.example import.tf
cp terraform.tfvars.example terraform.tfvars
```

Edit `import.tf` and replace every placeholder with the real resource ID.
Edit `terraform.tfvars` and fill in the values for your environment.

📄 [`modules/web-server/aws-native/automation/terraform/import.tf.example`](terraform/import.tf.example)
📄 [`modules/web-server/aws-native/automation/terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)

### Why

`import.tf` and `terraform.tfvars` contain real account IDs and ARNs —
both are gitignored and never committed. The `.example` files are the
versionable contract: they document every required input without exposing
real values. `import.tf` holds both provider alias declarations at this
phase — `main.tf` does not exist yet, which prevents Terraform from
attempting to plan or apply resource changes before the import cycle
is complete.

---

## Step 3 — Initialize the working directory

### What was done

With `import.tf` in place, initialize the AWS provider and set up the local
state backend.

```bash
cd modules/web-server/aws-native/automation/terraform/
terraform init
```

### Why

`terraform init` reads the `required_providers` block in `import.tf` and
downloads the matching provider version into `.terraform/`. Both provider
aliases share the same AWS provider binary — no additional download is
required for `aws.us_east_1`. State is kept local — no remote backend
in this lab.

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
| `aws_acm_certificate` | Generator may omit `provider = aws.us_east_1` | Add `provider = aws.us_east_1` to the resource block — without it Terraform will query `eu-west-1` and fail to find the cert |
| `aws_acm_certificate` | May include read-only attributes (`arn`, `status`, `domain_validation_options`) | Remove read-only attributes — keep `domain_name`, `subject_alternative_names`, `validation_method`, `key_algorithm`, `tags` |
| `aws_s3_bucket` | Generator may include read-only attributes (`bucket_domain_name`, `hosted_zone_id`, `region`) | Remove read-only attributes — keep `bucket`, `tags` |
| `aws_s3_bucket_public_access_block` | May omit the `bucket` reference | Verify it references `aws_s3_bucket.web_origin.id` |
| `aws_s3_bucket_policy` | `policy` generated as escaped JSON string | Verify it is valid JSON — the OAC condition must reference the CloudFront distribution ARN |
| `aws_cloudfront_distribution` | Generates all attributes including read-only `arn`, `domain_name`, `etag`, `hosted_zone_id`, `id`, `last_modified_time`, `status` | Remove all read-only attributes. Keep `aliases`, `default_cache_behavior`, `viewer_certificate`, `origin`, `restrictions`, `default_root_object`, `enabled`, `http_version`, `price_class`, `tags` |
| `aws_route53_record` | `alias` block may omit `evaluate_target_health` | Add `evaluate_target_health = false` — required by provider |

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

# aws_acm_certificate.main
# aws_cloudfront_distribution.main
# aws_route53_record.apex
# aws_route53_record.www
# aws_s3_bucket.web_origin
# aws_s3_bucket_policy.web_origin
# aws_s3_bucket_public_access_block.web_origin
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
terraform plan -out web-server.tfplan
terraform apply "web-server.tfplan"
```

📄 [`modules/web-server/aws-native/automation/terraform/main.tf.example`](terraform/main.tf.example)
📄 [`modules/web-server/aws-native/automation/terraform/outputs.tf.example`](terraform/outputs.tf.example)

### Why

Deleting `import.tf` removes the import blocks and the provider alias
declarations that lived there during Phase 1. `main.tf` takes over as
the single source of truth — it contains both provider alias blocks and
all resource definitions. A clean plan at this point confirms the import
cycle is complete: Terraform's desired state matches the live configuration
with zero drift.

If the plan shows diffs, reconcile the diverging attributes in `main.tf`
and re-run `plan` until the output is clean.

### Verification

```bash
terraform state list

# aws_acm_certificate.main
# aws_cloudfront_distribution.main
# aws_route53_record.apex
# aws_route53_record.www
# aws_s3_bucket.web_origin
# aws_s3_bucket_policy.web_origin
# aws_s3_bucket_public_access_block.web_origin

# Confirm the site is still live
curl -I https://buildyourinfra.click
# → HTTP/2 200
# → via: 1.1 xxxxxxxxxxxx.cloudfront.net (CloudFront)
```

---

## Phase 2 — Ongoing operations

Steps 7–8 cover normal operation after the import cycle is complete.
`main.tf` and `terraform.tfvars` are in place. `import.tf` does not exist.

---

## Step 7 — Destroy

### What was done

Tear down all resources managed by this module.

> **Warning:** `terraform destroy` disables and deletes the CloudFront
> distribution, deletes the S3 origin bucket and its content, deletes the
> ACM certificate, and removes the Route 53 Alias records.
> `buildyourinfra.click` will stop resolving immediately. The Route 53
> Public Hosted Zone is not managed by this module and is not affected.

> **CloudFront destroy order:** Terraform disables the distribution and
> waits for `Disabled` status before deleting it. This takes approximately
> 5 minutes. Do not interrupt the destroy process.

```bash
terraform destroy -auto-approve
```

### Why

`terraform destroy` reads the state file and deletes resources in the
correct dependency order — Route 53 records before CloudFront, CloudFront
before S3 bucket policy, S3 objects before the bucket, ACM certificate last.
No orphaned resources remain after destroy completes.

### Verification

```bash
terraform show
# → The state file is empty. No resources.

aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items[*].Id"
# → [] (empty)

aws s3 ls | grep multi-lab-web-origin
# → (no output)

dig buildyourinfra.click
# → NXDOMAIN or no ANSWER SECTION
```

---

## Step 8 — Redeploy

### What was done

After destroy, reprovision all resources from the `main.tf` definition.

> **Before applying:** a new ACM certificate request will trigger DNS
> validation. The CNAME records must already be in the Route 53 Public
> Hosted Zone — if they were deleted with the previous certificate, add
> them again before running apply or the certificate will stay in
> `PENDING_VALIDATION`. The apply will proceed but the distribution will
> not reach `Deployed` status until the certificate is `Issued`.

```bash
terraform plan -out web-server.tfplan
terraform apply web-server.tfplan
```

### Why

Redeploy creates a new CloudFront distribution with a new distribution ID
and a new `*.cloudfront.net` domain. The Route 53 Alias records are
re-created pointing to the new distribution. The ACM certificate is
re-requested — DNS validation reuses the same CNAME records in Route 53
if they were not deleted, so re-issuance is typically automatic. The S3
bucket name is deterministic (`multi-lab-web-origin-<account-id>`) — no
client-side configuration changes are required for the origin.

> **`web-server.tfplan` is gitignored** (`*.tfplan`) and never committed.

### Verification

```bash
terraform state list
# → same 7 resources as after initial import

aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items[*].{ID:Id,Status:Status,Domain:DomainName}" \
  --output table
# → Status: "Deployed"

curl -I https://buildyourinfra.click
# → HTTP/2 200
# → via: 1.1 xxxxxxxxxxxx.cloudfront.net (CloudFront)

curl -I http://buildyourinfra.click
# → HTTP/1.1 301 Moved Permanently
# → Location: https://buildyourinfra.click/
```