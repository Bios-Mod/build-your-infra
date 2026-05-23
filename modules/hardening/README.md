# Hardening

Security baseline applied before deploying any service. Follows the
defense-in-depth principle — multiple independent layers where the failure
of one does not compromise the system.

**Required prerequisite for all other modules.**

---

## Implementations

| Environment | Approach | Status | Doc |
|-------------|----------|--------|-----|
| self-managed | UFW · SSH · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · AIDE · Lynis | Complete | [self-managed.md](self-managed/self-managed.md) |
| aws-native | Security Groups · IMDSv2 · SSM · Inspector · GuardDuty · CloudTrail · Config | Planned | [aws-native.md](aws-native/aws-native.md) |

Lynis hardening index: **88** (local VM) · **90** (EC2 self-managed)