# PostgreSQL 18 Production Deployment Design

## Objective

Deploy and operate PostgreSQL 18 on the Debian 13 host
`postgres.lab.canhdinh.com` using Ansible. The deployment must provide TLS
certificates through the existing `lego` role, restrict database access to the
approved LAN and Tailscale networks, and maintain recoverable local backups.

Success means a repeatable, idempotent playbook can install, secure, validate,
back up, and renew TLS for the PostgreSQL service without creating application
databases or remote login roles.

## Approved Decisions

- Use a reusable `postgresql` Ansible role and a service-specific
  `postgres.yaml` playbook.
- Install PostgreSQL 18 from the official PostgreSQL Apt repository (PGDG).
- Permit database clients from `10.205.234.0/24` and `100.64.0.0/10` only.
- Require TLS and SCRAM-SHA-256 for all remote database authentication.
- Leave host firewall management outside this repository.
- Use the default PostgreSQL data directory at
  `/var/lib/postgresql/18/main`.
- Use a local pgBackRest repository at `/var/lib/pgbackrest`.
- Do not create application roles or databases.
- Apply conservative resource tuning derived from Ansible facts.

## Architecture

### Inventory And Playbook

The inventory gains a `postgres` host under the existing `lab` group:

```yaml
lab:
  hosts:
    postgres:
      ansible_host: postgres.lab.canhdinh.com
```

The `postgres.yaml` playbook targets that host with privilege escalation. It
runs the new `postgresql` role first and the existing `lego` role second.

The PostgreSQL role installs the server, creates the cluster and TLS target
paths, applies configuration, and establishes backup automation. The `lego`
role then obtains the trusted certificate and runs a deployment hook that
replaces the seeded certificate before reloading PostgreSQL.

### PostgreSQL Role

The role owns:

- PGDG Apt repository configuration and PostgreSQL 18 package installation.
- PostgreSQL cluster configuration and `pg_hba.conf`.
- TLS target files and secure permissions.
- pgBackRest configuration, stanza creation, and backup timers.
- Service handlers and post-deployment health checks.
- Input validation for version, network, and backup variables.

Role defaults expose the PostgreSQL major version, cluster name, port, allowed
CIDRs, TLS paths, backup schedule, and retention. Bounded memory and worker
values are calculated from host facts during convergence. The playbook
overrides only host-specific values.

On an unbootstrapped host, check mode validates role inputs but skips package,
repository, cluster, configuration, and backup tasks because their required
Python APT bindings and PostgreSQL runtime are not available yet. After the
first normal deployment, check mode inspects the managed deployment state.

## TLS Lifecycle

PostgreSQL starts safely before the first ACME issuance by seeding its managed
TLS paths from Debian's snake-oil certificate. These temporary files are never
used as an identity outside initial convergence.

The `lego` role requests an EC certificate for
`postgres.lab.canhdinh.com` through the existing Cloudflare DNS challenge.
Its deploy hook performs these steps:

1. Validate the renewed certificate and confirm that its public key matches the
  private key.
2. Stage both files with `postgres:postgres` ownership, mode `0644` for the
   certificate and `0600` for the private key.
3. Validate file readability and PostgreSQL configuration against the staged
  identity before activation.
4. Atomically activate both files and reload the PostgreSQL 18 `main` cluster
  so existing connections are not interrupted.
5. Roll back both files and reload the previous identity if activation or
  reload fails.

The existing daily `lego-renew.timer` owns renewal scheduling. PostgreSQL uses
TLS 1.2 or newer.

## Access And Authentication

PostgreSQL listens on its network interfaces. Access control is enforced in
this order:

1. Local Unix socket administration uses peer authentication.
2. All TCP connections for the `postgres` superuser are rejected.
3. TLS connections from `10.205.234.0/24` use SCRAM-SHA-256.
4. TLS connections from `100.64.0.0/10` use SCRAM-SHA-256.
5. Non-TLS TCP connections are rejected.
6. All other TCP connections are rejected.

`password_encryption` is set to `scram-sha-256`. The deployment does not expose
the `postgres` superuser remotely and does not create any password-bearing
roles. Future application roles must be least-privilege and store credentials
through SOPS.

Because this role does not manage a firewall, the surrounding network or host
firewall remains responsible for preventing unapproved clients from reaching
port 5432. `pg_hba.conf` remains the database authorization boundary even when
network filtering is absent.

## PostgreSQL Configuration

The role keeps `max_connections` at 100 and leaves `work_mem` conservative.
Memory settings are derived from detected RAM and clamped to safe minimum and
maximum values:

- `shared_buffers`: approximately 25% of RAM.
- `effective_cache_size`: approximately 75% of RAM.
- `maintenance_work_mem`: approximately 5% of RAM.
- Worker and parallelism settings: derived from CPU count with conservative
  upper bounds.

