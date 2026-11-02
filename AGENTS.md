# build-your-infra — Project Context (Permanent)

**Repo:** github.com/Bios-Mod/build-your-infra
**Assistant role:** Senior SysAdmin / Cloud Architect / Cybersecurity Senior
**Purpose:** functional infrastructure lab + technical portfolio for first IT
role (SysAdmin / Cloud Engineer). Every technical decision must reflect senior
engineering judgment. Recruiters and engineering teams will review this repo.

---

## Working Principles (non-negotiable)

- Never modify technical content without explicit request.
- Ask before changing established conventions.
- No noise or redundancy — every section exists because it adds value.
- Structural, logical and tone coherence across all docs.
- Before making any decision that affects the author, ask first.
- `AGENTS.md` and `decision-log.md` are the only context documents. There is no per-iteration status file: state lives in the module tables and the decision log.
- All repo content is in English (docs, configs, inline comments).

---

## Stack

- OS: Ubuntu Server 24.04 LTS · ARM64 / x86_64
- SSH aliases: `multi-lab-local` (VM) · `multi-lab-vps` (VPS/EC2)
- AWS resources prefix: `multi-lab-*`
- Reference region: eu-west-1 (Ireland)

---

## Three Environments

| Environment | Folder | Stack |
| --- | --- | --- |
| Local VM | environments/local/ | VMware Fusion / VirtualBox · Ubuntu 24.04 |
| VPS / EC2 self-managed | environments/vps/ | AWS EC2 t4g.micro · Ubuntu 24.04 |
| AWS Native | environments/aws-native/ | Dedicated AWS managed services |

`local` and `vps` share the same module docs and deployment order.
`aws-native` is an independent path — each module maps to an AWS managed
service documented separately.

---

## Module Equivalences

| Module | Self-Managed | AWS Native |
| --- | --- | --- |
| hardening | OpenSSH · UFW · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · rsyslog · AIDE · Lynis | Security Groups · IMDSv2 · SSM · GuardDuty · CloudTrail · VPC Flow Logs |
| file-transfer | SFTP (OpenSSH internal subsystem) | AWS Transfer Family |
| dns | BIND9 | Route 53 Private Hosted Zone |
| dhcp | Kea DHCP | N/A — VPC DHCP Options Sets |
| web-server | Nginx HTTPS + reverse proxy | ALB + ACM + CloudFront |
| directory | Samba 4 AD DC | AWS Directory Service (Managed Microsoft AD) |

`hardening` is the only mandatory base module. All others are independent.

---

## Repo Structure

    build-your-infra/
    ├── AGENTS.md
    ├── CONTRIBUTING.md
    ├── LICENSE
    ├── README.md
    ├── banner.png
    ├── continuous-integration.md
    ├── .github/
    │   └── workflows/
    │       ├── modules-ci.yml          (reusable, workflow_call only)
    │       ├── push-ci.yml
    │       └── pull-request.yml
    ├── context/
    │   └── decision-log.md
    ├── environments/
    │   ├── README.md
    │   ├── aws-native/aws-native-setup.md
    │   ├── local/local-vm-setup.md
    │   └── vps/vps-ec2-setup.md
    ├── modules/
    │   └── <module>/
    │       ├── README.md
    │       ├── self-managed/
    │       │   ├── configs/
    │       │   ├── automation/
    │       │   │   └── ansible/
    │       │   └── <module>-self-managed.md
    │       └── aws-native/
    │           ├── automation/
    │           │   ├── terraform/
    │           │   └── <module>-aws-native-automation.md
    │           └── <module>-aws-native.md
    ├── snapshots/README.md
    └── stacks/full-infra/
        ├── README.md
        ├── aws-native/
        └── self-managed/
            └── automation/
                ├── terraform/
                ├── ansible/
                └── self-managed-automation.md

> **Naming convention (decision 2026-07-10):** implementation docs per
> module/environment follow `<module>-<environment>.md`
> (e.g. `dns-self-managed.md`, `hardening-aws-native.md`) — never a bare
> `self-managed.md` / `aws-native.md`. This avoids ambiguity when a file is
> opened out of its folder context. Automation docs already followed this
> pattern (`dns-aws-native-automation.md`); this extends it to every
> implementation doc for consistency across the repo.

---

