# DNS — AWS Native

Route 53 Private Hosted Zone providing internal name resolution for
`multi-lab-vpc`. Allows EC2 instances and AWS services within the VPC
to resolve custom domain names without exposing DNS to the public internet.

---

## Scope

| Layer | Resource |
|---|---|
| Zone | Route 53 Private Hosted Zone — `multi-lab.internal` |
| Resolution | Enabled via `enableDnsSupport` on `multi-lab-vpc` |
| Record types | A (host), CNAME (alias), PTR (reverse — optional) |
| Observability | Route 53 Resolver Query Logging → CloudWatch Logs |

> **Cost notice:** A Private Hosted Zone is billed at **$0.50/month** regardless
> of query volume. Charges begin at creation. For this lab, the zone remains
> active across sessions — it is not a deploy-on-demand resource like Transfer
> Family. Delete the zone only when decommissioning the lab environment entirely.

---

## Relationship to Self-Managed

| Self-managed (BIND9) | AWS Native |
|---|---|
| `named.conf` — zone declaration | Private Hosted Zone creation |
| Forward zone file (`db.multi-lab.internal`) | Route 53 A / CNAME records |
| Reverse zone file (`db.10.0`) | Route 53 PTR records (optional) |
| `allow-query` / `allow-recursion` ACLs | VPC-scoped zone — private by design |
| `rndc reload` | Record changes apply in seconds (no reload) |
| `named-checkconf` / `named-checkzone` | Console / CLI validation per record |
| rsyslog DNS query logs | Route 53 Resolver Query Logging |

---

## Step 1 — Private Hosted Zone

### What was done

Created a Route 53 Private Hosted Zone `multi-lab.internal` associated with
`multi-lab-vpc` in `eu-west-1`.

**Console**

Route 53 → Hosted zones → Create hosted zone:

| Parameter | Value |
|---|---|
| Domain name | `multi-lab.internal` |
| Type | Private hosted zone |
| Region | `eu-west-1` |
| VPC ID | `multi-lab-vpc` |

→ **Create hosted zone**.

> **Auto-generated records:** Route 53 creates two records automatically upon
> zone creation — do not modify or delete them.
>
> | Name | Type | Value | TTL |
> |---|---|---|---|
> | `multi-lab.internal` | NS | Four Route 53 private name server hostnames | 172800 |
> | `multi-lab.internal` | SOA | Primary NS + zone admin contact + serial/refresh parameters | 900 |
>
> **NS (Name Server):** delegates authority for the zone to the four assigned
> Route 53 name servers. In a Private Hosted Zone these are internal AWS
> endpoints — they are not the same as public Route 53 NS records and have
> no public DNS significance.
>
> **SOA (Start of Authority):** defines the authoritative parameters for the
> zone — primary name server, responsible contact, serial number, and
> refresh/retry/expire timers. Route 53 manages the serial automatically on
> every record change.
>
> Both records are managed by Route 53. Proceed to Step 2 to add your own records.

> `.internal` is a non-delegated TLD reserved for internal use — it will
> never resolve publicly regardless of Route 53 configuration. Do not use
> `.local` (conflicts with mDNS/Bonjour) or a real TLD you do not own.

### Why

A Private Hosted Zone is only resolvable from within the associated VPC — no public DNS exposure, no ACL required. `enableDnsSupport` is already enabled on `multi-lab-vpc` 
(see decisions log), which activates the Route 53 Resolver at `169.254.169.253` 
inside the VPC. Any EC2 instance in the VPC will automatically use this resolver without any OS-level configuration.

### Verification

**CLI**
```bash
# Confirm VPC association
ZONE_ID=$(aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='multi-lab.internal.'].Id | [0]" \
  --output text | awk -F'/' '{print $NF}')

# → "VPCRegion": "eu-west-1",
#   "VPCId": "<multi-lab-vpc-id>"

aws route53 list-hosted-zones \
  --profile multi-lab-admin \
  --query "HostedZones[?Name=='multi-lab.internal.'].{ID:Id,Private:Config.PrivateZone}"

# → "Private": true
```

---

