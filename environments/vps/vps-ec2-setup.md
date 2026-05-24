# VPS / EC2 — Setup

AWS infrastructure provisioning for a self-managed Ubuntu Server instance.
Scope: billing protection, key pair, security group, EC2 instance, and first
connection. OS-level configuration starts in
[`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md).

---

## Environment

| Parameter     | Value                                            |
|---------------|--------------------------------------------------|
| Provider      | AWS EC2                                          |
| Region        | eu-west-1 (Europe — Ireland)                     |
| Instance      | t4g.micro · 2 vCPU · 1 GB RAM · Graviton2 ARM64  |
| OS            | Ubuntu Server 24.04 LTS (ARM64)                  |
| Storage       | 20 GiB EBS gp3                                   |
| Public IP     | Elastic IP (recommended) or auto-assigned        |
| Instance name | `multi-lab-aws`                                  |
| Admin user    | `ubuntu` (default AMI user, non-root with sudo)  |

> **EBS always bills.** The volume persists and is billed regardless of
> instance state. Stopping the instance suspends compute billing only.
> Terminating the instance deletes the volume — only do this if
> decommissioning entirely.

---

## Step 1 — Billing protection

### What was done
Free Tier usage alerts and a zero-spend budget enabled before provisioning
any resource.

> If [`environments/aws-native/aws-native-setup.md`](../aws-native/aws-native-setup.md)
> has already been completed, this step is done — skip to Step 2.

**Console**

1. **Free Tier alert:** Billing and Cost Management → Billing Preferences →
   Alert Preferences → enable *Free Tier usage alerts*.
2. **Zero-spend budget:** Billing and Cost Management → Budgets → Create
   budget → select *Zero spend budget* template → confirm.

### Why
An unattended running instance accrues cost silently. The zero-spend budget
fires on the first cent charged regardless of cause — it is the minimum
safety net before any resource is provisioned.

### Verification
Billing and Cost Management → Budgets — confirm budget status shows *OK*
and the alert email address is correct.

---

## Step 2 — Key pair

### What was done
An Ed25519 key pair associated with the instance at launch time. AWS injects
the public key once — at instance creation. It cannot be added through the
standard console flow after launch.

**Console — Option A: import existing key (recommended if a key already exists)**

```bash
# On the host machine — display the public key to paste into the console
cat ~/.ssh/id_ed25519.pub
# → ssh-ed25519 AAAA... user@host
```

EC2 → Key Pairs → Actions → Import key pair:

| Field                | Value          |
|----------------------|----------------|
| Name                 | `multi-lab-key` |
| Public key contents  | paste output above |

> Reusing an existing key keeps the same identity across VM and EC2
> deployments — one key covers both environments.

**Console — Option B: create new key pair**

EC2 → Key Pairs → Create key pair:

| Field              | Value           |
|--------------------|-----------------|
| Name               | `multi-lab-key` |
| Key pair type      | ED25519         |
| Private key format | .pem            |

Download the `.pem` when prompted — AWS provides it once only.

**CLI — move and secure the downloaded key**

```bash
mv ~/Downloads/multi-lab-key.pem ~/.ssh/
chmod 600 ~/.ssh/multi-lab-key.pem
```

### Why
Ed25519 is the most modern and efficient key algorithm supported by OpenSSH.
Importing an existing key rather than creating a new one avoids managing
multiple private keys across environments — the same key that authenticates
to the local VM also authenticates to EC2.

### Verification

```bash
# Confirm key is in place with correct permissions
ls -la ~/.ssh/ | grep -E "id_ed25519|multi-lab-key"
# → -rw------- id_ed25519 or multi-lab-key.pem

# Confirm key fingerprint matches what was uploaded
ssh-keygen -lf ~/.ssh/id_ed25519.pub
# → note the fingerprint — verify it matches EC2 → Key Pairs → multi-lab-key
```

---

## Step 3 — Security group

### What was done
A security group `multi-lab-sg` created with default-deny inbound and
explicit allow rules for SSH (temporary and hardened) and WireGuard.

**Console**

EC2 → Security Groups → Create security group:

| Field       | Value                              |
|-------------|------------------------------------|
| Name        | `multi-lab-sg`                     |
| Description | `multi-lab-aws — managed manually` |
| VPC         | `multi-lab-vpc`                    |

> If [`environments/aws-native/aws-native-setup.md`](../aws-native/aws-native-setup.md)
> has not been completed, `multi-lab-vpc` does not exist — select the
> Default VPC. The default VPC has permissive baseline settings; replace
> with a custom VPC before any production use.

**Inbound rules:**

| Type       | Protocol | Port  | Source            | Description                         |
|------------|----------|-------|-------------------|-------------------------------------|
| Custom TCP | TCP      | 22    | My IP (`/32`)     | Temporary — pre-hardening only      |
| Custom TCP | TCP      | 22222 | My IP (`/32`)     | SSH — post-hardening                |
| Custom UDP | UDP      | 51820 | 0.0.0.0/0, ::/0   | WireGuard VPN                       |

**Outbound rules:**

| Type        | Protocol | Port range | Destination       |
|-------------|----------|------------|-------------------|
| All traffic | All      | All        | 0.0.0.0/0, ::/0   |

> **Port 22 — temporary rule:** Ubuntu Server 24.04 starts SSH on port 22
> by default. This rule is required for the first connection and for hardening
> Step 3, which moves SSH to port 22222. The port 22 rule is removed in
> [`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md)
> Step 3 — do not delete it now.

