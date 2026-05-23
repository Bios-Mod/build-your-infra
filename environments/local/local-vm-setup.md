# Local VM — Setup

**Ubuntu 24.04 LTS · ARM64 / x86_64 · VMware Fusion / VirtualBox**

---

## Environment

| Parameter     | Value                                              |
|---------------|----------------------------------------------------|
| OS            | Ubuntu Server 24.04 LTS                            |
| Architecture  | ARM64 (Apple Silicon) / x86_64                     |
| Hypervisor    | VMware Fusion (macOS) · VMware Workstation · VirtualBox |
| Network       | Bridged adapter — static IP · LAN                  |
| Admin user    | Non-root user with sudo                            |

---

## Step 1 — Download Ubuntu Server

Download the Ubuntu Server 24.04 LTS ISO from [ubuntu.com/download/server](https://ubuntu.com/download/server).

- **Apple Silicon (ARM64):** select the ARM64 image.
- **x86_64:** select the standard AMD64 image.

---

## Step 2 — Create the VM

**VMware Fusion / Workstation:**
1. New virtual machine → drag the ISO → continue.
2. OS: Linux → Ubuntu 64-bit (or ARM64 if available).
3. Network adapter: **Bridged** (connect directly to the physical network).
4. Disk: 20 GiB minimum · store as single file.
5. RAM: 2 GB minimum recommended.

**VirtualBox:**
1. New → type: Linux · version: Ubuntu (64-bit).
2. Memory: 2048 MB minimum.
3. Hard disk: 20 GiB · VDI · dynamically allocated.
4. Settings → Network → Adapter 1: **Bridged Adapter**.

> **Bridged adapter is required.** NAT assigns a private IP visible only to
> the host. Bridged places the VM directly on the LAN — it gets its own IP
> from the router, reachable from any device on the network.

---

## Step 3 — Install Ubuntu Server

Boot the ISO and follow the installer. Key decisions:

- **Network:** leave as DHCP for now — static IP is configured in Step 4.
- **Storage:** use the full disk, no LVM required for this lab.
- **Profile:** set hostname, username, and password. This user becomes the
  primary admin (non-root with sudo).
- **OpenSSH:** enable "Install OpenSSH server" during installation.
- **Featured snaps:** skip all.

---

## Step 4 — Static IP

Connect to the VM via console (VMware/VirtualBox UI) or SSH on port 22.
Run the following on the **VM**:

```bash
ip a          # → note the interface name (e.g. ens160, eth0)
ip r          # → note the gateway (e.g. 192.168.1.1)
```

Edit the Netplan config on the **VM**:

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
        addresses: [8.8.8.8, 1.1.1.1]
```

```bash
sudo netplan apply
```

Verify on the **VM**:

```bash
ip a show ens160      # → confirm static IP
ping -c 3 8.8.8.8    # → confirm internet reachability
```

> The Netplan config file name may differ depending on the installer version.
> Run `ls /etc/netplan/` to confirm the filename before editing.

---

## Step 5 — First SSH Connection

From the host machine:

```bash
# ~/.ssh/config
Host multi-lab-local
  HostName 192.168.X.X     # static IP from Step 4
  User <your_user>
  IdentityFile ~/.ssh/<your_key>
  Port 22                  # temporary — update to 22222 after hardening

ssh multi-lab-local
```

---

## Post-Setup Checklist

- [ ] VM running — bridged network, static IP assigned
- [ ] SSH working on port 22
- [ ] `apt update && apt upgrade -y` completed
- [ ] Snapshot taken: `ubuntu-base-install`

**Next:** [`modules/hardening/self-managed/self-managed.md`](../../modules/hardening/self-managed/self-managed.md) — apply OS hardening. After hardening: update `~/.ssh/config` to port 22222.