## Step 2 — A Records

### What was done

Created A records mapping internal hostnames to the private IP addresses
of the lab instances.

> **Pre-requisite — retrieve private IPs before creating records:**
>
> The A records require the private IP of each instance. Retrieve them now.
>
> **EC2 instance (`multi-lab-aws`) — CLI:**
> ```bash
> aws ec2 describe-instances \
>   --filters "Name=tag:Name,Values=multi-lab-aws" \
>   --profile multi-lab-admin \
>   --query "Reservations.Instances.PrivateIpAddress" \
>   --output text
> # → 10.0.x.x  (use this value as the A record value below)
> ```

> **Console (alternative):**
>
> EC2 → Instances → `multi-lab-aws` → Details tab → **Private IPv4 address**

**Console**

Route 53 → Hosted zones → `multi-lab.internal` → Create record:

> Create one record per instance. Repeat for each hostname below.

| Record name | Type | Value | TTL |
|---|---|---|---|
| `ec2` | A | `<multi-lab-aws private IP>` | 300 |

> Use the private IP assigned to each instance — not the Elastic IP or
> public IP. Private IPs are stable within the VPC; public IPs change
> on stop/start unless an EIP is assigned.
>
> TTL 300 (5 minutes) balances resolver cache efficiency against
> propagation delay when records change. For a lab with infrequent IP
> changes, 300 is appropriate — lower values increase resolver query load
> with no practical benefit.

**CLI (alternative — batch creation):**
```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile multi-lab-admin \
  --change-batch '{
    "Changes": [
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "ec2.multi-lab.internal",
          "Type": "A",
          "TTL": 300,
          "ResourceRecords": [{"Value": "<multi-lab-aws private IP>"}]
        }
      }
    ]
  }'
# → "Status": "INSYNC" (propagation complete — typically < 60 seconds)
```

### Why

A records provide core forward resolution: `ec2.multi-lab.internal → <private IP>`.
Using a short, role-based hostname rather than an instance ID or IP makes all
subsequent module configurations (web-server, directory) portable — changing an IP
requires updating one DNS record, not every config file that references it.

### Verification

**CLI — from within the VPC (EC2 instance via SSM):**
```bash
# Open a session on multi-lab-aws or you can use SSH (ssh multi-lab-aws)
aws ssm start-session \
  --target <instance-id> \
  --profile multi-lab-admin

# Inside the session:
dig ec2.multi-lab.internal
# → ANSWER SECTION: ec2.multi-lab.internal. 300 IN A <private IP>

# Confirm resolver is Route 53 (169.254.169.253)
resolvectl status | grep "DNS Servers"
# → DNS Servers: 10.0.0.2  (Route 53 Resolver — VPC base address + 2)
```

---

## Step 3 — Resolver Query Logging

### What was done

Enabled Route 53 Resolver Query Logging for `multi-lab-vpc`, delivering
all DNS query logs to a dedicated CloudWatch Logs group.

**Console — create the log group first:**

CloudWatch → Log groups → Create log group:

| Parameter | Value |
|---|---|
| Log group name | `/aws/route53/multi-lab-vpc` |
| Retention | 1 month |
| Log class | Standard |

**Console — enable query logging:**

Route 53 → VPC Resolver → Query logging → Configure query logging:

| Parameter | Value |
|---|---|
| Name | `multi-lab-resolver-logging` |
| Query logs destination | CloudWatch Logs |
| Log group | `/aws/route53/multi-lab-vpc` |
| VPCs to log | `multi-lab-vpc` |

→ **Configure query logging**.

> Route 53 Resolver Query Logging creates a service-linked resource policy
> on the CloudWatch log group automatically — no IAM role is required.

### Why

Query logging records every DNS request originating from instances within
`multi-lab-vpc` — source IP, query name, query type, response code, and
resolved IP. This is the DNS-layer equivalent of VPC Flow Logs: it makes
name resolution activity auditable and correlatable with network events.
For the directory module, query logs will be essential to verify Samba 4
SRV record resolution. For the web-server module, they confirm that
internal clients are resolving the correct backend hostname.

### Verification

