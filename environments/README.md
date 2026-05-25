# Environments

This lab runs across three independent environments. Each deploys the same
modules — `local` and `vps` via self-managed Linux, `aws-native` via AWS
managed services.

---

## Overview

| Environment | Infrastructure | When to use |
|-------------|---------------|-------------|
| `local` | Ubuntu 24.04 LTS · VMware Fusion / VirtualBox | Full lab control, offline work, DHCP module (VM-only) |
| `vps` | Ubuntu 24.04 LTS · EC2 t4g.micro | Cloud-hosted self-managed deployment, same stack as local |
| `aws-native` | AWS managed services | Managed equivalents — no OS to configure |

`local` and `vps` share the same modules, configs, and deployment order.
`aws-native` is an independent path — each module maps to an AWS service
and is documented separately.

---

## Setup guides

| Environment | Guide |
|-------------|-------|
| `local` | [`local/local-vm-setup.md`](local/local-vm-setup.md) |
| `vps` | [`vps/vps-ec2-setup.md`](vps/vps-ec2-setup.md) |
| `aws-native` | [`aws-native/aws-native-setup.md`](aws-native/aws-native-setup.md) |

`local` and `vps` share the same module docs and deployment order —
complete the relevant setup guide, then follow
[`modules/hardening/self-managed/self-managed.md`](../modules/hardening/self-managed/self-managed.md)
before applying any other module.

`aws-native-setup.md` is a prerequisite for all `modules/*/aws-native/` docs.