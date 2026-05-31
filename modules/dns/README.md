# DNS

Internal name resolution for lab services and clients, with controlled recursion, split-horizon capability, and a forward path to future Active Directory integration.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed on the target environment before applying this module.

## Implementations

| Environment | Technology | Doc |
|---|---|---|
| self-managed | BIND9 (authoritative + recursive resolver) | [self-managed.md](self-managed/self-managed.md) |
| aws-native | Route 53 Private Hosted Zone | [aws-native.md](aws-native/aws-native.md) |

> **Deployment scope — self-managed:** BIND9 is deployed exclusively on the
> EC2 instance, which acts as the WireGuard hub. All other lab hosts (local VM,
> additional peers) consume DNS over the WireGuard tunnel — no DNS server is
> installed on client nodes.

> **Directory dependency:** Samba 4 AD DC includes its own internal DNS server that can > replace or integrate with BIND9. Review this module and its zone structure before 
> provisioning the directory module — zone delegation or full BIND9 replacement may be 
> required.