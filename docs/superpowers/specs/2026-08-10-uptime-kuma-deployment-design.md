# Uptime Kuma Deployment Design

**Date:** 2026-08-10
**Status:** Approved for implementation planning

## Objective

Deploy Uptime Kuma 2.5.0 to the existing `kuma` Incus container and use it to monitor the homelab's core services. The dashboard must be available only through the homelab network and Tailscale at `https://kuma.lab.canhdinh.com` with a publicly trusted certificate.

The deployment must be reproducible with Ansible, preserve monitoring state across application upgrades, send alerts through Brevo, and include focused deployment and runtime verification.

## Existing Environment

- The `kuma` Debian 13 Incus container already exists at `10.205.234.102`.
- Technitium resolves `kuma.lab.canhdinh.com` to the container.
- The container has 1 CPU, 2 GiB RAM, a 5 GiB ZFS-backed root disk, and the shared `debian` Incus profile.
- The container is running and cloud-init has completed.
- No Node.js runtime, process manager, container runtime, or reverse proxy is installed.
- Tailscale routes the Incus network but Uptime Kuma itself will not be exposed publicly.
- The shared Ansible `lego` role already obtains DNS-01 certificates through Cloudflare and installs renewal timers.

## Decisions

### Native Uptime Kuma Installation

Install Uptime Kuma directly on Debian instead of running its container image. Uptime Kuma documents native installation and direct systemd operation, and its package declares Node.js 20.4 or newer.

The role will pin Uptime Kuma 2.5.0 to release commit `d9a60dfc73140d15111752e4e8910ed4b54bd9a3`. Pinning both the release and commit prevents a moved tag from changing deployed code. npm will install production dependencies from the committed lockfile with integrity verification and download the matching prebuilt frontend.

### NodeSource Node.js 24 LTS

Install the latest available Node.js 24 LTS package from NodeSource's signed `node_24.x` APT repository. Node.js 24 is the current LTS line; the Debian 13 Node.js 20 package is EOL as of March 2026.

The repository major will remain explicitly pinned to `24`. Routine package upgrades may install compatible security and patch releases within that major but cannot silently move Kuma to a future Node.js major. The role will assert `node --version` reports major 24 before installing Kuma.

### systemd Instead of PM2

Run `node server/server.js` as a dedicated `kuma` system user under `uptime-kuma.service`. systemd already provides startup ordering, restart behavior, logs, and service state. Adding PM2 would duplicate those responsibilities.

The service will set:

- `NODE_ENV=production`
- `UPTIME_KUMA_HOST=127.0.0.1`
- `UPTIME_KUMA_PORT=3001`
- `DATA_DIR=/var/lib/uptime-kuma`

The application listener must not be reachable from another host.

### Nginx and Lego TLS

Nginx will be the only network-facing process and listen on port 443 for `kuma.lab.canhdinh.com`. It will proxy to `127.0.0.1:3001` and pass the HTTP upgrade, connection, host, real IP, and forwarded protocol headers required by Uptime Kuma's WebSocket interface.

The shared `lego` role will request a Let's Encrypt certificate with the explicit `kuma.lab.canhdinh.com` DNS name. A Kuma-specific deployment hook will:

1. Validate the issued certificate is unexpired.
2. Verify the certificate and private key match.
3. Stage both files with restrictive ownership and modes.
4. Atomically replace the Nginx certificate and key.
5. Validate the Nginx configuration.
6. Reload Nginx.

The role will seed the configured paths with Debian's snake-oil certificate and key so Nginx can start before initial ACME issuance. Port 80 will not be exposed because the service has no public HTTP challenge or public redirect requirement.

## Ansible Structure

Add these implementation surfaces:

- A `kuma` inventory host using `kuma.lab.canhdinh.com`.
- `ansible/kuma.yaml` to deploy the Uptime Kuma role and shared Lego role.
- `ansible/verify-kuma.yaml` for live deployment verification.
- `ansible/roles/uptime_kuma/` for defaults, validation, tasks, handlers, templates, and render tests.
- A README deployment, setup, backup, restore, upgrade, and troubleshooting section.

