# Role: directory

This role automates the deployment of Samba 4 as an Active Directory Domain Controller (AD DC) on Ubuntu Server 24.04 LTS (ARM64 / x86_64), implementing the security controls and configuration documented in [`modules/directory/self-managed/directory-self-managed.md`](../../../../../../../modules/directory/self-managed/directory-self-managed.md).

---

## Target Environments & Prerequisites

- **Targets:**
  - `ec2` (`multi-lab-vps` / `directory_servers`): AWS EC2 self-managed instance (t4g.micro Graviton2) hosting the Samba 4 Active Directory Domain Controller (`multilab.internal`).
- **Prerequisites:**
  - The `hardening` role must be fully deployed before applying `directory`. Pre-flight assertions verify that OpenSSH listens on the hardened port (`22222`).
  - The `dns` role must be fully deployed with `dns_listen_on: "127.0.0.1; 172.16.0.1;"` configured in `inventories/host_vars/multi-lab-vps.yml` before applying `directory`. Pre-flight assertions verify that `named` is not listening on `<directory_dc_ip>:53` to prevent port collision with Samba internal DNS.

---

## Role Variables & Inputs

### Mandatory Inventory Variables

| Variable | Description |
|---|---|
| `directory_dc_ip` | Primary private IPv4 address of the Domain Controller (must match `ansible_facts['default_ipv4']['address']`). |
| `directory_auditd_reboot` | Boolean flag controlling automatic reboot when auditd rules are updated on immutable kernels (`-e 2`). Required when `hardening_auditd_immutable_mode` is true. |

> **Note on Administrator Password:** The Active Directory Domain Administrator password is never stored in variables or inventory files. It is requested interactively at playbook runtime via `vars_prompt` in `playbooks/directory.yml` (`directory_admin_password`, minimum 8 characters, requiring characters from at least 3 of 4 classes: lowercase `[a-z]`, uppercase `[A-Z]`, digits `[0-9]`, and special characters `[^a-zA-Z0-9]`) and passed to tasks with `no_log: true`.

### Role Defaults (`defaults/main.yml`)

| Variable | Default Value | Purpose |
|---|---|---|
| `directory_configs_dir` | `{{ configs_root }}/directory/self-managed/configs` | Path to static directory source configuration files. |
| `directory_domain` | `multilab.internal` | Active Directory DNS domain name. |
| `directory_realm` | `MULTILAB.INTERNAL` | Active Directory Kerberos realm name. |
| `directory_netbios` | `MULTILAB` | Active Directory NetBIOS domain / workgroup name. |
| `directory_hostname` | `dc01` | Short hostname of the Domain Controller. |
| `directory_ufw_source` | `172.16.0.0/24` | Source subnet permitted to access AD DS ports via UFW (WireGuard overlay network). |
| `directory_dns_forwarder` | `127.0.0.1` | Upstream DNS forwarder address in `smb.conf` pointing to local BIND9 resolver. |
| `hardening_ssh_port` | `{{ ssh_hardened_port \| default(22222) }}` | Hardened OpenSSH listening port verified in pre-flight assertions. |
| `hardening_auditd_immutable_mode` | `true` | Auditd immutable kernel mode baseline. |

---

## Tasks & Tags

Execution can be targeted via Ansible tags:

| Tag | Scope | Description |
|---|---|---|
| `directory` | Complete Role | Executes pre-flight assertions, system preparation (hostname and `/etc/hosts`), package installation, member daemon disabling, domain provisioning, `smb.conf` parameter configuration, Kerberos client configuration, service enablement, UFW rules, auditd drop-in, AIDE drop-in, handler flush, and verification assertions. |
| `directory_verify` | Verification Only | Executes only the assertions defined in `tasks/verify.yml` (hostname and resolution, standalone daemon states, service status, `testparm` parameters including `server role`, UDP 53 socket listener by `samba`, UFW rules, functional levels, SRV and SOA DNS queries, Kerberos `kinit` authentication, auditd rules, and AIDE syntax). |

---

## Shared Files Notice

