# Incus

## Bootstrap the Incus host

The NVMe disk reserves approximately 1.8 TB for the Incus ZFS pool and keeps the host root filesystem small:

```text
NAME        MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0  1.8T  0 disk
├─nvme0n1p1 259:1    0  511M  0 part /boot/efi
├─nvme0n1p2 259:2    0    1G  0 part /boot
├─nvme0n1p3 259:3    0    4G  0 part [SWAP]
├─nvme0n1p4 259:4    0   50G  0 part /
└─nvme0n1p5 259:5    0  1.8T  0 part
```

Provision the Incus host:

```sh
cd ansible
ansible-playbook setup-incus.yaml --ask-become-pass
cd ..
```

The playbook installs Incus, the Zabbly kernel, and the OpenZFS packages, applies host tuning, and configures group membership. It does not initialize Incus or create its storage pool, bridge, or profiles. Before creating instances:

1. Initialize Incus.
2. Create the `pool1` ZFS storage pool.
3. Create and configure `incusbr0` as described below.
4. Apply [`incus-debian-profile.yaml`](../incus-debian-profile.yaml) as the `debian` profile.

## Incus network bridge

The Debian profile in [`incus-debian-profile.yaml`](../incus-debian-profile.yaml) connects each instance's `eth0` device to `incusbr0`. The [Incus bridge network](https://linuxcontainers.org/incus/docs/main/reference/network_bridge/) itself is configured on the Incus host and is not created by the current Ansible playbook.

Expected `incusbr0` network configuration:

```yaml
config:
 dns.mode: none
 ipv4.address: 10.205.234.1/24
 ipv4.dhcp: "false"
 ipv4.firewall: "false"
 ipv4.nat: "true"
 ipv6.address: none
 ipv6.dhcp: "false"
```

This configuration means:

