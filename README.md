# Homelab with Tailscale VPN

## Setup

- Hardware: Dell Optiplex 7000 Micro — Intel Core i7-12700T (14 cores, 20 threads), 64 GB RAM, 2 TB NVMe SSD.
- Public DNS domain: `canhdinh.com` (Cloudflare DNS)
- Private homelab subdomain: `lab.canhdinh.com` (split DNS via Tailscale VPN)
- Homelab OS: Debian 13 running [Incus](https://linuxcontainers.org/incus/docs/main/) with multiple virtual machines and containers
- Playbook `ansible/setup-incus.yaml` provisions the Incus host with required packages and configuration.

We use Zabbly builds for Incus, ZFS and Linux kernel:
- https://github.com/zabbly/incus
- https://github.com/zabbly/zfs
- https://github.com/zabbly/linux

### Debian 13 server setup

- Install a minimal Debian 13 server with SSH access and sudo privileges.
- Disk partition: We preserve 1.8T of the NVMe SSD for Incus virtual machines and containers (ZFS), with a small root partition for the host OS.
  ```
  NAME        MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
  nvme0n1     259:0    0  1.8T  0 disk
  ├─nvme0n1p1 259:1    0  511M  0 part /boot/efi
  ├─nvme0n1p2 259:2    0    1G  0 part /boot
  ├─nvme0n1p3 259:3    0    4G  0 part [SWAP]
  ├─nvme0n1p4 259:4    0   50G  0 part /
  └─nvme0n1p5 259:5    0  1.8T  0 part
  ```
- Install [Tailscale](https://tailscale.com/docs) and join the homelab network. Configure split DNS for `lab.canhdinh.com` to resolve internally via the homelab DNS server.
- Advertise Incus host as a subnet router (the Incus bridge network) for the `lab.canhdinh.com` network access.

Installing the [`mise`](https://mise.jdx.dev/) tool:

### Tooling management
```sh
curl https://mise.run | sh
```

```sh
mise task ls
```

```sh
mise run ansible:deps

cd ansible
ansible-playbook setup-incus.yaml --ask-become-pass
```

## Technitium DNS server

Hostname: `dns.lab.canhdinh.com`

Technitium DNS server is deployed manually on the `dns` host based on instructions [here](https://technitium.com/dns/).

```sh
curl -sSL https://download.technitium.com/dns/install.sh | sudo bash
```

Then the playbook `ansible/dns.yaml` is run to obtain a TLS certificate using the `lego` ACME client with DNS-01 challenge via Cloudflare DNS.

## Gitea Deploy And Verify

```sh
mise run ansible:deps

cd ansible
ansible-playbook gitea.yaml
ansible-playbook verify-gitea.yaml
ansible-playbook gitea.yaml
```

The third command should report `changed=0`.

First login: `https://gitea.lab.canhdinh.com/`, username `gitea-admin`, password from SOPS key `gitea_admin_password`. A mandatory immediate password change is required on first login.

## Gitea Health And Monitoring

```sh
sudo systemctl status gitea.service
sudo journalctl -u gitea.service --since today
sudo -u git /usr/local/bin/gitea doctor check --default --config /etc/gitea/app.ini
sudo systemctl status lego-renew.timer
```

## Gitea Upgrade Warning

Warning: stop Gitea and take a consistent backup before changing `gitea_version`.

pgBackRest covers relational data and iDrive e2 covers configured object classes, but `/var/lib/gitea` repositories and generated state have no off-host backup. Host loss is not recoverable from this deployment.

## Gitea Backup Boundary

- **Relational data (PostgreSQL)**: covered by pgBackRest (local backups only, no off-host replication).
- **Object storage**: covered by iDrive e2 for LFS, avatars, attachments, and packages.
- **Repositories and generated state**: `/var/lib/gitea` has no off-host backup. Loss of the Gitea host means permanent repository loss.

Recommended action before upgrading or destructive operations:

```sh
sudo systemctl stop gitea.service
```

## PostgreSQL Deploy And Verify

```sh
mise run ansible:deps

cd ansible
ansible-playbook postgres.yaml
ansible-playbook verify-postgres.yaml
ansible-playbook postgres.yaml
```

## Manual Backup And Health Checks

```sh
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres pgbackrest --stanza=main check
```

## Point-In-Time Restore (Manual And Destructive)

Warning: this procedure is destructive and can permanently discard current data if run incorrectly.

Warning: backups are local to the PostgreSQL host storage; they do not survive host or storage loss.

1. Stop PostgreSQL service.

```sh
sudo systemctl stop postgresql
```

2. Verify the cluster is stopped before any destructive filesystem changes.

```sh
sudo systemctl is-active postgresql
sudo pg_lsclusters --no-header
```

Expected state: `systemctl is-active postgresql` returns `inactive`, and `pg_lsclusters --no-header` shows `18 main` as `down`.

3. Confirm the backup timeline and choose a valid timestamp target.

```sh
sudo -u postgres pgbackrest --stanza=main info
```

4. Move the current data directory aside before restore.

```sh
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.pre-restore.$(date +%Y%m%d%H%M%S)
```

5. Restore to a point in time.

Replace `<RFC3339>` with an actual timestamp such as `2026-08-09T10:15:00Z`.

```sh
sudo -u postgres pgbackrest --stanza=main --type=time --target=<RFC3339> restore
```

6. Start PostgreSQL service.

```sh
sudo systemctl start postgresql
```
