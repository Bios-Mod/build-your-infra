# Decisions Log

Technical decisions that are closed and must not be revisited without explicit
request from the author.

---

## Infrastructure & Environment

- **Single AZ in multi-lab-vpc** — cost vs learning value evaluated and
  rejected. A second AZ requires a second NAT Gateway and cross-AZ data
  transfer costs with zero additional learning value for this lab scope.
- **Port 22 rule in multi-lab-sg** is removed during hardening Step 3 — not
  in vps-ec2-setup. The setup doc references it as temporary with a note
  pointing to hardening. Do not move it to setup.
- **apt update** belongs in hardening Step 1, not in environment setup docs.
  Environment docs end at first successful SSH connection.

---

## AWS Native

- **DNS resolution (enableDnsSupport)** is explicitly enabled in multi-lab-vpc.
  Required for SSM Session Manager and Route 53 Private Hosted Zones.
- **AdministratorAccess on multi-lab-admin** is intentional for the lab
  operator account. Scope-down applies to service roles per module, not the
  operator.
- **MFA Delete on CloudTrail S3 bucket** is optional — requires the root
  account, not any IAM user. Do not mark it as mandatory.
- **CloudTrail all-regions** is intentional — captures global IAM/STS events
  a single-region trail misses.
- **IMDSv2 enforcement** — single-instance lab, CLI targets one instance
  explicitly. No loop required.

---

## Self-Managed Hardening

- **USERGROUPS_ENAB=no in PAM** — Lynis AUTH-9328 finding does not apply
  when there is no private group. Documented as a deviation in custom.prf.
- **Lynis score EC2 > VM (90 vs 88)** — due to AWS platform controls, not
  additional manual steps. Does not imply different hardening procedures.

---

## Repository Scope

- **DHCP has no AWS Native equivalent** — VPC DHCP Options Sets is not a
  deployable module. Covered only in the DHCP module README.
- **Samba 4 AD DC internal DNS** may replace or integrate with BIND9. The
  DNS module must be reviewed before provisioning the directory module.
- **Status columns/badges are removed from all module READMEs and docs.**
  Status becomes stale immediately and cannot be trusted.
- **DNS deployed on EC2 only — local VM is a client peer.** BIND9 runs only
  on the EC2 WireGuard hub; local VM resolves via `172.16.0.1` over tunnel.

---

## Documentation Naming (2026-07-10)

- **Implementation docs renamed from `self-managed.md`/`aws-native.md` to
  `<module>-<environment>.md`** (e.g. `dns-self-managed.md`). The bare names
  were ambiguous once opened outside their folder — every module repeated the
  same two filenames. This aligns with the naming already used for automation
  docs (`<module>-aws-native-automation.md`). Renaming performed via `git mv`
  to preserve file history. All internal links (module READMEs, root README,
  cross-references between docs) were updated in the same commit per module.

---

## Config Generation

- **Comment syntax check before any config** — identify file type and native
  comment syntax before writing. Never assume `#` or `//` applies to files
  that don't support inline comments (BIND9 zones, plain text served
  literally). Non-negotiable, checked before the first line is written.
- **Config apply method** — `cp` for full-file replacement, `tee -a` for
  append. Never inline via heredoc. The `📄 configs/filename` reference in
  the step must always match the file used in the apply command.

## AWS CLI Query — JMESPath Array Indexing

- **All `describe-*` responses return arrays at the top level.**
  `.{key:value}` on the root node returns `null` — always index first.
- **Mandatory pattern:** `ResourceType[0].Field` — never `ResourceType.Field`.
- **Multi-result queries** use `[*]`; single-resource verifications always
  use `[0]`.

---

## Automation Phase — Terraform Decisions

- **Individual modules + full-stack are both mandatory.** A full-stack
  without individual modules is a black box; a module without a full-stack
  doesn't demonstrate composition.
