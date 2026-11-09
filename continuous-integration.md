# Continuous Integration

This document covers the CI layer of the repository — automated validation triggered on every push and pull request, implemented with GitHub Actions. CI does not deploy anything: it validates that self-managed configs and Terraform code are correct before a human merges to main.

CI complements the automation layer documented in `self-managed-automation.md` and `aws-native-automation.md`. Terraform provisions infrastructure, Ansible configures it, GitHub Actions verifies that all layers are correct on every change.

## Workflow structure

```bash
.github/workflows/
  modules-ci.yml      # reusable — workflow_call only, all module + full-infra + ansible jobs
  push-ci.yml         # push to main — calls modules-ci.yml
  pull-request.yml    # pull_request to main — calls modules-ci.yml + path-consistency
```

- **`modules-ci.yml`** defines every job once under `on: workflow_call`. A single `changes` job runs `dorny/paths-filter@v4` with two-level outputs (`steps.filter.outputs.<name>` exposed as `jobs.changes.outputs.<name>`) for thirteen scoped targets (`ansible-self-managed` + twelve `<module>-<environment>` filters) plus `any-module` (`modules/**`). Each of the twelve module jobs (`hardening`, `dns`, `file-transfer`, `web-server`, `directory` across both environments, plus `dhcp-self-managed` and `monitoring-self-managed`), `ansible-self-managed`, and `full-infra` runs conditionally on its output via `needs: changes`.
- **`ansible-self-managed`** runs on `ubuntu-24.04-arm` when `stacks/full-infra/self-managed/automation/ansible/**` changes: sets up Python 3.12, installs pinned packages from `requirements.txt` and Galaxy collections from `requirements.yml`, copies `hosts.yml.example` to `hosts.yml` to satisfy `ansible.cfg`, runs `ansible-lint --profile production`, and runs `ansible-playbook --syntax-check` across all `playbooks/*.yml` offline. Live `--check` runs against hosts remain manual.
- **`push-ci.yml`** runs on pushes to `main` and passes `base-ref: ${{ github.event.before }}` into `modules-ci.yml`, scoping `paths-filter` to the pushed commits instead of the entire branch history.
- **`pull-request.yml`** runs on `pull_request` to `main`, omits `base-ref` so `paths-filter` diffs against `main`, and adds the unconditional `path-consistency` gate verifying that every `configs/` path referenced in `cp`/`tee -a` doc commands exists in the repository (omitted from `push-ci.yml` to keep push validation module-scoped).

## Design decisions

- **`paths-filter` as an in-workflow gate:** Entry workflows always trigger and let `changes` skip untouched modules rather than duplicating path triggers across twelve per-module workflow files. Adding a new layer (such as Ansible) requires adding one filter and one job in `modules-ci.yml` without modifying `push-ci.yml` or `pull-request.yml`.
- **Self-managed syntax validation with ephemeral runner scaffolding:** Native linters (`sshd -t`, `named-checkconf`, `testparm -s`, `nginx -t`, `fail2ban-client -t`, `aide --check`, `kea-dhcp4 -t`) run non-interactively without starting daemons. Ephemeral setup on the runner provides `/run/sshd`, `/var/cache/bind`, `/etc/fail2ban/jail.local`, `/etc/kea/` + a dummy `ens160` interface (Kea's AppArmor profile restricts arbitrary paths and validates bound interfaces), and a temporary 1-day self-signed certificate + placeholder substitution (`<upstream_port>`) for `nginx -t` without touching committed configs.
- **AWS-native offline validation and excluded `terraform plan`:** Every `-aws-native` job runs `terraform fmt -check` and `terraform validate` with local backend assumptions and zero AWS credentials or remote state access. `terraform plan` stays local because there is no persistent AWS environment in the lab (lookups such as `data aws_vpc` in `dns` and `file-transfer` would fail without live resources).

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
