# Web Server — AWS Native

HTTPS static content delivery via S3 + CloudFront + ACM. S3 stores and
serves the content. CloudFront distributes it globally, terminates TLS at
the edge, and enforces HTTPS-only access. ACM provisions and auto-renews
the TLS certificate. No servers, no instances, no load balancers required.

> **Cost notice — billable services:** review current AWS pricing before
> deploying. Conditions below are accurate as of the time this lab was built.
>
> | Service | Billing model |
> |---|---|
> | ACM public certificate (non-exportable) | Free — no charge when used with CloudFront |
> | S3 | 5 GB storage + 20,000 GET requests/month free tier. Lab usage stays well within limits. |
> | CloudFront | 1 TB/month data transfer + 10M requests/month free tier. Lab traffic stays well within limits. |
> | Route 53 | Alias queries to CloudFront are free. Hosted zone $0.50/month — already active if the DNS module is deployed. |
>
> **This module has zero additional cost within AWS free tier limits.**

---

## Scope

| Layer | Resource |
|---|---|
| Edge / CDN | CloudFront distribution — HTTPS-only, HTTP redirect enforced |
| TLS termination | ACM public certificate (`us-east-1`) — auto-renewed |
| Origin | S3 bucket — private, accessible only via CloudFront OAC |
| Origin access | OAC (Origin Access Control) — SigV4 signed requests, distribution-scoped |
| Content | Static HTML — `modules/web-server/html/index.html` |
| Observability | CloudFront built-in metrics — CloudWatch (no additional setup required) |

---

## Relationship to Self-Managed

| Self-managed (Nginx) | AWS Native |
|---|---|
| Nginx serves static files from `/var/www/html` | S3 bucket serves static files |
| Let's Encrypt / certbot renewal | ACM auto-renewal — no cron, no intervention |
| Nginx `listen 443 ssl` | CloudFront HTTPS + ACM certificate |
| Nginx `return 301 https://` | CloudFront viewer protocol policy — redirect HTTP to HTTPS |
| UFW rule: allow 443 | S3 bucket policy — deny all except CloudFront OAC |
| Nginx `access_log` | CloudFront built-in metrics → CloudWatch |
| Manual cert rotation | ACM auto-renews 45 days before expiration |

---

## Step 1 — ACM Certificate

### What was done

Requested a public TLS certificate in `us-east-1` via AWS Certificate Manager
for `buildyourinfra.click`. CloudFront reads ACM certificates exclusively from
`us-east-1` — this is a platform constraint, not a configuration choice.

> **Pre-requisite — domain ownership required:** `buildyourinfra.click` must
> be registered and its Route 53 Public Hosted Zone must exist before
> proceeding. Domain registration is covered in this module — no prior
> module provides it.

> **If the DNS module is already deployed:** the Route 53 Public Hosted Zone
> for `buildyourinfra.click` already exists. The ACM validation CNAME will
> be added to that zone. No changes to the existing zone configuration are
> required.

**Console:**

ACM → **switch region to `us-east-1`** → Request certificate →
Request a public certificate:

| Parameter | Value |
|---|---|
| Fully qualified domain name | `buildyourinfra.click` |
| Additional name | `www.buildyourinfra.click` |
| Validation method | DNS validation |
| Key algorithm | RSA 2048 |

→ **Request**.

**DNS validation — add CNAME records:**

ACM → certificate ID → Domains table — a CNAME Name and CNAME Value appear
for each domain name.

> **Three possible outcomes:**
>
> **Scenario A — "Create records in Route 53" button appears:**
> ACM detected the Hosted Zone automatically. Click the button — records
> are added instantly. No manual action needed.
>
> **Scenario B — `Pending validation`, no button:**
> Add records manually. Route 53 → Hosted zones → `buildyourinfra.click`
> → Create record → Type: `CNAME` → paste CNAME Name as record name and
> CNAME Value as value → TTL: 300 → Save. Allow up to 30 minutes for
> the certificate to reach `Issued`.
>
> **Scenario C — certificate shows `Issued` immediately:**
> Validation CNAMEs were already present in the Hosted Zone (e.g. from a
> previous certificate request for the same domain). No action needed.