> **Source IP restriction:** both SSH rules restrict source to `My IP (/32)`.
> Update when your IP changes:
> ```bash
> curl -s ifconfig.me
> ```
> EC2 → Security Groups → `multi-lab-sg` → Inbound rules → Edit →
> replace the `/32` entry.

### Why
The Security Group filters at the hypervisor layer — traffic blocked here
never reaches the OS. UFW operates inside the kernel. Both run simultaneously:
a Security Group misconfiguration is caught by UFW, and a UFW misconfiguration
does not expose the instance to the internet. Two independent layers, neither
trusting the other.

Port 22 is opened temporarily to allow the first SSH connection before
hardening changes the port. Restricting it to `My IP` limits exposure to
the minimum required window.

### Verification

**Console**
EC2 → Security Groups → `multi-lab-sg` → Inbound rules — confirm three
rules: port 22 (My IP), port 22222 (My IP), port 51820 (0.0.0.0/0).

---

## Step 4 — EC2 instance

### What was done
EC2 instance `multi-lab-aws` launched with Ubuntu Server 24.04 LTS ARM64,
t4g.micro, gp3 storage, and the key pair and security group from Steps 2–3.

**Console**

EC2 → Instances → Launch Instance:

| Field                 | Value                                       |
|-----------------------|---------------------------------------------|
| Name                  | `multi-lab-aws`                             |
| AMI                   | Ubuntu Server 24.04 LTS — **64-bit (Arm)**  |
| Instance type         | `t4g.micro` — verify *Free tier eligible*   |
| Key pair              | `multi-lab-key`                             |
| Security group        | `multi-lab-sg`                              |
| Storage               | 20 GiB — **gp3** (not gp2)                 |
| Auto-assign public IP | Disabled — Elastic IP assigned in Step 5    |

> **AMI change warning:** selecting Ubuntu 24.04 after modifying other
> settings triggers *"Some of your current settings will be changed or
> removed"*. This is expected — the wizard resets suggested defaults.
> Confirm and re-verify that `multi-lab-sg` is still selected before launching.

### Why
t4g.micro (Graviton2 ARM64) is Free Tier eligible in eu-west-1 and matches
the ARM64 architecture used in the local VM — consistent tooling and behavior
across both environments. gp3 delivers 3,000 IOPS and 125 MB/s baseline at
no extra cost versus gp2 at the same price point — always prefer gp3.
`Auto-assign public IP` is disabled because Step 5 assigns a static Elastic
IP — the auto-assigned dynamic IP would be replaced immediately and serves
no purpose.

### Verification

**Console**
EC2 → Instances → `multi-lab-aws` — Instance state: *Running*,
Status checks: *2/2 checks passed* (allow ~2 minutes after launch).

---

## Step 5 — Elastic IP

### What was done
A static Elastic IP allocated and associated with `multi-lab-aws`.

> | Scenario | Recommendation |
> |---|---|
> | Instance stopped and started regularly | Elastic IP — free while instance is running, prevents endpoint changes |
> | Instance never stopped | Auto-assigned public IP sufficient — skip this step |

> **Elastic IP billing:** free only while associated to a **running** instance.
> A stopped instance with an associated Elastic IP **is billed** (~$0.005/hr).
> An unassociated Elastic IP is also billed. Release it if the instance is
> decommissioned.

**Console**

EC2 → Elastic IPs → Allocate Elastic IP address → Allocate.

EC2 → Elastic IPs → select the new address → Actions →
Associate Elastic IP address:

| Field         | Value           |
|---------------|-----------------|
| Resource type | Instance        |
| Instance      | `multi-lab-aws` |

The Elastic IP replaces the instance's public address immediately.

### Why
The default public IP assigned at launch changes on every stop/start cycle.
Any client config that references the instance IP — `~/.ssh/config`,
WireGuard `Endpoint`, DNS records — would require updating after every
restart. The Elastic IP is a static handle to the instance regardless of
its state history, making it a one-time configuration.

### Verification

**Console**
EC2 → Instances → `multi-lab-aws` → Public IPv4 address — confirm it
matches the Elastic IP address shown in EC2 → Elastic IPs.

**CLI**
```bash
curl -s ifconfig.me     # run from inside the instance after first connection
# → must match the Elastic IP
```

---

## Step 6 — First connection

### What was done
SSH client alias configured on the host machine and first connection
verified on the temporary port 22.

On the **host machine**, add to `~/.ssh/config`:

```bash
Host multi-lab-aws
HostName <ELASTIC_IP>
User ubuntu
IdentityFile ~/.ssh/id_ed25519
Port 22 # temporary — updated to 22222 after hardening
```
```bash
# First connection using SSH
ssh multi-lab-aws
# → shell prompt on the instance

uname -m                    # → aarch64
lsb_release -a              # → Ubuntu 24.04.x LTS
```

### Why
The `multi-lab-aws` alias establishes the hostname used consistently across
the repo and in subsequent module docs. Connecting on port 22 with key-based
auth is intentional at this stage — SSH hardening (port change to 22222,
`sshd_config` lockdown, password auth disabled) is applied in the hardening
module. The `ubuntu` user is the default AMI user — a named admin user is
created in hardening Step 0.

### Verification

```bash
ssh multi-lab-aws
# → shell prompt confirms key auth and network reachability

# Confirm instance identity
uname -m      # → aarch64
cat /etc/os-release | grep VERSION
# → VERSION="24.04.x LTS (Noble Numbat)"
```

---

**Next:** [`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md)

> After hardening: update `~/.ssh/config` entry for `multi-lab-aws` —
> change `Port 22` to `Port 22222`. The port 22 inbound rule in `multi-lab-sg`
> is removed in hardening Step 3.