Configuration enables checksums at cluster creation when supported, WAL
archiving for pgBackRest, the PostgreSQL logging collector, connection and
disconnection logging, lock-wait logging, checkpoint logging, and a bounded
slow-statement threshold. It does not log every SQL statement or parameter,
which could expose sensitive data.

## Backup And Recovery

pgBackRest uses a local repository at `/var/lib/pgbackrest` and a stanza for
the PostgreSQL 18 `main` cluster. PostgreSQL archives WAL continuously so the
retained backup window supports point-in-time recovery.

Two persistent systemd timers run with randomized delay:

- Weekly full backup.
- Daily differential backup on non-full-backup days.

The repository retains two complete full-backup sets and their required
differential backups and WAL. Scheduled jobs run a pgBackRest health check
before backup and fail visibly through systemd when the stanza or archive path
is unhealthy.

Local backups protect against accidental data changes and support point-in-time
recovery, but they do not protect against loss of the host or its storage.
Moving the pgBackRest repository off-host is required before this service can
tolerate host loss.

## Failure Handling

- Ansible validates all role inputs before package or service changes.
- Managed configuration files use atomic Ansible writes and notify handlers
  only when content changes.
- PostgreSQL configuration is validated before restart or reload.
- Certificate deployment leaves the active identity untouched if staging or
  validation fails and restores the previous identity if activation or reload
  fails.
- Backup commands return non-zero on failure so systemd records failed units.
- No task logs secrets or private-key content.

## Verification

Repository-level checks:

```sh
cd ansible
ansible-playbook --syntax-check postgres.yaml
ansible-playbook --syntax-check verify-postgres.yaml
ansible-playbook roles/postgresql/tests/render-config.yml
```

Use `yamllint` when it is installed. A template-focused test verifies rendered
PostgreSQL, client authentication, pgBackRest, and systemd files without
changing a real host.

Deployment verification must confirm:

- Installed server reports PostgreSQL major version 18.
- Cluster `18/main` is online.
- PostgreSQL reports TLS enabled with minimum protocol TLS 1.2, SCRAM password
  encryption, and data checksums enabled.
- Remote TLS presents a certificate valid for
  `postgres.lab.canhdinh.com`.
- PostgreSQL parses the managed `pg_hba.conf` without errors; the render test
  verifies the ordered superuser, approved-CIDR `hostssl`, plaintext, and
  catch-all rejection rules.
- pgBackRest stanza check succeeds and backup timers are active.
- A second playbook run reports no changes.

The README documents dependency installation, deployment, operational checks,
manual backup, backup inspection, and restore procedure. Restore documentation
must make the required service stop and destructive data replacement explicit.

## Expected Files

- `ansible/inventory.yaml`
- `ansible/postgres.yaml`
- `ansible/roles/postgresql/defaults/main.yaml`
- `ansible/roles/postgresql/tasks/main.yaml`
- `ansible/roles/postgresql/tasks/validate.yaml`
- `ansible/roles/postgresql/handlers/main.yaml`
- `ansible/roles/postgresql/files/lego-deploy-hook.sh`
- `ansible/roles/postgresql/templates/postgresql.conf.j2`
- `ansible/roles/postgresql/templates/pg_hba.conf.j2`
- `ansible/roles/postgresql/templates/pgbackrest.conf.j2`
- `ansible/roles/postgresql/templates/pgbackrest-backup@.service.j2`
- `ansible/roles/postgresql/templates/pgbackrest-full.timer.j2`
- `ansible/roles/postgresql/templates/pgbackrest-diff.timer.j2`
- `ansible/roles/postgresql/tests/render-config.yml`
- `ansible/verify-postgres.yaml`
- `README.md`

Exact task and template decomposition may change during planning if PostgreSQL
packaging provides a safer native file or unit to reuse.

## Out Of Scope

- Application databases, login roles, or schema migrations.
- High availability, replication, connection pooling, and automatic failover.
- Host firewall management.
- Remote backup storage and host-loss recovery.
- Monitoring server installation or external alert routing.
- PostgreSQL major-version upgrade automation.

## Acceptance Criteria

- One Ansible command converges a clean Debian 13 host to PostgreSQL 18.
- PostgreSQL accepts only TLS/SCRAM clients from the two approved CIDRs.
- A trusted certificate for the requested hostname is installed and renewed by
  the existing `lego` role without service downtime.
- Local pgBackRest full, differential, and WAL backups are configured and
  schedulable.
- Configuration rendering, syntax, deployed health, TLS, and idempotence checks
  pass.
- No plaintext secret, private key, application role, or application database
  is added to the repository.
