# Harbor operations

## First login and registry use

Open `https://harbor.lab.canhdinh.com/` and sign in with the default administrator
username `admin` and the initial password stored in `harbor_admin_password`.
Change that password after first login, then update `harbor_admin_password` in
`ansible/host_vars/harbor/secrets.sops.yaml` to match. Harbor uses the configured
value only on its first startup; `verify-harbor.yaml` uses it to authenticate API
checks.

Harbor controls repositories through projects and creates a public `library` project during installation. Create a private project for restricted images by following Harbor's [project creation procedure](https://goharbor.io/docs/2.15.0/working-with-projects/create-projects/), then authenticate and push an image:

```sh
docker login harbor.lab.canhdinh.com
docker tag source_image harbor.lab.canhdinh.com/project/image:tag
docker push harbor.lab.canhdinh.com/project/image:tag
```

Assign users the narrowest suitable project role. See Harbor's [user and project role documentation](https://goharbor.io/docs/2.15.0/administration/managing-users/) for the Limited Guest, Guest, Developer, Maintainer, and Project Admin permissions.

## PostgreSQL TLS

Harbor connects to `postgres.lab.canhdinh.com` with `ssl_mode: verify-full`.
The PostgreSQL server must present its lego-managed Let's Encrypt certificate
before Harbor starts. Harbor 2.15.3 uses [pgx](https://github.com/goharbor/harbor/blob/v2.15.3/src/common/dao/pgsql.go)
for database connections and migrations; its [TLS implementation](https://github.com/jackc/pgx/blob/v5.11.0/pgconn/config.go)
verifies the certificate chain and hostname using system trust when no custom CA
is configured. The Harbor core image provides its CA bundle at
`/etc/pki/tls/certs/ca-bundle.crt`.

`verify-harbor.yaml` checks the running core container's database hostname,
`verify-full` setting, and readable, nonempty CA bundle alongside Harbor API health.

## Vulnerability scanning

The bundled Trivy adapter is enabled as Harbor's default scanner. It downloads
vulnerability and Java databases from Aqua Security's OCI repositories and
verifies registry certificates. The managed configuration scans for known
vulnerabilities, including those without an available fix.

To scan an artifact, open its project and repository, select the artifact, and click **Scan**. Configure scheduled scans or scan-on-push in Harbor to automate scanning. Check scanner registration and container health with:

```sh
cd ansible
ansible-playbook verify-harbor.yaml
```

The verification playbook confirms that Trivy is healthy, enabled as the default scanner, and supports vulnerability scanning. It does not execute an artifact scan or prove that vulnerability databases are current.

## Lifecycle and reconfiguration

Run lifecycle commands from the installer directory on the Harbor VM:

```sh
cd /opt/harbor
sudo docker compose ps
sudo docker compose stop
sudo docker compose start
sudo systemctl status lego-renew.timer
```

Use `docker compose stop` and `docker compose start` only for temporary shutdowns.
For persistent configuration changes, edit the Ansible role or inventory and
rerun `ansible-playbook harbor.yaml`. Ansible overwrites `/opt/harbor/harbor.yml`,
so do not edit it directly. When managed configuration changes, the role
regenerates the Compose project following Harbor's
[reconfiguration lifecycle](https://goharbor.io/docs/2.15.0/install-config/reconfigure-manage-lifecycle/).

Run `ansible-playbook verify-harbor.yaml` after configuration changes. Do not print `/opt/harbor/harbor.yml` or generated files under `/opt/harbor/common/config` because they contain database and object-storage credentials. Do not run `docker compose down -v`, delete `/var/lib/harbor`, or remove the SeaweedFS bucket as routine troubleshooting steps.

## Upgrade procedure

Do not change `harbor_version` as a routine package bump. Follow the upgrade guide for the target release. The [Harbor 2.15 upgrade guide](https://goharbor.io/docs/2.15.0/administration/upgrade/) supports migration from 2.12 or later. Before an upgrade:

1. Drain Actions jobs and pause the runner and certificate renewal before stopping
   writes to Harbor.
2. Take and validate a consistent backup of the `harbor` PostgreSQL database.
   Rehearse the target release's schema migration and database restore in an
   isolated database.
3. Back up or snapshot the `homelab-harbor` SeaweedFS bucket.
4. Preserve `/opt/harbor/harbor.yml`, `/var/lib/harbor`, `/etc/harbor`, and `/var/lib/lego` for rollback. Verify an encrypted off-host copy. Name the set `pre<version>-YYYYMMDDTHHMMSSZ` with the target version and UTC timestamp, and record all snapshot and archive paths.
5. Update the pinned installer version and checksum together. Also update the supported-version assertion in `roles/harbor/tasks/validate.yaml` and the expected version in `verify-harbor.yaml`. The template's `_version` and its test expectation identify the configuration schema (`2.15.0`), not the patch release; change them only when the upstream schema changes.
6. Migrate the configuration as required by Harbor, run the role test, deploy, and run `ansible-playbook verify-harbor.yaml`.

Harbor core performs database schema migration when the new release starts. Do not proceed without a rollback point for both PostgreSQL metadata and SeaweedFS registry blobs; neither copy is a complete Harbor backup by itself.

Harbor uses the separately managed PostgreSQL 18 service. Apply its upgrade
procedure separately from any bundled-database instructions in Harbor's guide.
Keep the private-network webhook restriction enabled in core and jobservice.

### Verify an upgrade

1. Run `ansible-playbook verify-harbor.yaml` from `ansible/` for API health,
   PostgreSQL TLS, and scanner checks.
2. Test an authenticated image push, pull, and run. Scan the artifact with Trivy
   and test a Docker Hub proxy pull/run from the runner account.
3. Compare existing bucket objects with the backup hashes. Remove temporary
   smoke-test resources after the checks pass.
4. Resume the runner and renewal timer, then rerun deployment and require
   `changed=0`.
5. Complete the upgrade-backup cleanup below after every verification step passes.

### Rollback

Pause the runner and renewal timer, stop Harbor, and restore the matching VM
snapshot, `harbor` database, and bucket contents before starting the backed-up
version. Restore only Harbor's database; restoring the shared PostgreSQL cluster
would also rewind Gitea. Restore the matching configuration and TLS/ACME state.
If the snapshot contains a stopped Compose project, start it explicitly and
remove maintenance masks from the renewal units. Restoring a backup discards
writes accepted since its timestamp.

## Clean up upgrade backups

Keep the rollback set until deployment, artifact tests, and the `changed=0`
rerun succeed. Then remove the upgrade-specific VM snapshot, encrypted archive,
and temporary backup staging. This ends the pre-upgrade rollback option; keep
routine backups under their own retention policy.

From the administrator workstation, run `incus info homelab-server:harbor` and
select the exact snapshot recorded for the completed upgrade. In Bash, replace
the placeholder with that set's name and stop if any deletion fails:

```bash
set -euo pipefail
backup_set='<exact-upgrade-backup-set>'
[[ "$backup_set" =~ ^pre[0-9]+(\.[0-9]+)*-[0-9]{8}T[0-9]{6}Z$ ]]
incus snapshot delete homelab-server:harbor "$backup_set"
rm -- "$HOME/.local/state/homelab-backups/harbor/$backup_set.tar.age"
```

Remove any host-side copy and staging files by their exact recorded paths. List
the snapshots and archive directories again to confirm the set is absent. Do
not delete Harbor's live state, registry bucket, or scheduled snapshots.
