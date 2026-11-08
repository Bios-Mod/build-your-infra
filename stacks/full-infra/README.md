# Full Infrastructure Stack — build-your-infra

**Terraform · EC2 · VPC · GuardDuty · CloudTrail · Transfer Family · Route 53 · CloudFront · Directory Service**

---

This directory contains the full-stack deployments for build-your-infra —
the integration layer that composes all modules into a single, reproducible
`terraform apply`. Each module retains its own `automation/terraform/` for
standalone deployment; this stack is the composition layer that connects them.

Two implementations are provided, one per environment path:

| Implementation | Tool | Scope | Doc |
|---|---|---|---|
| `aws-native/` | Terraform | All AWS Native modules composed as a single deployment | [`aws-native/aws-native-automation.md`](aws-native/aws-native-automation.md) |
| `self-managed/` | Terraform + Ansible | EC2 greenfield (Terraform) + OS hardening and service orchestration (Ansible) | [`self-managed/automation/self-managed-automation.md`](self-managed/automation/self-managed-automation.md) |

---

## aws-native

Provisions the full AWS Native infrastructure from scratch in a single
`terraform apply`: VPC baseline, Security Groups, GuardDuty, CloudTrail,
Security Hub, Transfer Family, Route 53 Private Hosted Zone, CloudFront
distribution with ACM certificate, and Directory Service. Each module is
called as a Terraform `source` reference — configs stay in
`modules/*/aws-native/automation/terraform/`.

> **Prerequisites:** AWS credentials configured for the `multi-lab-admin` profile. Each module must be applied and verified on its own first, then destroyed (`terraform destroy`) before running this stack: it is a greenfield deployment and the module deployments would otherwise collide on resource names (`multi-lab-vpc`, `multi-lab-sg`, …).

---

## self-managed

Provisions a clean EC2 instance (`multi-lab-aws`) running Ubuntu Server 24.04 LTS ARM64 from the canonical AMI, attaching an Elastic IP, configuring Security Groups with dynamic IP ingress, and attaching an IAM instance profile with SSM Session Manager access. Covers the infrastructure layer only: instance placement, network assignment, and Security Groups.

The operating system configuration layer is automated with Ansible. All six modules (hardening, file-transfer, dns, web-server, directory, and dhcp) are fully automated and orchestrated through [`playbooks/site.yml`](self-managed/automation/ansible/playbooks/site.yml), establishing the complete baseline from scratch without relying on pre-baked AMI snapshots.
See [`self-managed-automation.md`](self-managed/automation/self-managed-automation.md) for the end-to-end automation guide.

> This stack represents the correct boundary for Terraform in self-managed
> environments: provision the infrastructure, not the OS. Forcing Terraform
> into service configuration would contradict both the architecture of this
> repo and the documented manual baseline.

---

**Docker equivalent:** Full manual & automated infrastructure stack with Nginx, BIND9, SFTP, and Traefik reverse proxy — [`containerize-your-infra/stacks/full-infra`](https://github.com/Bios-Mod/containerize-your-infra/tree/main/stacks/full-infra)
