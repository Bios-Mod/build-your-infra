# Directory — AWS Native

AWS Directory Service Managed Microsoft AD directory deployed into the lab
VPC, providing Kerberos authentication, LDAP, Group Policy, and DNS for the
`multi-lab.internal` domain. The directory controllers are fully managed by
AWS — no OS access, no patching, no replication configuration required.

> **Cost notice:** AWS Directory Service Standard Edition bills at
> approximately **$0.05 per directory controller hour**. A Managed AD
> directory always provisions **two domain controllers** across two
> Availability Zones — minimum cost is ~**$0.10/hour** ($73/month).
> There is no free tier and no pause option — billing begins at creation
> and stops only at deletion. This module uses a **deploy-on-demand**
> strategy: provision the directory, complete all verification steps,
> then delete it. A full session of 2–3 hours costs under $1.00.
> Do not leave the directory running unattended.

---

## Scope

| Layer | Resource |
|---|---|
| Service | AWS Directory Service — Managed Microsoft AD (Standard Edition) |
| Domain | `multi-lab.internal` |
| Controllers | 2 DCs — automatically provisioned across two subnets |
| Network | `multi-lab-vpc` — private subnets (`10.0.2.0/24` + dedicated AZ-b subnet) |
| DNS | Managed AD DNS replaces Route 53 PHZ resolver for domain queries |
| Auth | Kerberos v5 · LDAP · NTLM (legacy fallback) |
| Admin | `Admin` account — Managed AD built-in administrative user |
| IAM | `AWSDirectoryServiceFullAccess` on `multi-lab-admin` |

---

## Relationship to Self-Managed

| Self-Managed | AWS Native |
|---|---|
| Samba 4 AD DC — provisioned on the EC2 instance | Managed Microsoft AD — two dedicated AWS-managed controllers |
| Domain provisioned via `samba-tool domain provision` | Domain provisioned via Console / CLI wizard |
| Internal DNS server on Samba DC (replaces BIND9) | Managed AD DNS resolver — DHCP Options Set update required |
| Kerberos KDC built into Samba 4 | Kerberos KDC on managed DCs — transparent to clients |
| Domain join via `realm join` on client | Domain join via SSM directory service or `realm join` |
| GPOs managed via RSAT tools | GPOs managed via RSAT (EC2 joined Windows or Linux with RSAT) |
| Manual replication if multi-DC | Automatic multi-AZ replication — no operator action |

---

## Step 1 — Second Subnet (AZ-b prerequisite)

### What was done

Managed AD requires exactly two subnets in **different Availability Zones**.
The existing private subnet `10.0.2.0/24` is in `eu-west-1a`. A second
private subnet must exist in a different AZ before the directory can be
created. If this subnet was already added during a previous module, skip
to Step 2.

**Console**

VPC → Subnets → Create subnet:

| Parameter | Value |
|---|---|
| VPC | `multi-lab-vpc` |
| Subnet name | `multi-lab-private-2` |
| Availability Zone | `eu-west-1b` |
| IPv4 CIDR | `10.0.3.0/24` |

→ **Create subnet**.

No route table changes are required — Managed AD controllers communicate
within the VPC. The subnet does not need internet access; the controllers
pull updates from AWS internal endpoints.

**CLI**
```bash
aws ec2 create-subnet \
  --vpc-id $(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=multi-lab-vpc" \
    --query "Vpcs.VpcId" --output text \
    --profile multi-lab-admin) \
  --cidr-block 10.0.3.0/24 \
  --availability-zone eu-west-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=multi-lab-private-2}]' \
  --profile multi-lab-admin
```

### Why

AWS Directory Service distributes its two domain controllers across two
separate Availability Zones for high availability. This is non-optional —
the wizard rejects single-AZ configurations. Using a dedicated private
subnet (`10.0.3.0/24`) keeps the second DC isolated from the existing
`10.0.2.0/24` private subnet and preserves the clean CIDR layout of the
existing VPC design.

### Verification

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs \
    --filters 'Name=tag:Name,Values=multi-lab-vpc' \
    --query 'Vpcs[0].VpcId' --output text \
    --profile multi-lab-admin)" \
  --query "Subnets[*].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone}" \
  --profile multi-lab-admin

