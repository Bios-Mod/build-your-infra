# Hardening — AWS Native

> **Status: Planned — not yet implemented.**
> This document will cover the AWS-native hardening baseline once this
> environment is provisioned. Structure and controls are defined below
> as a reference for implementation.

---

## Scope

AWS-native hardening operates at three levels that have no direct equivalent
in the self-managed implementation:

| Level | Controls |
|---|---|
| Account & IAM | Root account locked · MFA enforced · least-privilege roles · no long-lived access keys |
| Network | VPC with custom NACL · Security Groups (default-deny per service) · no 0.0.0.0/0 SSH |
| Instance | IMDSv2 enforced · SSM Session Manager (no SSH exposure) · encrypted EBS volumes |
| Detection | GuardDuty (threat intelligence) · Inspector (vulnerability scanning) · CloudTrail (API audit) · AWS Config (compliance drift) |

---

## Planned Controls

### IAM Baseline
- Root account: no access keys, MFA enabled, never used for daily operations
- Admin access via IAM role with MFA condition (`aws:MultiFactorAuthPresent: true`)
- EC2 instance profile — scoped IAM role attached to instance, no user credentials on disk
- No inline policies — managed policies only, one per functional boundary

### Network
- Custom VPC — no default VPC in use
- Security Groups: default-deny inbound, explicit allow per service per module
- SSH (`22222/tcp`) not exposed to `0.0.0.0/0` — access via SSM Session Manager or WireGuard only
- VPC Flow Logs enabled — routed to CloudWatch Logs

### Instance
- IMDSv2 enforced (`HttpTokens: required`) — blocks SSRF-based metadata credential theft
- EBS root volume encrypted at rest (default KMS key or CMK)
- SSM Agent active — provides shell access without an open SSH port
- No SSH key pair attached to instance when SSM is the access method

### Detection & Audit
- **GuardDuty** — continuous threat detection on VPC Flow Logs, CloudTrail, DNS logs
- **AWS Inspector** — automated CVE scanning on EC2 and container images
- **CloudTrail** — all API calls logged to S3 with integrity validation enabled
- **AWS Config** — records configuration changes; rules flag deviations from baseline

---

## Relationship to Self-Managed

The controls above replace or complement the self-managed stack:

| Self-managed | AWS Native equivalent |
|---|---|
| UFW (firewall) | Security Groups + NACLs |
| SSH key-only + port 22222 | SSM Session Manager (no SSH port required) |
| WireGuard VPN | VPC private subnets + VPN Gateway (optional) |
| sysctl / AppArmor / auditd | AWS Inspector + SSM Patch Manager + CloudTrail |
| Lynis runtime audit | AWS Config conformance packs (CIS AWS Foundations) |
| Fail2Ban | GuardDuty (automated threat detection + findings) |

---

## Implementation Reference

- [aws-native-setup.md](../../environments/aws-native/aws-native-setup.md) — base VPC, IAM, and account prerequisites
- [automation/](automation/) — Terraform / AWS CLI scripts *(planned)*