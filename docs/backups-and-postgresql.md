# PostgreSQL operations

## Backup and health checks

Run these commands on the PostgreSQL host:

```sh
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres pgbackrest --stanza=main check
```

## Backup coverage

| Data | Coverage |
| --- | --- |
| PostgreSQL relational data | pgBackRest local backups only; no off-host replication |
| Gitea object storage | SeaweedFS stores LFS objects, avatars, attachments, archives, packages, and Actions data on the dedicated 500 GiB ZFS volume; the former Backblaze bucket is a temporary rollback copy, not a continuously updated backup |
| Harbor registry blobs | SeaweedFS stores blobs in `homelab-harbor` on the dedicated 500 GiB ZFS volume; no off-host backup |
| Harbor local state | Valkey state, Trivy databases, generated configuration, logs, certificates, and Docker images under `/var/lib/harbor`, `/opt/harbor`, `/etc/harbor`, and `/var/lib/lego` have no off-host backup |
| Gitea repositories and generated state | `/var/lib/gitea` uses the separate 20 GiB `pool1/gitea-data` custom volume; instance snapshots do not include it; no off-host backup |
| Uptime Kuma SQLite state | Validated gzip backups under `/var/backups/uptime-kuma/`; newest 14 retained by count; no off-host replication |

> [!WARNING]
> Loss of the Incus storage pool causes permanent Gitea repository loss. The current PostgreSQL and Uptime Kuma backups also do not survive loss of their hosts or storage. SeaweedFS object storage has no off-host backup. Add off-host protection for Harbor registry blobs and Gitea objects before retiring the former Backblaze rollback copy.

## PostgreSQL point-in-time restore

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
