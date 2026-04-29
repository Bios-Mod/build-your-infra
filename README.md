# Multi-Service Linux Server — Build & Hardening Guide

![Lynis Hardening Index](https://img.shields.io/badge/Lynis%20Index-88-brightgreen?style=flat-square&logo=linux&logoColor=white)
![CIS Level 1](https://img.shields.io/badge/CIS-Level%201%20Aligned-blue?style=flat-square)
![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=flat-square&logo=ubuntu&logoColor=white)
![OpenSSH](https://img.shields.io/badge/OpenSSH-Ed25519-black?style=flat-square&logo=openssh&logoColor=white)
![WireGuard](https://img.shields.io/badge/WireGuard-VPN-red?style=flat-square&logo=wireguard&logoColor=white)
![UFW](https://img.shields.io/badge/UFW-Firewall-informational?style=flat-square&logo=linux&logoColor=white)
![Fail2Ban](https://img.shields.io/badge/Fail2Ban-active-success?style=flat-square)
![AppArmor](https://img.shields.io/badge/AppArmor-enforce-blueviolet?style=flat-square)
![Phase](https://img.shields.io/badge/Phase-OS%20Hardening%20Complete-success?style=flat-square)

A practical, step-by-step reference for deploying and hardening a self-managed
Linux server from scratch. Covers OS hardening, network services, and identity
management — each layer documented at the configuration level, with the
reasoning behind every decision explained inline.

Built and tested on Ubuntu Server 24.04 LTS. Works on a VM (VMware, VirtualBox),
directly on bare metal hardware, or on a VPS. VM-specific steps are clearly
marked — everything else applies universally.

No GUI tools. No automation frameworks. Everything via CLI.

---

## Stack & Environment

| Component     | Detail |
|---------------|--------|
| OS            | Ubuntu Server 24.04 LTS |
| Architecture  | ARM64 (aarch64) / x86_64 — see note |
| Deployment    | VM (VMware Fusion · VMware Workstation · VirtualBox) · Bare metal · VPS |
| Network       | Static IP — Bridged (VM) / direct (bare metal / VPS) |
| Remote Access | SSH key-based authentication (Ed25519) |

> **Architecture note:** This lab was built and tested on ARM64 (Apple Silicon
> via VMware Fusion). All configurations are architecture-agnostic except where
> noted. x86_64 users on VMware Workstation, VirtualBox, or bare metal can
> follow the same steps — differences are called out inline.

---

## Deploying This Lab

**Prerequisites**
- Ubuntu Server 24.04 LTS (ARM64 or x86_64)
- One of:
  - **VM:** VMware Fusion (macOS) · VMware Workstation · VirtualBox — Bridged network adapter
  - **Bare metal:** Any x86_64 or ARM64 machine with Ubuntu Server installed directly
  - **VPS:** Any cloud provider (AWS EC2, Hetzner, DigitalOcean…) — Ubuntu 24.04 image
- SSH access to the server

**Deployment order**
Steps are numbered and must be followed in sequence — each layer depends on
the one before it. Start with `docs/01-os-hardening.md` before deploying
any service.

**Using the configs**
Each file in `configs/` includes a `Deploy to:` header with the exact target
path and reload command. Replace `192.168.X.X` placeholders with your actual
values before applying.

---

## Foundation

| Step | Component | Technology | Status | Doc |
|------|-----------|------------|--------|-----|
| 01 | OS Hardening | OpenSSH · UFW · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · rsyslog · AIDE · Lynis | ✅ Complete | [`docs/01-os-hardening.md`](docs/01-os-hardening.md) |

12 steps covering 9 independent security layers — Lynis hardening index **88**.

## Services

| Step | Service | Technology | Status | Doc |
|------|---------|------------|--------|-----|
| 02 | File Transfer | SFTP (OpenSSH subsystem) | 🔲 Planned | [`docs/02-sftp.md`](docs/02-sftp.md) |
| 03 | DNS | BIND9 | 🔲 Planned | [`docs/03-dns-bind9.md`](docs/03-dns-bind9.md) |
| 04 | DHCP | Kea / ISC DHCP | 🔲 Planned | [`docs/04-dhcp.md`](docs/04-dhcp.md) |
| 05 | Web Server | Nginx + HTTPS (self-signed) | 🔲 Planned | [`docs/05-nginx-https.md`](docs/05-nginx-https.md) |
| 06 | Reverse Proxy | Nginx (`proxy_pass`) | 🔲 Planned | [`docs/06-reverse-proxy.md`](docs/06-reverse-proxy.md) |
| 07 | Directory Server | Samba 4 | 🔲 Planned | [`docs/07-samba4.md`](docs/07-samba4.md) |

Services are deployed in order of complexity — each layer builds on the
security foundation established before it.

> **Samba 4 dependency:** AD DC mode includes its own internal DNS server
> that can replace or integrate with BIND9. Review the BIND9 configuration
> from Step 03 before provisioning Samba — zone delegation or full BIND9
> replacement may be required. Documented in
> [`docs/07-samba4.md`](docs/07-samba4.md).

---

## Repository Structure
```
multi-lab/
├── CONTRIBUTING.md
├── LICENSE
├── README.md
├── configs
│   ├── aide
│   ├── audit
│   ├── fail2ban
│   ├── limits
│   ├── logrotate
│   ├── lynis
│   ├── modprobe
│   ├── netplan
│   ├── pam
│   ├── rsyslog
│   ├── ssh
│   ├── sysctl
│   ├── ufw
│   ├── unattended-upgrades
│   └── wireguard
├── docs
│   └── 01-os-hardening.md
└── snapshots
    └── README.md
```

Each subdirectory in `configs/` maps to a service or system component.
Every file includes a `Deploy to:` header with the exact target path and
reload command.

📄 Snapshot log → [`snapshots/README.md`](snapshots/README.md)