The role will own application installation, systemd, Nginx, local backup automation, and the certificate deployment hook. The shared Lego role remains responsible for ACME account state, issuance, and renewal scheduling.

Role defaults will expose the pinned Kuma version and commit, Node.js major, hostname, bind address, ports, installation and data paths, backup path, and retention period. Validation will reject unsupported or unsafe combinations before mutation.

## Filesystem and Release Layout

Use separate immutable and mutable paths:

| Path | Purpose |
| --- | --- |
| `/opt/uptime-kuma/releases/<commit>/` | Versioned application source, production dependencies, and frontend |
| `/opt/uptime-kuma/current` | Symlink to the active verified release |
| `/var/lib/uptime-kuma/` | SQLite database and mutable Kuma state |
| `/var/backups/uptime-kuma/` | Root-restricted local SQLite backups |
| `/etc/nginx/sites-available/uptime-kuma` | Managed reverse-proxy configuration |
| `/etc/uptime-kuma/tls/` | Active Nginx certificate and key |

The role builds a new release before changing the `current` symlink. A failed checkout, npm installation, or frontend download leaves the running release untouched. After successful activation and verification, keep the active release and one previous release to support rollback while controlling disk use.

The mutable data directory will be owned by the `kuma` account and inaccessible to other unprivileged users. TLS keys and backups will be root-restricted. Kuma's SQLite database contains notification credentials and must be treated as secret-bearing state.

## Initial Application Setup

Uptime Kuma 2.5 does not provide a supported management REST API. The maintained `uptime-kuma-api` Python client only supports Uptime Kuma 1.21.3 through 1.23.2. The deployment will not manipulate Kuma's private Socket.IO protocol or write directly to its SQLite schema.

After Ansible deploys and verifies the service, the operator will complete one setup session at `https://kuma.lab.canhdinh.com`:

1. Create the administrator using a strong, unique password generated and stored in the operator's password manager.
2. Enable two-factor authentication for the administrator.
3. Enable trusted proxy headers because Kuma is reachable only through the local Nginx proxy.
4. Add a Brevo notification using an API key, from address, and from name stored in the operator's password manager.
5. Send and confirm a test notification.
6. Create the monitor group and checks below.
7. Attach the Brevo notification to every monitor.

The README will provide field-by-field values without printing secrets. This setup boundary is intentional and must remain visible in deployment documentation.

## Initial Monitor Set

Create a `Homelab` group with a 60-second heartbeat interval and three retries before a down notification.

| Monitor | Type | Target and expectation |
| --- | --- | --- |
| Uptime Kuma | HTTPS | `https://kuma.lab.canhdinh.com/`, valid TLS and successful response |
| Gitea | HTTPS | `https://gitea.lab.canhdinh.com/`, valid TLS and accepted successful or redirect response |
| PostgreSQL | TCP | `postgres.lab.canhdinh.com:5432` accepts a connection |
| Technitium DNS | DNS A record | Ask `dns.lab.canhdinh.com` for `kuma.lab.canhdinh.com` and expect `10.205.234.102` |
| Incus host | Ping | `debian-incus` is reachable |
| DNS host | Ping | `dns.lab.canhdinh.com` is reachable |
| PostgreSQL host | Ping | `postgres.lab.canhdinh.com` is reachable |
| Gitea host | Ping | `gitea.lab.canhdinh.com` is reachable |

HTTPS checks provide certificate-expiry visibility. The Brevo notification will be active for every check.

The Kuma HTTPS check can detect Nginx, DNS, and certificate failures while the Kuma process remains available. It cannot notify when Kuma or its host is completely unavailable. External monitoring is required to close that gap and is outside this deployment's scope.

## Backup and Restore

Install `sqlite3` and a root-owned oneshot backup service with a daily persistent systemd timer. The service will use SQLite's online `.backup` command against the live Kuma database, write to a temporary file, validate the backup with `PRAGMA quick_check`, compress it, and atomically place the completed archive in `/var/backups/uptime-kuma`.