- `10.205.234.1` is the bridge gateway for the `10.205.234.0/24` instance network.
- Incus DHCP is disabled. The [built-in DHCP server in Technitium](https://technitium.com/dns/help.html#dhcp-server) provides dynamic leases for instances that use DHCP mode.
- Incus does not register DNS records for instances on the bridge. Static-mode instances receive the Technitium DNS address through cloud-init; DHCP-mode instances receive it from the Technitium scope.
- IPv4 NAT provides outbound connectivity through the Incus host.
- Incus bridge firewalling is disabled. Enforce access through host firewall rules and Tailscale access controls.
- IPv6 addressing and DHCP are disabled.
- The Incus host advertises `10.205.234.0/24` through its Tailscale subnet router so tailnet clients can reach instances directly.

The lab [disables SNAT for Tailscale subnet routes](https://tailscale.com/docs/features/subnet-routers#disable-snat) with `--snat-subnet-routes=false`. This preserves each connecting device's Tailscale IP address, so services, logs, and access controls identify the client rather than the Incus subnet router.

Tailscale normally requires devices behind a non-SNAT subnet router to return `100.64.0.0/10` traffic through that router. No additional routing-table entry is required inside these instances: their existing default route already uses `10.205.234.1`, which is the Incus host and Tailscale subnet router, so reply traffic follows the correct path.

Configure a Technitium DHCP scope for the Incus network with:

- Network: `10.205.234.0/24`
- Address pool: `10.205.234.100` through `10.205.234.200`
- Router (default gateway): `10.205.234.1`
- DNS server: the IPv4 address of `dns.lab.canhdinh.com`
- Domain name: `lab.canhdinh.com`

Keep static instance addresses outside `10.205.234.100` through `10.205.234.200`. The static-mode instance script checks addresses reported by Incus but does not inspect active or reserved Technitium DHCP leases.

Inspect the bridge on the Incus host:

```sh
incus network show incusbr0
ip -4 address show dev incusbr0
ip -4 route show 10.205.234.0/24
```

Confirm that the `10.205.234.0/24` route is advertised and approved in the Tailscale admin console before deploying services.

## Configure instance SSH keys

Tailscale SSH manages access to the Incus host as the local `lab` user. Internal Debian instances do not run Tailscale and use standard OpenSSH instead. This lab uses the default Ed25519 identity at `$HOME/.ssh/id_ed25519`. If it does not already exist, generate it on the administrator workstation:

```sh
ssh-keygen -t ed25519 -a 100 \
   -f "$HOME/.ssh/id_ed25519" \
   -C "homelab"
```

Do not overwrite an existing key pair. Protect the private key at `$HOME/.ssh/id_ed25519` and never add it to the repository or the Incus profile. Display the public key:

```sh
cat "$HOME/.ssh/id_ed25519.pub"
```

Replace `<your-ssh-key>` under `ssh_authorized_keys` in [`incus-debian-profile.yaml`](../incus-debian-profile.yaml) with the complete, single-line public key. Apply the updated profile from the Incus host or a workstation configured to manage it as an Incus remote:

```sh
incus profile edit debian < incus-debian-profile.yaml
```

> [!IMPORTANT]
> Replace the placeholder and apply the profile before deployment. Cloud-init injects the key when an instance is first created; changing the profile later does not update `authorized_keys` in existing instances.

The profile creates the internal instance account as `admin`, which differs from the Incus host's `lab` account. After the instance starts and is reachable through the Tailscale subnet route, connect with:

```sh
ssh admin@<instance-hostname-or-ip>
```

OpenSSH and Ansible discover the default `id_ed25519` identity automatically. If you use a non-default key name and do not load the key into an SSH agent or select it in the SSH client configuration, set its path explicitly in `ansible/ansible.cfg`:

```ini
[defaults]
private_key_file = ~/.ssh/homelab-incus
```

This setting applies to every host that uses the Ansible configuration. For a one-time run, use `--private-key ~/.ssh/homelab-incus`. If different hosts require different keys, set the `ansible_ssh_private_key_file` host variable in inventory instead of using a global default.

## Create Incus instances

Use [`create-incus-instance.py`](../create-incus-instance.py) through `uv` to create containers or virtual machines with the required image, profiles, bridge, and network mode. View all supported options:

```sh
uv run create-incus-instance.py --help
```

Static IPv4 configuration is the default. This command creates a container, selects the first IPv4 address on `incusbr0` that is not reported by an existing instance, and writes the address, gateway, and DNS settings to cloud-init:

```sh
uv run create-incus-instance.py app01 \
   --nameserver 1.1.1.1 \
   --search-domain lab.canhdinh.com
```

Use the Technitium DNS server address instead of `1.1.1.1` when the instance must resolve private `lab.canhdinh.com` records. Repeat `--nameserver` or `--search-domain` to configure multiple values.

To skip static cloud-init networking and let the guest request DHCP configuration, add `--dhcp`:

```sh
uv run create-incus-instance.py app02 --dhcp
```

> [!IMPORTANT]
> Incus DHCP is disabled on `incusbr0`. Before using `--dhcp`, enable the Technitium DHCP scope for `10.205.234.100` through `10.205.234.200` and ensure the instance can reach that DHCP service on the bridge; otherwise, it will not receive an IPv4 address.

Additional options include:

- `--image` selects the image; the default is `images:debian/13/cloud`.
- `--profile` adds an Incus profile and can be repeated; the `debian` profile is included by default.
- `--vm` creates a virtual machine instead of a container.
- `--incus-bridge` selects the bridge inspected for static address allocation; the applied profiles still determine which network the instance NIC uses.
- `--storage-pool`, `--storage-size`, and `--storage-path` create or reuse, then attach a custom filesystem volume.
- `--storage-type block` creates a block volume for a VM. It requires `--vm`, `--storage-pool`, and `--storage-size`, and does not accept `--storage-path`.

Create the SeaweedFS container with a dedicated 500 GiB ZFS-backed data volume:

```sh
uv run create-incus-instance.py s3 \
  --dhcp \
  --storage-pool pool1 \
  --storage-size 500GiB \
  --storage-path /var/lib/seaweedfs
incus start s3
```

Create a new PostgreSQL container with a dedicated 20 GiB filesystem volume:

```sh
uv run create-incus-instance.py postgres \
  --dhcp \
  --storage-pool pool1 \
  --storage-size 20GiB \
  --storage-path /var/lib/postgresql
incus start postgres
```

The volume is named `postgres-data` and attached as device `data`. For an existing
cluster, stop PostgreSQL and copy and verify its data before switching the mount;
see [PostgreSQL storage](backups-and-postgresql.md#data-volume).

Create a new Gitea container with a dedicated 20 GiB filesystem volume:

```sh
uv run create-incus-instance.py gitea \
  --dhcp \
  --storage-pool pool1 \
  --storage-size 20GiB \
  --storage-path /var/lib/gitea
incus start gitea
```

The volume is named `gitea-data` and attached as device `data`. For an existing
deployment, [migrate the data](gitea.md#local-data-volume) before mounting over
`/var/lib/gitea`.

Create the Gitea Actions runner VM with DHCP and a dedicated 100 GiB block volume for Docker:

```sh
uv run create-incus-instance.py gitea-runner \
  --vm \
  --dhcp \
  --storage-pool pool1 \
  --storage-size 100GiB \
  --storage-type block
incus config set gitea-runner limits.cpu=2 limits.memory=4GiB
incus config device set gitea-runner root size=20GiB
incus start gitea-runner
```

The block volume is named `gitea-runner-data` and attached as device `data`. Inside the VM, udev exposes it at `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_data`; the Gitea Runner role validates that identifier before creating an ext4 filesystem and mounting it at `/var/lib/docker`.

The `debian` profile defaults to one CPU, 2 GiB of memory, and a 5 GiB root disk. Before deploying Harbor, provide at least two virtual CPUs, 3,800 MiB of reported memory, and a 40 GB root filesystem. Provisioning 4 GiB of memory and a 40 GiB disk safely exceeds those validation thresholds.

The script uses `incus create`, so the new instance remains stopped. Inspect its configuration, then start it explicitly:

```sh
incus config show app01 --expanded
incus start app01
```
