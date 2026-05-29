# File Transfer — AWS Native

AWS Transfer Family managed SFTP endpoint with S3 backend, scoped IAM role,
CloudWatch Logs delivery, and a dedicated Security Group. Requires the base
environment and hardening module completed before applying this module.

> **Cost notice:** AWS Transfer Family has no Free Tier. The SFTP endpoint
> is billed at **$0.30/hour** regardless of transfer activity — cost begins
> at creation and stops only after deletion. This module uses a
> **deploy-on-demand** strategy: create the endpoint, complete all
> verification steps, then delete it. A full session of 1–2 hours costs
> under $1.00. Do not leave the endpoint running unattended.

---

## Scope

| Layer | Resource |
|---|---|
| Endpoint | AWS Transfer Family — SFTP protocol only |
| Backend | S3 bucket `multi-lab-transfer-<account-id>` |
| Auth | SSH public key — no password path |
| Access control | Security Group — port 22 restricted to operator IP |
| IAM | Scoped role allowing Transfer Family to write to S3 only |
| Observability | CloudWatch Logs — structured SFTP session and error logs |

---

## Relationship to Self-Managed

| Self-managed | AWS Native |
|---|---|
| OpenSSH internal-sftp subsystem | AWS Transfer Family managed endpoint |
| Dedicated `sftpuser` system account | Transfer Family logical user |
| Chroot jail (`/srv/sftp/sftpuser/`) | S3 bucket prefix scope (`/uploads`) |
| UFW allow on `wg0` + port 22222 | Security Group restrict to operator IP on port 22 |
| `internal-sftp -l VERBOSE` syslog | CloudWatch Logs group `/aws/transfer/multi-lab-transfer` |
| auditd `-w /srv/sftp/` | S3 server access logging + CloudTrail S3 data events |
| Ed25519 key-based auth only | SSH public key stored in Transfer Family logical user |

---

## Step 1 — S3 Bucket

### What was done

Created a dedicated S3 bucket `multi-lab-transfer-<account-id>` to serve as
the SFTP backend. Block Public Access enabled on all four settings. Bucket
versioning enabled to preserve overwritten files.

**Console**

S3 → Create bucket:

| Parameter | Value |
|---|---|
| Bucket name | `multi-lab-transfer-<account-id>` |
| Region | `eu-west-1` |
| Bucket type | General purpose |
| Object ownership | ACLs disabled — Bucket owner enforced |
| Block all public access | Enabled (all four options) |
| Bucket versioning | Enabled |
| Default encryption | SSE-S3 (enabled by default) |


> Replace `<account-id>` with the 12-digit AWS account ID. S3 bucket names
> are globally unique — including the account ID avoids collisions and makes
> ownership explicit.

> **Versioning:** preserves previous versions of overwritten or deleted
> objects. For a lab SFTP backend, it provides a simple recovery path without
> requiring a separate backup mechanism. Objects accumulate storage costs only
> if files are actively overwritten — negligible at lab scale.

### Why

A dedicated bucket isolates SFTP data from all other S3 resources in the
account. Block Public Access prevents any future policy misconfiguration from
accidentally exposing objects. SSE-S3 encrypts objects at rest with
AWS-managed keys — no additional configuration or cost. Versioning means a
mistaken `rm` or overwrite during testing is recoverable.

### Verification

**CLI**
```bash
aws s3api get-bucket-location \
  --bucket multi-lab-transfer-<account-id> \
  --profile multi-lab-admin
# → "LocationConstraint": "eu-west-1"

aws s3api get-public-access-block \
  --bucket multi-lab-transfer-<account-id> \
  --profile multi-lab-admin
# → all four fields: true

aws s3api get-bucket-versioning \
  --bucket multi-lab-transfer-<account-id> \
  --profile multi-lab-admin
# → "Status": "Enabled"
```

---

## Step 2 — IAM Role for Transfer Family

### What was done

Created IAM role `multi-lab-transfer-role` with a trust policy scoped to the
Transfer Family service principal and an inline policy granting S3 access
limited to the SFTP bucket only.

**Console**

IAM → Roles → Create role:

- Trusted entity type: **Custom trust policy** → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Service": "transfer.amazonaws.com"
    },
    "Action": "sts:AssumeRole"
  }]
}
```

- Permissions step: leave empty → skip to next.
- Role name: `multi-lab-transfer-role` → **Create role**.

Once created, attach the inline policy:

IAM → Roles → `multi-lab-transfer-role` → Permissions → Add permissions →
Create inline policy → JSON tab → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::multi-lab-transfer-<account-id>"
    },
    {
      "Sid": "AllowObjectOperations",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::multi-lab-transfer-<account-id>/*"
    }
  ]
}
```

