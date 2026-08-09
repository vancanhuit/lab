# PostgreSQL 18 Production Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy an idempotent, TLS-only PostgreSQL 18 service with local pgBackRest backups on `postgres.lab.canhdinh.com`.

**Architecture:** A reusable `postgresql` role installs PostgreSQL 18 from PGDG, creates and configures the cluster, and owns local backup automation. A service playbook applies that role before the existing `lego` role, whose deploy hook atomically installs renewed PEM files and reloads PostgreSQL.

**Tech Stack:** Ansible 14.2, ansible-core, Debian 13, PostgreSQL 18, pgBackRest, systemd, PGDG Apt repository, lego 5.3.1, Cloudflare DNS-01, SOPS.

## Global Constraints

- Target host is `postgres.lab.canhdinh.com` running Debian 13.
- PostgreSQL major version is exactly 18; cluster name is `main`; port is 5432.
- Remote clients are limited to `10.205.234.0/24` and `100.64.0.0/10`.
- Every remote connection requires TLS 1.2 or newer and SCRAM-SHA-256.
- Every remote connection as PostgreSQL role `postgres` is rejected.
- Host firewall configuration remains out of scope.
- Data stays at `/var/lib/postgresql/18/main`; backups stay at `/var/lib/pgbackrest`.
- No application database, login role, plaintext secret, or private key enters Git.
- Local backups retain two full backup sets; off-host disaster recovery remains out of scope.
- Do not modify the generic `lego` role unless a failing test proves a generic defect.
- Do not commit any checkpoint unless the user explicitly authorizes commits.

---

## File Map

- `ansible/roles/postgresql/defaults/main.yaml`: supported role inputs and conservative defaults.
- `ansible/roles/postgresql/tasks/validate.yaml`: side-effect-free role input validation shared by deployment and local tests.
- `ansible/roles/postgresql/tasks/main.yaml`: validation, PGDG setup, cluster creation, TLS seed, configuration, pgBackRest initialization, and service state.
- `ansible/roles/postgresql/handlers/main.yaml`: validated PostgreSQL reload/restart handlers and systemd reload.
- `ansible/roles/postgresql/templates/postgresql.conf.j2`: Ansible-owned `conf.d` settings.
- `ansible/roles/postgresql/templates/pg_hba.conf.j2`: ordered local, remote-superuser rejection, TLS allow, and catch-all rejection rules.
- `ansible/roles/postgresql/templates/pgbackrest.conf.j2`: local repository, retention, and cluster paths.
- `ansible/roles/postgresql/templates/pgbackrest-backup@.service.j2`: checked full/differential backup runner.
- `ansible/roles/postgresql/templates/pgbackrest-full.timer.j2`: weekly full backup schedule.
- `ansible/roles/postgresql/templates/pgbackrest-diff.timer.j2`: daily differential schedule excluding full-backup day.
- `ansible/roles/postgresql/tests/render-config.yml`: local rendering and rule-order tests.
- `ansible/inventory.yaml`: PostgreSQL host registration.
- `ansible/postgres.yaml`: production orchestration and lego deploy hook.
- `ansible/verify-postgres.yaml`: deployed service, TLS, access-rule, backup, and timer checks.
- `README.md`: deployment, verification, backup, recovery, and residual-risk runbook.

---

### Task 1: Configuration Contract And Rendering Tests

**Files:**
- Create: `ansible/roles/postgresql/defaults/main.yaml`
- Create: `ansible/roles/postgresql/templates/postgresql.conf.j2`
- Create: `ansible/roles/postgresql/templates/pg_hba.conf.j2`
- Create: `ansible/roles/postgresql/tests/render-config.yml`

**Interfaces:**
- Consumes: Ansible facts `memtotal_mb` and `processor_vcpus` during real deployment.
- Produces: role variables prefixed `postgresql_`; rendered server settings and ordered client authentication rules used by Tasks 2-5.

- [ ] **Step 1: Write failing rendering tests**

Create a localhost play with fixed test facts and role variables. Render both templates to temporary files, slurp their contents, and assert these exact properties:

