# VPS / EC2 — Setup

**Ubuntu 24.04 LTS · ARM64 · EC2 t4g.micro**

---

## Introduction

AWS infrastructure provisioning required before applying OS hardening.
Scope: key pair, security group, EC2 instance, and first connection.
OS-level configuration starts in [`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md).

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
| Instance      | t4g.micro · 2 vCPU · 1 GB RAM · Graviton2 ARM64  |
| OS            | Ubuntu Server 24.04 LTS (ARM64)                  |
| Storage       | 20 GiB EBS gp3                                   |
| Public IP     | Elastic IP — static                              |
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

| Field              | Value           |
|--------------------|-----------------|
| Name               | `multi-lab-key` |
| Key pair type      | ED25519         |
| Private key format | .pem            |

Download the `.pem` when prompted — AWS provides it once only.

```bash
mv ~/Downloads/multi-lab-key.pem ~/.ssh/
chmod 600 ~/.ssh/multi-lab-key.pem
```

**Option B — Import existing key (used in this build):**

```bash
cat ~/.ssh/<your_key>.pub
# → ssh-ed25519 AAAA... user@host
```

Paste the output into "Public key contents". Name: `multi-lab-key`.

> Reusing an existing key keeps the same identity across VM and EC2
> deployments — one key covers both environments.

---

## Step 2 — Security Group

**EC2 → Security Groups → Create security group**

| Field       | Value                              |
|-------------|------------------------------------|
| Name        | `multi-lab-sg`                     |
| Description | `multi-lab-aws — managed manually` |
| VPC         | Default VPC                        |

> If you have completed [`aws-native-setup.md`](../aws-native/aws-native-setup.md),
> use `multi-lab-vpc` instead of the Default VPC.

### Inbound rules

| Type       | Protocol | Port  | Source          | Description                              |
|------------|----------|-------|-----------------|------------------------------------------|
| Custom TCP | TCP      | 22    | My IP (`/32`)   | Temporary — first connection, pre-hardening. Delete after hardening. |
| Custom TCP | TCP      | 22222 | My IP (`/32`)   | SSH — post-hardening                     |
| Custom UDP | UDP      | 51820 | 0.0.0.0/0, ::/0 | WireGuard VPN                            |

### Outbound rules

| Type        | Protocol | Port range | Destination     |
|-------------|----------|------------|-----------------|
| All traffic | All      | All        | 0.0.0.0/0, ::/0 |

### Port 22 — temporary rule

Ubuntu Server 24.04 starts SSH on port 22 by default. The hardened
`sshd_config` moves SSH to port 22222. Port 22 must remain open until
hardening is applied — delete this rule afterwards.

### Source IP restriction

Both SSH rules restrict source to `My IP` (`/32`). Update when your IP changes:

```bash
curl -s ifconfig.me
```

EC2 → Security Groups → `multi-lab-sg` → Inbound rules → Edit → replace the `/32` entry.

### Security Group and UFW — two independent layers

The Security Group filters at the hypervisor — traffic blocked here never
reaches the OS. UFW operates inside the kernel. Both run simultaneously:
a Security Group misconfiguration is caught by UFW, and a UFW misconfiguration
does not expose the instance to the internet.

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
> Confirm and re-verify that `multi-lab-sg` is still selected before launching.

> **gp3 vs gp2:** gp3 provides 3,000 IOPS and 125 MB/s baseline at no extra
> cost. gp2 at 20 GiB delivers ~100 IOPS. Same price — always choose gp3.

---

## Step 4 — Elastic IP

The default public IP is dynamic — it changes on every stop/start cycle.
An Elastic IP provides a static public address at no cost while the instance
is running.

**EC2 → Elastic IPs → Allocate Elastic IP address → Allocate**\
**Actions → Associate Elastic IP address → Instance: `multi-lab-aws` → Associate**

| Field         | Value           |
|---------------|-----------------|
| Resource type | Instance        |
| Instance      | `multi-lab-aws` |

The Elastic IP replaces the dynamic public IP immediately. Update
`~/.ssh/config → HostName` and the WireGuard `Endpoint` field with the
static address — one-time change.

---

## Step 5 — First Connection

The instance is reachable ~30 seconds after launch (status: `running`).

```bash
# ~/.ssh/config
Host multi-lab-aws
  HostName <ELASTIC_IP>
  User ubuntu
  IdentityFile ~/.ssh/<your_key>
  Port 22                   # temporary — update to 22222 after hardening

ssh multi-lab-aws

uname -m                    # → aarch64
lsb_release -a              # → Ubuntu 24.04.x LTS

sudo apt update && sudo apt upgrade -y
```

> After WireGuard is deployed (hardening module), SSH targets the WireGuard
> address (`10.0.0.1`). The Elastic IP is the stable `Endpoint` in every
> client config — no updates needed on stop/start.

---

## Post-Deployment Checklist

- [ ] Free Tier alert and zero-spend budget active
- [ ] Instance `multi-lab-aws` running — status: `running`
- [ ] AMI confirmed: Ubuntu 24.04 LTS ARM64 (`uname -m` → `aarch64`)
- [ ] SSH working on port 22 (temporary)
- [ ] Security group `multi-lab-sg` attached — ports 22, 22222, 51820 open
- [ ] `apt update && apt upgrade -y` completed
- [ ] Elastic IP allocated and associated
- [ ] Instance stopped — Free Tier hours preserved

**Next:** [`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md) — apply OS hardening. After hardening: delete the port 22 inbound rule from `multi-lab-sg` and update `~/.ssh/config` to port 22222.