**CLI (alternative):**
```bash
aws acm request-certificate \
  --domain-name buildyourinfra.click \
  --subject-alternative-names www.buildyourinfra.click \
  --validation-method DNS \
  --region us-east-1 \
  --profile multi-lab-admin
# → "CertificateArn": "arn:aws:acm:us-east-1:<account-id>:certificate/<uuid>"
```

### Why

ACM eliminates TLS certificate operational burden: no private key storage,
no renewal scripts, no certbot cron jobs. Public non-exportable certificates
are free. DNS validation persists in Route 53 — ACM reuses the same CNAME
record on every auto-renewal without any manual intervention.

Only one certificate is needed. CloudFront is a global service that reads
ACM exclusively from `us-east-1`. There is no regional component in this
stack that requires a second certificate.

### Verification

```bash
aws acm describe-certificate \
  --certificate-arn <cert-arn-us-east-1> \
  --region us-east-1 \
  --profile multi-lab-admin \
  --query "Certificate.{Status:Status,Domain:DomainName}"
# → "Status": "ISSUED", "Domain": "buildyourinfra.click"
```

---

## Step 2 — S3 Origin Bucket

### What was done

Created a private S3 bucket `multi-lab-web-origin-<account-id>` and uploaded
`index.html`. The bucket policy locking access to CloudFront only is applied
automatically by AWS when the OAC is configured in Step 3.

**Console — create bucket:**

S3 → Create bucket:

| Parameter | Value |
|---|---|
| Bucket name | `multi-lab-web-origin-<account-id>` |
| Region | `eu-west-1` |
| Object ownership | ACLs disabled (recommended) |
| Block all public access | **Enabled** — all four options on |
| Versioning | Disabled |
| Encryption | SSE-S3 (default) |

→ **Create bucket**.

**Upload content:**

S3 → `multi-lab-web-origin-<account-id>` → Upload → Add files →
select `modules/web-server/html/index.html` → **Upload**.

**CLI (alternative):**
```bash
# Create bucket
aws s3api create-bucket \
  --bucket multi-lab-web-origin-<account-id> \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1 \
  --profile multi-lab-admin

# Block all public access
aws s3api put-public-access-block \
  --bucket multi-lab-web-origin-<account-id> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,\
    BlockPublicPolicy=true,RestrictPublicBuckets=true \
  --profile multi-lab-admin

# Upload index.html
aws s3 cp modules/web-server/html/index.html \
  s3://multi-lab-web-origin-<account-id>/index.html \
  --profile multi-lab-admin
```

### Why

S3 is the origin — it stores the content CloudFront distributes. Blocking
all public access at the bucket level is mandatory: direct S3 URL access
must return 403. The only authorized path to the content is through
CloudFront via OAC. Bucket name includes the account ID to guarantee global
uniqueness — S3 namespace is shared across all AWS accounts.

### Verification

```bash
# Confirm public access is blocked
aws s3api get-public-access-block \
  --bucket multi-lab-web-origin-<account-id> \
  --profile multi-lab-admin
# → BlockPublicAcls: true, IgnorePublicAcls: true,
#   BlockPublicPolicy: true, RestrictPublicBuckets: true

# Confirm content is present
aws s3 ls s3://multi-lab-web-origin-<account-id>/ \
  --profile multi-lab-admin

# → index.html
```

---

## Step 3 — CloudFront Distribution

### What was done

Created a CloudFront distribution using the new AWS wizard (6-step flow).
S3 is the origin. Private bucket access is enforced automatically via OAC.
TLS is terminated at the edge using the ACM certificate from `us-east-1`.
WAF is disabled — not required for static content delivery at lab scale.

> **Pre-requisite:** Step 1 (ACM certificate `us-east-1` — `Issued`) and
> Step 2 (S3 origin bucket with `index.html` uploaded) must be complete
> before proceeding.

**Console:**

CloudFront → Distributions → **Create distribution**.

---

**Wizard step 1 — Choose a plan:**

Select **Free** → **Next**.

---

**Wizard step 2 — Get started:**

| Parameter | Value |
|---|---|
| Distribution name | `multi-lab-cf` |
| Distribution type | Single website or app |
| Route 53 managed domain | `buildyourinfra.click` → click **Check domain** |

→ **Next**.

---

**Wizard step 3 — Specify origin:**

