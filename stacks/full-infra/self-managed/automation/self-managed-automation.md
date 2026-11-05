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
| --- | --- | --- |
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
>
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

---

## Step 7b — Greenfield provisioning from a clean account

### What was done

Provision the entire self-managed EC2 infrastructure directly from a clean AWS account without running an import cycle.

> **Account Isolation Warning:** Do not deploy the `aws-native` hardening module in the same AWS account as the self-managed stack. Both stacks share identical global and regional resource names (`multi-lab-vpc`, `multi-lab-sg`, `multi-lab-ec2-role`), causing collision errors during resource creation.

> **Billing Alert (EBS & Elastic IP):** The 20 GiB gp3 root volume persists and accrues cost even when the instance is stopped. The allocated Elastic IP is free only while associated with a running EC2 instance; stopped instances with associated Elastic IPs or unassociated Elastic IPs accrue hourly charges (~$0.005/hr). Release resources when no longer needed.

Prerequisites:

- AWS CLI configured with profile `multi-lab-admin` in region `eu-west-1`.
- Terraform `>= 1.15.6`.
- Dedicated Ed25519 lab SSH key generated at `~/.ssh/id_ed25519_multi-lab`.

Query the latest official Canonical Ubuntu Server 24.04 LTS ARM64 AMI ID:

**Run on the control node (Mac):**

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --region eu-west-1 \
  --profile multi-lab-admin \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
  --query "sort_by(Images,&CreationDate)[-1].[ImageId,Name]"
# → ["ami-0xxxxxxxxxxxxxxxxx", "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-..."]
```

Activate the configuration files and initialize the working directory:

**Run on the control node (Mac):**

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf
cp terraform.tfvars.example terraform.tfvars

terraform init
```

Set the discovered `ami_id` in `terraform.tfvars`. Generate the execution plan and apply the infrastructure, passing your current public IP to open temporary SSH bootstrap access (port 22) and hardened SSH access (port 22222) in the Security Group:

**Run on the control node (Mac):**

```bash
terraform plan \
  -var "ssh_bootstrap_cidr=$(curl -s ifconfig.me)/32" \
  -var "ssh_hardened_cidr=$(curl -s ifconfig.me)/32"

terraform apply \
  -var "ssh_bootstrap_cidr=$(curl -s ifconfig.me)/32" \
  -var "ssh_hardened_cidr=$(curl -s ifconfig.me)/32"

terraform output
# → instance_public_ip = "X.X.X.X"
# → instance_id = "i-0xxxxxxxxxxxxxxxxx"
```

Verify initial SSH connection using the default `ubuntu` user and confirm AWS Systems Manager connectivity:

**Run on the control node (Mac):**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab ubuntu@<EIP>
# → authenticates successfully; exit session

aws ssm describe-instance-information \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --query "InstanceInformationList[*].{ID:InstanceId,Status:PingStatus}"
# → PingStatus: "Online"
```

📄 [`main.tf.example`](terraform/main.tf.example)
📄 [`variables.tf`](terraform/variables.tf)
📄 [`terraform.tfvars.example`](terraform/terraform.tfvars.example)
📄 [`outputs.tf.example`](terraform/outputs.tf.example)

### Why

A reproducible greenfield deployment allows provisioning the self-managed EC2 target on demand in any clean AWS account without importing pre-existing resources. The self-contained stack deploys the dedicated VPC (`10.0.0.0/16`), public subnet, route table, internet gateway, Elastic IP, and EC2 instance profile (`multi-lab-ec2-role`) with `AmazonSSMManagedInstanceCore` attached.

IMDSv2 is enforced at the instance layer (`http_tokens = "required"`, `http_put_response_hop_limit = 1`) to eliminate SSRF attack vectors against the metadata service. Dynamic ingress rules open ports 22 and 22222 restricted strictly to the operator's current public workstation IP (`/32`), preventing exposure to automated scanning bots before WireGuard is fully established.

### Verification

Confirm that the instance is reachable over SSH and registered with AWS Systems Manager Session Manager:

**Run on the control node (Mac):**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab ubuntu@<EIP> uname -m
# → aarch64

aws ssm describe-instance-information \
  --profile multi-lab-admin \
  --region eu-west-1 \
  --query "InstanceInformationList[*].{ID:InstanceId,Status:PingStatus}"
# → [{"ID": "i-0xxxxxxxxxxxxxxxxx", "Status": "Online"}]
```

---

## Phase 3 — Ansible configuration layer

Terraform provisions the EC2 host; Ansible configures the operating system of
both self-managed targets (local VM and EC2) from the same roles. The roles
deploy the files in `modules/<module>/self-managed/configs/` — the single
source of truth — and reproduce, step by step, what the manual module docs
describe. All commands run on the control node (the Mac) from:

**Run on the control node (Mac):**

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/ansible
```

This phase starts with the local VM. EC2 is added in the hardening EC2 block,
once the VM has passed every gate.

> **Prerequisites:** a local VM created with
> [`environments/local/local-vm-setup.md`](../../../../environments/local/local-vm-setup.md)
> (ends at the first SSH connection), Python 3.12 to 3.14 (not 3.15) on the control node, and
> the repository cloned at `~/build-your-infra`.

---

## Step 8 — Prepare the control node

### What was done

Create an isolated Python environment, install the pinned dependencies and
collections, create the real inventory files from their `.example` pairs, and
install the public key on the installer user so Ansible can connect without a
password.

> **Python version:** verify your interpreter with `python3.14 --version` before
> creating the virtual environment. `ansible-core 2.21` supports Python 3.12 to
> 3.14 on the control node; Python 3.15 is incompatible and fails at startup.
> If Python 3.14 is not installed, use an explicit `python3.12` or `python3.13`
> binary.

**Run on the control node (Mac):**

```bash
python3.14 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml

cp inventories/hosts.yml.example inventories/hosts.yml
cp inventories/host_vars/multi-lab-local.yml.example inventories/host_vars/multi-lab-local.yml