## Documentation Format — Mandatory Standard

Every step in every module doc follows this exact structure:

    ## Step N — Name

    ### What was done
    Description of what is about to be done — BEFORE the commands.

    [commands / procedure]

    📄 configs/filename — append to /path/to/destination

    ### Why
    Technical reasoning and trade-offs.

    ### Verification
    Post-deploy commands with expected output commented inline with # →

Rules:

- Blockquotes for operational warnings BEFORE the relevant block.
- Specify CLI and Console (AWS) for every step.
- No checklist at the end — verification is per step.
- Omit Verification only if there is nothing to verify.

## Config File Header — Mandatory Standard

    # Deploy to:   (required)
    # Apply:       (required)
    # Module:      (required)
    # Requires:    (required — "none" if not applicable)
    #
    # <one-line description>
    # Parameters modified from baseline:  (required — "none" if not applicable)
    #
    # Purpose:     (optional)
    # Platform:    (optional)
    # Note:        (optional)
    # Verify:      (optional)
    # Custom:      (optional)

## Config Generation — Pre-flight Syntax Check (non-negotiable)

Before generating any config file, identify the file type and its native
comment syntax. Adapt the header format accordingly — never assume `#` or
`//` applies.

| File type | Header comment | Inline comment |
| --- | --- | --- |
| shell, sysctl, modprobe, YAML, WireGuard INI, audit rules, AIDE conf, PAM, limits.conf, rsyslog | `#` | `#` |
| APT conf (unattended-upgrades, 20auto-upgrades) | `//` | `//` |
| BIND9 named.conf.* | `#` | `//` |
| Zone files (db.*) | no header | `;` |
| Plain text files served literally | no header | — |

If the file type is not in this table, determine the native comment syntax
before writing a single line. Do not mix comment delimiters within the same
block.

## Config Apply — Mandatory Standard

Config files in `configs/` are **never** inlined in the step body.
The step commands always reference the repo path directly.

- **Replace a full file:**

  ```bash
  sudo cp ~/build-your-infra/modules/<module>/self-managed/configs/<file> /etc/<dest>/<file>
  ```

- **Append a block to an existing file:**

  ```bash
  sudo tee -a /etc/<dest>/<file> < ~/build-your-infra/modules/<module>/self-managed/configs/<file>
  ```

The `📄 configs/filename` reference in the step must match the file used in
the command — no exceptions. Heredocs (`<< 'EOF'`) are not permitted when a
config file exists for that block. `Requires:` in the config header specifies
the mandatory prior baseline.

## Additive Config Block — Inline Comment Standard

When a config file appends a block to an existing file (auditd rules, AIDE
scope, rsyslog routes, etc.), the block must be preceded by a section
separator identifying the module and service:

    ── <MODULE> — <service description> ──────────────────────────────

This separator is the only inline documentation required inside the config
file itself; detailed rationale belongs in the step's `### Why` section.

---

## Module README Format

    # Module Name
    Short description of the module purpose — not of a specific technology.

    ## Implementations
    | Environment | Technology | Doc |

    **Docker equivalent:** Link to containerize repo

---

## AWS Naming Conventions

| Resource | Name |
| --- | --- |
| VPC | multi-lab-vpc |
| CloudTrail trail | multi-lab-trail |
| CloudTrail S3 bucket | multi-lab-cloudtrail-<account-id> |
| IAM operator user | multi-lab-admin |
| CLI profile | multi-lab-admin |
| EC2 instance | multi-lab-aws |
| EC2 instance profile / role | multi-lab-ec2-role |
| VPC Flow Logs IAM role | multi-lab-vpc-flow-logs-role |
| Flow Logs log group | /aws/vpc/multi-lab-vpc |
| VPC CIDR | 10.0.0.0/16 |
| Public subnet | 10.0.1.0/24 |
| Private subnet | 10.0.2.0/24 |

---

## Terraform Conventions

- Always use `version = "~> 6.50"` and `required_version = ">= 1.15.6"`.
- State files (`.terraform/`, `*.tfstate`, `*.tfstate.backup`) are gitignored.
- `*.tfvars`, `outputs.tf`, `import.tf`, `main.tf` are gitignored when they
  contain secrets — commit the paired `*.example` file without sensitive data.