| Parameter | Value |
|---|---|
| Origin type | **Amazon S3** |
| S3 origin | `multi-lab-web-origin-<account-id>.s3.eu-west-1.amazonaws.com` |
| Origin path | *(leave empty)* |
| Allow private S3 bucket access to CloudFront | **Checked** *(Recommended)* |
| Origin settings | Use recommended origin settings |
| Cache settings | Use recommended cache settings tailored to serving S3 content |

> **"Allow private S3 bucket access to CloudFront"** is the new wizard
> equivalent of OAC (Origin Access Control). When checked, CloudFront
> automatically updates the S3 bucket policy to allow access exclusively
> from this distribution. No manual bucket policy editing required.

→ **Next**.

---

**Wizard step 4 — Enable security:**

| Parameter | Value |
|---|---|
| Use monitor mode (WAF) | **Unchecked** |
| Protection against Layer 7 DDoS attacks | Not available on Free plan — ignore |

> WAF is not required for static HTML delivery at lab scale. Leave all
> options unchecked and proceed.

→ **Next**.

---

**Wizard step 5 — Get TLS certificate:**

The ACM certificate for `buildyourinfra.click` appears automatically
under **Available certificates** — CloudFront detects it because it is
in `us-east-1` and covers the domain entered in wizard step 2.

| Parameter | Value |
|---|---|
| Certificate | `buildyourinfra.click (<certificate-id>)` — select it |

> If the certificate does not appear, click **Refresh certificates**.
> Confirm the certificate is in `us-east-1` and status is `Issued` before
> proceeding. Certificates in other regions are not listed here.

→ **Next**.

---

**Wizard step 6 — Review and create:**

Verify the summary reflects all values above → **Create distribution**.

Deployment takes 5–10 minutes. Status changes from *In Progress* to
*Deployed* when the distribution is ready.

### Why

The new CloudFront wizard abstracts OAC configuration behind the
*"Allow private S3 bucket access"* checkbox — the underlying mechanism
is identical: CloudFront writes a bucket policy scoped to the specific
distribution ARN using SigV4 signing. Direct S3 URL access returns 403.

WAF is excluded because the threat surface of a static S3-backed site
with no user input, no authentication, and no dynamic content does not
justify the added complexity. In a production environment with user-facing
forms or authenticated routes, WAF with at minimum the AWS Managed Rules
Core Rule Set would be required.

TLS termination at the CloudFront edge with the ACM certificate means
the viewer-to-CloudFront connection is encrypted end-to-end. The
CloudFront-to-S3 connection uses HTTPS by default via the S3 endpoint.

### Verification

```bash
# Get distribution domain name and ID
aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items[*].{ID:Id,Status:Status,Domain:DomainName}" \
  --output table

# → Status: "Deployed"
# → Domain: xxxxxxxxxxxx.cloudfront.net  ← use this value below, NOT the ID

# Test via CloudFront domain name (DNS step not yet done — use this URL)
curl -I https://<xxxxxxxxxxxx>.cloudfront.net
# → HTTP/2 200
# → x-cache: Miss from cloudfront
# → server: AmazonS3 via CloudFront

# Confirm S3 direct access is blocked
curl -I https://multi-lab-web-origin-<account-id>.s3.eu-west-1.amazonaws.com/index.html
# → HTTP/403 Forbidden

# Confirm OAC bucket policy was applied automatically
aws s3api get-bucket-policy \
  --bucket multi-lab-web-origin-<account-id> \
  --profile multi-lab-admin \
  --query Policy \
  --output text | python3 -m json.tool
# → "Principal": {"Service": "cloudfront.amazonaws.com"}
# → "Condition": {"StringEquals": {"AWS:SourceArn": "arn:aws:cloudfront::<account-id>:distribution/<id>"}}
```

---

## Step 4 — DNS

### What was done

Created Route 53 Alias records pointing `buildyourinfra.click` and
`www.buildyourinfra.click` to the CloudFront distribution.

> **If the DNS module is already deployed:** the Route 53 Public Hosted Zone
> for `buildyourinfra.click` already exists with NS and SOA records. Add the
> Alias records below to the existing zone — do not create a new zone.
>
> **If the DNS module is not deployed:** the Route 53 Public Hosted Zone was
> created automatically when the domain was registered. It is ready to use —
> no additional setup required before this step.

**Console:**

Route 53 → Hosted zones → `buildyourinfra.click` → Create record:

**Apex record (`buildyourinfra.click`):**