```yaml
vars:
  postgresql_version: 18
  postgresql_cluster_name: main
  postgresql_port: 5432
  postgresql_allowed_cidrs:
    - 10.205.234.0/24
    - 100.64.0.0/10
  postgresql_tls_cert_path: /etc/postgresql/18/main/tls/server.crt
  postgresql_tls_key_path: /etc/postgresql/18/main/tls/server.key
  postgresql_shared_buffers_mb: 1024
  postgresql_effective_cache_size_mb: 3072
  postgresql_maintenance_work_mem_mb: 256
  postgresql_max_worker_processes: 8
  postgresql_max_parallel_workers: 4
```

Assertions must prove:

```yaml
- postgresql_rendered is search("ssl_min_protocol_version = 'TLSv1.2'")
- postgresql_rendered is search("password_encryption = 'scram-sha-256'")
- postgresql_rendered is search("archive_command = 'pgbackrest --stanza=main archive-push %p'")
- pg_hba_rendered.index('host all postgres 0.0.0.0/0 reject') < pg_hba_rendered.index('hostssl all all 10.205.234.0/24 scram-sha-256')
- pg_hba_rendered.index('hostssl all all 10.205.234.0/24 scram-sha-256') < pg_hba_rendered.index('hostnossl all all 0.0.0.0/0 reject')
- pg_hba_rendered is search('hostssl all all 100.64.0.0/10 scram-sha-256')
- pg_hba_rendered is search('host all all ::0/0 reject')
```

- [ ] **Step 2: Run tests and verify missing-template failure**

Run:

```sh
cd ansible
ansible-playbook -i localhost, roles/postgresql/tests/render-config.yml
```

Expected: failure because `postgresql.conf.j2` and `pg_hba.conf.j2` do not exist.

- [ ] **Step 3: Add defaults and minimal templates**

Define these defaults:

```yaml
postgresql_version: 18
postgresql_cluster_name: main
postgresql_port: 5432
postgresql_listen_addresses: '*'
postgresql_allowed_cidrs: []
postgresql_tls_directory: "/etc/postgresql/{{ postgresql_version }}/{{ postgresql_cluster_name }}/tls"
postgresql_tls_cert_path: "{{ postgresql_tls_directory }}/server.crt"
postgresql_tls_key_path: "{{ postgresql_tls_directory }}/server.key"
postgresql_data_directory: "/var/lib/postgresql/{{ postgresql_version }}/{{ postgresql_cluster_name }}"
postgresql_log_min_duration_statement_ms: 1000
postgresql_backup_stanza: main
postgresql_backup_repository: /var/lib/pgbackrest
postgresql_backup_retention_full: 2
postgresql_backup_full_calendar: 'Sun *-*-* 02:00:00'
postgresql_backup_diff_calendar: 'Mon..Sat *-*-* 02:00:00'
postgresql_backup_randomized_delay: 30m
```

The PostgreSQL template must configure the port, listen addresses, TLS paths,
TLS 1.2 floor, SCRAM password storage, WAL archive command, logging collector,
connection/disconnection logging, lock-wait logging, checkpoint logging,
one-second slow-query threshold, and supplied memory/worker values.

The HBA template must render in this order:

```text
local all postgres peer
local all all peer
host all postgres 0.0.0.0/0 reject
host all postgres ::0/0 reject
hostssl all all 10.205.234.0/24 scram-sha-256
hostssl all all 100.64.0.0/10 scram-sha-256
hostnossl all all 0.0.0.0/0 reject
hostnossl all all ::0/0 reject
host all all 0.0.0.0/0 reject
host all all ::0/0 reject
```

Generate the two `hostssl` lines from `postgresql_allowed_cidrs`; never hard-code
the production networks in the reusable template.

- [ ] **Step 4: Run rendering tests**

Run the Task 1 command again.

Expected: `failed=0`; all settings and HBA order assertions pass.

- [ ] **Step 5: Run focused lint**

Run:

```sh
cd ansible
ansible-lint roles/postgresql/defaults/main.yaml roles/postgresql/tests/render-config.yml
```

Expected: no violations.