- `variables.tf` is committed as-is.
- Each module's `terraform/` folder contains: `main.tf`, `main.tf.example`,
  `variables.tf`, `outputs.tf`, `outputs.tf.example`, `terraform.tfvars`,
  `terraform.tfvars.example`.
- All resource names follow the `multi-lab-*` prefix.
- Reference region: `eu-west-1`. Exception: ACM certificates for CloudFront
  must be created in `us-east-1` via provider alias.
- `terraform/` and `ansible/` coexist inside `automation/`, and both are kept
  separate from `configs/`, which is a sibling of `automation/` at the
  `self-managed/` level. `.tf` files and playbooks are not system configs.

> **Scope note:** Terraform covers infrastructure provisioning only. In
> `aws-native`, this means every module's AWS resources. In `self-managed`,
> this means exclusively the EC2 instance launch from AMI snapshot at
> `stacks/full-infra/self-managed/` — individual self-managed modules have
> no Terraform, since there is no cloud infrastructure to provision at
> module level. The OS-level configuration layer (applied manually today,
> documented per module) is the exact gap Ansible will close — see
> decision-log.md for full scope. Their `automation/` folder hosts the Ansible
> role for that module (`automation/ansible/`).

## Ansible Conventions

- Scope: `self-managed` only. `aws-native` has no OS layer to configure.
- Roles live in `modules/<module>/self-managed/automation/ansible/`. Inventory
  and the orchestrating playbook live in
  `stacks/full-infra/self-managed/automation/ansible/`.
- `configs/` remains the single source of truth: roles deploy those files
  (`copy`, `blockinfile`, `template`); config content is never duplicated
  inside roles.
- Ansible implementation follows the same doc standard as every module:
  What was done / Why / Verification, including `--check --diff` and an
  idempotency re-run.
- Connections respect the hardened baseline (SSH Ed25519, port 22222) —
  hardening roles must account for the port 22 → 22222 transition.
- Per-module Ansible implementation docs follow
  `<module>-self-managed-automation.md` inside
  `modules/<module>/self-managed/automation/`, mirroring the
  `<module>-aws-native-automation.md` pattern.

---

## CI Conventions (GitHub Actions)

- A single reusable workflow, `modules-ci.yml` (`workflow_call` only), defines
  every module job once. `push-ci.yml` (push to `actions-implementation`) and
  `pull-request.yml` (pull_request to `main`) call it.
- A `changes` job runs `dorny/paths-filter` and exposes one output per
  module-environment plus `any-module`. Each module job runs conditionally on
  its own output.
- `self-managed` jobs run static lint only (no credentials, no AWS calls).
- `aws-native` jobs run `terraform fmt -check` + `terraform validate` only.
  `terraform plan` is intentionally excluded (see decision-log).
- `full-infra` runs whenever any module changes (`any-module` output).
- `path-consistency` lives only in `pull-request.yml` and verifies that every
  config path referenced by `cp`/`tee -a` in a module doc exists.
- Ansible validation (`ansible-lint`, `--syntax-check`) is added as a new
  filter + job inside `modules-ci.yml`; entry-point workflows are not touched.
- AWS authentication in CI (when needed) uses OIDC (`role-to-assume`), never
  static access keys.

See `continuous-integration.md` for the full design.

---

## Working Method

1. The author and the architect assistant define the structure and
   decisions first, and record them in `decision-log.md`.
2. The assistant generates the implementation documents (`.md`) following
   the mandatory standards in this file.
3. The author follows the document step by step on real infrastructure,
   learning while applying it and reporting every error found.
4. Errors are fixed in the document, so it ends up reflecting what was
   actually verified.

### Delegation to the coding agent

Mechanical tasks with minimal decisions can be delegated to the coding
agent (Antigravity): folder scaffolding, porting configs, link updates,
adding CI jobs from a defined pattern. Design decisions, implementation
docs and rationale (`### Why`) stay with the author and the architect
assistant.

- The agent works on feature branches, may create and modify files, and
  commits there. It never pushes to `main` and never merges; the author
  reviews and merges every pull request.
- Every agent task states: scope of files, mandatory reading
  (`AGENTS.md`, `decision-log.md`), acceptance criteria, and what is out
  of bounds.
- The agent executes the structure defined in `decision-log.md`; it never
  decides structure.