- **/etc/hosts:** Managed via `ansible.builtin.lineinfile`. Configures mapping for `<directory_dc_ip> dc01.multilab.internal dc01` using a tolerant regular expression, without modifying `systemd-resolved` or `/etc/resolv.conf`.
- **/etc/ufw/user.rules:** Managed via `community.general.ufw` module. Adds targeted rules for incoming AD DS ports (88/tcp, 88/udp, 389/tcp, 636/tcp, 445/tcp, 135/tcp, 3268/tcp) restricted to `172.16.0.0/24`. AD DS ports are never exposed on the public interface.
- **/etc/audit/rules.d/:** Deploys an independent drop-in at `/etc/audit/rules.d/99-zz-directory.rules` (mode `0640`) containing active watches for `/etc/samba/` and `/var/lib/samba/private/`. The `dns.keytab` watch is conditionally omitted when `SAMBA_INTERNAL` is used since `dns.keytab` is not generated.
- **/etc/aide/aide.conf.d/:** Deploys an independent drop-in at `/etc/aide/aide.conf.d/99-zz-directory` (mode `0644`) ordered alphabetically after `99-hardening` (which defines `CONTENTEX`), covering `/etc/samba/`, `/var/lib/samba/private/`, and `/var/lib/samba/bind-dns/`.

---

## Non-Automated Procedures & Accepted Deviations

1. **Steps 1 & 4 (System Resolver):** The manual guide modifies `/etc/resolv.conf` and locks it with `chattr +i`. The automated baseline leaves `systemd-resolved` and `/etc/resolv.conf` untouched to preserve the multi-tier resolver baseline configured in the `dns` module. Local resolution of the DC FQDN is handled by `/etc/hosts`, and upstream forwarding to BIND9 is handled by Samba's `dns forwarder = 127.0.0.1`.
2. **Step 3 (`SAMBA_INTERNAL` vs `BIND9_DLZ` & Provisioning State):** Samba 4 is provisioned using `--dns-backend=SAMBA_INTERNAL` rather than `BIND9_DLZ` to avoid permissions conflicts and AppArmor scoping defects present on Ubuntu 24.04 packages. The provision task uses `creates: /var/lib/samba/private/krb5.conf` (which is generated at the end of a complete provision, whereas `sam.ldb` is created early). Pre-flight assertions detect and abort on partial provisions (`sam.ldb` exists without `krb5.conf`) without deleting files, prompting the operator to perform a clean slate per manual Step 3.
3. **Step 3 (Functional Level 2016):** `samba-tool domain provision` in Samba 4.19 defaults to Windows Server 2008 R2. The role specifies both `--function-level=2016` and `--option="ad dc functional level = 2016"` so that forest, domain, and lowest DC functional levels match Windows Server 2016 as specified in the manual documentation.
4. **Step 8 (DNS Query Target):** In Step 8 of the manual guide, `samba-tool dns serverinfo 127.0.0.1` is executed against loopback. Because `interfaces = <directory_dc_ip>` and `bind interfaces only = yes` restrict Samba internal DNS to the private IP, queries must target `<directory_dc_ip>` rather than `127.0.0.1` (which is served by BIND9).
5. **Conditional `samba_keytab` Audit Rule:** With `SAMBA_INTERNAL`, `/var/lib/samba/bind-dns/dns.keytab` is not created. Kernel `auditctl` rejects watches on non-existent files. The role dynamically excludes this rule unless the keytab file physically exists.
6. **SMB2 Limitation:** SMB2 protocol verification is excluded from automated assertions due to a known Samba 4.19.5 defect on aarch64 architectures documented in the manual module.
7. **Client Domain Join & Snapshots:** Joining client machines to the Active Directory domain and taking hypervisor/AMI snapshots remain manual operational steps.
8. **Internal DNS & Server Role Verification:** Because `dns backend` is an option passed to `samba-tool domain provision` and not a parameter stored in `smb.conf`, `testparm` rejects it with rc 1. The role verifies `server role = active directory domain controller` via `testparm -s` and asserts that the UDP 53 listener bound to `<directory_dc_ip>` is owned by `samba` to confirm internal DNS operation.