- [ ] **Step 6: Prepare checkpoint**

```sh
git add ansible/roles/postgresql/defaults ansible/roles/postgresql/templates/postgresql.conf.j2 ansible/roles/postgresql/templates/pg_hba.conf.j2 ansible/roles/postgresql/tests/render-config.yml
git diff --cached --check
```

If commits are authorized: `git commit -m "feat(postgresql): define secure configuration"`.

---

### Task 2: PGDG Installation And Cluster Lifecycle

**Files:**
- Create: `ansible/roles/postgresql/tasks/validate.yaml`
- Create: `ansible/roles/postgresql/tasks/main.yaml`
- Create: `ansible/roles/postgresql/handlers/main.yaml`
- Modify: `ansible/roles/postgresql/tests/render-config.yml`

**Interfaces:**
- Consumes: Task 1 defaults and templates.
- Produces: online PostgreSQL `18/main` cluster, data checksums, managed TLS paths, calculated tuning values, and safe configuration handlers.

- [ ] **Step 1: Add failing validation cases**

Extend the test playbook with assertions equivalent to role preconditions:

```yaml
- postgresql_version | int == 18
- postgresql_cluster_name is string
- postgresql_cluster_name | length > 0
- postgresql_allowed_cidrs | length > 0
- postgresql_backup_retention_full | int >= 2
```

Validate each network without another collection: split the value once at `/`,
require an IPv4 dotted-quad plus prefix, require four octets in the range 0-255,
and require a prefix in the range 0-32. Keep the production values covered by
rendering tests.

- [ ] **Step 2: Run test and verify validation failure**

Create side-effect-free `tasks/validate.yaml`, include it from `tasks/main.yaml`,
and import it from the local test. Add one negative test block with an empty
network list, capture its expected assertion failure with `block`/`rescue`, and
assert the message contains:

```text
postgresql_allowed_cidrs must contain at least one IPv4 CIDR
```

Run:

```sh
cd ansible
ansible-playbook -i localhost, roles/postgresql/tests/render-config.yml
```

Expected: failure until validation tasks exist and are included by the test.

- [ ] **Step 3: Implement package and cluster tasks**

Implement this order in `tasks/main.yaml`:

1. Import `validate.yaml`, which asserts Debian 13 during deployment,
   PostgreSQL 18, non-empty valid IPv4 CIDRs, valid port, retention of at
   least two, and positive schedules.
2. Install `ca-certificates`, `postgresql-common`, and `openssl`.
3. Write `/etc/postgresql-common/createcluster.conf` with
   `create_main_cluster = false` before installing the versioned server.
4. Configure PGDG with `ansible.builtin.deb822_repository`:

```yaml
name: pgdg
types: [deb]
uris: [https://apt.postgresql.org/pub/repos/apt]
suites: ["{{ ansible_facts.distribution_release }}-pgdg"]
components: [main]
architectures: ["{{ ansible_facts.architecture | regex_replace('^x86_64$', 'amd64') | regex_replace('^aarch64$', 'arm64') }}"]
signed_by: https://www.postgresql.org/media/keys/ACCC4CF8.asc
```

5. Install `postgresql-18`, `postgresql-client-18`, and `pgbackrest`.
6. Query `pg_lsclusters --no-header`; create `18/main` only when absent:

```sh
pg_createcluster 18 main --start -- --data-checksums
```

7. Calculate bounded tuning facts from `ansible_facts.memtotal_mb` and
   `ansible_facts.processor_vcpus`: shared buffers 25% clamped to 128-8192 MB,
   effective cache 75% clamped to 512-32768 MB, maintenance memory 5% clamped
   to 64-2048 MB, worker processes clamped to 2-16, parallel workers clamped
   to 2-8 and never above worker processes.
8. Create the TLS directory as `postgres:postgres` mode `0750`.
9. Seed absent managed certificate and key from Debian snake-oil files with
   modes `0644` and `0600`; never overwrite an existing ACME certificate.
10. Render `99-ansible.conf` under the cluster's `conf.d`, replace
    `pg_hba.conf`, and ensure the cluster service is enabled and started.

