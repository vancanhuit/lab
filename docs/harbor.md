# Harbor operations

## First login and registry use

Open `https://harbor.lab.canhdinh.com/` and sign in with the default administrator username `admin` and the initial password stored in `harbor_admin_password`. Change that password after first login, then update `harbor_admin_password` in `ansible/host_vars/harbor/secrets.sops.yaml` to the current password. Harbor uses the configured value only on its first startup, but `verify-harbor.yaml` uses it to authenticate API checks.

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
before Harbor starts. Harbor 2.15.2 uses [pgx](https://github.com/goharbor/harbor/blob/v2.15.2/src/common/dao/pgsql.go)
for database connections and migrations; its [TLS implementation](https://github.com/jackc/pgx/blob/v5.10.0/pgconn/config.go)
verifies the certificate chain and hostname using system trust when no custom CA
is configured. The Harbor core image provides its CA bundle at
`/etc/pki/tls/certs/ca-bundle.crt`.

`verify-harbor.yaml` checks the running core container's database hostname,
`verify-full` setting, and readable, nonempty CA bundle alongside Harbor API health.

## Vulnerability scanning

The bundled Trivy adapter is Harbor's enabled default scanner. It downloads vulnerability and Java databases from Aqua Security's OCI repositories and verifies registry certificates. The managed configuration scans for known vulnerabilities and includes vulnerabilities without an available fix.

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

Use `docker compose stop` and `docker compose start` only for temporary shutdowns. Make persistent configuration changes in the Ansible role or inventory and rerun `ansible-playbook harbor.yaml`; do not edit `/opt/harbor/harbor.yml` directly because Ansible overwrites it. The role follows Harbor's [reconfiguration lifecycle](https://goharbor.io/docs/2.15.0/install-config/reconfigure-manage-lifecycle/) by regenerating the Compose project when managed configuration changes.

Run `ansible-playbook verify-harbor.yaml` after configuration changes. Do not print `/opt/harbor/harbor.yml` or generated files under `/opt/harbor/common/config` because they contain database and object-storage credentials. Do not run `docker compose down -v`, delete `/var/lib/harbor`, or remove the SeaweedFS bucket as routine troubleshooting steps.

## Upgrade procedure

Do not change `harbor_version` as a routine package bump. Follow the upgrade guide for the target release. The [Harbor 2.15 upgrade guide](https://goharbor.io/docs/2.15.0/administration/upgrade/) supports migration from 2.12 or later. Before an upgrade:

1. Stop writes to Harbor.
2. Take and validate a consistent PostgreSQL backup.
3. Back up or snapshot the `homelab-harbor` SeaweedFS bucket.
4. Preserve `/opt/harbor/harbor.yml`, `/var/lib/harbor`, `/etc/harbor`, and `/var/lib/lego` for rollback.
5. Update the pinned installer version and checksum together. Also update the supported-version assertion in `roles/harbor/tasks/validate.yaml`, the expected version in `verify-harbor.yaml`, and the version expectation in `roles/harbor/tests/render-config.yml`.
6. Migrate the configuration as required by Harbor, run the role test, deploy, and run `ansible-playbook verify-harbor.yaml`.

Harbor core performs database schema migration when the new release starts. Do not proceed without a rollback point for both PostgreSQL metadata and SeaweedFS registry blobs; neither copy is a complete Harbor backup by itself.

The [Harbor 2.15.2 release](https://github.com/goharbor/harbor/releases/tag/v2.15.2) upgrades the bundled PostgreSQL database from version 15 to 18. That migration does not apply here because Harbor uses the separately managed PostgreSQL 18 service.
