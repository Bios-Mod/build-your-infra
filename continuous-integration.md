# Continuous Integration

This document covers the CI layer of the repository — automated validation triggered on every push and pull request, implemented with GitHub Actions. CI does not deploy anything: it validates that self-managed configs and Terraform code are correct before a human merges to main.

CI complements the automation layer documented in `self-managed-automation.md` and `aws-native-automation.md`. Terraform provisions infrastructure, Ansible configures it, GitHub Actions verifies that all layers are correct on every change.

## Introduction

A single reusable workflow, not per-module files. Every module has two independent environments — self-managed and aws-native — that require entirely different validation: self-managed runs static config linters with no credentials, aws-native runs Terraform fmt and validate with no AWS calls. Duplicating this logic across six module files and two trigger files (push, pull request) would mean changing the same validation rule in up to twelve places. `modules-ci.yml` defines every module job once, callable via `workflow_call` from both entry points.

`paths-filter` is an in-workflow gate, not an event-level trigger. Unlike a module-per-file design where `paths:` on the workflow itself decides whether it runs, this repo's push and pull-request workflows always execute, then use `dorny/paths-filter` inside a `changes` job to compute which module and environment actually changed. Every module job depends on `changes` and runs conditionally via `if: needs.changes.outputs.<module>-<environment> == 'true'`. A change to `modules/dns/self-managed/**` only runs `dns-self-managed` — `dns-aws-native`, `hardening-self-managed`, and every other job are skipped, keeping compute scoped to what actually changed.

Self-managed jobs validate syntax, not runtime behavior. `sshd -t`, `named-checkconf`, `testparm -s`, `nginx -t`, `fail2ban-client -t`, and `aide --check` are the native, non-interactive validators shipped with each service — installed fresh on the runner, run against the repo's config files directly, with no service ever started. This catches malformed configuration before it reaches a real server, without requiring a persistent test environment.

Aws-native jobs run `terraform fmt -check` and `terraform validate` only. Both commands require no AWS credentials and no state access — they check formatting and internal HCL syntax only. `terraform plan` is explicitly excluded from CI: there is no persistent AWS environment in this lab, so a plan would either fail against missing dependent resources (`data aws_vpc` lookups in `dns` and `file-transfer`) or misleadingly show a full from-scratch creation. `plan` remains a manual step, run locally before apply.

`full-infra` always runs when any module changes. The full-stack composition depends on every individual module's Terraform being internally valid — it is gated behind the `any-module` output from the same `changes` job, not behind its own separate path filter, so it never runs redundantly on documentation-only or environment-setup changes.

## Design decisions

- **`workflow_call` as the single source of truth.** `modules-ci.yml` is not triggered directly — it declares `on: workflow_call` and is invoked identically by `push-ci.yml` (push to `main`) and `pull-request.yml` (pull_request to `main`). Adding a new validation — such as the Ansible layer — means adding one filter and one job inside `modules-ci.yml`; both entry points inherit it automatically with zero duplication.
- **Nested paths-filter per module, not per repository.** Each module has two filters (`<module>-self-managed`, `<module>-aws-native`) pointing at its own subfolder. This mirrors the fact that self-managed and aws-native are architecturally independent within a module — a Terraform-only change must never trigger a config lint job, and vice versa.
- **`any-module` as an aggregate filter.** A single broad filter (`modules/**`) feeds the `full-infra` job's condition, avoiding a twelve-way `OR` across every module-environment output. It is evaluated by the same `paths-filter` step as every other filter, just with a wider pattern.
- **Ansible validation in CI.** Ansible lives exclusively in `stacks/full-infra/self-managed/automation/ansible/` (roles, inventory, and playbooks) — self-managed modules do not have individual `automation/` folders. Its validation (`ansible-lint`, `--syntax-check`) is implemented as a single filter and job (`ansible-self-managed`) scoped to that path inside `modules-ci.yml`, without touching `push-ci.yml` or `pull-request.yml`. Applying roles (`--check` against a real host) stays a manual step, like `terraform plan`.
- **`path-consistency` lives only in `pull-request.yml`, not in the reusable workflow.** It verifies that every config path referenced in a module doc's `cp`/`tee -a` command physically exists in the repo — a documentation/config drift check, not a module validation. It runs unconditionally on every PR, independent of which paths changed, and is intentionally excluded from `push-ci.yml` to keep the fast debug loop focused on module correctness only.
- **Self-managed validators require scaffolding the runner is missing by default.** Native syntax checkers assume the service's expected runtime layout exists — `sshd -t` needs `/run/sshd`, `named-checkconf`/`named-checkzone` need `/var/cache/bind`, `fail2ban-client -t` needs `jail.local` copied into `/etc/fail2ban/`, `kea-dhcp4 -t` needs the config copied to `/etc/kea/` (its AppArmor profile blocks reads from arbitrary paths) plus a dummy interface (`ens160`) since Kea validates interface bindings at parse time, and `nginx -t` needs a real (if self-signed, 1-day) TLS cert pair to satisfy `ssl_certificate`/`ssl_certificate_key`, plus a runtime placeholder substitution for templated values like `<upstream_port>` that are intentionally left unresolved in the committed config. None of this scaffolding touches the repo's config files — it exists only in the ephemeral runner, created and torn down per job.
- **Local Terraform backend, no remote state in CI.** State files are gitignored and kept local per environment. CI never reads or writes state — `validate` operates on configuration syntax alone, which is why it works identically whether or not a real AWS environment exists behind it.
- **`push-ci.yml` scopes `paths-filter` to the actual diff via `base-ref`.** It passes `github.event.before` (the commit SHA prior to the push) into `modules-ci.yml`'s `base-ref` input, so `dorny/paths-filter` compares against the real previous state of the branch rather than a fixed default. `pull-request.yml` omits this input, falling back to the workflow's `main` default — correct for a PR, since the comparison should always be against the target branch, not the commit before the PR was opened.

