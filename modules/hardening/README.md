# Hardening

Security baseline applied before deploying any service. Follows the
defense-in-depth principle — multiple independent layers where the failure
of one does not compromise the system.

**Required prerequisite for all other modules.**

---

## Implementations

| Environment | Approach | Doc |
|-------------|----------|-----|
| self-managed | UFW · SSH · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · AIDE · Lynis | [hardening-self-managed.md](self-managed/hardening-self-managed.md) |
| aws-native | Security Groups · IMDSv2 · SSM · GuardDuty · CloudTrail · Security Hub · VPC Flow Logs | [hardening-aws-native.md](aws-native/hardening-aws-native.md) |

Lynis hardening index: **88** (local VM) · **90** (EC2 self-managed)