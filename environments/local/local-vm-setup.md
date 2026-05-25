# Local VM — Setup

Ubuntu Server 24.04 LTS deployed as a local virtual machine.
Base environment for all `modules/*/self-managed/` deployments.

---

## Environment

| Parameter    | Value                                                       |
|--------------|-------------------------------------------------------------|
| OS           | Ubuntu Server 24.04 LTS                                     |
| Architecture | ARM64 (Apple Silicon) · x86_64                              |
| Hypervisor   | VMware Fusion (macOS) · VMware Workstation · VirtualBox     |
| Network      | Bridged adapter — static IP · LAN                           |
| Admin user   | Non-root user with sudo                                     |

---

## Step 1 — Download Ubuntu Server ISO

### What was done
Download the correct Ubuntu Server 24.04 LTS ISO for the target architecture
from [ubuntu.com/download/server](https://ubuntu.com/download/server).

- **ARM64 (Apple Silicon):** select the ARM64 image explicitly — the default
  download on the site is AMD64.
- **x86_64:** select the standard AMD64 image.

### Why
Ubuntu Server 24.04 LTS is the project baseline across all environments.
The architecture must match the host: an AMD64 ISO on Apple Silicon runs
under emulation with significant performance overhead.

---

## Step 2 — Create the VM

### What was done
Create a new virtual machine configured with bridged networking and
sufficient resources for a headless Ubuntu Server install.

**VMware Fusion / Workstation:**
1. New virtual machine → drag the ISO → continue.
2. OS: Linux → Ubuntu 64-bit (ARM64 if on Apple Silicon).
3. Network adapter: **Bridged** (connect directly to the physical network).
4. Disk: 20 GiB minimum · store as single file.
5. RAM: 2 GB minimum.

**VirtualBox:**
1. New → type: Linux · version: Ubuntu (64-bit).
2. Memory: 2048 MB minimum.
3. Hard disk: 20 GiB · VDI · dynamically allocated.
4. Settings → Network → Adapter 1: **Bridged Adapter**.

### Why
Bridged networking places the VM directly on the LAN — it receives its own
IP from the router and is reachable from any device on the network. NAT
assigns a private IP visible only to the host, which prevents cross-device
SSH access and breaks any lab scenario involving network-level connectivity
between machines.

---

## Step 3 — Install Ubuntu Server

### What was done
Boot the ISO and complete the installer with the following decisions:

- **Network:** leave as DHCP — static IP is configured in Step 4.
- **Storage:** use the full disk · no LVM required for this lab.
- **Profile:** set hostname, username, and password. This user becomes the
  primary admin (non-root with sudo).
- **OpenSSH:** enable *Install OpenSSH server* during installation.
- **Featured snaps:** skip all.

### Why
Enabling OpenSSH during installation avoids a post-install package step and
ensures SSH is available immediately for Step 5. LVM adds snapshot and
volume management complexity that provides no value for this lab. DHCP is
left active temporarily — static IP configuration via Netplan in Step 4
requires knowing the interface name first, which is confirmed after boot.

---

## Step 4 — Static IP

### What was done
Assign a static IP to the VM via Netplan, replacing the DHCP lease.

Connect to the VM via the hypervisor console and identify the network
interface and current gateway:

```bash
ip a       # → note the interface name (e.g. ens160, eth0, enp0s1)
ip r       # → note the default gateway (e.g. 192.168.1.1)
```

Confirm the Netplan config filename:

```bash
ls /etc/netplan/
# → e.g. 00-installer-config.yaml
```

Edit the file:

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

```yaml
network:
  version: 2
  ethernets:
    ens160:                      # replace with your interface name
      dhcp4: false
      addresses:
        - 192.168.X.X/24         # replace with your chosen static IP
      routes:
        - to: default
          via: 192.168.X.1       # replace with your gateway
      nameservers:
        addresses: [9.9.9.9, 149.112.112.112]
```

Apply the configuration:

```bash
sudo netplan apply
```

### Why
A static IP is required for the SSH alias in Step 5 and for any
cross-environment reference to this machine throughout the lab. A DHCP
lease can change on reboot or router reassignment, breaking SSH config
entries and any module that references this host by IP. The Netplan file
name varies by installer version — confirming it with `ls` before editing
prevents writing to a file that is not loaded.

### Verification

```bash
ip a show ens160      # → confirm static IP assigned
ping -c 3 8.8.8.8    # → confirm internet reachability
```

---

## Step 5 — First SSH connection

### What was done
Configure the SSH client alias on the host machine and verify connectivity
to the VM on the temporary port 22.

On the **host machine**, add to `~/.ssh/config`:
```bash
Host multi-lab-local
  HostName 192.168.X.X        # static IP from Step 4
  User <your_user>
  Port 22                     # temporary — updated to 22222 after hardening
```

```bash
ssh multi-lab-local
```

### Why
The `~/.ssh/config` alias establishes the `multi-lab-local` hostname used
consistently across the repo and in subsequent module docs. Connecting on
port 22 with password auth is intentional at this stage — SSH hardening
(key-only auth, port change to 22222, `sshd_config` lockdown) is applied
in the hardening module. Separating base connectivity from security
configuration keeps each doc focused on its scope.

### Verification

```bash
ssh multi-lab-local
# → shell prompt on the VM confirms connectivity
```

---

**Next:** [`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md)

> After hardening: update `~/.ssh/config` entry for `multi-lab-local` —
> change `Port 22` to `Port 22222` and add `IdentityFile ~/.ssh/<your_key>`.