Retain 14 daily backups. Backup failure must make the systemd unit fail and remain visible in the journal. Do not use a raw file copy of the live database.

Restore documentation will require stopping Kuma, preserving the current data directory, decompressing a selected backup with correct ownership and mode, validating the restored database, and starting Kuma. The existing Incus snapshots provide short-term host-level rollback. Off-host Kuma backup is not part of this change.

## Upgrade and Rollback

An upgrade changes the pinned Kuma version and full release commit in role defaults. The role builds and verifies the new release without changing the active symlink, creates a fresh SQLite backup, stops Kuma only for activation, switches the symlink, and starts the service.

If startup or readiness fails, the role will report the failure without deleting the previous release or backup. The runbook will describe restoring the previous symlink and, when a database migration prevents application rollback, restoring the pre-upgrade SQLite backup.

Node.js stays on major 24 until a separate compatibility review updates the role default and render/runtime tests.

## Failure Handling

- Validate all role inputs before package or filesystem changes.
- Verify the NodeSource signing key and configure APT with an explicit `signed-by` keyring.
- Use npm's lockfile and integrity metadata; do not use an unconstrained global npm package installation.
- Do not activate a release until its package version, dependencies, and frontend are present.
- Restart Kuma only when the active release or service definition changes.
- Validate Nginx before initial start and every certificate reload.
- Reject a partial TLS state where only the certificate or key exists.
- Keep staged certificate and backup files under restrictive umasks and clean temporary files on failure.
- Mark tasks that handle secret-bearing configuration or output with `no_log` where applicable.

## Verification

### Static and Render Checks

The role render test will load role defaults without overwriting explicit test variables and validate generated content for:

- The NodeSource `node_24.x` repository and signed keyring reference.
- The localhost-only Kuma listener and data directory.
- The systemd service user, working directory, restart policy, and environment.
- Nginx TLS, proxy, forwarded, and WebSocket settings.
- The Lego deployment hook's validation and atomic replacement behavior.
- The SQLite backup service, timer, integrity check, and retention command.

Run Ansible syntax checks, the focused render playbook, `ansible-lint`, and `git diff --check` before live deployment.

### Live Verification

`verify-kuma.yaml` will assert:

- Node.js reports major 24.
- The checked-out package reports Uptime Kuma 2.5.0.
- `uptime-kuma.service`, `nginx.service`, `lego-renew.timer`, and the backup timer are enabled and in the expected state.
- Kuma listens on `127.0.0.1:3001` and not on an external address.
- Nginx listens on port 443 and no service listens publicly on port 3001.
- `nginx -t` succeeds.
- `https://kuma.lab.canhdinh.com/` returns a successful response with certificate validation enabled.
- The served certificate contains `kuma.lab.canhdinh.com` and remains valid for at least seven days.
- The data directory exists with the expected owner and restrictive mode.
- An on-demand backup succeeds and its database passes `PRAGMA quick_check`.

After verification, rerun `ansible-playbook kuma.yaml`. The second run must report `changed=0` for the Kuma host. The operator then completes the one-time UI setup and confirms delivery of the Brevo test alert.

## Security Boundaries

- Kuma is private and has no public ingress.
- Only Nginx accepts remote connections; the Node.js listener is loopback-only.
- The application runs without root privileges.
- Certificate private keys, SQLite state, and backups are not world-readable.
- Admin and Brevo credentials remain in the operator's password manager and Kuma's restricted SQLite state and are not printed in playbook output or documentation.
- Two-factor authentication is required for the administrator.
- Trusted proxy headers are enabled only because Nginx is the sole path to Kuma.

## Non-Goals

- Public exposure or Cloudflare Tunnel access.
- Automatic monitor or notification provisioning through Kuma's unsupported private API.
- Direct mutation of Kuma's SQLite schema.
- MariaDB or PostgreSQL as Kuma's application database.
- A public status page.
- External monitoring of Kuma itself.
- Off-host Kuma backups.
- Automatic Node.js major upgrades.