| Parameter | Value |
|---|---|
| Record name | *(leave empty — apex)* |
| Record type | A |
| Alias | **Yes** |
| Route traffic to | Alias to CloudFront distribution |
| Distribution | select `buildyourinfra.click` from the dropdown |

→ **Create records**.

**`www` record:**

| Parameter | Value |
|---|---|
| Record name | `www` |
| Record type | A |
| Alias | **Yes** |
| Route traffic to | Alias to CloudFront distribution |
| Distribution | select `buildyourinfra.click` from the dropdown |

→ **Create records**.

> **Alias vs CNAME:** Route 53 Alias records resolve the CloudFront domain
> without an extra DNS hop and are free for queries to AWS endpoints. The
> apex domain (`buildyourinfra.click`) cannot use a CNAME per RFC 1034 —
> Alias is the only valid option for the root domain.

**CLI (alternative):**
```bash
# Get the CloudFront distribution domain name
CF_DOMAIN=$(aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items.DomainName" \
  --output text)

# Get hosted zone ID
ZONE_ID=$(aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='buildyourinfra.click.'].Id" \
  --output text | awk -F'/' '{print $NF}')

# Create both alias records
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile multi-lab-admin \
  --change-batch "{
    \"Changes\": [
      {
        \"Action\": \"CREATE\",
        \"ResourceRecordSet\": {
          \"Name\": \"buildyourinfra.click\",
          \"Type\": \"A\",
          \"AliasTarget\": {
            \"HostedZoneId\": \"Z2FDTNDATAQYW2\",
            \"DNSName\": \"$CF_DOMAIN\",
            \"EvaluateTargetHealth\": false
          }
        }
      },
      {
        \"Action\": \"CREATE\",
        \"ResourceRecordSet\": {
          \"Name\": \"www.buildyourinfra.click\",
          \"Type\": \"A\",
          \"AliasTarget\": {
            \"HostedZoneId\": \"Z2FDTNDATAQYW2\",
            \"DNSName\": \"$CF_DOMAIN\",
            \"EvaluateTargetHealth\": false
          }
        }
      }
    ]
  }"
# → "Status": "INSYNC"
```

> `Z2FDTNDATAQYW2` is the fixed Route 53 Hosted Zone ID for all CloudFront
> distributions globally — it is not your zone ID. This value is constant
> and required for CloudFront Alias records.


> **Known gap:** The CloudFront wizard does not set `DefaultRootObject`.
> Without it, CloudFront requests `/` to S3 with no key — S3 returns 403.
> Always set it explicitly after creation.

```bash
# Fix missing DefaultRootObject (required if created via wizard or CLI without it)
aws cloudfront get-distribution-config \
  --id ELYETQLN17EQY \
  --profile multi-lab-admin > /tmp/cf-config.json

ETAG=$(cat /tmp/cf-config.json | python3 -c "import sys,json; print(json.load(sys.stdin)['ETag'])")

cat /tmp/cf-config.json | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['DistributionConfig']['DefaultRootObject'] = 'index.html'
print(json.dumps(d['DistributionConfig']))
" > /tmp/cf-config-fixed.json

aws cloudfront update-distribution \
  --id ELYETQLN17EQY \
  --distribution-config file:///tmp/cf-config-fixed.json \
  --if-match $ETAG \
  --profile multi-lab-admin \
  --query 'Distribution.Status'

# → "InProgress" — wait ~2 min then re-verify
```

> **Known gap:** The CloudFront wizard only adds the apex domain to
> `Aliases` (Alternate Domain Names). `www` must be added manually,
> otherwise CloudFront rejects the TLS handshake for `www` with
> `sslv3 alert handshake failure`. Additionally, the default ACM
> certificate only covers the apex — a new certificate with both
> `buildyourinfra.click` and `www.buildyourinfra.click` as SANs must
> be requested, issued, and associated to the distribution.