Policy name: `multi-lab-transfer-s3-policy` → **Create policy**.

### Why

Transfer Family assumes this role when writing to S3 on behalf of the
authenticated SFTP user — it requires `sts:AssumeRole` permission granted
explicitly via the trust policy. The inline policy follows least privilege:
`ListBucket` scoped to the bucket ARN (not `/*`) is required for directory
listings; object operations are scoped to the bucket prefix. No access to
other S3 buckets, IAM, EC2, or any other service is granted.

### Verification

**CLI**
```bash
aws iam get-role \
  --role-name multi-lab-transfer-role \
  --profile multi-lab-admin \
  --query "Role.AssumeRolePolicyDocument.Statement[0].Principal"
# → { "Service": "transfer.amazonaws.com" }

aws iam list-role-policies \
  --role-name multi-lab-transfer-role \
  --profile multi-lab-admin
# → "PolicyNames": ["multi-lab-transfer-s3-policy"]
```

---

## Step 3 — Security Group

### What was done

Created Security Group `multi-lab-transfer-sg` with a single inbound rule
allowing SFTP (TCP 22) from the operator's IP only.

**Console**

VPC → Security Groups → Create security group:

| Parameter | Value |
|---|---|
| Name | `multi-lab-transfer-sg` |
| Description | SFTP access — operator IP only |
| VPC | `multi-lab-vpc` |

Inbound rules → Add rule:

| Type | Protocol | Port | Source |
|---|---|---|---|
| Custom TCP | TCP | 22 | `<your-public-ip>/32` |

> Replace `<your-public-ip>` with your current public IP. Use
> `curl -s https://checkip.amazonaws.com` to retrieve it. The `/32` suffix
> restricts access to a single host — no range, no `0.0.0.0/0`.

Outbound rules: leave default (allow all) — Transfer Family needs outbound
to reach S3 and CloudWatch Logs within AWS.

> **Transfer Family uses port 22**, not a custom port like the self-managed
> setup (22222). The Security Group is the only network-layer restriction —
> there is no OS-level firewall to configure.

### Why

The Security Group is the sole network perimeter for the Transfer Family
endpoint. Without it, the SFTP endpoint is reachable from any IP on the
internet — authenticated only by public key. Restricting to a single source
IP eliminates the brute-force surface entirely and means no key rotation
is needed to remediate an IP change. Outbound is left open: Transfer Family
must reach S3 via the S3 Gateway VPC endpoint created during aws-native-setup,
and CloudWatch Logs via the internet gateway or a VPC endpoint.

### Verification

**CLI**
```bash
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=multi-lab-transfer-sg" \
  --query "SecurityGroups[0].{ID:GroupId,Inbound:IpPermissions}" \
  --profile multi-lab-admin
# → Inbound: port 22, protocol tcp, source: <your-public-ip>/32
```

---

## Step 4 — Transfer Family Server

### What was done

Created the Transfer Family SFTP server with CloudWatch Logs enabled,
the Security Group from Step 3 attached, and deployed into the public
subnet of `multi-lab-vpc`.

> **Billing starts now.** The endpoint is billed at $0.30/hour from the
> moment it is created. Complete Steps 5–7 without pause and proceed
> directly to the teardown step after verification.

**Pre-requisite — Allocate an Elastic IP (Console):**

> An Elastic IP is required when using a VPC endpoint with Public access.
> One EIP must exist per selected Availability Zone before the server can
> be created. Allocate it now — the wizard will not create it for you.

EC2 → Elastic IPs → Allocate Elastic IP address:

| Parameter | Value |
|---|---|
| Network Border Group | `eu-west-1` |
| Public IPv4 address pool | Amazon's pool of IPv4 addresses |

→ **Allocate** — note the allocated IP address.

> **Cost:** EIPs are free while associated to a running resource. An
> unassociated EIP incurs a $0.005/hour charge. Transfer Family associates
> the EIP automatically at server creation — it remains associated (free)
> until the server is deleted. Add EIP release to the teardown step.

**Console**

AWS Transfer Family → Servers → Create server:

**Page 1 — Choose protocols:**

| Parameter | Value |
|---|---|
| Protocol | SFTP only |

> FTPS and FTP are not enabled — they require additional certificate
> management (FTPS) or transmit credentials in plaintext (FTP). SFTP
> over SSH key authentication is the only protocol appropriate for this lab.

**Page 2 — Choose an identity provider:**

| Parameter | Value |
|---|---|
| Identity provider | Service managed |

