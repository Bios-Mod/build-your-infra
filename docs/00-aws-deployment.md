# Multi-Lab Server — AWS Deployment

**Ubuntu 24.04 LTS · ARM64 · EC2 t4g.micro**

---

## Introduction

This document covers the AWS infrastructure provisioning required before
applying the OS hardening in [`docs/01-os-hardening.md`](01-os-hardening.md).

Scope: key pair, security group, EC2 instance, and first connection. OS-level
configuration starts in Step 01.

> **Parallel deployment:** A local VM build runs on VMware Fusion (Apple
> Silicon). The AWS instance is an independent cloud deployment of the same
> stack — both follow the same hardening baseline from Step 01 onward.
> DHCP (Step 04) is VM-only and does not apply to the cloud deployment.

> **AWS account prerequisite:** Before provisioning any resource, enable Free
> Tier usage alerts (AWS Billing → Billing Preferences → Alert Preferences)
> and configure a zero-spend budget (Billing → Budgets). An unattended running
> instance accrues cost silently without these alerts.

---

## Environment

| Parameter     | Value                                            |
|---------------|--------------------------------------------------|
| Provider      | AWS EC2                                          |
| Region        | eu-west-1 (Europe — Ireland)                     |
| Instance      | t4g.micro · 2 vCPU · 1 GB RAM · Graviton2 ARM64 |
| OS            | Ubuntu Server 24.04 LTS (ARM64)                  |
| Storage       | 20 GiB EBS gp3                                   |
| Public IP     | Dynamic — changes on stop/start                  |
| Instance name | `multi-lab-aws`                                  |
| Admin user    | `ubuntu` (default AMI user, non-root with sudo)  |

> **EBS always bills.** The volume persists and is billed regardless of
> instance state. Stopping the instance suspends compute billing only.
> Terminating the instance deletes the volume — only do this if
> decommissioning entirely.

---

## Step 1 — Key Pair

**EC2 → Key Pairs → Create key pair** (recommended) or
**Actions → Import key pair** (if reusing an existing key).

> **Important:** AWS injects the public key into the instance at launch time
> only. If you do not associate a key pair during instance creation, there is
> no supported way to add one later without stopping the instance and using
> the EC2 serial console or a workaround. Always associate a key pair at
> launch — it cannot be added through the standard flow after the fact.

**Option A — Create new (recommended for new deployments):**

| Field            | Value         |
|------------------|---------------|
| Name             | `multi-lab-key` |
| Key pair type    | ED25519        |
| Private key format | .pem        |

Download the `.pem` when prompted — AWS provides it once only.

```bash
mv ~/Downloads/multi-lab-key.pem ~/.ssh/
chmod 600 ~/.ssh/multi-lab-key.pem
```

**Option B — Import existing key (used in this build):**

```bash
# Copy your existing public key
cat ~/.ssh/<your_key>.pub
# → ssh-ed25519 AAAA... user@host
```

Paste the output into "Public key contents". Name: `multi-lab-key`.

> Reusing an existing key keeps the same identity across both the VM and
> AWS deployments — one key covers both environments on any client that
> connects to both.

---

## Step 2 — Security Group

**EC2 → Security Groups → Create security group**

| Field       | Value                              |
|-------------|------------------------------------|
| Name        | `multi-lab-sg`                     |
| Description | `multi-lab-aws — managed manually` |
| VPC         | Default VPC                        |

### Inbound rules

| Type       | Protocol | Port  | Source          | Description                              |
|------------|----------|-------|-----------------|------------------------------------------|
| Custom TCP | TCP      | 22    | My IP (`/32`)   | Temporary — first connection, pre-hardening. Delete after Step 01. |
| Custom TCP | TCP      | 22222 | My IP (`/32`)   | SSH — post-hardening (Step 01)           |
| Custom UDP | UDP      | 51820 | 0.0.0.0/0, ::/0 | WireGuard VPN                            |

### Outbound rules

| Type        | Protocol | Port range | Destination     | Description  |
|-------------|----------|------------|-----------------|--------------|
| All traffic | All      | All        | 0.0.0.0/0, ::/0 | Allow all outbound |