- **`stacks/full-infra/self-managed/`** deploys EC2 from AMI snapshot
  (`multi-lab-aws-active-directory`) — infrastructure layer only. OS
  configuration was applied manually and documented per module. Ansible will
  close this gap in a future iteration; this is the correct pattern (don't
  force Terraform where it doesn't belong).
- **Module implementation order (aws-native):** hardening → dns →
  file-transfer → web-server → directory. Lowest to highest complexity;
  `directory` last due to billing cost and ~30 min provisioning time.
- **`stacks/` at repo root** — structural coherence with
  `containerize-your-infra`, which uses the same pattern.
- **`terraform import` is selective per module**, resource by resource —
  never a full-account import (produces an unstructured monolith). Flow:
  write import blocks → `terraform plan -generate-config-out=generated.tf` →
  reconcile HCL → clean plan → apply → remove import blocks → destroy/redeploy.
- **Legacy module provider constraint** — no `depends_on`, no `providers`
  passthrough on modules declaring their own `provider` block internally.
  The two-phase apply pattern handles ordering instead.
- **Two-phase apply for greenfield full-stack** — `dns` and `file_transfer`
  resolve the VPC via `data "aws_vpc"` at plan time; on greenfield, this
  requires phase 1 (`-target=module.hardening`) then phase 2 (full stack).
- **`html_dir` variable in web-server** — `filemd5()`/`source` resolve paths
  relative to the Terraform working directory. Never hardcode paths in
  modules composed into a stack; use a variable with a module-relative default.
- **`create_ec2_record` optional in dns module** — disabled by default in the
  aws-native full-stack (no EC2 instance there). Never hardcode a default IP.
- **Terraform vs Ansible gap — precise scope (2026-07-10).** Terraform is
  fully applied across all `aws-native` modules individually
  (`modules/<name>/aws-native/automation/terraform/`) — each module deploys
  its own AWS-managed resources independently. In `self-managed`, Terraform
  is applied **only** at `stacks/full-infra/self-managed/` — it provisions
  the EC2 instance from the pre-hardened AMI snapshot
  (`multi-lab-aws-active-directory`), covering the infrastructure layer only
  (instance, network, security groups). Individual self-managed modules have
  **no** Terraform — there is nothing to provision at module level in that
  environment (no cloud resources, just OS configuration on an existing host).
  The actual gap is not "Terraform vs Ansible" as parallel tools — it is
  that **the OS configuration layer of the self-managed snapshot was applied
  manually** and is documented per module (`*-self-managed.md`), but not
  yet automated. Ansible is the tool that will close this specific gap:
  configuration management on top of the snapshot's infrastructure layer,
  not a replacement for Terraform's infrastructure-provisioning role. Do not
  conflate the two — Terraform provisions, Ansible configures. Ansible is
  planned but not yet implemented; together with monitoring it is the final
  phase of the repo.

---

## Automation Phase — Ansible Decisions

- **Scope: self-managed only.** `aws-native` provisions managed services with
  Terraform; there is no OS to configure. Ansible closes the configuration
  gap of the self-managed snapshot, not a Terraform gap.
- **Two-level layout.** Roles per module in
  `modules/<module>/self-managed/automation/ansible/`; inventory and
  orchestrating playbook in `stacks/full-infra/self-managed/automation/ansible/`
  — the same module + stack pattern used for Terraform.
- **`configs/` stays the single source of truth.** Roles consume the existing
  files; no duplicated config content.
- **Implementation order:** hardening → dns → file-transfer → web-server →
  directory → dhcp, lowest to highest complexity. Hardening first because it
  is the only mandatory base.
- **Monitoring (Prometheus + Grafana)** is a later module, self-managed only,
  added after the Ansible base is closed. It also exists in
  `containerize-your-infra`, where Ansible is not planned for now.
- **Ansible implementation docs** follow
  `<module>-self-managed-automation.md` inside
  `modules/<module>/self-managed/automation/`.

---

## CI Implementation

- **No persistent AWS environment exists** (billing constraints). Therefore
  `terraform plan` is excluded from all CI workflows — a plan against
  `data "aws_vpc"` references that don't exist would always fail. CI for
  `aws-native` is limited to `fmt` + `validate`.
- **Terraform backend is local** — state is gitignored and never shared with
  CI runners. `validate` does not require state.
- **Single reusable workflow.** `modules-ci.yml` (`workflow_call`) defines
  every job once; `push-ci.yml` and `pull-request.yml` are thin entry points.
  Rationale: avoids duplicating validation rules across up to twelve files.
- **`paths-filter` runs inside the workflow, not as a trigger.** A `changes`
  job computes per-module-environment outputs and `any-module`.
- **`full-infra` runs when any module changes**, gated by `any-module`, so it
  never runs on documentation-only changes.
- **`self-managed` and `aws-native` jobs are split per module**, each with
  its own filter — different risk profile and tooling.
- **`path-consistency` is PR-only**, to keep the push loop focused on module
  correctness.

## Repository Closure & Scope (2026-11-02)

- **Closure criteria.** The repo is closed once Ansible is applied across all
  self-managed modules and monitoring (Prometheus + Grafana) is deployed.
  The architecture diagram is produced last, so it is built once against the
  final stack.
- **`context/current-iteration.md` is removed.** Status is already reflected
  in the module tables and this log; a separate status doc added friction and
  went stale.
- **Problem-first framing without rewriting.** The root README gains a short
  problem/approach intro and each module README opens with the problem it
  solves. Step-level `### Why` sections stay as they are.

## Working Method (2026-11-02)

- Structure and decisions first, then implementation docs generated by the
  architect assistant, then the author executes them step by step and feeds
  errors back into the docs.
- Mechanical tasks may be delegated to the coding agent (Antigravity);
  design, docs and rationale are not delegated. Prompts are written by the
  author and the assistant.
- The coding agent works on feature branches and opens pull requests; it
  never pushes to `main` or merges. It executes structure defined here and
  never decides it.