> Service managed stores public keys directly in Transfer Family — no
> external IdP (Cognito, LDAP, AD) required. Appropriate for a single-user
> lab.

**Page 3 — Choose an endpoint:**

| Parameter | Value |
|---|---|
| Endpoint type    | VPC                         |
| Access           | Internet Facing             |
| VPC              | `multi-lab-vpc`             |
| IP address type  | IPv4                        |
| Availability Zones | `eu-west-1<x>` — select the AZ matching subnet `10.0.1.0/24` (one AZ only) |
| Elastic IP         | select the EIP allocated in the pre-requisite above                   |
| Subnet           | `10.0.1.0/24` (public)      |
| Security Group   | `multi-lab-transfer-sg`     |

> **VPC endpoint type** places the Transfer Family endpoint inside the VPC
> with a private or public-facing address. Using the public subnet with an
> Internet Gateway allows external SFTP access without a separate NLB.
> The internal endpoint type is for VPN/Direct Connect-only access —
> not required here.

**Page 4 — Choose a domain:**

| Parameter | Value |
|---|---|
| Domain | Amazon S3 |

**Page 5 — Configure additional settings:**

> The CloudWatch logging section does not have an explicit enable/disable
> toggle — logging is activated by assigning a log group and a role.
> Leave both fields empty to disable logging entirely. For this lab, both
> are required.

**CloudWatch Logs — create the log group inline:**

Open the CloudWatch log group link inside the logging section to open
CloudWatch in a new tab:

CloudWatch → Log groups → Create log group:

| Parameter | Value |
|---|---|
| Log group name | `/aws/transfer/multi-lab-transfer` |
| Retention | 1 month (for this lab) |
| Log class | Standard |

> **Log class — Standard vs. Infrequent Access:**
> Standard — full CloudWatch functionality: Insights queries, metric filters, 
> alarms, subscriptions, and live tail. Higher ingestion cost ($0.50/GB).
> 
> Infrequent Access — ~50% cheaper ingestion ($0.25/GB) but disables metric filters, 
> alarms, live tail, and subscription filters. Only basic log viewing and Insights 
> queries are available.
> 
> For this lab, choose Standard — Transfer Family SFTP activity logs are low volume 
> (negligible cost), and Standard preserves the option to add metric filters or alarms
> in future hardening steps without recreating the log group. Infrequent Access makes 
> sense for high-volume application logs where those features are not needed.

→ **Create** — close the tab and return to the Transfer Family wizard.

Back in the Transfer Family wizard → CloudWatch log group field →
click the **refresh icon** → select `/aws/transfer/multi-lab-transfer`.

**Page 5 parameters:**

| Parameter | Value |
|---|---|
| CloudWatch log group | `/aws/transfer/multi-lab-transfer` |
| Logging role | Leave empty — only required when using Managed Workflows |
| Managed workflows | Leave empty (out of scope for this module) |
| Security policy | `TransferSecurityPolicy-2024-01` |
| Server Host Key | Leave default (AWS-generated) |

**Additional optional fields — Page 5:**

| Parameter | Value | Reason |
|---|---|---|
| Optimized directories | Leave default (disabled) | Relevant only for buckets with >100k objects or deep prefix hierarchies — not applicable for a lab environment |
| Pre-authentication display banner | Leave empty | Optional branding/warning message shown before login — out of scope |
| SetStat option | Leave default (disabled) | Ignore SETSTAT enables compatibility with clients that send unsupported SFTP attribute commands — not needed for standard clients |
| TLS session resumption | N/A (greyed out) | Only available when FTPS is enabled in Step 1 — this server uses SFTP only |
| Passive IP (PASV) | N/A (greyed out) | Only available when FTP or FTPS is enabled in Step 1 — this server uses SFTP only |

> **Logging role:** the field is disabled unless a Managed Workflow is
> assigned. For standard SFTP logging, Transfer Family writes to the
> selected log group using an internal service-linked role — no explicit
> IAM role is needed here. The `multi-lab-transfer-role` created in
> Step 2 covers S3 bucket access, not CloudWatch delivery.
>
> **Security policy `TransferSecurityPolicy-2024-01`:** restricts the
> allowed cryptographic algorithms for the SFTP handshake. Always select
> the most recent policy unless legacy client support is required.


**Page 6 — Review and create:** confirm all settings → **Create server**.

After creation, note the **Server endpoint** (format:
`<server-id>.server.transfer.eu-west-1.amazonaws.com`).

### Why

