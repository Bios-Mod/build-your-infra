# Full Infrastructure Stack — build-your-infra

**Terraform · EC2 · VPC · GuardDuty · CloudTrail · Transfer Family · Route 53 · CloudFront · Directory Service · Ansible**

Composition layer connecting all lab modules (each retains its standalone implementation under `modules/<name>/`); see [README.md — Automation](../../README.md#automation) for scope, module ordering, and tooling overview.

| Implementation | Tool | Scope | Doc |
|---|---|---|---|
| `aws-native/` | Terraform | All AWS Native modules composed as a single deployment | [`aws-native/aws-native-automation.md`](aws-native/aws-native-automation.md) |
| `self-managed/` | Terraform + Ansible | EC2 greenfield (Terraform) + OS hardening and service orchestration (Ansible) | [`self-managed/automation/self-managed-automation.md`](self-managed/automation/self-managed-automation.md) |

---

## aws-native

Sources each module from `modules/*/aws-native/automation/terraform/` into a single greenfield `terraform apply`.

> **Prerequisites:** AWS credentials configured for the `multi-lab-admin` profile. Each module must be applied and verified on its own first, then destroyed (`terraform destroy`) before running this stack: it is a greenfield deployment and the module deployments would otherwise collide on resource names (`multi-lab-vpc`, `multi-lab-sg`, …).

---

## self-managed

Terraform provisions the clean EC2 host, Elastic IP, VPC security groups, and SSM role, while Ansible automates all service modules and orchestrates convergence through [`playbooks/site.yml`](self-managed/automation/ansible/playbooks/site.yml) without pre-baked AMIs. See [`self-managed-automation.md`](self-managed/automation/self-managed-automation.md).

> This stack represents the correct boundary for Terraform in self-managed
> environments: provision the infrastructure, not the OS. Forcing Terraform
> into service configuration would contradict both the architecture of this
> repo and the documented manual baseline.

---

**Docker equivalent:** Full manual & automated infrastructure stack with Nginx, BIND9, SFTP, and Traefik reverse proxy — [`containerize-your-infra/stacks/full-infra`](https://github.com/Bios-Mod/containerize-your-infra/tree/main/stacks/full-infra)