- [ ] **Step 4: Add validated handlers**

Handlers must run configuration checks as `postgres` before service action:

```sh
/usr/lib/postgresql/18/bin/postgres -D /var/lib/postgresql/18/main -C config_file
```

Use `pg_ctlcluster 18 main reload` for settings and HBA changes. Reserve restart
for cluster-creation or settings PostgreSQL reports as restart-only. Add a
separate `systemctl daemon-reload` handler for Task 3 units.

- [ ] **Step 5: Run static checks**

Run:

```sh
cd ansible
ansible-playbook --syntax-check -i localhost, roles/postgresql/tests/render-config.yml
ansible-lint roles/postgresql/tasks/main.yaml roles/postgresql/handlers/main.yaml
```

Expected: both commands exit 0.

- [ ] **Step 6: Prepare checkpoint**

```sh
git add ansible/roles/postgresql/tasks/main.yaml ansible/roles/postgresql/handlers/main.yaml ansible/roles/postgresql/tests/render-config.yml
git diff --cached --check
```

If commits are authorized: `git commit -m "feat(postgresql): install PostgreSQL 18"`.

---

### Task 3: pgBackRest Backup Automation

**Files:**
- Create: `ansible/roles/postgresql/templates/pgbackrest.conf.j2`
- Create: `ansible/roles/postgresql/templates/pgbackrest-backup@.service.j2`
- Create: `ansible/roles/postgresql/templates/pgbackrest-full.timer.j2`
- Create: `ansible/roles/postgresql/templates/pgbackrest-diff.timer.j2`
- Modify: `ansible/roles/postgresql/tasks/main.yaml`
- Modify: `ansible/roles/postgresql/tests/render-config.yml`

**Interfaces:**
- Consumes: online cluster and backup defaults from Tasks 1-2.
- Produces: pgBackRest `main` stanza, continuous WAL archiving, weekly full and Monday-through-Saturday differential backup timers.

- [ ] **Step 1: Add failing backup rendering tests**

Render all four templates and assert:

```text
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
start-fast=y
process-max=2

[main]
pg1-path=/var/lib/postgresql/18/main
pg1-port=5432
```

Also assert service commands are exactly:

```ini
ExecStartPre=/usr/bin/pgbackrest --stanza=main check
ExecStart=/usr/bin/pgbackrest --stanza=main --type=%i backup
```

Timer assertions must cover `Persistent=true`, the approved `OnCalendar`, and
`RandomizedDelaySec=30m`.

- [ ] **Step 2: Run tests and verify missing-template failure**

Run:

```sh
cd ansible
ansible-playbook -i localhost, roles/postgresql/tests/render-config.yml
```

Expected: missing `pgbackrest.conf.j2` failure.

- [ ] **Step 3: Implement pgBackRest templates and tasks**

Create `/etc/pgbackrest/pgbackrest.conf` as `root:postgres` mode `0640` and the
repository as `postgres:postgres` mode `0750`. Install the service as
`pgbackrest-backup@.service` and timers as `pgbackrest-full.timer` and
`pgbackrest-diff.timer`.

After PostgreSQL configuration handlers have run, execute stanza creation as
`postgres`:

```sh
pgbackrest --stanza=main stanza-create
```

Set `changed_when` only when output reports stanza creation. Then run:

```sh
pgbackrest --stanza=main check
```

Enable and start both timers with `daemon_reload: true`. Do not run an initial
full backup during ordinary convergence; expose the documented manual command
in Task 5.

- [ ] **Step 4: Run rendering and lint checks**

Run:

```sh
cd ansible
ansible-playbook -i localhost, roles/postgresql/tests/render-config.yml
ansible-lint roles/postgresql/tasks/main.yaml roles/postgresql/templates/*.j2
```

Expected: rendering tests pass and lint exits 0.

- [ ] **Step 5: Prepare checkpoint**

```sh
git add ansible/roles/postgresql/templates ansible/roles/postgresql/tasks/main.yaml ansible/roles/postgresql/tests/render-config.yml
git diff --cached --check
```

