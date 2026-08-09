# Homelab Tailscale

```sh
mise task ls
```

```sh
mise run ansible:deps

cd ansible
ansible-playbook setup-incus.yaml --ask-become-pass
```

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