**CLI**
```bash
aws route53resolver list-resolver-query-log-configs \
  --profile multi-lab-admin \
  --query "ResolverQueryLogConfigs[*].{Name:Name,Status:Status,Dest:DestinationArn}"
# → "Status": "CREATED", "Dest": "arn:aws:logs:eu-west-1:...:log-group:/aws/route53/multi-lab-vpc"

# Confirm VPC association
aws route53resolver list-resolver-query-log-config-associations \
  --profile multi-lab-admin \
  --query "ResolverQueryLogConfigAssociations[*].{VPC:ResourceId,Status:Status}"
# → "Status": "ACTIVE", "VPC": "<multi-lab-vpc-id>"
```

**Functional test — trigger a query and confirm log delivery:**
```bash
# Inside the EC2 instance (SSM or SSH):
dig ec2.multi-lab.internal
# → status: NOERROR, A <private IP>

resolvectl status | grep "DNS Servers"
# → DNS Servers: 10.0.0.2  (Route 53 Resolver — VPC base CIDR + 2)

# CloudWatch — allow 1-2 minutes for log delivery
aws logs filter-log-events \
  --log-group-name /aws/route53/multi-lab-vpc \
  --filter-pattern '{ $.query_name = "ec2.multi-lab.internal." }' \
  --profile multi-lab-admin \
  --query "events[*].message" \
  --limit 3

# → JSON entries with query_name, srcaddr, rcode: "NOERROR", answers: [<private IP>]
```

---

## Step 4 — Teardown

### What was done

Disabled Route 53 Resolver Query Logging for `multi-lab-vpc` to stop log
ingestion charges. The Private Hosted Zone and its records are retained —
they carry a fixed cost of $0.50/month and are required for all subsequent
modules.

> **What to delete vs. what to keep:**
> Route 53 Private Hosted Zone: **keep** — $0.50/month flat, no per-query
> cost for private zones, and all future modules (web-server, directory)
> depend on internal name resolution being active.
> Resolver Query Logging: **disable** — billed per query volume. For an
> idle lab the cost is negligible, but the log group will accumulate data
> with no operational value between active sessions.

**Console — remove VPC association from query logging config:**

Route 53 → Resolver → Query logging → `multi-lab-resolver-logging` →
Delete → Stop logging queries → **delete** 

> Disassociating the VPC stops log delivery immediately. The config and
> the log group are retained — re-associating restores logging instantly
> when needed for the next module.

**CLI (alternative):**
```bash
# Get the query log config ID
CONFIG_ID=$(aws route53resolver list-resolver-query-log-configs \
  --profile multi-lab-admin \
  --query "ResolverQueryLogConfigs[?Name=='multi-lab-resolver-logging'].Id" \
  --output text)

# Get the association ID
ASSOC_ID=$(aws route53resolver list-resolver-query-log-config-associations \
  --profile multi-lab-admin \
  --query "ResolverQueryLogConfigAssociations[?ResolverQueryLogConfigId=='$CONFIG_ID'].Id" \
  --output text)

# Disassociate
aws route53resolver disassociate-resolver-query-log-config \
  --resolver-query-log-config-id "$CONFIG_ID" \
  --resource-id <multi-lab-vpc-id> \
  --profile multi-lab-admin

# → "Status": "DELETING" → transitions to dissociated
```

### Why

Query logging is the only variable-cost component in this module. The
Private Hosted Zone has a predictable fixed cost and cannot be paused —
deleting it would require recreating all records before the next module.
Disassociating the VPC from the logging config is the minimal action that
stops billing without losing configuration state.

### Verification

```bash
aws route53resolver list-resolver-query-log-config-associations \
  --profile multi-lab-admin \
  --query "ResolverQueryLogConfigAssociations[*].{VPC:ResourceId,Status:Status}"
# → [] (empty — no active associations, logging stopped)

# Confirm zone and records are intact
aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile multi-lab-admin \
  --query "ResourceRecordSets[?Type=='A'].{Name:Name,IP:ResourceRecords[0].Value}"

# → ec2.multi-lab.internal → <private IP>
```

---