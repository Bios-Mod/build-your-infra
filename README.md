# build-your-infra — Multi-Environment Infrastructure Lab

[![Lynis VM](https://img.shields.io/badge/Lynis%20VM-88-brightgreen?style=flat-square&logo=linux&logoColor=white)](modules/hardening/self-managed/self-managed.md)
[![Lynis EC2](https://img.shields.io/badge/Lynis%20EC2-90-brightgreen?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/self-managed/self-managed.md)
[![WireGuard](https://img.shields.io/badge/WireGuard-VPN-red?style=flat-square&logo=wireguard&logoColor=white)](modules/hardening/self-managed/self-managed.md)
[![UFW](https://img.shields.io/badge/UFW-Firewall-informational?style=flat-square&logo=linux&logoColor=white)](modules/hardening/self-managed/self-managed.md)
[![Fail2Ban](https://img.shields.io/badge/Fail2Ban-active-success?style=flat-square)](modules/hardening/self-managed/self-managed.md)
[![AppArmor](https://img.shields.io/badge/AppArmor-enforce-blueviolet?style=flat-square)](modules/hardening/self-managed/self-managed.md)
[![auditd](https://img.shields.io/badge/auditd-active-blue?style=flat-square)](modules/hardening/self-managed/self-managed.md)
[![GuardDuty](https://img.shields.io/badge/GuardDuty-enabled-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/aws-native.md)
[![CloudTrail](https://img.shields.io/badge/CloudTrail-audit-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/aws-native.md)
[![Security Hub](https://img.shields.io/badge/Security%20Hub-enabled-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/aws-native.md)

[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=flat-square&logo=ubuntu&logoColor=white)](environments/local/local-vm-setup.md)
[![SFTP](https://img.shields.io/badge/SFTP-OpenSSH%20subsystem-blue?style=flat-square)](modules/file-transfer/self-managed/self-managed.md)
[![BIND9](https://img.shields.io/badge/BIND9-DNS-informational?style=flat-square)](modules/dns/self-managed/self-managed.md)
[![Nginx](https://img.shields.io/badge/Nginx-HTTPS%20%2B%20proxy-009639?style=flat-square&logo=nginx&logoColor=white)](modules/web-server/self-managed/self-managed.md)
[![Samba4](https://img.shields.io/badge/Samba4-AD%20DC-blue?style=flat-square)](modules/directory/self-managed/self-managed.md)
[![Kea DHCP](https://img.shields.io/badge/Kea-DHCP-informational?style=flat-square)](modules/dhcp/self-managed/self-managed.md)

[![AWS EC2](https://img.shields.io/badge/AWS-EC2%20t4g.micro-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](environments/vps/vps-ec2-setup.md)
[![SSM](https://img.shields.io/badge/SSM-Session%20Manager-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/hardening/aws-native/aws-native.md)
[![Transfer Family](https://img.shields.io/badge/Transfer%20Family-SFTP-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/file-transfer/aws-native/aws-native.md)
[![Route 53](https://img.shields.io/badge/Route%2053-Private%20DNS-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/dns/aws-native/aws-native.md)
[![S3](https://img.shields.io/badge/S3-Static%20Origin-FF9900?style=flat-square&logo=amazons3&logoColor=white)](modules/web-server/aws-native/aws-native.md)
[![ACM](https://img.shields.io/badge/ACM-TLS%20Certificates-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/web-server/aws-native/aws-native.md)
[![CloudFront](https://img.shields.io/badge/CloudFront-CDN-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/web-server/aws-native/aws-native.md)
[![Directory Service](https://img.shields.io/badge/Directory%20Service-Managed%20AD-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](modules/directory/aws-native/aws-native.md)

A practical, step-by-step reference for deploying and hardening infrastructure across three environments: local VM, VPS, and AWS Native managed services. Each module is implemented at the configuration level, with the reasoning behind every decision explained inline.

Built and tested on Ubuntu Server 24.04 LTS. Deployments use both the AWS Management Console (where the GUI provides the clearest workflow) and the CLI. No automation frameworks at this stage — automation of deployed modules is planned as a follow-up phase.

---

## Environments

| Component     | Local (VM)                                        | VPS / EC2                                       | AWS Native                          |
|---------------|---------------------------------------------------|-------------------------------------------------|-------------------------------------|
| OS            | Ubuntu Server 24.04 LTS                           | Ubuntu Server 24.04 LTS                         | Managed (per service)               |
| Architecture  | ARM64 (Apple Silicon) / x86_64                    | ARM64 (Graviton2)                               | —                                   |
| Deployment    | VMware Fusion / VirtualBox · Bridged network      | EC2 t4g.micro · eu-west-1                       | AWS managed services · eu-west-1    |
| Network       | Static IP · LAN                                   | Elastic IP · VPC                                | VPC · private subnets               |
| Remote Access | SSH Ed25519 · port 22222 · WireGuard VPN          | SSH Ed25519 · port 22222 · WireGuard VPN        | SSM Session Manager / service APIs  |

`local` and `vps` follow the same self-managed hardening baseline. `aws-native`
replaces each service with its AWS managed equivalent — no OS to manage.

> See [`environments/README.md`](environments/README.md) for environment setup
> guides and when to use each.

> **Architecture note:** Built and tested on ARM64 (Apple Silicon via VMware
> Fusion and AWS Graviton2). All configurations are architecture-agnostic
> except where noted. x86_64 users can follow the same steps — differences
> are called out inline.

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

12 steps covering 9 independent security layers — Lynis hardening index **88** (VM) · **90** (EC2).

### Services

| Module | Self-Managed Technology | AWS Native Technology | Doc |
|--------|-------------------------|-----------------------|-----|
| File Transfer | SFTP (OpenSSH subsystem) | AWS Transfer Family | [`modules/file-transfer/`](modules/file-transfer/README.md) |
| DNS | BIND9 | Route 53 Private Hosted Zones | [`modules/dns/`](modules/dns/README.md) |
| Web Server | Nginx + HTTPS · reverse proxy | S3 · CloudFront · ACM | [`modules/web-server/`](modules/web-server/README.md) |
| Directory | Samba 4 AD DC | AWS Directory Service (Managed Microsoft AD) | [`modules/directory/`](modules/directory/README.md) |
| DHCP | Kea DHCP | N/A — local only | Planned | [`modules/dhcp/`](modules/dhcp/README.md) |

> **Directory dependency:** Samba 4 AD DC mode includes its own internal DNS
> server that can replace or integrate with BIND9. Review the DNS module
> before provisioning the directory — zone delegation or full BIND9
> replacement may be required.

---

## Repository Structure
```
build-your-infra/
├── AGENTS.md
├── context
│   ├── current-iteration.md
│   └── decision-log.md
├── CONTRIBUTING.md
├── environments
│   ├── aws-native
│   │   └── aws-native-setup.md
│   ├── local
│   │   └── local-vm-setup.md
│   ├── README.md
│   └── vps
│       └── vps-ec2-setup.md
├── LICENSE
├── modules
│   ├── dhcp
│   │   ├── README.md
│   │   └── self-managed
│   │       ├── automation
│   │       ├── configs
│   │       └── self-managed.md
│   ├── directory
│   │   ├── aws-native
│   │   │   ├── automation
│   │   │   └── aws-native.md
│   │   ├── README.md
│   │   └── self-managed
│   │       ├── automation
│   │       ├── configs
│   │       └── self-managed.md
│   ├── dns
│   │   ├── aws-native
│   │   │   ├── automation
│   │   │   └── aws-native.md
│   │   ├── README.md
│   │   └── self-managed
│   │       ├── automation
│   │       ├── configs
│   │       │   ├── aide
│   │       │   ├── audit
│   │       │   ├── bind
│   │       │   └── netplan
│   │       └── self-managed.md
│   ├── file-transfer
│   │   ├── aws-native
│   │   │   ├── automation
│   │   │   └── aws-native.md
│   │   ├── README.md
│   │   └── self-managed
│   │       ├── automation
│   │       ├── configs
│   │       │   ├── aide
│   │       │   ├── audit
│   │       │   └── ssh
│   │       └── self-managed.md
│   ├── hardening
│   │   ├── aws-native
│   │   │   ├── automation
│   │   │   └── aws-native.md
│   │   ├── README.md
│   │   └── self-managed
│   │       ├── automation
│   │       ├── configs
│   │       │   ├── aide
│   │       │   ├── audit
│   │       │   ├── fail2ban
│   │       │   ├── limits
│   │       │   ├── logrotate
│   │       │   ├── lynis
│   │       │   ├── modprobe
│   │       │   ├── netplan
│   │       │   ├── pam
│   │       │   ├── rsyslog
│   │       │   ├── ssh
│   │       │   ├── sysctl
│   │       │   ├── ufw
│   │       │   ├── unattended-upgrades
│   │       │   └── wireguard
│   │       └── self-managed.md
│   └── web-server
│       ├── aws-native
│       │   ├── automation
│       │   └── aws-native.md
│       ├── html
│       │   └── index.html
│       ├── README.md
│       └── self-managed
│           ├── automation
│           ├── configs
│           │   ├── aide
│           │   ├── audit
│           │   └── nginx
│           └── self-managed.md
├── README.md
└── snapshots
    └── README.md
```

📄 Snapshot log → [`snapshots/README.md`](snapshots/README.md)