VPC placement scopes the endpoint to the `multi-lab-vpc` network boundary
— the Security Group applies at the VPC level. CloudWatch Logs records every
session event (authentication attempt, file transfer, error) structured and
searchable — the operational equivalent of `internal-sftp -l VERBOSE` from
the self-managed setup. The 2024-01 security policy enforces modern
cryptographic standards without manual cipher list management.

### Verification

**Console**

Transfer Family → Servers — confirm server status is **Online**.

**CLI**
```bash
aws transfer list-servers \
  --profile multi-lab-admin \
  --query "Servers[*].{ID:ServerId,State:State,Endpoint:EndpointType}"
# → State: "ONLINE", EndpointType: "VPC"

# Retrieve the server endpoint address
aws transfer describe-server \
  --server-id <server-id> \
  --profile multi-lab-admin \
  --query "Server.EndpointDetails"
# → VpcEndpointId and VpcId confirmed
```

---

## Step 5 — Logical User

### What was done

Created a logical user `sftpuser` scoped to the `/uploads` prefix in the
S3 bucket, authenticated via SSH public key, using the IAM role from Step 2.

**Pre-requisite — generate an SSH keypair for SFTP (client machine):**

```bash
# ── On the CLIENT machine ──────────────────────────────────────────────────────
ssh-keygen -t ed25519 -C "sftp-multi-lab-transfer" -f ~/.ssh/id_ed25519_transfer

# Display the public key — copy the full output for the next step
cat ~/.ssh/id_ed25519_transfer.pub

chmod 600 ~/.ssh/id_ed25519_transfer
chmod 644 ~/.ssh/id_ed25519_transfer.pub
```

**Console**

Transfer Family → Servers → `<server-id>` → Users → Add user:

| Parameter | Value |
|---|---|
| Username | `sftpuser` |
| Role | `multi-lab-transfer-role` |
| Policy | None — role permissions apply without restriction |
| Home directory — S3 bucket | `multi-lab-transfer-<account-id>` + Restricted |
| Optional folder | `uploads` |
| SSH public key | paste output of `cat ~/.ssh/id_ed25519_transfer.pub` |

> **Policy (session policy):** an optional inline policy that further
> restricts the role's permissions for this specific user. Permissions
> granted by the role but not present in the session policy are denied.
> Leave empty to apply the full role permissions as-is. Use session
> policies when multiple users share a single role but require isolated
> access to per-user S3 prefixes — not needed for a single-user lab setup.

> **Restricted home directory:** maps the logical user's root (`/`) to the
> S3 prefix `/uploads` inside the bucket. The user cannot navigate above
> `/uploads` — equivalent to the chroot jail in the self-managed setup.
> Without this restriction, the user has access to the entire bucket.

### Why

The logical user decouples SFTP identity from OS accounts — there is no
system user, no shell, and no `/etc/passwd` entry. The IAM role assigned to
the user determines what S3 operations are permitted. `Restricted` home
directory enforces prefix-level isolation at the Transfer Family layer, before
the IAM policy is evaluated — two independent enforcement layers, matching the
`ForceCommand` + `ChrootDirectory` layering from the self-managed setup.

### Verification

**Console**

Transfer Family → Servers → `<server-id>` → Users → `sftpuser` —
confirm role ARN, home directory, and SSH public key fingerprint are correct.

**CLI**
```bash
aws transfer describe-user \
  --server-id <server-id> \
  --user-name sftpuser \
  --profile multi-lab-admin \
  --query "User.{Role:Role,HomeDirectoryType:HomeDirectoryType,Mappings:HomeDirectoryMappings}"
# → {
#     "Role": "arn:aws:iam::541801281490:role/multi-lab-transfer-role",
#     "HomeDirectoryType": "LOGICAL",
#     "Mappings": [{"Entry": "/", "Target": "/multi-lab-transfer-541801281490/uploads"}]
#   }
```

---

## Step 6 — Client Connection and Transfer Test

### What was done

Added a dedicated `Host` block to `~/.ssh/config` on the client machine and
performed an end-to-end transfer verification.

**Client SSH config** (`~/.ssh/config`):
```bash
Host multi-lab-transfer
HostName <server-id>.server.transfer.eu-west-1.amazonaws.com
User sftpuser
IdentityFile ~/.ssh/id_ed25519_transfer
```

> Replace `<server-id>` with the value from Step 4. Port 22 is the default
> for SFTP — no explicit `Port` directive needed.

### Why

The `Host` block eliminates all explicit flags from the `sftp` command —
`sftp multi-lab-transfer` is the only command needed. The dedicated alias
prevents accidentally connecting with the wrong key or user, and makes
the alias purpose explicit in the config file.

### Verification