ssh-copy-id -i ~/.ssh/CHANGE_ME_lab_key.pub CHANGE_ME_installer_user@192.168.1.CHANGE_ME
```

Edit `inventories/host_vars/multi-lab-local.yml` (created from its `.example`)
and replace the example values with your real environment parameters:
installer user (`vm_initial_user`), administrator account (`admin_username`),
current reachable IP (`vm_lan_ip`), network interface (`vm_interface`), static
IP with prefix (`vm_static_ip`, e.g. `192.168.1.50/24`), gateway router
(`vm_gateway`) and trusted LAN subnet (`lan_trusted_cidr`, e.g.
`192.168.1.0/24`). Inventory editing is done exclusively in this host file; no
host-specific values are edited in `inventories/group_vars/vm.yml`.

`vm_initial_user` is the account created by the Ubuntu installer; Ansible uses
it for the first connection, before hardening. `admin_username` is the
non-root administrator account that hardening restricts SSH to
(`AllowUsers`). On the local VM both can be the same account, since the
installer user already is the primary administrator with `sudo`. On EC2 the
first connection uses the AMI user (`ubuntu`) and Step 0 creates the
administrator account.

#### SSH Key Configuration

Generate and use a dedicated Ed25519 SSH key pair for the lab (e.g., `~/.ssh/CHANGE_ME_lab_key`),
rather than personal, system, or GitHub keys. Configure both the public key installed
onto the dedicated administrator account (`admin_public_key_file: "~/.ssh/CHANGE_ME_lab_key.pub"`)
and the private key used by the Ansible control node (`ansible_ssh_private_key_file: "~/.ssh/CHANGE_ME_lab_key"`)
in `inventories/host_vars/multi-lab-local.yml`.

In `~/.ssh/config`, add `IdentityFile ~/.ssh/CHANGE_ME_lab_key` and `IdentitiesOnly yes` to the
`Host multi-lab-local` block. Step 3 hardening restricts authentication attempts to 3
(`MaxAuthTries 3`); without `IdentitiesOnly yes`, the SSH client presents all keys loaded
in `ssh-agent`, which can exhaust allowed attempts and trigger a lockout before reaching
the correct key. If the private key is protected with a passphrase, load it into your agent
once per terminal session using `ssh-add ~/.ssh/CHANGE_ME_lab_key`.

#### Connection States Lifecycle (`connection_mode`)

Host inventories track three progressive network connection states via `connection_mode`:

| Mode | Destination Port | SSH User | Target IP | When it applies |
| --- | --- | --- | --- | --- |
| `pre` | `22` | Initial OS user (`vm_initial_user` on VM, `ubuntu` on EC2) | LAN IP (`vm_lan_ip`) or Elastic IP (`ec2_eip`) | Default state. Used during initial provisioning (`bootstrap.yml`) and pre-hardening tasks. |
| `hardened` | `22222` | Dedicated administrator (`admin_username`) | LAN IP (`vm_lan_ip`) or Elastic IP (`ec2_eip`) | Set in `host_vars/<host>.yml` after completing Step 3 (SSH Hardening), before WireGuard perimeter lockdown. |
| `wg` | `22222` | Dedicated administrator (`admin_username`) | WireGuard interface IP (`172.16.0.1` on EC2 hub, `172.16.0.3` on VM peer) | Set in `host_vars/<host>.yml` after Step 5 (WireGuard) is deployed and the VPN tunnel on the Mac control node is active. |

> **Transition Timing:** Never switch to `connection_mode: "hardened"` until Step 3 has successfully reconfigured and restarted `sshd` on port 22222. Never switch to `connection_mode: "wg"` until the WireGuard tunnel on your control node (Mac) is up and you have confirmed end-to-end reachability to the VPN IP (`ping 172.16.0.1` or `ssh -p 22222 <admin_user>@172.16.0.1`).

> **Optional but recommended:** take a hypervisor snapshot of the VM before
> the first run.

📄 [`requirements.txt`](ansible/requirements.txt)
📄 [`requirements.yml`](ansible/requirements.yml)
📄 [`inventories/hosts.yml.example`](ansible/inventories/hosts.yml.example)
📄 [`inventories/host_vars/multi-lab-local.yml.example`](ansible/inventories/host_vars/multi-lab-local.yml.example)
📄 [`inventories/host_vars/multi-lab-vps.yml.example`](ansible/inventories/host_vars/multi-lab-vps.yml.example)

### Why

`requirements.txt` and `requirements.yml` pin the exact versions of
`ansible-core`, `ansible-lint` and the two collections, so every run — on the
control node, on a delegated agent and in CI — uses the same toolchain. The
virtual environment keeps those versions isolated from the system Python.
The `passlib` package is included because the `password_hash` filter used in
`bootstrap.yml` runs locally on the control node, and modern Python releases on
macOS (Python >= 3.13) remove the standard library `crypt` module.
`hosts.yml` and `host_vars/*.yml` contain real addresses and usernames, so
they are gitignored; only the `.example` pairs are versioned. Ansible runs over
SSH and cannot type a password, so key authentication on the installer user is
required before the first connection.

### Verification

**Run on the control node (Mac):**

```bash
ansible --version
# → ansible [core 2.21.6]

ansible-galaxy collection list | grep -E "community.general|ansible.posix"
# → community.general ...
# → ansible.posix ...

ansible-playbook playbooks/ping.yml --limit multi-lab-local
# → multi-lab-local : ok=2 changed=0 unreachable=0 failed=0
```

### Troubleshooting

- **Python 3.15 incompatibility:** `ansible-core 2.21` supports Python 3.12 to 3.14 on the control node. Python 3.15 is incompatible and fails at startup with module import errors. Use Python 3.14 to create `.venv`.
- **`passlib` requirement on modern macOS:** Python >= 3.13 removes the standard library `crypt` module. The `passlib` package is pinned in `requirements.txt` to enable the `password_hash('sha512', rounds=65536)` Jinja filter on the local macOS control node without depending on deprecated system C-bindings.

---

## Step 9 — Bootstrap the admin user (Hardening Step 0)

### What was done

Ensure the dedicated non-root administrator account (`admin_username`) exists,
belongs to the `sudo`, `adm` and `admin` groups, and has your Ed25519 public
key installed. If the account does not exist, the playbook creates it and sets
the password you type at the prompt. If it already exists — for example, when
`admin_username` is the installer user — the playbook only adds the missing
group memberships and the key, and leaves the current password untouched.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/bootstrap.yml --limit multi-lab-local --ask-become-pass
# → BECOME password: (the installer user's sudo password)
# → Admin password: (hidden)
```

The `Admin password` prompt is only applied when the account is created; for an
existing account, enter its current password (the value is ignored). The same
playbook can be run again safely.

📄 [`roles/hardening/tasks/step_00_admin_user.yml`](ansible/roles/hardening/tasks/step_00_admin_user.yml)

### Why

Step 3 of hardening restricts SSH to `AllowUsers <admin_username>` with key-only
authentication. The user and its key must exist and be verified before that
step, or the host is locked out. The password is asked at runtime and hashed in
memory, so no password or hash is ever written to the repository. A password
for `sudo` is kept on purpose: it is a second factor for any privileged
operation even when SSH uses keys.

> **Do not continue until the check below succeeds from a new terminal.**
> The access chain (Step 3 onward) disables password authentication.

### Verification

Test passwordless SSH authentication with the newly provisioned administrator account from a new terminal window:

**Run on the control node (Mac):**

```bash
ssh -i ~/.ssh/CHANGE_ME_lab_key -o IdentitiesOnly=yes -p 22 <admin_username>@<vm_lan_ip>
# → must authenticate without a password prompt
```

Verify account identity, group memberships, and directory permissions inside the SSH session on the VM:

**Run on the VM (inside the SSH session):**

```bash
id <admin_username>
# → uid=... groups=...,27(sudo),4(adm),...

ls -la /home/<admin_username>/.ssh/
# → drwx------ .ssh            <admin_username>:<admin_username>
# → -rw------- authorized_keys <admin_username>:<admin_username>
```

Exit the SSH session. Back on the control node, execute the bootstrap playbook again to verify that repeated runs report zero changes:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/bootstrap.yml --limit multi-lab-local --ask-become-pass
# → changed=0 on the second run
```

---

## Step 10 — System update and automated security upgrades (Hardening Step 1)

### What was done

Update the package index, apply a full upgrade, install the package audit tools
and unattended-upgrades, enable the weekly `debsums` check and deploy the two
unattended-upgrades configuration files. Review the change set first with
`--check --diff`, then apply.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step1 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step1 --ask-become-pass
```

📄 [`configs/unattended-upgrades/50unattended-upgrades`](../../../../modules/hardening/self-managed/configs/unattended-upgrades/50unattended-upgrades)
📄 [`configs/unattended-upgrades/20auto-upgrades`](../../../../modules/hardening/self-managed/configs/unattended-upgrades/20auto-upgrades)

### Why

Same reasoning as manual Step 1: known CVEs are exploited automatically, and
automating only security patches keeps the system current without risking
unattended service changes (`Automatic-Reboot: false`). `--check --diff` shows
exactly what Ansible would change before it touches the host — a habit that
matters more as the playbook grows. A second run reporting zero changes proves
the role is idempotent.

### Verification

Verify idempotence by executing the step again:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step1 --ask-become-pass
# → changed=0 on the second run
```

Verify service status, upgrade dry run, and package integrity on the target machine:

**Run on the VM (hypervisor console or SSH):**

```bash
sudo unattended-upgrade --dry-run --debug
systemctl status unattended-upgrades
grep CRON_CHECK /etc/default/debsums
# → CRON_CHECK=weekly
sudo debsums -s
# → no output = package integrity clean
```

---

## Step 11 — Static IP configuration (Hardening Step 2, VM only)

### What was done

Deploy the hardened Netplan configuration and the systemd-networkd drop-in that
fixes the Netplan DHCP bug, then apply them. The role skips this step on EC2.

> **Operational warnings & lockout prevention:**
>
> - **DHCP pool exclusion:** Choose `vm_static_ip` strictly outside your router's DHCP pool to prevent IP collisions and subtle connection drops.
> - **IP consistency & recovery:** `vm_static_ip` must be consistent with the host IP reached in Step 0. If a network misconfiguration occurs, SSH connectivity is lost immediately; recovery requires logging in directly through the hypervisor console (VMware / VirtualBox window). Keep the console open and take a hypervisor snapshot before applying.
> - **Netplan file precedence & cloud-init override:** Netplan processes files in `/etc/netplan/` in alphabetical order where lexicographically later files override earlier ones (e.g. `50-cloud-init.yaml` overrides `00-installer-config.yaml` and re-enables dynamic DHCP). The role automatically quarantines any extra `*.yaml` files to `/root/netplan-backup/` and disables cloud-init network configuration (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`) to ensure the static configuration persists across reboots.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step2 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step2 --ask-become-pass
```

📄 [`configs/netplan/00-installer-config.yaml`](../../../../modules/hardening/self-managed/configs/netplan/00-installer-config.yaml)
📄 [`configs/netplan/no-dhcp.conf`](../../../../modules/hardening/self-managed/configs/netplan/no-dhcp.conf)

### Why

Same reasoning as manual Step 2: a static address is a prerequisite for every
service, and the drop-in disables the dynamic address that Netplan 0.106 still
requests. The role fills the placeholders of the repository files (`192.168.X.X`,
gateway, interface) from the inventory, so the committed configs stay the single
source of truth.

### Verification

Verify interface addressing, default routing, and DNS configuration on the VM:

**Run on the VM (hypervisor console or SSH):**

```bash
ip a show <vm_interface>
# → single static IP, no secondary dynamic address

ip route show
# → default route via <vm_gateway>

resolvectl status | grep "DNS Servers"
# → 9.9.9.9 149.112.112.112
```

Execute the entire Block 2A baseline from the control node to verify complete idempotence:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_2a --ask-become-pass
# → changed=0 (gate for block 2A: second run with no changes)
```

### Troubleshooting

- **IP collision inside DHCP pool:** Ensure `vm_static_ip` is selected strictly outside your router's DHCP reservation pool to prevent duplicate IP conflicts.
- **Conflicting Netplan / cloud-init files:** If DHCP continues to be acquired dynamically on reboot, inspect `/etc/netplan/`. The role automatically moves conflicting files to `/root/netplan-backup/` and disables cloud-init network configuration (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`), but verify no custom drop-ins in `/etc/systemd/network/` override `DHCP=no`.
- **Pre-flight assertion errors (`< >` or `CHANGE_ME`):** The assertion fails if `vm_interface`, `vm_static_ip`, or `vm_gateway` contains placeholder strings (`<`, `>`, `CHANGE_ME`) or if the VM is not currently reachable at the target IP. Replace all values in the real `inventories/host_vars/multi-lab-local.yml` before running.

---

## Step 12 — EC2 bootstrap (Hardening Steps 0–1)

### What was done

Configure the inventory for `multi-lab-vps`, accept the EC2 host key fingerprint into the control node's `known_hosts`, provision the dedicated administrator account on the instance via `bootstrap.yml` (Step 0), and execute system updates and automated security patching (Step 1). Step 2 (static Netplan IP) is automatically skipped on EC2 because network addressing is managed by AWS VPC DHCP and the Elastic IP.

Create `inventories/host_vars/multi-lab-vps.yml` from its `.example` template:

**Run on the control node (Mac):**

```bash
cd ~/build-your-infra/stacks/full-infra/self-managed/automation/ansible
cp inventories/host_vars/multi-lab-vps.yml.example inventories/host_vars/multi-lab-vps.yml
```

Edit `inventories/host_vars/multi-lab-vps.yml` and configure your instance parameters:

- `ec2_eip`: Elastic IP address from `terraform output instance_public_ip`.
- `admin_username`: dedicated administrator account name.
- `admin_public_key_file`: path to your dedicated Ed25519 public key (`~/.ssh/id_ed25519_multi-lab.pub`).
- `ansible_ssh_private_key_file`: path to your private key (`~/.ssh/id_ed25519_multi-lab`).

Establish initial SSH connectivity as `ubuntu` to accept the host key into `~/.ssh/known_hosts`:

**Run on the control node (Mac):**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab ubuntu@<ec2_eip>
# → Type 'yes' to accept host key fingerprint; then exit the session
exit
```

Execute the bootstrap playbook to create the administrative user and replicate authorized keys:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/bootstrap.yml --limit multi-lab-vps
```

Apply baseline system updates and configure automated unattended security upgrades:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step1 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step1 --ask-become-pass
```

📄 [`inventories/host_vars/multi-lab-vps.yml.example`](ansible/inventories/host_vars/multi-lab-vps.yml.example)
📄 [`playbooks/bootstrap.yml`](ansible/playbooks/bootstrap.yml)
📄 [`roles/hardening/tasks/step_00_admin_user.yml`](ansible/roles/hardening/tasks/step_00_admin_user.yml)
📄 [`roles/hardening/tasks/step_01_updates.yml`](ansible/roles/hardening/tasks/step_01_updates.yml)

### Why

The default AMI user `ubuntu` is a predictable identity. Creating a named administrative user provides auditable log attribution for privileged operations. Replicating the launch key from `/home/ubuntu/.ssh/authorized_keys` ensures immediate passwordless key authentication for the administrator while keeping `ubuntu` intact for cloud-init compatibility. Applying Step 1 ensures known CVE vulnerabilities are patched before configuring perimeter security.

### Verification

Verify administrator account provisioning and key authentication from the control node:

**Run on the control node (Mac):**

```bash
ssh -i ~/.ssh/id_ed25519_multi-lab <admin_username>@<ec2_eip>
# → authenticates without password prompt
```

Verify account groups and unattended-upgrades service state inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
id <admin_username>
# → uid=1001(<admin_username>) groups=...,27(sudo),4(adm)...

systemctl status unattended-upgrades
# → Active: active (running)
```

Exit the session and verify idempotence on the control node:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step1 --ask-become-pass
# → changed=0
```

---

### Targets & Execution Order

| Target | Inventory Alias | `--limit` | Real `host_vars` File | `connection_mode` Used | Notes |
| --- | --- | --- | --- | --- | --- |
| AWS EC2 | `multi-lab-vps` | `--limit multi-lab-vps` | `inventories/host_vars/multi-lab-vps.yml` | `pre` → `hardened` → `wg` | WireGuard VPN hub (`172.16.0.1`). Deployed first. |
| Local VM | `multi-lab-local` | `--limit multi-lab-local` | `inventories/host_vars/multi-lab-local.yml` | `pre` → `hardened` → `wg` | WireGuard client peer (`172.16.0.3`). Deployed second. |

---

## Step 13 — SSH hardening (Hardening Step 3)

> Applies to: EC2 (multi-lab-vps) · VM (multi-lab-local)

### What was done

Deploy the hardened `sshd_config` replacing the `AllowUsers` placeholder with the administrator username, install pre-authentication legal warning banners to `/etc/issue.net` and `/etc/issue`, remove unused legacy RSA and ECDSA host keys from disk, and restart the OpenSSH service.

> **Lockout Prevention Pre-checks:** The playbook validates that the administrator user exists and `/home/<admin_username>/.ssh/authorized_keys` is non-empty before touching configuration files.
>
> **EC2 Security Group Prerequisite:** Ensure port `22222` is allowed in Security Group `multi-lab-sg` for your workstation IP (`ssh_hardened_cidr`) before running this step. Keep an active SSH session or SSM Session Manager open in a separate window during deployment.

#### EC2 (multi-lab-vps)

**EC2 · multi-lab-vps · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step3 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step3 --ask-become-pass
```

Update `connection_mode: "hardened"` in your real host variables file `inventories/host_vars/multi-lab-vps.yml`.

#### Local VM (multi-lab-local)

On the local VM, the initial user is the OS installer account (`vm_initial_user`, typically `sysadmin`) rather than `ubuntu`. Access migrates identically to the dedicated administrator (`admin_username`).

**VM · multi-lab-local · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step3 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step3 --ask-become-pass
```

Update `connection_mode: "hardened"` in your real host variables file `inventories/host_vars/multi-lab-local.yml`.

📄 [`configs/ssh/sshd_config`](../../../../modules/hardening/self-managed/configs/ssh/sshd_config)
📄 [`configs/ssh/issue.net.template`](../../../../modules/hardening/self-managed/configs/ssh/issue.net.template)

### Why

Disabling password authentication and restricting access exclusively to Ed25519 keys eliminates brute-force dictionary attacks. Whitelisting `AllowUsers` prevents lateral movement using unauthorized accounts. Moving to port 22222 drastically reduces internet scanner noise in `auth.log`. Removing RSA and ECDSA keys enforces single-algorithm host identity.

### Verification

#### EC2 (multi-lab-vps)

Test passwordless SSH authentication on the new hardened port:

**EC2 · multi-lab-vps · Run on the control node (Mac):**

```bash
ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@<ec2_eip>
# → authenticates successfully on port 22222

ssh -p 22222 -o PubkeyAuthentication=no -o PreferredAuthentications=password <admin_username>@<ec2_eip>
# → Permission denied (publickey)
```

#### Local VM (multi-lab-local)

Test passwordless SSH authentication on the new hardened port:

**VM · multi-lab-local · Run on the control node (Mac):**

```bash
ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@<vm_static_ip>
# → authenticates successfully on port 22222

ssh -p 22222 -o PubkeyAuthentication=no -o PreferredAuthentications=password <admin_username>@<vm_static_ip>
# → Permission denied (publickey)
```

#### Both Targets

Verify effective daemon configuration inside the SSH session:

**EC2 & VM · Run on the target host (SSH session):**

```bash
sudo sshd -T | grep -E "port|permitrootlogin|passwordauthentication|allowusers"
# → port 22222
# → permitrootlogin no
# → passwordauthentication no
# → allowusers <admin_username>

ls /etc/ssh/ssh_host_*
# → /etc/ssh/ssh_host_ed25519_key
# → /etc/ssh/ssh_host_ed25519_key.pub
```

### Troubleshooting

- **Sudo password prompt (`BECOME password`):** From this step forward, the `BECOME password` prompted by Ansible is the administrator account password (`admin_username`) created in Step 0, NOT the original installer or cloud-init (`ubuntu`) password.
- **Connection mode transition:** Add or update `connection_mode: "hardened"` directly in your target host variables file (`inventories/host_vars/multi-lab-vps.yml` on EC2, `inventories/host_vars/multi-lab-local.yml` on VM), not in example templates or group variables.

---

## Step 14 — UFW firewall (Hardening Step 4)

> Applies to: EC2 (multi-lab-vps) · VM (multi-lab-local)

### What was done

Configure UFW default policies to deny inbound and allow outbound traffic, apply rate limiting on port 22222/tcp, configure logging level to `medium`, deploy `/etc/ufw/sysctl.conf` to persist `log_martians=1`, and enable the UFW firewall service.

#### EC2 (multi-lab-vps)

**EC2 · multi-lab-vps · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step4 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step4 --ask-become-pass
```

#### Local VM (multi-lab-local)

On the local VM, UFW activates with SSH on port 22222 without an outer AWS Security Group. There is no risk of cloud SG cut-off, but testing secondary SSH access before closing the active session is mandatory:

**VM · multi-lab-local · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step4 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step4 --ask-become-pass
```

📄 [`configs/ufw/sysctl.conf`](../../../../modules/hardening/self-managed/configs/ufw/sysctl.conf)

### Why

Default-deny packet filtering ensures no services are exposed to the network unless explicitly permitted. Rate limiting on port 22222 caps connection attempts at the network layer before reaching the SSH daemon. Medium logging captures dropped packets against the default policy for auditing.

### Verification

Verify UFW status and active firewall rules inside the SSH session:

**EC2 & VM · Run on the target host (SSH session):**

```bash
sudo ufw status verbose
# → Status: active
# → Logging: on (medium)
# → Default: deny (incoming), allow (outgoing), disabled (routed)

sudo ufw status numbered
# → 22222/tcp                   LIMIT IN    Anywhere
```

---

## Step 15 — WireGuard VPN (Hardening Step 5)

> Applies to: EC2 (multi-lab-vps) · VM (multi-lab-local)

### What was done

Install WireGuard, generate the server key pair idempotently with restrictive permissions (`0600`), deploy `wg0.conf` for the VPN hub (EC2) or client peer (VM), enable kernel packet forwarding in `/etc/sysctl.d/99-wireguard.conf`, enable and start `wg-quick@wg0`, and configure UFW rules for the VPN tunnel (`51820/udp`, SSH on `wg0` only, routed forwarding on the hub).

### Safe Sequence & Progression Protocol

Execute the exact validated sequence below to transition from public SSH to the WireGuard perimeter without lockout risk:

1. **Obtain Mac Public Key Before Initial Run:**
   Retrieve the public key of your Mac control node.
   - If using the WireGuard macOS App: open the tunnel, click **Edit**, and copy the **Public key**.
   - If using CLI (`wireguard-tools`):

     ```bash
     awk '/PrivateKey/ {print $3}' /etc/wireguard/wg0.conf | wg pubkey
     ```

   - If no key pair exists yet on the Mac, generate one:

     ```bash
     wg genkey | tee mac_private.key | wg pubkey > mac_public.key
     ```

   Configure the 44-character public key in your real host variables file `inventories/host_vars/multi-lab-vps.yml`:

   ```yaml
   wireguard_peer_public_keys:
     mac: "<mac-public-key>"
     local_vm: "CHANGE_ME_LOCAL_VM_WIREGUARD_PUBLIC_KEY"
   ```

   Ansible enforces an assertion verifying that `mac` exists, contains no placeholder text (`CHANGE_ME`, `<`), and is valid 44-character base64 before deploying the hub.

2. **Deploy Step 5 on EC2 Hub (without `--check`):**
   Run the playbook with `hardening_wg_close_public_ssh: false` (the default). Execute without `--check` on initial deployment so the server key pair is generated on disk:

   **EC2 · multi-lab-vps · Run on the control node (Mac):**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
     --tags hardening_step5 --ask-become-pass
   ```

   Copy the displayed WireGuard Public Key from the Ansible output:
   `# → WireGuard Public Key for multi-lab-vps: <hub-public-key>`

3. **Configure Mac WireGuard Tunnel:**
   In your Mac WireGuard configuration (`/etc/wireguard/wg0.conf` or macOS App), retain the existing `[Interface]` section (or populate from `configs/wireguard/client-template.conf` with `Address = 172.16.0.2/32`). Update ONLY the `[Peer]` section with the hub parameters:

   ```ini
   [Peer]
   PublicKey           = <hub-public-key>
   Endpoint            = <ec2_eip>:51820
   AllowedIPs          = 172.16.0.0/24
   PersistentKeepalive = 25
   ```

   > ⚠️ **Security Rule:** Never copy or paste a PrivateKey. Each host generates and stores its private key locally; only public keys are shared.

4. **Activate Tunnel and Verify Connectivity:**
   Start the tunnel on the Mac and verify the handshake, ICMP ping, and SSH over VPN:

   **Mac · Run on the control node (Mac):**

   ```bash
   sudo wg-quick up wg0
   sudo wg show
   # → latest handshake: a few seconds ago, transfer: ...
   ping -c 3 172.16.0.1
   ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@172.16.0.1
   # → connects successfully over the encrypted VPN interface
   ```

5. **Close Public SSH on UFW and AWS Security Group:**
   With tunnel connectivity verified, set `hardening_wg_close_public_ssh: true` in your real host variables file `inventories/host_vars/multi-lab-vps.yml` and re-run Step 5 to delete the public rate-limited port 22222 rule from UFW:

   **EC2 · multi-lab-vps · Run on the control node (Mac):**

   ```bash
   ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
     --tags hardening_step5 --ask-become-pass
   ```

   Then update the AWS Security Group `multi-lab-sg` via Terraform with empty CIDR variables to close ports 22 and 22222 publicly:

   **Terraform · Run on the control node (Mac):**

   ```bash
   cd ~/build-your-infra/stacks/full-infra/self-managed/automation/terraform
   terraform apply -var "ssh_bootstrap_cidr=" -var "ssh_hardened_cidr="
   ```

6. **Switch Connection Mode in Inventory:**
   Update `connection_mode: "wg"` in your real host variables file `inventories/host_vars/multi-lab-vps.yml`. From this point forward, Ansible connects exclusively via `172.16.0.1:22222`.

#### Local VM (multi-lab-local)

The local VM acts as a VPN client (`172.16.0.3/32`), not a hub. It requires the EC2 hub to be deployed first, with `wireguard_hub_public_key` and `wireguard_endpoint` configured in `inventories/host_vars/multi-lab-local.yml`. Port `51820/udp` is not opened in UFW on the VM:

**VM · multi-lab-local · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step5 --ask-become-pass
```

📄 [`configs/wireguard/wg0.conf`](../../../../modules/hardening/self-managed/configs/wireguard/wg0.conf)
📄 [`configs/wireguard/client-template.conf`](../../../../modules/hardening/self-managed/configs/wireguard/client-template.conf)
📄 [`configs/sysctl/99-wireguard.conf`](../../../../modules/hardening/self-managed/configs/sysctl/99-wireguard.conf)

### Why

WireGuard provides cryptographic authentication at the network transport layer before application protocols engage. Restricting SSH exclusively to `wg0` makes port 22222 invisible to internet scanners. Kernel packet forwarding (`ip_forward = 1`) and UFW route forwarding enable the EC2 hub to relay traffic between connected client peers (Mac and local VM).

### Verification

Verify WireGuard tunnel status and peer handshakes on the EC2 hub:

**EC2 · Run on the instance (SSH session):**

```bash
sudo wg show
# → interface: wg0, listening port: 51820
# → peer: <mac_public_key>, latest handshake: X seconds ago, transfer: ...

sudo ufw status numbered
# → 51820/udp                  ALLOW IN    Anywhere
# → 22222/tcp on wg0           ALLOW IN    Anywhere
# → Anywhere on wg0            ALLOW FWD   Anywhere on wg0
```

Confirm that public SSH is blocked from outside the tunnel:

**Mac · Run on the control node (Mac):**

```bash
ssh -p 22222 -o ConnectTimeout=5 <admin_username>@<ec2_eip>
# → Connection timed out
```

### Troubleshooting

- **`Key is not the correct length or format`:** WireGuard public keys must be exactly 32 bytes encoded in base64 (44 characters ending with `=`). This error occurs when example placeholder text (such as `CHANGE_ME_...`) is left in `host_vars` or copied into `wg0.conf`. The role pre-flight assertion prevents deployment if the key is invalid.
- **Absence of Handshake (`latest handshake` missing in `wg show`):**
  - Verify AWS Security Group: port `51820/udp` must be allowed from `0.0.0.0/0` in `multi-lab-sg`.
  - Check for crossed keys: the client `[Peer] PublicKey` must equal the hub public key, and the hub `[Peer] PublicKey` must equal the client public key.
  - Check service logs: run `sudo journalctl -xeu wg-quick@wg0` on the hub to identify syntax or interface errors.
- **SSM Session Manager as Emergency Recovery Path:** If SSH connectivity is interrupted on EC2, start an AWS Systems Manager session to inspect and recover network access without open inbound ports:

  ```bash
  aws ssm start-session --target <instance_id> --profile multi-lab-admin
  ```

---

## Step 16 — Fail2Ban (Hardening Step 6)

> Applies to: EC2 (multi-lab-vps) · VM (multi-lab-local)

### What was done

Install Fail2Ban, deploy the `allowipv6.conf` override to suppress CLI warnings, and deploy `jail.local` configuring ban escalation policies across `sshd` and `recidive` jails using the UFW ban backend. Whitelist loopback, the WireGuard subnet (`172.16.0.0/24`), and `lan_trusted_cidr` (VM only).

#### EC2 (multi-lab-vps)

**EC2 · multi-lab-vps · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step6 --ask-become-pass
```

Verify full Block 2B execution on EC2:

**EC2 · multi-lab-vps · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_2b --ask-become-pass
# → changed=0 (gate for block 2B)
```

#### Local VM (multi-lab-local)

Deployment is identical to EC2 but operates on local LAN and VPN traffic:

**VM · multi-lab-local · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_step6 --ask-become-pass
```

Verify full Block 2B execution on VM:

**VM · multi-lab-local · Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-local \
  --tags hardening_2b --ask-become-pass
# → changed=0 (gate for block 2B)
```

📄 [`configs/fail2ban/jail.local`](../../../../modules/hardening/self-managed/configs/fail2ban/jail.local)
📄 [`configs/fail2ban/fail2ban.d/allowipv6.conf`](../../../../modules/hardening/self-managed/configs/fail2ban/fail2ban.d/allowipv6.conf)

### Why

Fail2Ban provides defense-in-depth at the application layer for any traffic reaching the host through the network perimeter. The `sshd` jail imposes a 48-hour ban upon 3 failed attempts, while `recidive` imposes a 30-day deterrent ban for repeat offenders.

### Verification

Verify active jails and aggressive filter mode inside the SSH session:

**EC2 & VM · Run on the target host (SSH session):**

```bash
sudo fail2ban-client status
# → Number of jail: 2
# → Jail list: recidive, sshd

sudo fail2ban-client status sshd
# → Currently banned: 0

sudo fail2ban-client get sshd failregex | wc -l
# → 33 (or greater)
```

---

## Step 17 — Kernel hardening (Hardening Step 7)

### What was done

Deploy `/etc/sysctl.d/99-z-hardening.conf` applying kernel hardening parameters across network stack, memory protections, filesystem controls, and core dump restrictions. The handler reloads runtime sysctl values across the entire system.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step7 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step7 --ask-become-pass
```

📄 [`configs/sysctl/99-z-hardening.conf`](../../../../modules/hardening/self-managed/configs/sysctl/99-z-hardening.conf)

### Why

The kernel exposes interfaces and capabilities by default that facilitate post-compromise exploitation. Restricting ptrace to child processes (`kernel.yama.ptrace_scope = 1`), hiding kernel pointers (`kernel.kptr_restrict = 2`), and restricting dmesg (`kernel.dmesg_restrict = 1`) prevent privilege escalation and information leakage. Network stack parameters block IP spoofing (`rp_filter = 1`), absorb SYN flood attacks with cryptographic cookies (`tcp_syncookies = 1`), and ignore ICMP redirects. The `99-z-` file prefix guarantees this configuration loads after vendor defaults in `/usr/lib/sysctl.d/` (such as `99-protect-links.conf`).

### Verification

Verify sysctl runtime parameters inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
# Confirm 99-z-hardening loads last among sysctl.d files
sudo sysctl --system | grep "Applying"

# Memory and privilege protections
sysctl kernel.randomize_va_space        # → 2
sysctl kernel.kptr_restrict             # → 2
sysctl kernel.dmesg_restrict            # → 1
sysctl kernel.sysrq                     # → 0
sysctl kernel.perf_event_paranoid       # → 3
sysctl kernel.unprivileged_bpf_disabled # → 2

# Filesystem protections
sysctl fs.suid_dumpable                 # → 0
sysctl fs.protected_fifos               # → 2
sysctl fs.protected_hardlinks           # → 1
sysctl fs.protected_symlinks            # → 1

# Network protections
sysctl net.ipv4.tcp_syncookies          # → 1
sysctl net.ipv4.tcp_rfc1337             # → 1
sysctl net.ipv4.conf.all.rp_filter      # → 1
sysctl net.ipv4.conf.all.accept_redirects    # → 0
sysctl net.ipv4.ip_forward              # → 1
```

---

## Step 18 — AppArmor (Hardening Step 8)

### What was done

Install `apparmor-utils`, `apparmor-profiles`, and `apparmor-profiles-extra` to expand Mandatory Access Control (MAC) enforcement and make available a library of pre-packaged application profiles in `/usr/share/apparmor/extra-profiles/`.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step8 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step8 --ask-become-pass
```

### Why

AppArmor restricts running programs to explicitly permitted capabilities, file paths, and network operations. Even if a future service (such as Nginx or BIND9) is compromised via an unpatched vulnerability, AppArmor confines the compromised process to what its profile permits, blocking lateral movement across the host.

### Verification

Verify AppArmor status and loaded profiles inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
sudo aa-status
# → shows loaded profiles and enforce mode active for base daemons

sudo dmesg | grep -i apparmor
# → no profile load errors or DENIED boot entries

ls /usr/share/apparmor/extra-profiles/ | wc -l
# → ~100 profiles available for downstream services
```

---

## Step 19 — Attack surface reduction: services and daemons (Hardening Step 9.1)

### What was done

Disable ModemManager, mask `packagekit` and `udisks2`, purge apport crash reporting packages (+ autoremove) and reload sysctl, migrate AWS Systems Manager Agent from snap to native apt deb on EC2, purge snapd, remove snap filesystem leftovers, and place snapd on apt hold.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_1 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_1 --ask-become-pass
```

### Why

Every running daemon represents potential attack surface. `packagekit` and `udisks2` use D-Bus socket activation without standard systemd install sections; masking symlinks them to `/dev/null` preventing activation. Apport sets `fs.suid_dumpable = 2` at runtime, creating readable SUID process core dumps; purging it permanently restores the hardened `fs.suid_dumpable = 0` baseline. On EC2, the AWS SSM Agent is pre-installed as a snap; migrating to the native debian package before purging snapd guarantees that out-of-band Systems Manager shell access remains fully functional without open inbound firewall ports.

### Verification

Verify service mask status, sysctl dumpable parameter, and package holds inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
systemctl is-enabled udisks2
# → masked

sysctl fs.suid_dumpable
# → fs.suid_dumpable = 0

dpkg -l | grep apport
# → no output

apt-mark showhold | grep snapd
# → snapd

snap list 2>&1
# → Command 'snap' not found

# EC2 only: confirm SSM agent is active via apt
sudo systemctl is-active amazon-ssm-agent
# → active
dpkg -l | grep amazon-ssm-agent
# → ii amazon-ssm-agent ...
```

### Troubleshooting

- **SSM deb preinst aborts with `installed by snap`:** If `dpkg -i` fails during SSM agent migration because snap metadata remains registered, note that the running `snapd` daemon retains state in memory and the deb package `preinst` script queries `snap list`. Stop `snap.amazon-ssm-agent.amazon-ssm-agent.service`, `snapd.service`, and `snapd.socket` before removing `/var/lib/snapd`.

---

## Step 20 — Attack surface reduction: filesystem and user hardening (Hardening Step 9.2)

### What was done

Restrict file permissions on crontabs (`0600`), cron directories (`0700`), and `sudoers.d` (`0750`). Configure `/etc/login.defs` with strict parameters: `UMASK 027`, `USERGROUPS_ENAB no`, password aging (`PASS_MAX_DAYS 90`, `PASS_MIN_DAYS 1`, `PASS_WARN_AGE 14`), and `SHA_CRYPT_MIN/MAX_ROUNDS 65536`. Install `libpam-pwquality` and `libpam-tmpdir`, deploy hardened `common-password`, `common-session`, and `limits.conf` (disabling core dumps at shell level), and enforce password aging policy on the administrator account.

> **Operational Warning (Lockout Risk):** Deploying `common-password` and `common-session` alters system-wide PAM authentication and session setup. Always maintain an independent secondary active SSH session open before executing this step to prevent accidental administrative lockout in the event of syntax or module errors.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_2 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_2 --ask-become-pass
```

📄 [`configs/pam/common-password`](../../../../modules/hardening/self-managed/configs/pam/common-password)
📄 [`configs/pam/common-session`](../../../../modules/hardening/self-managed/configs/pam/common-session)
📄 [`configs/limits/limits.conf`](../../../../modules/hardening/self-managed/configs/limits/limits.conf)

### Why

Restricting cron and sudoers directory permissions prevents lateral privilege escalation from compromised low-privilege service accounts. Setting `UMASK 027` with `USERGROUPS_ENAB no` prevents group-writable default files. PAM pwquality enforces minimum 12-character complex passwords and 65536 SHA-512 rounds. `libpam-tmpdir` isolates `$TMPDIR` per session under `/tmp/user/<uid>`, eliminating symlink race attacks in world-writable `/tmp`. Disabling core dumps via `limits.conf` complements the kernel-level `fs.suid_dumpable = 0` control.

### Verification

Verify login definitions, directory permissions, and administrator aging inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
grep "^UMASK" /etc/login.defs
# → UMASK          027
grep "^USERGROUPS_ENAB" /etc/login.defs
# → USERGROUPS_ENAB        no
grep "SHA_CRYPT" /etc/login.defs
# → SHA_CRYPT_MIN_ROUNDS 65536
# → SHA_CRYPT_MAX_ROUNDS 65536

stat -c "%n %a" /etc/crontab /etc/sudoers.d
# → /etc/crontab 600
# → /etc/sudoers.d 750

sudo chage -l <admin_username>
# → Maximum password age: 90
# → Minimum password age: 1
# → Number of days of warning before password expires: 14
```

#### Author Manual Steps & Verification in a New Session

Session-level environment variables (umask, TMPDIR, and ulimits) take effect only upon creating a fresh login session. Open a **NEW terminal window** and connect via SSH:

**Run on the control node (Mac) from a new terminal:**

```bash
ssh -p 22222 -i ~/.ssh/id_ed25519_multi-lab <admin_username>@172.16.0.1
```

**Run inside the NEW SSH session:**

```bash
# Verify umask 027
umask
# → 0027

# Verify private session TMPDIR isolation
echo $TMPDIR
# → /tmp/user/<uid>

# Verify user-initiated core dump limit is zero
ulimit -c
# → 0

# Re-encrypt existing administrator password to apply 65536 rounds to shadow hash
sudo passwd <admin_username>
# Enter new password meeting pwquality policy (>= 12 chars, upper, lower, digits, symbols)
sudo grep "^<admin_username>:" /etc/shadow | cut -d: -f2 | cut -c1-3
# → $6$ (SHA-512 verified)
```

> **Note on Account Expiry:** Account expiry (`chage -E`) is intentionally NOT applied — see AUTH-9282 in Step 12 skips.

---

## Step 21 — Attack surface reduction: kernel modules (Hardening Step 9.3)

### What was done

Deploy `/etc/modprobe.d/disable-unused-protocols.conf` blacklisting `dccp`, `sctp`, `rds`, and `tipc` protocol modules via `/bin/false`, and rebuild the initial ramdisk via handler `update-initramfs -u`.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_3 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_3 --ask-become-pass
```

📄 [`configs/modprobe/disable-unused-protocols.conf`](../../../../modules/hardening/self-managed/configs/modprobe/disable-unused-protocols.conf)

### Why

Unused network protocol stacks (`dccp`, `sctp`, `rds`, `tipc`) reside directly in the kernel and have a long history of high-severity CVEs (including remote code execution and local root escalation). Blacklisting them ensures modprobe returns an error (`/bin/false`) rather than dynamically loading the module if an unprivileged process requests a socket using one of those protocol families.

### Verification

Verify kernel module load status inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
lsmod | grep -E "dccp|sctp|rds|tipc"
# → no output

sudo modprobe dccp 2>&1
# → Operation not permitted (or: Invalid argument)
```

---

## Step 22 — Attack surface reduction: monitoring and forensics (Hardening Step 9.4)

### What was done

Preconfigure Postfix debconf to "No configuration" to eliminate interactive prompts, install `rkhunter`, configure mirror updates and whitelists in `/etc/rkhunter.conf` and `/etc/default/rkhunter`, perform signature updates (`rkhunter --update`), refresh the file properties database baseline snapshot (`rkhunter --propupd`) when packages or configuration change, install and enable process accounting (`acct`), and configure automated performance data collection (`sysstat`). Tasks on package-generated configuration files and service units are protected under check mode (`ignore_errors: "{{ ansible_check_mode }}"`) to ensure `--check --diff` passes cleanly on fresh unconfigured hosts.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_4 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step9_4 --ask-become-pass
```

### Why

Detection tools provide situational awareness and forensic capability post-incident. `rkhunter` checks system binaries against rootkit signatures and verifies checksums; executing `rkhunter --propupd` strictly when package or configuration tasks report changes ensures the baseline reflects post-deploy file state while achieving zero changes on subsequent idempotent executions. GNU `acct` records every command executed by every user independent of shell history. `sysstat` gathers CPU, memory, and disk I/O metrics every 10 minutes to detect abnormal resource exhaustion or crypto-mining activity.

### Verification

Verify rkhunter configuration, process accounting, and sysstat metrics inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
grep -E "CRON_DAILY|CRON_DB|APT_AUTO" /etc/default/rkhunter
# → CRON_DAILY_RUN="true"
# → CRON_DB_UPDATE="true"
# → APT_AUTOGEN="yes"

# Verify acct is actively logging commands
sudo lastcomm | head -5
# → displays recently executed commands with timestamps and user attribution

# Verify sysstat performance metrics collection
sar -u 1 2
# → displays active CPU metrics sample
```

### Troubleshooting

- **`rkhunter --update` exit code 2:** Running `rkhunter --update` returns exit code `2` when signature files are updated (`[ Updated ]` output); this indicates successful signature refresh and is not an error.

---

## Step 23 — Audit trail: auditd and AIDE (Hardening Step 10)

### What was done

Install `auditd` and `audispd-plugins`, deploy `/etc/audit/rules.d/99-hardening.rules` with conditional immutable mode (`-e 2`), reload audit rules via `augenrules --load` (executed conditionally when rules change, with automated restart recovery if active immutable mode returns "Operation not permitted"), verify runtime audit state with `auditctl -s`, install `aide` and `aide-common`, deploy `/etc/aide/aide.conf.d/99-hardening`, initialize the cryptographic database baseline snapshot (`aide --init`), activate the database snapshot (`aide.db.new` moved to `aide.db` strictly when the baseline was initialized), and enable automated daily integrity checks in `/etc/default/aide`.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step10 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step10 --ask-become-pass
```

📄 [`configs/audit/99-hardening.rules`](../../../../modules/hardening/self-managed/configs/audit/99-hardening.rules)
📄 [`configs/aide/99-hardening`](../../../../modules/hardening/self-managed/configs/aide/99-hardening)

### Why

auditd and AIDE cover complementary security dimensions: auditd logs events in real-time at the kernel syscall level (identity modifications, pam authentication, privilege escalation via sudo, file deletion), while AIDE detects persistent filesystem state tampering against a cryptographically hashed baseline snapshot.

`augenrules --load` and auditd restarts execute only when rules change (`hardening_audit_rules_deploy.changed`). If an existing session has `-e 2` active, auditd returns `Operation not permitted`; the role catches this specific error condition, restarts `auditd` to clear the loaded ruleset, and re-applies rules. A post-load runtime verification queries `auditctl -s` to confirm `enabled 2` (or `enabled 1` when `hardening_auditd_immutable_mode` is false); on ARM64, this verification catches any silent abort caused by deprecated syscall names (such as `unlink`/`rename` outside `*at` variants). For AIDE, moving `aide.db.new` to `aide.db` is gated strictly on `hardening_aide_init.changed`, guaranteeing an existing baseline is never overwritten.

### Verification

Verify audit rules status, immutable mode, and AIDE database baseline inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
# Confirm active audit rule keys
sudo auditctl -l | grep -c "\-k"
# → rule count active

# Confirm immutable mode
sudo auditctl -s | grep enabled
# → enabled 2

# Verify identity audit rule trigger on /etc/shadow access
sudo cat /etc/shadow > /dev/null
sudo ausearch -k identity | tail -3
# → type=SYSCALL ... key="identity"

# Verify AIDE database exists and daily cron is configured
sudo ls -lh /var/lib/aide/aide.db
# → -rw------- ... /var/lib/aide/aide.db
grep CRON_DAILY_RUN /etc/default/aide
# → CRON_DAILY_RUN=yes
```

### Troubleshooting

- **`augenrules` error `Enable must be 0, 1, or 2 was 2##`:** The deployed `/etc/audit/rules.d/99-hardening.rules` file must strictly end with a trailing newline character. Without a terminating newline, `augenrules` appends section header comments (`##`) directly to the `-e 2` flag on the final line, resulting in an unparseable integer error.

---

## Step 24 — Log management: rsyslog and logrotate (Hardening Step 11)

### What was done

Enable the UFW packet logging switch, pre-create dedicated log files `/var/log/ufw.log` and `/var/log/fail2ban.log` owned by `syslog:adm` (mode `0640`) without modifying existing file timestamps, deploy `rsyslog/20-ufw.conf`, `rsyslog/99-hardening.conf`, and `logrotate/hardening-logs`, and restart the rsyslog daemon.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step11 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step11 --ask-become-pass
```

📄 [`configs/rsyslog/20-ufw.conf`](../../../../modules/hardening/self-managed/configs/rsyslog/20-ufw.conf)
📄 [`configs/rsyslog/99-hardening.conf`](../../../../modules/hardening/self-managed/configs/rsyslog/99-hardening.conf)
📄 [`configs/logrotate/hardening-logs`](../../../../modules/hardening/self-managed/configs/logrotate/hardening-logs)

### Why

Dedicated log routing separates firewall dropped packets and intrusion prevention bans from generic system logs, dramatically speeding up forensic analysis and Fail2Ban recidive parsing. Rsyslog runs under unprivileged uid `syslog`; pre-creating log files with `syslog:adm 0640` prevents silent event discard. The logrotate policy compresses logs weekly and signals rsyslog (`systemctl reload rsyslog`) so that the daemon re-binds to new file inodes upon rotation.

### Verification

Verify log file ownership, rsyslog configuration syntax, and logrotate dry-run inside the SSH session:

**Run on the VM / EC2 (inside the SSH session):**

```bash
# Verify ownership and permissions
ls -lh /var/log/ufw.log /var/log/fail2ban.log
# → syslog:adm 0640 on both files

# Validate rsyslog configuration syntax
sudo rsyslogd -N1
# → End of config validation run. Bye.

# Test logrotate configuration dry-run
sudo logrotate --debug /etc/logrotate.d/hardening-logs 2>&1 | grep -E "considering|rotating"
# → considering log /var/log/ufw.log
# → considering log /var/log/fail2ban.log
```

---

## Step 25 — Security audit baseline: Lynis (Hardening Step 12)

### What was done

Install Lynis (verifying version 3.0.9), deploy `lynis/custom.prf`, execute full system security audit, parse `hardening_index` from `/var/log/lynis-report.dat`, display score summary, and emit a warning if the Hardening Index falls below the target threshold. In accordance with the decision log, Lynis records the score and emits a warning without failing execution (no enforce option).

> **Target Hardening Index Baseline:**
>
> - **Lynis ≥ 90 on AWS EC2** (`multi-lab-vps`)
> - **Lynis ≥ 88 on Local VM** (`multi-lab-local`)
>
> **Score Delta Explanation:** AWS EC2 achieves a higher baseline score (90 vs 88) due to platform-managed controls (hypervisor isolation, physical hardware security, cloud metadata management) that Lynis recognizes automatically in cloud instances. The delta is infrastructure-level, not configuration-level: both target environments run identical OS hardening roles.

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step12 --check --diff --ask-become-pass

ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_step12 --ask-become-pass
```

📄 [`configs/lynis/custom.prf`](../../../../modules/hardening/self-managed/configs/lynis/custom.prf)

### Why

Running Lynis validates that all defense-in-depth controls are active at runtime and establishes a baseline to detect regressions. Intentional deviations from standard CIS benchmarks are explicitly documented and suppressed in `custom.prf`, demonstrating intentional engineering rather than unaddressed findings.

### Verification

Verify Hardening Index score from the generated report data:

**Run on the VM / EC2 (inside the SSH session):**

```bash
sudo grep hardening_index /var/log/lynis-report.dat
# → hardening_index=90 (EC2) or hardening_index=88 (VM)
```

Verify full Block 2C execution and complete idempotence:

**Run on the control node (Mac):**

```bash
ansible-playbook playbooks/hardening.yml --limit multi-lab-vps \
  --tags hardening_2c --ask-become-pass
# → changed=0 (gate for block 2C: second run with no changes)
```
