# DHCP

Manual address assignment doesn't scale and causes conflicts on a shared network. Dynamic address assignment and lease management for the local network.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed
on the target environment before applying this module.

> **Deployment scope:** This module applies exclusively to the local VM
> environment. In AWS, address assignment is handled at the VPC layer through
> DHCP Options Sets — there is no deployable DHCP service equivalent.

## Implementations

| Environment | Technology | Doc |
| --- | --- | --- |
| self-managed (local VM) | Kea DHCP | [dhcp-self-managed.md](self-managed/dhcp-self-managed.md) |
| aws-native | N/A — VPC DHCP Options Sets | — |

**Automation (self-managed):** Ansible role [`dhcp`](../../stacks/full-infra/self-managed/automation/self-managed-automation.md#dhcp--kea-dhcpv4-service) (local VM only)