```bash
# Test connectivity — accept the host key on first connection
sftp multi-lab-transfer
# → Connected to <server-id>.server.transfer.eu-west-1.amazonaws.com.

# Verify prefix confinement — root must show only uploads/
sftp> ls
# → uploads/
sftp> exit

# End-to-end transfer test - Execute this in client machine
echo "transfer-family-test" > /tmp/transfer_test.txt
sftp multi-lab-transfer
sftp> put /tmp/transfer_test.txt
sftp> ls 
# → transfer_test.txt
sftp> rm transfer_test.txt
sftp> bye

# Confirm object in S3
aws s3 ls s3://multi-lab-transfer-<account-id>/uploads/ \
  --profile multi-lab-admin
# → (empty after rm — object deleted successfully)

# Cleanup client
rm /tmp/transfer_test.txt
```

**Verify CloudWatch Logs received session events:**

**Console**

CloudWatch → Log Management → Log groups → `/aws/transfer/multi-lab-transfer` → confirm log
stream exists and contains session events from the SFTP connection above. (Select the local timezone for coherence with the time)

**CLI**
```bash
aws logs describe-log-streams \
  --log-group-name /aws/transfer/multi-lab-transfer \
  --profile multi-lab-admin \
  --query "logStreams[*].logStreamName"
# → log stream names matching the server ID

aws logs get-log-events \
  --log-group-name /aws/transfer/multi-lab-transfer \
  --log-stream-name <log-stream-name> \
  --profile multi-lab-admin \
  --query "events[*].message" \
  --limit 5
# → structured session events: OPEN, CLOSE, PUT, RM entries
```

---

## Step 7 — Teardown

### What was done

Deleted the Transfer Family server and emptied the S3 bucket to stop all
billable charges. The IAM role, Security Group, and CloudWatch log group
are retained — they are either free or carry no active cost.

> **Delete the server first.** Transfer Family cannot be deleted while users
> are connected. Wait for active sessions to close or stop them from the
> console before proceeding.

**Console**

Transfer Family → Servers → `<server-id>` → Actions → **Delete** → confirm.

> Server deletion is immediate. Billing stops at the next billing boundary
> (hourly). S3, CloudWatch Logs, and IAM resources continue to exist — they
> are not deleted by removing the server.

**Release the Elastic IP (Console):**

> Transfer Family disassociates the EIP automatically when the server is
> deleted. An unassociated EIP accrues $0.005/hour from that moment —
> release it immediately.

EC2 → Elastic IPs → select the EIP allocated in Step 4 →
Actions → **Release Elastic IP address** → confirm.

**CLI — empty and delete S3 bucket (optional — removes storage cost):**

```bash
# Remove all objects (required before bucket deletion)
aws s3 rm s3://multi-lab-transfer-<account-id> \
  --recursive \
  --profile multi-lab-admin

# Remove all versioned objects and delete markers
aws s3api delete-objects \
  --bucket multi-lab-transfer-<account-id> \
  --delete "$(aws s3api list-object-versions \
    --bucket multi-lab-transfer-<account-id> \
    --profile multi-lab-admin \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)" \
  --profile multi-lab-admin

# Delete the bucket
aws s3api delete-bucket \
  --bucket multi-lab-transfer-<account-id> \
  --region eu-west-1 \
  --profile multi-lab-admin

# Confirm EIP released
aws ec2 describe-addresses \
  --profile multi-lab-admin \
  --query "Addresses[?Domain=='vpc'].{IP:PublicIp,AssociationId:AssociationId}"
# → [] (empty — EIP released) 
```

> Within the S3 Free Tier (5 GB / 12 months), keeping the empty bucket
> costs nothing. Delete it only if the Free Tier has expired or if you
> prefer a clean account state.

### Why

Transfer Family is billed continuously while the server exists — there is no
pause or stop option, only delete. The teardown step is the operational
conclusion of this module, not an optional cleanup. Retaining the IAM role
and Security Group preserves the configuration for future re-deployment
without repeating Steps 2 and 3.

### Verification

**CLI**
```bash
aws transfer list-servers \
  --profile multi-lab-admin \
  --query "Servers[*].ServerId"
# → [] (empty — server deleted)

# Confirm billing stopped — adjust dates to current day
aws ce get-cost-and-usage \
  --time-period Start=<YYYY-MM-DD>,End=<YYYY-MM-DD+1> \
  --granularity DAILY \
  --metrics BlendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["AWS Transfer Family"]}}' \
  --profile multi-lab-admin
# → Amount reflects only the session just concluded — no ongoing charges
```

> Cost Explorer data has up to 24h latency — the current day's
> charges may not appear immediately. Use the Billing Dashboard in the
> console for a real-time estimate.

---