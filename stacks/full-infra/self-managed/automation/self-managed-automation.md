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