```bash
# Add www alias and update certificate in one operation
rm /tmp/cf-config.json /tmp/cf-config-fixed.json 2>/dev/null
aws cloudfront get-distribution-config \
  --id ELYETQLN17EQY \
  --profile multi-lab-admin > /tmp/cf-config.json

ETAG=$(cat /tmp/cf-config.json | python3 -c "import sys,json; print(json.load(sys.stdin)['ETag'])")

cat /tmp/cf-config.json | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['DistributionConfig']['Aliases']['Quantity'] = 2
d['DistributionConfig']['Aliases']['Items'] = ['buildyourinfra.click', 'www.buildyourinfra.click']
d['DistributionConfig']['ViewerCertificate']['ACMCertificateArn'] = 'arn:aws:acm:us-east-1:541801281490:certificate/c33f5761-3afe-47db-9750-1380671ce149'
d['DistributionConfig']['ViewerCertificate']['Certificate'] = 'arn:aws:acm:us-east-1:541801281490:certificate/c33f5761-3afe-47db-9750-1380671ce149'
print(json.dumps(d['DistributionConfig']))
" > /tmp/cf-config-fixed.json

aws cloudfront update-distribution \
  --id ELYETQLN17EQY \
  --distribution-config file:///tmp/cf-config-fixed.json \
  --if-match $ETAG \
  --profile multi-lab-admin \
  --query 'Distribution.Status'

# → "InProgress" — wait ~2 min
```

### Why

Alias records complete the resolution chain: `buildyourinfra.click` →
CloudFront edge IP → S3 origin. Without them the domain does not resolve
and the certificate cannot be verified end-to-end from a browser. The
CloudFront distribution already has `buildyourinfra.click` as an alternate
domain name (set in Step 3) — this step activates that mapping at the DNS
layer.

### Verification

```bash
# Confirm DNS resolves to CloudFront
dig buildyourinfra.click
# → ANSWER SECTION: buildyourinfra.click. A <CloudFront edge IP>

# End-to-end HTTPS test via custom domain
curl -I https://buildyourinfra.click
# → HTTP/2 200
# → via: 1.1 xxxxxxxxxxxx.cloudfront.net (CloudFront)
# → x-cache: Miss from cloudfront

# Confirm HTTP redirects to HTTPS
curl -I http://buildyourinfra.click
# → HTTP/1.1 301 Moved Permanently
# → Location: https://buildyourinfra.click/

# www also resolves
curl -I https://www.buildyourinfra.click
# → HTTP/2 200
```

---

## Step 5 — CloudFront Monitoring

### What was done

Verified CloudFront built-in metrics are active in CloudWatch. No setup
required — metrics are enabled automatically for every distribution.

**Console:**

CloudFront → Distributions → select distribution → **View Metrics** tab.

Available metrics without any additional configuration or cost:

| Metric | What it shows |
|---|---|
| Requests | Total requests served by the distribution |
| Bytes downloaded | Data transferred to viewers |
| Error rate (4xx / 5xx) | Percentage of requests returning client or server errors |
| Cache hit rate | Percentage of requests served from CloudFront edge vs. fetched from S3 |

> **Additional metrics (optional — $0.01/metric/month):**
> CloudFront → Distributions → select distribution → Monitoring →
> **Enable additional metrics** — adds origin latency, cache hit/miss
> breakdown by status code, and per-edge-location data.
> At lab scale this costs cents per month and is covered by free tier credits.
> Not required for this lab.

### Why

CloudFront built-in metrics provide the operational equivalent of Nginx
`access_log` analysis for a static site: total traffic volume, error rate,
and cache efficiency. Cache hit rate is the key metric for a CDN — a high
hit rate means content is being served from CloudFront edge nodes rather
than fetching from S3 on every request, which reduces latency and S3 API
costs. These metrics require zero configuration and are available immediately
after the distribution is deployed.

### Verification

```bash
# Confirm metrics are available via CLI
aws cloudwatch list-metrics \
  --namespace AWS/CloudFront \
  --dimensions Name=DistributionId,Value=<distribution-id> \
  --profile multi-lab-admin \
  --query "Metrics[*].MetricName"
# → ["Requests", "BytesDownloaded", "4xxErrorRate",
#    "5xxErrorRate", "TotalErrorRate"]

# Get request count for the last hour
aws cloudwatch get-metric-statistics \
  --namespace AWS/CloudFront \
  --metric-name Requests \
  --dimensions Name=DistributionId,Value=<distribution-id> \
                Name=Region,Value=Global \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Sum \
  --profile multi-lab-admin

# → "Sum": <number of requests in the last hour>
```

---

## Step 6 — Teardown

### What was done

Disabled and deleted all resources created in this module. Domain and Route 53
hosted zone are retained until the full lab is decommissioned.