### Port 22 — temporary rule

Ubuntu Server 24.04 starts with SSH on port 22 by default. The hardened
`sshd_config` (Step 01) moves SSH to port 22222. Port 22 must remain open
in the Security Group until that config is applied.

**After completing SSH hardening in Step 01:** delete the port 22 inbound
rule from `multi-lab-sg`.

### Source IP restriction

Both SSH rules restrict source to `My IP` (`/32`). Update when your IP
changes (travel, network change):

```bash
# Find your current public IP
curl -s ifconfig.me
```

EC2 → Security Groups → `multi-lab-sg` → Inbound rules → Edit →
replace the `/32` entry with the new IP.

### Security Group and UFW — two independent layers

The Security Group filters at the hypervisor — traffic blocked here never
reaches the OS. UFW (Step 01) operates inside the kernel. Both run
simultaneously: a Security Group misconfiguration is caught by UFW, and a
UFW misconfiguration does not expose the instance to the internet.

---

## Step 3 — EC2 Instance

**EC2 → Instances → Launch Instance**

| Field                 | Value                                      |
|-----------------------|--------------------------------------------|
| Name                  | `multi-lab-aws`                            |
| AMI                   | Ubuntu Server 24.04 LTS — **64-bit (Arm)** |
| Instance type         | `t4g.micro` — verify "Free tier eligible"  |
| Key pair              | `multi-lab-key`                            |
| Security group        | `multi-lab-sg`                             |
| Storage               | 20 GiB — **gp3** (not gp2)                |
| Auto-assign public IP | Enabled                                    |

> **AMI change warning:** selecting Ubuntu 24.04 after modifying other
> settings triggers *"Some of your current settings will be changed or
> removed"*. This is expected — the wizard resets its suggested defaults.
> Confirm and re-verify that `multi-lab-sg` is still selected before
> launching.

> **gp3 vs gp2:** gp3 provides 3,000 IOPS and 125 MB/s baseline included
> at no extra cost. gp2 at 20 GiB delivers ~100 IOPS. Same price — always
> choose gp3.

---

## Step 4 — First Connection

The instance is reachable ~30 seconds after launch (status: `running`).

```bash
# EC2 → Instances → multi-lab-aws → Public IPv4 address

# ~/.ssh/config
Host multi-lab-aws
  HostName <PUBLIC_IP>
  User ubuntu
  IdentityFile ~/.ssh/<your_key>
  Port 22                   # temporary — update to 22222 after Step 01

ssh multi-lab-aws

# Verify architecture
uname -m                    # → aarch64

# Verify OS
lsb_release -a              # → Ubuntu 24.04.x LTS

# First update
sudo apt update && sudo apt upgrade -y
```

### Stop/start IP workflow

The public IP changes on every stop/start cycle. After restarting:

```bash
# Retrieve new IP via AWS CLI
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=multi-lab-aws" \
  --query 'Reservations.Instances.PublicIpAddress' \
  --output text

# Update ~/.ssh/config → HostName with the new IP
```

> After WireGuard is deployed (Step 01), SSH always targets the WireGuard
> address (`10.0.0.1`) regardless of the public IP. Only the WireGuard
> `Endpoint` field needs updating on IP change — see Step 01.

---

## Post-Deployment Checklist

- [ ] Free Tier alert and zero-spend budget active
- [ ] Instance `multi-lab-aws` running — status: `running`  
- [ ] AMI confirmed: Ubuntu 24.04 LTS ARM64 (`uname -m` → `aarch64`)
- [ ] SSH working on port 22 (temporary)
- [ ] Security group `multi-lab-sg` attached — ports 22, 22222, 51820 open
- [ ] First `apt update && apt upgrade -y` completed
- [ ] Instance stopped — Free Tier hours preserved

**Next:** [`docs/01-os-hardening.md`](01-os-hardening.md) —
apply OS hardening. After Step 01: delete the port 22 inbound rule from
`multi-lab-sg` and update `~/.ssh/config` to port 22222.