If commits are authorized: `git commit -m "feat(postgresql): automate local backups"`.

---

### Task 4: Production Playbook And ACME Deployment Hook

**Files:**
- Modify: `ansible/inventory.yaml`
- Create: `ansible/postgres.yaml`

**Interfaces:**
- Consumes: `postgresql` role, existing `lego` role, and SOPS-backed `cloudflare.api_token` consumed by lego.
- Produces: one production entry point targeting inventory host `postgres` and renewing certificate name `postgres`.

- [ ] **Step 1: Write playbook syntax test and verify failure**

Run before creating the playbook:

```sh
cd ansible
ansible-playbook --syntax-check postgres.yaml
```

Expected: failure because `postgres.yaml` does not exist.

- [ ] **Step 2: Register host and create playbook**

Add:

```yaml
lab:
  hosts:
    postgres:
      ansible_host: postgres.lab.canhdinh.com
```

The playbook must use `hosts: postgres`, `become: true`, and these values:

```yaml
postgresql_allowed_cidrs:
  - 10.205.234.0/24
  - 100.64.0.0/10
lego_domain_names:
  - postgres.lab.canhdinh.com
lego_certificate_name: postgres
```

Run roles in this order:

```yaml
roles:
  - postgresql
  - lego
```

Configure `lego_hooks.deploy.script` to:

1. Use `set -eu` and a restrictive umask.
2. Verify certificate validity with `openssl x509 -checkend 0 -noout`.
3. Compare SHA-256 hashes of DER-encoded public keys extracted from the
   certificate and private key.
4. Install both source files to `.new` files owned by `postgres:postgres` with
   modes `0644` and `0600`.
5. Validate PostgreSQL configuration as `postgres` with the versioned
   `postgres` binary before replacing active files.
6. Preserve current target files as `.old`, then rename both `.new` files onto
   the managed paths.
7. Reload with `pg_ctlcluster 18 main reload`.
8. On success, remove `.old` files. On failure, restore both `.old` files,
   reload the restored identity, and exit non-zero so lego records failure.

Source files are `/var/lib/lego/certificates/postgres.crt` and
`/var/lib/lego/certificates/postgres.key`. Target files are
`/etc/postgresql/18/main/tls/server.crt` and `server.key`.

- [ ] **Step 3: Run syntax and inventory checks**

Run:

```sh
cd ansible
ansible-inventory --host postgres
ansible-playbook --syntax-check postgres.yaml
ansible-lint postgres.yaml inventory.yaml
```

Expected: inventory resolves the requested FQDN; syntax and lint exit 0.

- [ ] **Step 4: Prepare checkpoint**

```sh
git add ansible/inventory.yaml ansible/postgres.yaml
git diff --cached --check
```

If commits are authorized: `git commit -m "feat(postgresql): add production playbook"`.

---

### Task 5: Deployed Verification And Operations Runbook

**Files:**
- Create: `ansible/verify-postgres.yaml`
- Modify: `README.md`

**Interfaces:**
- Consumes: deployed `postgres` inventory host and PostgreSQL/pgBackRest units from Tasks 2-4.
- Produces: repeatable remote acceptance checks and operator commands.

- [ ] **Step 1: Create failing deployed verification playbook**

Target `postgres` with privilege escalation and read-only checks. Register and
assert these commands:

```sh
psql --version
pg_lsclusters --no-header
sudo -u postgres psql -Atqc "show ssl; show ssl_min_protocol_version; show password_encryption; show data_checksums"
sudo -u postgres psql -Atqc "select count(*) from pg_hba_file_rules where error is not null"
sudo -u postgres pgbackrest --stanza=main check
systemctl is-enabled lego-renew.timer pgbackrest-full.timer pgbackrest-diff.timer
systemctl is-active postgresql lego-renew.timer pgbackrest-full.timer pgbackrest-diff.timer
```

Use Ansible `become_user: postgres` instead of embedding `sudo` in command
tasks. Assert version `18`, cluster `18 main` online, `on`, `TLSv1.2`,
`scram-sha-256`, `on`, zero HBA parse errors, successful pgBackRest check, and
enabled/active timers.