> **What to delete vs. what to keep:**
>
> | Resource | Action | Reason |
> |---|---|---|
> | CloudFront distribution | **Disable → Delete** | No idle cost but clean decommission |
> | S3 origin bucket `multi-lab-web-origin-<account-id>` | **Delete** | Remove content and bucket |
> | ACM certificate `us-east-1` | **Delete** | Free but no longer needed |
> | Route 53 Alias records (A records for apex and www) | **Delete** | Domain stops resolving to deleted distribution |
> | Route 53 Hosted Zone | **Keep** | Required by other modules — $0.50/month flat |
> | Domain `buildyourinfra.click` | **Delete when full lab ends** | Route 53 → Registered domains → Delete |

> **CloudFront distributions must be disabled before they can be deleted.**
> Disable → wait until status changes to *Disabled* (~5 min) → then Delete.

**Console — disable and delete CloudFront distribution:**

CloudFront → Distributions → select distribution → **Disable** →
wait for *Disabled* status → **Delete**.

> A residual CloudFront distribution exists with an active
> pricing plan (created via the 6-step wizard). It cannot be deleted until the
> plan is cancelled and the monthly billing cycle ends. The distribution used
> for this lab is the standard one created afterwards. When tearing down:
> disable the standard distribution first, then cancel the wizard plan on the
> residual one and delete it at end of billing cycle.

**Console — delete S3 origin bucket:**

S3 → `multi-lab-web-origin-<account-id>` → **Empty** → confirm →
**Delete** → confirm.

**Console — delete ACM certificate:**

ACM → region `us-east-1` → select `buildyourinfra.click` certificate →
**Delete**.

**Console — delete Route 53 Alias records:**

Route 53 → Hosted zones → `buildyourinfra.click` → select the A records
for `buildyourinfra.click` and `www.buildyourinfra.click` → **Delete**.

**CLI (alternative):**
```bash
# Get distribution ID
DIST_ID=$(aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items.Id" \
  --output text)

# Get ETag and config, set Enabled: false
ETAG=$(aws cloudfront get-distribution-config \
  --id $DIST_ID --profile multi-lab-admin \
  --query ETag --output text)

aws cloudfront get-distribution-config \
  --id $DIST_ID --profile multi-lab-admin \
  --query DistributionConfig > /tmp/dist-config.json

# Edit /tmp/dist-config.json: set "Enabled": false — then apply
aws cloudfront update-distribution \
  --id $DIST_ID \
  --distribution-config file:///tmp/dist-config.json \
  --if-match $ETAG \
  --profile multi-lab-admin

# Wait for Disabled
aws cloudfront wait distribution-deployed \
  --id $DIST_ID --profile multi-lab-admin

# Delete distribution
NEW_ETAG=$(aws cloudfront get-distribution \
  --id $DIST_ID --profile multi-lab-admin \
  --query ETag --output text)

aws cloudfront delete-distribution \
  --id $DIST_ID --if-match $NEW_ETAG \
  --profile multi-lab-admin

# Empty and delete S3 bucket
aws s3 rm s3://multi-lab-web-origin-<account-id> \
  --recursive --profile multi-lab-admin
aws s3api delete-bucket \
  --bucket multi-lab-web-origin-<account-id> \
  --profile multi-lab-admin

# Delete ACM certificate
aws acm delete-certificate \
  --certificate-arn <cert-arn-us-east-1> \
  --region us-east-1 \
  --profile multi-lab-admin
```

### Why

CloudFront has no idle cost but deleting it confirms the module is fully
decommissioned and prevents dangling OAC references. The S3 origin bucket
has negligible idle cost but should be removed along with its content.
The ACM certificate is free — deleting it signals clean module teardown.
The Route 53 hosted zone and domain are retained because the DNS module and
future modules depend on them — only the web-server Alias records are removed.

### Verification

```bash
# Confirm distribution deleted
aws cloudfront list-distributions \
  --profile multi-lab-admin \
  --query "DistributionList.Items[*].Id"
# → [] (empty)

# Confirm S3 bucket deleted
aws s3 ls | grep multi-lab-web-origin
# → (no output)

# Confirm ACM cert deleted
aws acm list-certificates \
  --region us-east-1 \
  --profile multi-lab-admin \
  --query "CertificateSummaryList[*].DomainName"
  
# → [] or list without buildyourinfra.click

# Confirm DNS no longer resolves
dig buildyourinfra.click
# → NXDOMAIN or no ANSWER SECTION
```

---