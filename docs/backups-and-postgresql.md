# PostgreSQL operations

## Data volume

PostgreSQL uses the 20 GiB Incus filesystem volume `pool1/postgres-data`, attached
as device `data` at `/var/lib/postgresql`. Cluster data, WAL, and cluster logs live
under `/var/lib/postgresql/18/main`. The pgBackRest repository remains at
`/var/lib/pgbackrest` on the container root disk. Configuration and TLS state remain
under `/etc/postgresql`.

The deployment role checks the mount before making changes, including in check
mode. The `postgresql@18-main.service` override requires the mount before startup;
the parent `postgresql.service` is only a meta unit. If the guard fails, restore
the Incus attachment. An empty directory on the root disk does not satisfy it.

Inspect storage from the administrator workstation:

```sh
incus storage volume get homelab-server:pool1 postgres-data size
incus config device show homelab-server:postgres
incus exec homelab-server:postgres -- findmnt -M /var/lib/postgresql
```

Expected quota: `20GiB`; expected source: `pool1/custom/default_postgres-data`.
Instance snapshots do not include this custom volume. Coordinate any data-volume
restore with the matching PostgreSQL configuration and pgBackRest recovery state.

### Migration and recovery

During the migration on 2026-09-19, the cluster and pgBackRest backup timers and
services were stopped and runtime-masked before copying `/var/lib/postgresql`
with `cp -a` to the staged volume at `/mnt/postgres-data`. PostgreSQL reported a clean shutdown.
The copy passed a byte-for-byte comparison, metadata checks, and offline
`pg_checksums --check` with zero bad checksums before the mount was switched.

The original, stopped cluster at `/var/lib/postgresql.root-disk-backup` was removed
on 2026-09-19 after verifying the data-volume mount, PostgreSQL, pgBackRest, and
application health. The pgBackRest repository was preserved.

For future migrations, remove the migration-time copy only after accepting the
migration. It becomes stale once PostgreSQL resumes writes. If startup fails,
try repairing the `data` attachment first. After writes resume, a storage rollback
needs a fresh copy of the current cluster taken while it is stopped, or a
coordinated pgBackRest restore. Do not use the stale migration-time copy. Keep a
mount at `/var/lib/postgresql` during recovery.

For another migration, first inspect tablespaces and `pg_wal` for external paths,
check pgBackRest, then pause backup jobs and stop PostgreSQL before copying.
Verify the stopped copy and mount before unmasking and starting the cluster and
backup timers. Run `ansible-playbook verify-postgres.yaml` from `ansible/` afterward.

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
| PostgreSQL relational data | Cluster data and WAL use the separate 20 GiB `pool1/postgres-data` volume; pgBackRest backups remain on the container root disk at `/var/lib/pgbackrest`; no off-host replication |
| Gitea object storage | SeaweedFS stores LFS objects, avatars, attachments, archives, packages, and Actions data on the dedicated 500 GiB ZFS volume; an encrypted off-host point-in-time copy is retained for the [2026-10-07 upgrade](gitea.md#gitea-2810-upgrade-2026-10-07); no scheduled off-host backup; the former Backblaze copy is not continuously updated |
| Harbor registry blobs | SeaweedFS stores blobs in `homelab-harbor` on the dedicated 500 GiB ZFS volume; no off-host backup |
| Harbor local state | Valkey state, Trivy databases, generated configuration, logs, certificates, and Docker images under `/var/lib/harbor`, `/opt/harbor`, `/etc/harbor`, and `/var/lib/lego` have no off-host backup |
| Gitea repositories and generated state | `/var/lib/gitea` uses the separate 20 GiB `pool1/gitea-data` custom volume; instance snapshots do not include it; a custom-volume snapshot and encrypted off-host copy are retained for the [2026-10-07 upgrade](gitea.md#gitea-2810-upgrade-2026-10-07); no scheduled off-host backup |
| Uptime Kuma SQLite state | Validated gzip backups under `/var/backups/uptime-kuma/`; newest 14 retained by count; no off-host replication |

> [!WARNING]
> The latest Gitea upgrade archive can recover its database, repositories, configuration, and objects only to 2026-10-07 10:50:55 UTC; newer writes have no scheduled off-host protection. Routine PostgreSQL and Uptime Kuma backups also do not survive loss of their hosts or storage. Harbor registry blobs have no off-host backup. Add scheduled off-host protection before retiring rollback copies.

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
