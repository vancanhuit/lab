# Homelab Tailscale

```sh
mise task ls
```

```sh
mise run ansible:deps

cd ansible
ansible-playbook setup-incus.yaml --ask-become-pass
```

## PostgreSQL Deploy And Verify

```sh
mise run ansible:deps

cd ansible
ansible-playbook postgres.yaml --ask-become-pass
ansible-playbook verify-postgres.yaml --ask-become-pass
ansible-playbook postgres.yaml --ask-become-pass
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
