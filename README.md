![build-your-infra banner](./banner.png)

# build-your-infra — Multi-Environment Infrastructure Lab

[![Push](https://github.com/Bios-Mod/build-your-infra/actions/workflows/push-ci.yml/badge.svg)](https://github.com/Bios-Mod/build-your-infra/actions/workflows/push-ci.yml)
[![Pull Request](https://github.com/Bios-Mod/build-your-infra/actions/workflows/pull-request.yml/badge.svg)](https://github.com/Bios-Mod/build-your-infra/actions/workflows/pull-request.yml)

[![Lynis VM](https://img.shields.io/badge/Lynis%20VM-88-brightgreen?style=flat-square&logo=linux&logoColor=white)](modules/hardening/self-managed/hardening-self-managed.md)
[![Lynis EC2](https://img.shields.io/badge/Lynis%20EC2-90-brightgreen?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/self-managed/hardening-self-managed.md)
[![WireGuard](https://img.shields.io/badge/WireGuard-VPN-red?style=flat-square&logo=wireguard&logoColor=white)](modules/hardening/self-managed/hardening-self-managed.md)
[![UFW](https://img.shields.io/badge/UFW-Firewall-informational?style=flat-square&logo=linux&logoColor=white)](modules/hardening/self-managed/hardening-self-managed.md)
[![Fail2Ban](https://img.shields.io/badge/Fail2Ban-active-success?style=flat-square)](modules/hardening/self-managed/hardening-self-managed.md)
[![AppArmor](https://img.shields.io/badge/AppArmor-enforce-blueviolet?style=flat-square)](modules/hardening/self-managed/hardening-self-managed.md)
[![auditd](https://img.shields.io/badge/auditd-active-blue?style=flat-square)](modules/hardening/self-managed/hardening-self-managed.md)
[![GuardDuty](https://img.shields.io/badge/GuardDuty-enabled-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/hardening-aws-native.md)
[![CloudTrail](https://img.shields.io/badge/CloudTrail-audit-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/hardening-aws-native.md)
[![Security Hub](https://img.shields.io/badge/Security%20Hub-enabled-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/hardening-aws-native.md)

[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=flat-square&logo=ubuntu&logoColor=white)](environments/local/local-vm-setup.md)
[![SFTP](https://img.shields.io/badge/SFTP-OpenSSH%20subsystem-blue?style=flat-square)](modules/file-transfer/self-managed/file-transfer-self-managed.md)
[![BIND9](https://img.shields.io/badge/BIND9-DNS-informational?style=flat-square)](modules/dns/self-managed/dns-self-managed.md)
[![Nginx](https://img.shields.io/badge/Nginx-HTTPS%20%2B%20proxy-009639?style=flat-square&logo=nginx&logoColor=white)](modules/web-server/self-managed/web-server-self-managed.md)
[![Samba4](https://img.shields.io/badge/Samba4-AD%20DC-blue?style=flat-square)](modules/directory/self-managed/directory-self-managed.md)
[![Kea DHCP](https://img.shields.io/badge/Kea-DHCP-informational?style=flat-square)](modules/dhcp/self-managed/dhcp-self-managed.md)
[![Ansible](https://img.shields.io/badge/Ansible-automation-EE0000?style=flat-square&logo=ansible&logoColor=white)](stacks/full-infra/self-managed/automation/self-managed-automation.md)
[![Terraform](https://img.shields.io/badge/Terraform-IaC-7B42BC?style=flat-square&logo=terraform&logoColor=white)](stacks/full-infra/self-managed/automation/self-managed-automation.md)

[![AWS EC2](https://img.shields.io/badge/AWS-EC2%20t4g.micro-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](environments/vps/vps-ec2-setup.md)
[![SSM](https://img.shields.io/badge/SSM-Session%20Manager-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/hardening-aws-native.md)
[![Transfer Family](https://img.shields.io/badge/Transfer%20Family-SFTP-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/file-transfer/aws-native/file-transfer-aws-native.md)
[![Route 53](https://img.shields.io/badge/Route%2053-Private%20DNS-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/dns/aws-native/dns-aws-native.md)
[![S3](https://img.shields.io/badge/S3-Static%20Origin-FF9900?style=flat-square&logo=amazons3&logoColor=white)](modules/web-server/aws-native/web-server-aws-native.md)
[![ACM](https://img.shields.io/badge/ACM-TLS%20Certificates-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/web-server/aws-native/web-server-aws-native.md)
[![CloudFront](https://img.shields.io/badge/CloudFront-CDN-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/web-server/aws-native/web-server-aws-native.md)
[![Directory Service](https://img.shields.io/badge/Directory%20Service-Managed%20AD-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/directory/aws-native/directory-aws-native.md)

Server infrastructure is usually built once by hand and never reproduced: configurations drift, security baselines are undocumented, and nobody remembers why a setting was chosen. This lab solves that by deploying the same service set (hardening, file transfer, DNS, web, directory, DHCP, monitoring) across three environments — local VM, VPS and AWS Native — documenting the reasoning behind every decision inline, and then automating each layer with the tool that fits it: Terraform provisions, Ansible configures, GitHub Actions validates.

Built and tested on Ubuntu Server 24.04 LTS. Deployments use both the AWS Management Console (where the GUI provides the clearest workflow) and the CLI.

The same services are also deployed as Docker containers in
[containerize-your-infra](https://github.com/Bios-Mod/containerize-your-infra)
— a parallel lab covering the same stack at a different level of abstraction.
That repo documents the containerized equivalent of each module here:
Nginx, BIND9, SFTP, and reverse proxy via Traefik v3, deployed with Docker
Engine and Compose v2 across dev (OrbStack on macOS) and prod
(Ubuntu 24.04 LTS · EC2 t4g.micro) environments.

---

## Environments

| Component | Local (VM) | VPS / EC2 | AWS Native |
| --- | --- | --- | --- |
| OS | Ubuntu Server 24.04 LTS | Ubuntu Server 24.04 LTS | Managed (per service) |
| Architecture | ARM64 (Apple Silicon) / x86_64 | ARM64 (Graviton2) | — |
| Deployment | VMware Fusion / VirtualBox · Bridged network | EC2 t4g.micro · eu-west-1 | AWS managed services · eu-west-1 |
| Network | Static IP · LAN | Elastic IP · VPC | VPC · private subnets |
| Remote Access | SSH Ed25519 · port 22222 · WireGuard VPN | SSH Ed25519 · port 22222 · WireGuard VPN | SSM Session Manager / service APIs |

`local` and `vps` follow the same self-managed hardening baseline. `aws-native`
replaces each service with its AWS managed equivalent — no OS to manage.

> See [`environments/README.md`](environments/README.md) for
> environment setup guides and when to use each.
>
> **Architecture note:** Built and tested on ARM64 (Apple
> Silicon via VMware Fusion and AWS Graviton2).
> All configurations are architecture-agnostic except
> where noted. x86_64 users can follow the same steps —
> differences are called out inline.

---

## Architecture

Three planes connect through one WireGuard network. The Mac drives Terraform and Ansible, the EC2 instance is the WireGuard hub and public edge, and the local VM is a peer that also hosts the monitoring stack. GitHub Actions validates every change before it reaches `main`.

```mermaid
flowchart LR
    subgraph MAC["Control node · Mac"]
        ANS["Ansible"]
        TFM["Terraform"]
        BRW["Browser"]
    end

    CI["GitHub Actions<br/>lint · syntax · terraform validate"]

    subgraph AWS["AWS eu-west-1 · multi-lab-vpc 10.0.0.0/16"]
        subgraph EC2["EC2 multi-lab-vps · WireGuard hub 172.16.0.1"]
            EC2S["BIND9 · Nginx + Let's Encrypt<br/>Samba AD DC · SFTP · node_exporter"]
        end
        R53["Route 53<br/>public zone"]
    end

    subgraph LAN["Local LAN 192.168.1.0/24"]
        subgraph VM["VM multi-lab-local · WireGuard peer 172.16.0.3"]
            VMS["Kea DHCP · Nginx self-signed<br/>SFTP · node_exporter"]
            MON["Prometheus · blackbox_exporter<br/>Grafana :3000"]
        end
    end

    TFM -->|provisions| AWS
    ANS -->|SSH 22222 over WireGuard| EC2
    ANS -->|SSH 22222 over LAN| VM
    MAC <-->|WireGuard 172.16.0.2| EC2
    VM <-->|WireGuard 172.16.0.0/24| EC2
    MON -->|scrape :9100 · probe DNS HTTPS TCP| EC2S
    BRW -->|Grafana over wg0| MON
    R53 -->|A record| EC2
    CI -.->|validates pushed code| MAC
```

The monitoring server runs on the local VM and reaches the EC2 hub only through `wg0`. Grafana is reachable only over WireGuard, keeping metrics and dashboards off public networks. The `aws-native` path (Managed AD, Transfer Family, CloudFront) is an independent alternative not shown here.

---

## Deploying This Lab

Choose your environment and follow its setup guide before applying any module:

- **Local VM** — Ubuntu Server 24.04 LTS · VMware Fusion / VirtualBox (bridged adapter) → [`environments/local/local-vm-setup.md`](environments/local/local-vm-setup.md)
- **VPS / EC2** — Ubuntu Server 24.04 LTS on any cloud provider → [`environments/vps/vps-ec2-setup.md`](environments/vps/vps-ec2-setup.md)
- **AWS Native** — AWS account with IAM user, custom VPC, and base security services enabled → [`environments/aws-native/aws-native-setup.md`](environments/aws-native/aws-native-setup.md)

Apply modules in order — `hardening` is the only hard prerequisite. All other
modules are independent and can be deployed individually on top of the
hardened base.

---

## Modules

### Foundation

| Module | Self-Managed Technology | AWS Native Technology | Doc |
|--------|-------------------------|-----------------------|-----|
| Hardening | OpenSSH · UFW · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · rsyslog · AIDE · Lynis | Security Groups · IMDSv2 · SSM · GuardDuty · CloudTrail | [`modules/hardening/`](modules/hardening/README.md) |

13 steps (Steps 0–12) covering independent security layers — Lynis hardening index **88** (VM) · **90** (EC2).

### Services

| Module | Self-Managed Technology | AWS Native Technology | Doc |
| -------- | ------------------------- | ----------------------- | ----- |
| File Transfer | SFTP (OpenSSH subsystem) | AWS Transfer Family | [`modules/file-transfer/`](modules/file-transfer/README.md) |
| DNS | BIND9 | Route 53 Private Hosted Zones | [`modules/dns/`](modules/dns/README.md) |
| Web Server | Nginx + HTTPS · reverse proxy | S3 · CloudFront · ACM | [`modules/web-server/`](modules/web-server/README.md) |
| Directory | Samba 4 AD DC | AWS Directory Service (Managed Microsoft AD) | [`modules/directory/`](modules/directory/README.md) |
| DHCP | Kea DHCP | N/A — local only | [`modules/dhcp/`](modules/dhcp/README.md) |
| Monitoring | Prometheus · Grafana · node_exporter · blackbox_exporter | N/A — self-managed only | [`modules/monitoring/`](modules/monitoring/README.md) |

> **Directory dependency:** Samba 4 AD DC mode includes its own
> internal DNS server that can replace or integrate with BIND9.
> Review the DNS module before provisioning the directory — zone
> delegation or full BIND9 replacement may be required.

## Automation

Each layer of the lab is automated with the tool that matches its scope. Terraform provisions infrastructure, Ansible configures the operating system, and GitHub Actions validates both.

| Environment | Tool | Scope | Location |
| --- | --- | --- | --- |
| aws-native | Terraform | Per-module import + redeploy | `modules/<name>/aws-native/automation/terraform/` |
| self-managed | Terraform | EC2 greenfield from the canonical Ubuntu 24.04 ARM64 AMI — infrastructure layer | `stacks/full-infra/self-managed/automation/terraform/` |
| self-managed | Ansible | OS configuration layer — hardening, file-transfer, dns, web-server, directory, dhcp, and monitoring automated via [`site.yml`](stacks/full-infra/self-managed/automation/ansible/playbooks/site.yml); see [`self-managed-automation.md`](stacks/full-infra/self-managed/automation/self-managed-automation.md) | `stacks/full-infra/self-managed/automation/ansible/` (roles, inventory, playbooks) |

The aws-native implementation order is `hardening` → `dns` → `file-transfer` → `web-server` → `directory`. Each module is independently deployable, and the full-stack composition sources them all.

The self-managed Terraform stack provisions a clean EC2 host running Ubuntu Server 24.04 LTS ARM64 from the canonical AMI — infrastructure only. Ansible roles reproduce the entire OS configuration baseline from scratch without relying on pre-baked images. The self-managed implementation order is `hardening` → `file-transfer` → `dns` → `web-server` → `directory` → `dhcp` → `monitoring`, where `site.yml` provides full-stack convergence over already initialized hosts (initial host bootstrap and progressive `connection_mode` transitions are documented separately in the guide). To eliminate all ongoing cloud billing after experimentation, see the [Teardown](stacks/full-infra/self-managed/automation/self-managed-automation.md#teardown--destroy-all-lab-resources) guide for step-by-step instructions on how to remove every resource the lab creates.

---

## Continuous Integration

Every module and automation stack is validated on push and pull request via GitHub Actions — self-managed configs through native syntax checkers (`sshd -t`, `named-checkconf`, `testparm`, `nginx -t`, `fail2ban-client -t`, `aide --check`), Ansible automation through `ansible-lint` and `--syntax-check`, and aws-native Terraform through `fmt -check` and `validate`. A single reusable workflow (`modules-ci.yml`) defines every check once; push and pull-request entry points call it via `workflow_call`, avoiding duplicated validation logic across triggers.

`terraform plan` is intentionally excluded from CI — there is no persistent AWS environment in this lab, so `plan` remains a manual, local step before apply.

See [`continuous-integration.md`](continuous-integration.md) for the full workflow structure, design decisions, and actions used.

---

## Repository Structure

```
├── .github
│   └── workflows
│       ├── modules-ci.yml
│       ├── pull-request.yml
│       └── push-ci.yml
├── banner.png
├── continuous-integration.md
├── CONTRIBUTING.md
├── environments
│   ├── aws-native
│   │   └── aws-native-setup.md
│   ├── local
│   │   └── local-vm-setup.md
│   ├── README.md
│   └── vps
│       └── vps-ec2-setup.md
├── LICENSE
├── modules
│   ├── dhcp
│   │   ├── README.md
│   │   └── self-managed
│   ├── directory
│   │   ├── aws-native
│   │   ├── README.md
│   │   └── self-managed
│   ├── dns
│   │   ├── aws-native
│   │   ├── README.md
│   │   └── self-managed
│   ├── file-transfer
│   │   ├── aws-native
│   │   ├── README.md
│   │   └── self-managed
│   ├── hardening
│   │   ├── aws-native
│   │   ├── README.md
│   │   └── self-managed
│   ├── monitoring
│   │   ├── README.md
│   │   └── self-managed
│   └── web-server
│       ├── aws-native
│       ├── html
│       ├── README.md
│       └── self-managed
├── README.md
├── snapshots
│   └── README.md
└── stacks
    └── full-infra
        ├── aws-native
        ├── README.md
        └── self-managed
```

📄 Snapshot log → [`snapshots/README.md`](snapshots/README.md)
