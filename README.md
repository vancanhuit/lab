# Homelab with Tailscale VPN

This repository contains the Ansible configuration for a Debian 13 homelab running Incus, Technitium DNS, [PostgreSQL](https://www.postgresql.org/docs/18/), and [Gitea](https://docs.gitea.com/) over a Tailscale VPN.

## Environment

| Component | Configuration |
| --- | --- |
| Hardware | Dell Optiplex 7000 Micro, Intel Core i7-12700T (14 cores, 20 threads), 64 GB RAM, 2 TB NVMe SSD |
| Public domain | `canhdinh.com`, hosted by [Cloudflare DNS](https://developers.cloudflare.com/dns/) |
| Private domain | `lab.canhdinh.com`, resolved through [Tailscale split DNS](https://tailscale.com/kb/1054/dns#restricted-nameservers) |
| Host OS | Debian 13 |
| Virtualization | [Incus](https://linuxcontainers.org/incus/docs/main/) with ZFS storage |

The Incus host uses Zabbly builds for:

- [Incus](https://github.com/zabbly/incus)
- [ZFS](https://github.com/zabbly/zfs)
- [Linux kernel](https://github.com/zabbly/linux)

## Prerequisites

- Install a minimal Debian 13 server with SSH access and sudo privileges.
- Install [Tailscale](https://tailscale.com/docs), join the tailnet, and configure split DNS for `lab.canhdinh.com`.
- Advertise the Incus bridge network from the Incus host through a [Tailscale subnet router](https://tailscale.com/kb/1019/subnets).
- Configure the Ansible inventory hosts in `ansible/inventory.yaml`.
- Add the required Cloudflare, PostgreSQL, Gitea, [IDrive e2](https://www.idrive.com/s3-storage-e2/), and [Brevo](https://developers.brevo.com/docs/send-a-transactional-email) secrets to `ansible/group_vars/all/secrets.sops.yaml`.

Commands in this runbook are executed from the repository root unless a step changes directory.

## Install Tooling

Install [`mise`](https://mise.jdx.dev/):

```sh
curl https://mise.run | sh
```

Install the pinned tools and Ansible collections:

```sh
mise install
mise run ansible:deps
```

List the available repository tasks:

```sh
mise task ls
```

## Bootstrap the Incus Host

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

## Deployment Sequence

Run these stages in order. DNS must resolve the service hostnames before PostgreSQL or Gitea requests certificates and starts accepting connections.

### 1. Deploy DNS

Technitium DNS is installed manually on `dns.lab.canhdinh.com`. On the DNS host, run:

```sh
curl -sSL https://download.technitium.com/dns/install.sh | sudo bash
```

Configure the `lab.canhdinh.com` zone and its host records in Technitium, then obtain and deploy its TLS certificate with `lego`:

```sh
cd ansible
ansible-playbook dns.yaml
```

There is no dedicated DNS verification playbook. Before continuing, confirm that all deployment hostnames resolve from the Ansible controller:

```sh
getent hosts dns.lab.canhdinh.com
getent hosts postgres.lab.canhdinh.com
getent hosts gitea.lab.canhdinh.com
```

### 2. Deploy PostgreSQL

Deploy PostgreSQL 18 and its `lego`-managed TLS certificate:

```sh
ansible-playbook postgres.yaml
```

Verify the PostgreSQL service, TLS endpoint, backup configuration, and timers:

```sh
ansible-playbook verify-postgres.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook postgres.yaml
```

The second deployment should report `changed=0` for the PostgreSQL host.

### 3. Deploy Gitea

Gitea depends on the PostgreSQL service from the previous stage. The Gitea playbook creates its PostgreSQL role and database before deploying Gitea with built-in HTTPS.

```sh
ansible-playbook gitea.yaml
```

Verify the Gitea service, listener, TLS endpoint, configuration, administrator, and doctor checks:

```sh
ansible-playbook verify-gitea.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook gitea.yaml
cd ..
```

The second deployment should report `changed=0` for both the Gitea and PostgreSQL hosts.

## Gitea Operations

### First Login

Open `https://gitea.lab.canhdinh.com/` and sign in as `gitea-admin`. The initial password is stored in the SOPS key `gitea_admin_password`; Gitea requires an immediate password change on first login.

User registration is enabled, and new accounts must confirm their email address through the configured Brevo transactional mail service.

### Health Checks

Run these commands on the Gitea host:

```sh
sudo systemctl status gitea.service
sudo journalctl -u gitea.service --since today
sudo -u git /usr/local/bin/gitea doctor check --default --config /etc/gitea/app.ini
sudo systemctl status lego-renew.timer
```

### Upgrade Procedure

Stop Gitea and take a consistent backup before changing `gitea_version`:

```sh
sudo systemctl stop gitea.service
```

Do not upgrade until the repository and generated-state backup limitation below is acceptable.

## PostgreSQL Operations

### Backup and Health Checks

Run these commands on the PostgreSQL host:

```sh
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres pgbackrest --stanza=main check
```

## Backup Coverage

| Data | Coverage |
| --- | --- |
| PostgreSQL relational data | pgBackRest local backups only; no off-host replication |
| Gitea object storage | iDrive e2 stores LFS objects, avatars, attachments, and packages |
| Gitea repositories and generated state | `/var/lib/gitea` has no off-host backup |

> [!WARNING]
> Loss of the Gitea host causes permanent repository loss. The current PostgreSQL backups also do not survive loss of the PostgreSQL host or its storage.

## PostgreSQL Point-in-Time Restore

> [!CAUTION]
> This procedure is destructive and can permanently discard current data. Confirm the backup timeline and target before moving the current data directory.

Run all commands in this section on the PostgreSQL host.

1. Stop PostgreSQL:

   ```sh
   sudo systemctl stop postgresql
   ```

2. Verify that the cluster is stopped before changing the filesystem:

   ```sh
   sudo systemctl is-active postgresql
   sudo pg_lsclusters --no-header
   ```

   Expected state: `systemctl is-active postgresql` returns `inactive`, and `pg_lsclusters --no-header` shows `18 main` as `down`.

3. Inspect the available backups and choose a valid restore target:

   ```sh
   sudo -u postgres pgbackrest --stanza=main info
   ```

4. Move the current data directory aside:

   ```sh
   sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.pre-restore.$(date +%Y%m%d%H%M%S)
   ```

5. Restore to the selected point in time. Replace `<RFC3339>` with a timestamp such as `2026-08-09T10:15:00Z`:

   ```sh
   sudo -u postgres pgbackrest --stanza=main --type=time --target=<RFC3339> restore
   ```

6. Start PostgreSQL:

   ```sh
   sudo systemctl start postgresql
   ```

7. Verify the restored service and backup stanza:

   ```sh
   sudo systemctl status postgresql
   sudo -u postgres pgbackrest --stanza=main check
   ```
