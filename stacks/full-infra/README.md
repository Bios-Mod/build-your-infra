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
| `self-managed/` | Terraform | EC2 instance launched from pre-hardened AMI snapshot — infrastructure layer only | [`self-managed/self-managed-automation.md`](self-managed/self-managed-automation.md) |

---

## aws-native

Provisions the full AWS Native infrastructure from scratch in a single
`terraform apply`: VPC baseline, Security Groups, GuardDuty, CloudTrail,
Security Hub, Transfer Family, Route 53 Private Hosted Zone, CloudFront
distribution with ACM certificate, and Directory Service. Each module is
called as a Terraform `source` reference — configs stay in
`modules/*/aws-native/automation/terraform/`.

> **Prerequisites:** AWS credentials configured for the `multi-lab-admin`
> profile. All individual module Terraform configurations must have been
> applied and verified before running this stack.

---

## self-managed

Launches the EC2 instance (`multi-lab-aws`) from the
`multi-lab-aws-active-directory` AMI — a pre-hardened image with all
self-managed services already configured: SFTP, BIND9, Nginx, Samba AD DC.
Covers the infrastructure layer only: instance placement, network
assignment, and Security Groups.

The configuration layer (OS hardening, service setup, hardening baseline)
was applied manually and is documented in each module under
`modules/*/self-managed/`. A future Ansible layer will close this gap and
enable full from-scratch provisioning without relying on a snapshot.
`self-managed-automation.md` is the single automation doc for this
environment — it will grow to cover the Ansible layer when implemented.

> This stack represents the correct boundary for Terraform in self-managed
> environments: provision the infrastructure, not the OS. Forcing Terraform
> into service configuration would contradict both the architecture of this
> repo and the documented manual baseline.

---

**Docker equivalent:** Full manual & automated infrastructure stack with Nginx, BIND9, SFTP, and Traefik reverse proxy — [`containerize-your-infra/stacks/full-infra`](https://github.com/Bios-Mod/containerize-your-infra/tree/main/stacks/full-infra)