From the controller, verify the presented certificate without exposing data:

```sh
openssl s_client -starttls postgres -connect postgres.lab.canhdinh.com:5432 -servername postgres.lab.canhdinh.com -verify_hostname postgres.lab.canhdinh.com -verify_return_error </dev/null
```

Mark all verification tasks `changed_when: false`.

- [ ] **Step 2: Run syntax check before deployment**

Run:

```sh
cd ansible
ansible-playbook --syntax-check verify-postgres.yaml
```

Expected: syntax passes; execution fails until the host is deployed.

- [ ] **Step 3: Write operations documentation**

Document exact commands:

```sh
mise run ansible:deps
cd ansible
ansible-playbook postgres.yaml --ask-become-pass
ansible-playbook verify-postgres.yaml --ask-become-pass
ansible-playbook postgres.yaml --ask-become-pass
```

Document manual backup and inspection:

```sh
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres pgbackrest --stanza=main check
```

Document point-in-time restore as a deliberately manual, destructive runbook:
stop PostgreSQL, confirm the chosen backup with `pgbackrest info`, move the
existing data directory aside, restore with `--type=time --target=<RFC3339>`,
and start PostgreSQL. State that the operator must replace `<RFC3339>` with an
actual timestamp and that local backups do not survive host/storage loss.

- [ ] **Step 4: Run documentation and static checks**

Run:

```sh
git diff --check -- README.md ansible/verify-postgres.yaml
cd ansible
ansible-playbook --syntax-check verify-postgres.yaml
ansible-lint verify-postgres.yaml
```

Expected: all commands exit 0.

- [ ] **Step 5: Prepare checkpoint**

```sh
git add README.md ansible/verify-postgres.yaml
git diff --cached --check
```

If commits are authorized: `git commit -m "docs(postgresql): add operations runbook"`.

---

### Task 6: End-To-End Deployment And Review

**Files:**
- Verify: all files listed in the File Map.

**Interfaces:**
- Consumes: complete deployment.
- Produces: evidence for syntax, rendering, deployed behavior, TLS identity, backup health, and idempotence.

- [ ] **Step 1: Run local quality gates**

```sh
mise run ansible:deps
cd ansible
ansible-playbook -i localhost, roles/postgresql/tests/render-config.yml
ansible-playbook --syntax-check postgres.yaml
ansible-playbook --syntax-check verify-postgres.yaml
ansible-lint postgres.yaml verify-postgres.yaml roles/postgresql
```

Expected: all commands exit 0.

- [ ] **Step 2: Check deployment diff**

```sh
cd ansible
ansible-playbook postgres.yaml --check --diff --ask-become-pass
```

Expected: only planned package, repository, PostgreSQL, pgBackRest, lego, and
systemd changes; no secret values or private-key content in output.

- [ ] **Step 3: Deploy once**

```sh
cd ansible
ansible-playbook postgres.yaml --ask-become-pass
```

Expected: play completes with `failed=0`; PostgreSQL, lego renewal, and backup
timers are active.

- [ ] **Step 4: Run deployed verification**

```sh
cd ansible
ansible-playbook verify-postgres.yaml --ask-become-pass
```

Expected: every assertion passes, including PostgreSQL 18, checksums, TLS 1.2,
SCRAM, HBA parsing, certificate hostname, pgBackRest, and timers.

- [ ] **Step 5: Prove idempotence**

```sh
cd ansible
ansible-playbook postgres.yaml --ask-become-pass
```

Expected: `changed=0` for host `postgres`. A certificate reconciliation task
may execute but must report unchanged when no certificate is issued or renewed.

- [ ] **Step 6: Review final diff with cavecrew**

Dispatch `cavecrew-reviewer` against the full working-tree diff. Fix every red
or yellow correctness/security finding, rerun the narrow affected check, then
rerun Steps 1, 4, and 5.

- [ ] **Step 7: Prepare final checkpoint**

```sh
git status --short
git diff --check
git diff --stat
```

Expected: only approved PostgreSQL deployment, design, plan, tests, and README
changes. Commit only when the user explicitly requests it.
