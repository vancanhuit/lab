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

### Recover the data volume

If the mount guard fails, keep PostgreSQL stopped and repair device `data` so it
attaches `pool1/postgres-data` at `/var/lib/postgresql`. Use the storage checks
above to verify its source and quota before starting the cluster.

If data needs recovery, pause the backup jobs and stop PostgreSQL. Inspect
tablespaces and `pg_wal` for external paths before restoring a consistent stopped
copy or using the [pgBackRest restore procedure](#postgresql-point-in-time-restore).
Preserve the pgBackRest repository. Check the restored files and run offline
`pg_checksums --check`; require zero bad checksums before startup. Restore any
paused timers after recovery.

Run `ansible-playbook verify-postgres.yaml` from `ansible/` and check Gitea and
Harbor afterward. Keep the data mount present throughout recovery. Never restore
a stale copy over newer writes or start PostgreSQL on an empty root-disk directory.

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
| Gitea object storage | SeaweedFS stores LFS objects, avatars, attachments, archives, packages, and Actions data on the dedicated 500 GiB ZFS volume; no scheduled off-host backup |
| Harbor registry blobs | SeaweedFS stores blobs in `homelab-harbor` on the dedicated 500 GiB ZFS volume; no scheduled off-host backup |
| Harbor local state | Valkey state, Trivy databases, configuration, TLS/ACME state, Docker images, and logs reside on the VM; no scheduled off-host backup |
| Gitea repositories and generated state | `/var/lib/gitea` uses the separate 20 GiB `pool1/gitea-data` custom volume; instance snapshots do not include it; no scheduled off-host backup |
| Uptime Kuma SQLite state | Validated gzip backups under `/var/backups/uptime-kuma/`; newest 14 retained by count; no off-host replication |
| Vault secrets and audit logs | Raft data on the LXC root filesystem at `/var/lib/vault/raft`; verify file auditing is enabled and local log rotation is active; no automatic snapshots or off-host backup; follow [Vault snapshot and key custody guidance](vault.md#storage-restarts-and-recovery) before storing real secrets |

> [!WARNING]
> Gitea and Harbor have no scheduled off-host protection. Routine PostgreSQL and Uptime Kuma backups also do not survive loss of their hosts or storage. Temporary upgrade rollback sets are not a disaster-recovery backup policy.

Create a rollback set before changing a service version. Keep it through
deployment, health checks, application smoke tests, and the idempotence rerun.
Once all checks succeed, remove the upgrade-specific snapshots, archives, and
staging files by their exact recorded names. Follow the [Gitea](gitea.md#clean-up-upgrade-backups)
or [Harbor](harbor.md#clean-up-upgrade-backups) cleanup commands. Scheduled backups,
routine snapshots, and Vault initialization credentials have separate retention
requirements.

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
