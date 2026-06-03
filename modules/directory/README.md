# Directory

Centralized identity store providing Kerberos authentication, LDAP directory
queries, Group Policy enforcement, and integrated DNS for domain-joined hosts.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed
on the target environment before applying this module.

## Implementations

| Environment | Technology | Doc |
|---|---|---|
| aws-native | AWS Directory Service (Managed Microsoft AD) | [aws-native.md](aws-native/aws-native.md) |
| self-managed | Samba 4 AD DC | [self-managed.md](self-managed/self-managed.md) |

> **AWS Native cost:** Managed AD (Standard Edition) bills at ~$0.10/hour
> (two controllers, always-on). Use the deploy-on-demand strategy documented
> in the aws-native implementation guide.