```bash
.github/workflows/
  modules-ci.yml      # reusable — workflow_call only, all module + full-infra + ansible jobs
  push-ci.yml         # push to main — calls modules-ci.yml
  pull-request.yml    # pull_request to main — calls modules-ci.yml + path-consistency
```

## Actions used

| Action | Used in | Purpose |
| --- | --- | --- |
| `actions/checkout@v7` | every job that reads repo content | clones the repo into the runner |
| `dorny/paths-filter@v4` | `changes` job in `modules-ci.yml` | detects which module/environment paths changed in the diff |
| `actions/setup-python@v5` | `ansible-self-managed` | sets up Python 3.12 for Ansible linting and syntax checks |
| `hashicorp/setup-terraform@v4` | every `-aws-native` job, `full-infra` | installs Terraform 1.15.6 CLI on the runner |

No custom build action is required — self-managed jobs install their validator package (`openssh-server`, `bind9-utils`, `samba-common-bin`, `nginx`, `fail2ban`, `auditd`, `aide`, `prometheus`, `prometheus-blackbox-exporter`, `jq`) directly via `apt-get` and invoke the tool's native syntax-check flag.

## Workflow structure

**`modules-ci.yml`** — the only file containing job logic. One `changes` job computes thirteen module and automation outputs (`ansible-self-managed` + twelve module-environment outputs) plus `any-module` via `paths-filter`. Twelve module jobs (`hardening-self-managed`, `hardening-aws-native`, `dns-self-managed`, `dns-aws-native`, `file-transfer-self-managed`, `file-transfer-aws-native`, `web-server-self-managed`, `web-server-aws-native`, `directory-self-managed`, `directory-aws-native`, `dhcp-self-managed`, `monitoring-self-managed`) and one automation job (`ansible-self-managed`) each run conditionally on their own output. `full-infra` runs conditionally on `any-module`.

**`ansible-self-managed`** — runs on `ubuntu-24.04-arm` when changes occur under `stacks/full-infra/self-managed/automation/ansible/**`. Sets up Python 3.12 (`actions/setup-python@v5`), installs pinned dependencies from `requirements.txt` and Galaxy collections from `requirements.yml`, copies `hosts.yml.example` to `hosts.yml` to satisfy the inventory reference in `ansible.cfg`, runs `ansible-lint --profile production`, and executes `ansible-playbook --syntax-check` dynamically across all playbooks in `playbooks/*.yml`. It does not connect to real hosts and runs entirely offline.

**`push-ci.yml`** — triggers on push to `main`. Calls `modules-ci.yml` with `base-ref: ${{ github.event.before }}`, scoping `paths-filter` to only the commits in that specific push rather than the full branch history — so an iterative debugging session only re-runs jobs for modules actually touched in each push, not everything since `main` diverged. Adds no additional jobs beyond the reusable workflow.

**`pull-request.yml`** — triggers on `pull_request` to `main`. Calls `modules-ci.yml` and adds `path-consistency` as an independent, unconditional job. This is the merge gate: every module touched in the PR diff is validated, the full-stack composition is checked, and documentation-to-config drift is caught, all before a human approves the merge.

Every module job depends on `changes` (`needs: changes`) and reads its corresponding boolean via `needs.changes.outputs.<name>`. This two-level output pattern — `steps.filter.outputs.<name>` inside the `changes` job, re-exposed as `jobs.changes.outputs.<name>` for consumption by dependent jobs — is what allows a single `paths-filter` invocation to gate thirteen independent jobs without repeating the diff-detection logic.