# multi-lab-private   10.0.2.0/24  eu-west-1a
# multi-lab-private-2 10.0.3.0/24  eu-west-1b
```

---

## Step 2 — Security Group for Directory

### What was done

Created Security Group `multi-lab-directory-sg` scoping the inbound ports
required for Active Directory traffic within the VPC. Managed AD controllers
are not exposed to the internet — all rules use VPC CIDR as source.

**Console**

VPC → Security Groups → Create security group:

| Parameter | Value |
|---|---|
| Name | `multi-lab-directory-sg` |
| Description | Managed AD — intra-VPC AD traffic only |
| VPC | `multi-lab-vpc` |

Inbound rules → Add rule (one per row):

| Type | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Custom TCP | TCP | 53 | `10.0.0.0/16` | DNS queries to DC |
| Custom UDP | UDP | 53 | `10.0.0.0/16` | DNS queries to DC |
| Custom TCP | TCP | 88 | `10.0.0.0/16` | Kerberos |
| Custom UDP | UDP | 88 | `10.0.0.0/16` | Kerberos |
| Custom TCP | TCP | 135 | `10.0.0.0/16` | RPC endpoint mapper |
| Custom TCP | TCP | 389 | `10.0.0.0/16` | LDAP |
| Custom UDP | UDP | 389 | `10.0.0.0/16` | LDAP |
| Custom TCP | TCP | 445 | `10.0.0.0/16` | SMB / AD replication |
| Custom TCP | TCP | 464 | `10.0.0.0/16` | Kerberos password change |
| Custom UDP | UDP | 464 | `10.0.0.0/16` | Kerberos password change |
| Custom TCP | TCP | 636 | `10.0.0.0/16` | LDAPS |
| Custom TCP | TCP | 3268 | `10.0.0.0/16` | Global Catalog |
| Custom TCP | TCP | 3269 | `10.0.0.0/16` | Global Catalog SSL |
| Custom TCP | TCP | 49152-65535 | `10.0.0.0/16` | RPC dynamic ports |

Outbound rules: leave default (allow all).

**CLI**
```bash
# Create the group
SG_ID=$(aws ec2 create-security-group \
  --group-name multi-lab-directory-sg \
  --description "Managed AD - intra-VPC AD traffic only" \
  --vpc-id $(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=multi-lab-vpc" \
    --query "Vpcs.VpcId" --output text \
    --profile multi-lab-admin) \
  --profile multi-lab-admin \
  --query "GroupId" --output text)

# Authorize inbound rules in bulk
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --ip-permissions \
    'IpProtocol=tcp,FromPort=53,ToPort=53,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=udp,FromPort=53,ToPort=53,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=88,ToPort=88,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=udp,FromPort=88,ToPort=88,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=135,ToPort=135,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=389,ToPort=389,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=udp,FromPort=389,ToPort=389,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=445,ToPort=445,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=464,ToPort=464,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=udp,FromPort=464,ToPort=464,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=636,ToPort=636,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=3268,ToPort=3268,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=3269,ToPort=3269,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    'IpProtocol=tcp,FromPort=49152,ToPort=65535,IpRanges=[{CidrIp=10.0.0.0/16}]' \
  --profile multi-lab-admin

echo "SG ID: $SG_ID"
```

### Why

Managed AD controllers sit inside the VPC and never require internet-facing
rules. Scoping all inbound rules to `10.0.0.0/16` means only resources
inside `multi-lab-vpc` can initiate AD traffic — no exposure beyond the VPC
boundary. The RPC dynamic port range (49152–65535) is required for
post-authentication AD operations; blocking it causes domain join and Group
Policy failures that are difficult to diagnose. LDAPS (636) and Global
Catalog SSL (3269) are included to support secure LDAP queries without
additional configuration.

### Verification

```bash
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=multi-lab-directory-sg" \
  --query "SecurityGroups[0].{ID:GroupId,Rules:IpPermissions[*].{Proto:IpProtocol,From:FromPort,To:ToPort}}" \
  --profile multi-lab-admin

# → 14 inbound rules across TCP/UDP, all sourced from 10.0.0.0/16
```

---

## Step 3 — Managed AD Directory

### What was done

Provisioned the Managed Microsoft AD directory in `multi-lab.internal` using
Standard Edition, deployed across the two private subnets created in Steps 1
and pre-existing `10.0.2.0/24`.

> **Billing starts now.** Directory provisioning typically takes 20–40 minutes.
> Billing begins immediately at creation, not when the directory reaches
> Active state. Do not cancel mid-provisioning — a failed directory still
> accrues charges until explicitly deleted.

**Console**

Directory Service → Set up directory → **AWS Managed Microsoft AD**:

| Parameter | Value |
|---|---|
| Directory type | AWS Managed Microsoft AD |
| Edition | Standard |

> **Standard vs. Enterprise Edition:** Standard supports up to 30,000 objects
> and is sufficient for a lab environment. Enterprise supports 500,000 objects,
> multi-region replication, and trust relationships with on-premises AD —
> none of which are needed here. Standard is ~60% cheaper.

| Parameter | Value |
|---|---|
| Directory DNS name | `multi-lab.internal` |
| Directory NetBIOS name | `MULTILAB` |
| Admin password | (set a strong password — store it securely) |
| Confirm password | (repeat) |

> **Admin account:** AWS creates a built-in `Admin` account with delegated
> domain admin privileges. Full Schema Admin and Enterprise Admin rights
> are reserved by AWS and cannot be delegated. For a lab, the `Admin`
> account is sufficient.

| Parameter | Value |
|---|---|
| VPC | `multi-lab-vpc` |
| Subnets | `multi-lab-private` (`10.0.2.0/24`, `eu-west-1a`) |
| | `multi-lab-private-2` (`10.0.3.0/24`, `eu-west-1b`) |

> The wizard requires two subnets in different AZs — this enforces the
> automatic multi-AZ DC placement. AWS selects which DC goes to which
> subnet; this cannot be controlled.

**Review and create:** confirm all settings → **Create directory**.

The directory enters `Creating` state. Wait for `Active` status before
proceeding to Step 4. Monitor via:

```bash
aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions[*].{Name:Name,ID:DirectoryId,Stage:Stage}"
# → Stage: "Creating" → wait until "Active"
```

**CLI alternative (full provisioning in one command):**
```bash
aws ds create-microsoft-ad \
  --name multi-lab.internal \
  --short-name MULTILAB \
  --password '<AdminPassword>' \
  --edition Standard \
  --vpc-settings VpcId=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=multi-lab-vpc" \
    --query "Vpcs.VpcId" --output text \
    --profile multi-lab-admin),SubnetIds=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=multi-lab-private" \
    --query "Subnets.SubnetId" --output text \
    --profile multi-lab-admin),$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=multi-lab-private-2" \
    --query "Subnets.SubnetId" --output text \
    --profile multi-lab-admin) \
  --profile multi-lab-admin
```

> Replace `<AdminPassword>` with the password set in the Console wizard.
> Store it in a secrets manager or password manager — it cannot be retrieved
> after creation, only reset.

### Why

Standard Edition provides full Microsoft AD functionality — Kerberos,
LDAP, GPO, DNS, Kerberos constrained delegation — sufficient for all lab
scenarios without the Enterprise Edition cost premium. The two-subnet
deployment distributes the DCs across AZs automatically; this is not
optional and reflects real production design. `multi-lab.internal` as the
domain name preserves namespace consistency with the Route 53 PHZ and the
self-managed Samba implementation — a recruiter reviewing both modules sees
intentional equivalence, not two unrelated setups.

### Verification

```bash
aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions[0].{Name:Name,ID:DirectoryId,Stage:Stage,DNS:DnsIpAddrs,Edition:Edition}"
# → {
#     "Name": "multi-lab.internal",
#     "Stage": "Active",
#     "DNS": ["10.0.2.x", "10.0.3.x"],   ← DC IP addresses (note these)
#     "Edition": "Standard"
#   }
```

> Note the two DNS IP addresses returned — these are the DC IPs. They are
> required for Step 4 (DHCP Options Set) and Step 5 (domain join).

---

## Step 4 — DNS Integration

### What was done

Updated the VPC DHCP Options Set to point DNS resolution to the Managed AD
domain controllers. This replaces the Route 53 Resolver as the primary DNS
source for all instances in `multi-lab-vpc` while the directory is active.

> **DNS forwarding:** Managed AD's built-in DNS server automatically
> forwards unknown names to the VPC resolver (`169.254.169.253`). All
> existing VPC DNS resolution continues to work without any additional
> configuration — no dependency on any other lab module.

> **Revert on teardown:** the DHCP Options Set must be restored to the
> default AWS-managed DNS (`AmazonProvidedDNS`) before deleting the
> directory in Step 7, or instances will lose DNS resolution after teardown.

**Console**

VPC → DHCP option sets → Create DHCP option set:

| Parameter | Value |
|---|---|
| Name | `multi-lab-ad-dhcp` |
| Domain name | `multi-lab.internal` |
| Domain name servers | `<DC-IP-1>` (from Step 3 verification) |
| | `<DC-IP-2>` (from Step 3 verification) |

> All other fields (NTP servers, NetBIOS name servers, NetBIOS node type,
> IPv6 preferred lease time) — leave empty. Managed AD handles NetBIOS
> resolution internally. EC2 instances use the Amazon Time Sync Service
> (169.254.169.123) regardless of this option set. IPv6 is not used in this lab.

→ **Create DHCP option set**.

VPC → Your VPCs → `multi-lab-vpc` → Actions → Edit VPC settings →
DHCP options set → select `multi-lab-ad-dhcp` → **Save**.

**CLI**
```bash
# Create the DHCP options set — replace IPs with DC IPs from Step 3
DHCP_ID=$(aws ec2 create-dhcp-options \
  --dhcp-configurations \
    "Key=domain-name,Values=multi-lab.internal" \
    "Key=domain-name-servers,Values=<DC-IP-1>,<DC-IP-2>" \
  --tag-specifications 'ResourceType=dhcp-options,Tags=[{Key=Name,Value=multi-lab-ad-dhcp}]' \
  --profile multi-lab-admin \
  --query "DhcpOptions.DhcpOptionsId" --output text)

# Associate with the VPC
aws ec2 associate-dhcp-options \
  --dhcp-options-id $DHCP_ID \
  --vpc-id $(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=multi-lab-vpc" \
    --query "Vpcs.VpcId" --output text \
    --profile multi-lab-admin) \
  --profile multi-lab-admin

echo "DHCP Options Set ID: $DHCP_ID"
```

### Why

The DHCP Options Set is the VPC-native mechanism for distributing DNS server
addresses to all instances. Pointing it at the AD DCs means every instance
that renews its DHCP lease will automatically use the AD DNS server —
no per-instance configuration required. The Managed AD DNS server's built-in forwarder to the VPC resolver (`169.254.169.253`) preserves resolution of all non-AD names —
no functional regression for any existing VPC service.

### Verification

```bash
# Verify DHCP options set is active on the VPC
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=multi-lab-vpc" \
  --query "Vpcs[0].{VPC:VpcId,DHCP:DhcpOptionsId}" \
  --profile multi-lab-admin

# → DhcpOptionsId matches the ID created above

# On the EC2 instance (multi-lab-aws) — verify DNS servers updated
# (requires DHCP lease renewal
sudo dhcpcd -n ens5

resolvectl status
# → DNS Servers: <DC-IP-1> <DC-IP-2>

# Resolve an AD record from the EC2 instance
nslookup multi-lab.internal
# → Server: <DC-IP-1>  →  Address: <DC-IP>

# Confirm Route 53 PHZ records still resolve (non-AD name)
nslookup <any-route53-phz-record>
# → resolved via AD forwarder → 169.254.169.253 → Route 53 Resolver
```

---

## Step 5 — Domain Join (EC2)

### What was done

Joined `multi-lab-aws` (the EC2 instance) to the `multi-lab.internal` domain
using the `realm` utility. AWS SSM directory service join is an alternative
approach — the manual `realm` method is used here because it is
environment-agnostic and produces identical results to the self-managed path.

> **SSM Join (alternative):** AWS provides a seamless domain join feature
> via Systems Manager that can join EC2 instances to Managed AD at launch
> or on-demand, without installing any agent. It requires an IAM instance
> profile with `AmazonSSMDirectoryServiceAccess` attached to the EC2 instance.
> For this lab, the manual path is used to document the explicit join process
> and match the self-managed workflow. The SSM approach is referenced in the
> automation/ subfolder.

**Prerequisites — on `multi-lab-aws`:**
```bash
# Install required packages
sudo apt update
sudo apt install -y realmd sssd sssd-tools libnss-sss libpam-sss \
  adcli samba-common-bin oddjob oddjob-mkhomedir packagekit krb5-user

# During krb5-user installation, set:
# Default Kerberos version 5 realm: MULTI-LAB.INTERNAL
# PAM Configuration: NO
```

**Discover and join the domain:**
```bash
# Verify the domain is reachable and discoverable
realm discover multi-lab.internal
# → multi-lab.internal
# →   type: kerberos
# →   realm-name: MULTI-LAB.INTERNAL
# →   domain-name: multi-lab.internal
# →   configured: no
# →   server-software: active-directory
# →   client-software: sssd

# Join the domain — enter ACTIVE DIRECTORY Admin password when prompted
sudo realm join -U Admin multi-lab.internal
# → (no output = success)
```

**Configure SSSD for home directory creation:**
```bash
sudo bash -c 'cat >> /etc/sssd/sssd.conf << EOF

# ── DIRECTORY — sssd home directory settings ──────────────────────────────────
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
EOF'

sudo systemctl restart sssd

# pam-auth-update may detect local modifications and refuse to run non-interactively.
# If the command below returns "Local modifications to /etc/pam.d/common-*, not updating",
# run: sudo pam-auth-update --force
# An interactive menu appears — confirm [*] Unix authentication, [*] SSS authentication,
# and [*] Create home directory on login are selected, then Ok.
sudo pam-auth-update --enable mkhomedir
```

### Why

`realm join` handles the full AD join workflow — Kerberos ticket acquisition,
computer account creation in AD, DNS SRV record lookup for DCs, and SSSD
configuration — in a single command. SSSD provides the NSS and PAM
integration that makes AD users resolvable by the OS without manual
`/etc/passwd` entries. The `fallback_homedir` pattern creates per-user
home directories on first login, matching the behavior expected from the
self-managed Samba join path.

### Verification

```bash
# Verify domain membership
realm list
# → multi-lab.internal
# →   type: kerberos
# →   realm-name: MULTI-LAB.INTERNAL
# →   configured: kerberos-member
# →   server-software: active-directory

# Verify AD user lookup
id Admin@multi-lab.internal
# → uid=<UID>(admin@multi-lab.internal) gid=<GID> groups=...

# Kerberos authentication test
kinit Admin@MULTI-LAB.INTERNAL
# → (enter password — no output = Kerberos ticket issued)

klist
# → Credentials cache: ... 
# →   Principal: Admin@MULTI-LAB.INTERNAL
# →   Valid starting: <timestamp>  Expires: <timestamp+10h>
# →   krbtgt/MULTI-LAB.INTERNAL@MULTI-LAB.INTERNAL

# DNS SRV record — confirms DC discovery path
nslookup -type=SRV _ldap._tcp.multi-lab.internal
# → _ldap._tcp.multi-lab.internal  SRV  0 100 389  <dc-hostname>
```

---

## Step 6 — Directory Service Verification

### What was done

Ran a full-stack verification from the AWS Console and from the EC2 instance
to confirm directory health, DC connectivity, replication, and SNS
notification channel.

**Console — Directory health:**

Directory Service → Directories → `multi-lab.internal` → confirm:
- Directory status: **Active**

**Enable SNS notifications for directory health events (Console):**

Directory Service → `multi-lab.internal` → Maintenance → SNS notifications →
**Enable** → Create or select an SNS topic:

| Parameter | Value |
|---|---|
| SNS topic name | `multi-lab-directory-alerts` |
| Subscription | email address (optional for lab) |

> Directory health events (controller failure, replication error, snapshot
> failure) are published to this topic. Not required for the lab to function,
> but demonstrates operational awareness and matches CloudTrail/GuardDuty
> alert patterns established in the hardening module.

**CLI — directory health and DC status:**
```bash
# Full directory description
aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions.{Name:Name,Stage:Stage,DNS:DnsIpAddrs,Edition:Edition,VpcId:VpcSettings.VpcId}"
# → Stage: "Active", DNS: [<DC-IP-1>, <DC-IP-2>]

# Domain controller details
aws ds describe-domain-controllers \
  --directory-id $(aws ds describe-directories \
    --profile multi-lab-admin \
    --query "DirectoryDescriptions[?Name=='multi-lab.internal'].DirectoryId" \
    --output text) \
  --profile multi-lab-admin \
  --query "DomainControllers[*].{AZ:AvailabilityZone,Status:Status,SubnetId:SubnetId}"
# → Both DCs show Status: "Active", each in a different AZ

# From multi-lab-aws — full AD connectivity check
sudo sssctl domain-status multi-lab.internal
# → Online status: Online
# → Active servers:
# →   AD: <DC-hostname>

# LDAP query via AD bind
ldapsearch -x -H ldap://<DC-IP-1> \
  -D "Admin@multi-lab.internal" \
  -w '<AdminPassword>' \
  -b "DC=multi-lab,DC=internal" \
  "(objectClass=user)" cn sAMAccountName 2>/dev/null | head -20
# → returns Admin user entry and any other provisioned users
```

### Why

Two-level verification — AWS API and OS-level — confirms that the managed
infrastructure layer and the client configuration layer are both operational.
The `sssctl domain-status` check confirms that SSSD is actively communicating
with the DCs, not just that the domain join succeeded. The LDAP query validates
end-to-end AD protocol functionality independently of the realm/SSSD stack.

---

## Step 7 — Teardown

### What was done

Removed the domain join from the EC2 instance, restored the VPC DNS
configuration, and deleted the Managed AD directory to stop all billable
charges.

> **Order matters.** Leave the domain before deleting the directory.
> Deleting the directory first leaves the EC2 instance with a broken
> SSSD configuration that must be manually cleaned up.

**Step 7.1 — Leave the domain (EC2 instance):**

```bash
# Leave the domain — revokes the computer account in AD
sudo realm leave multi-lab.internal
# → (no output = success)

# Remove SSSD packages
sudo apt purge -y sssd sssd-tools libnss-sss libpam-sss adcli realmd
sudo apt autoremove -y

# Verify DNS resolution still works after SSSD removal
resolvectl status
nslookup google.com
```

**Step 7.2 — Restore DHCP Options Set (Console):**

VPC → Your VPCs → `multi-lab-vpc` → Actions → Edit VPC settings →
DHCP options set → select **default** (`AmazonProvidedDNS`) → **Save**.

```bash
# CLI — restore default DHCP options
aws ec2 associate-dhcp-options \
  --dhcp-options-id default \
  --vpc-id $(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=multi-lab-vpc" \
    --query "Vpcs.VpcId" --output text \
    --profile multi-lab-admin) \
  --profile multi-lab-admin
```

**Step 7.3 — Delete the directory (Console):**

> Managed AD cannot be deleted while snapshot operations are running.
> Wait for any pending operations to complete before proceeding.

Directory Service → Directories → `multi-lab.internal` →
Actions → **Delete** → type the directory ID to confirm → **Delete**.

Deletion takes 10–15 minutes. Billing stops at the next hourly boundary
after the directory enters `Deleting` state.

```bash
# CLI — initiate directory deletion
aws ds delete-directory \
  --directory-id $(aws ds describe-directories \
    --profile multi-lab-admin \
    --query "DirectoryDescriptions[?Name=='multi-lab.internal'].DirectoryId" \
    --output text) \
  --profile multi-lab-admin

# Monitor deletion
aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions[*].{Name:Name,Stage:Stage}"
# → Stage: "Deleting" → wait until entry disappears entirely
```

**Step 7.4 — Cleanup (optional):**

```bash
# Delete the custom DHCP options set (no longer needed)
aws ec2 delete-dhcp-options \
  --dhcp-options-id <DHCP_ID from Step 4> \
  --profile multi-lab-admin

# Delete the second subnet if not used by other modules
aws ec2 delete-subnet \
  --subnet-id $(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=multi-lab-private-2" \
    --query "Subnets.SubnetId" --output text \
    --profile multi-lab-admin) \
  --profile multi-lab-admin
```

> Retain `multi-lab-directory-sg` — it is free and preserves the
> configuration for future re-deployment. Delete the second subnet only
> if no other module depends on it.

### Why

Managed AD is the most expensive resource in this lab — there is no pause
or stop option. Billing is continuous from creation to deletion. Leaving the
domain before deleting the directory ensures the computer account is cleanly
removed from AD and the EC2 instance is left in a consistent state. Restoring
`AmazonProvidedDNS` before deletion ensures instances do not lose DNS
resolution during the 10–15 minute deletion window.

### Verification

```bash
# Confirm directory deleted
aws ds describe-directories \
  --profile multi-lab-admin \
  --query "DirectoryDescriptions[*].{Name:Name,Stage:Stage}"
# → [] (empty — directory deleted)

# Confirm DNS restored on EC2
resolvectl status | grep "DNS Servers"
# → DNS Servers: 169.254.169.253   ← AmazonProvidedDNS
```

> Cost Explorer data has up to 24h latency — the current day's charges
> may not appear immediately. Use the Billing Dashboard for a real-time
> estimate.

