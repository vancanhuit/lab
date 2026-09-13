# Uptime Kuma operations

## First login and setup

Open `https://kuma.lab.canhdinh.com/` and configure the initial administrator account:

Use `kuma-admin` as the username. Generate a strong, unique password in your password manager and enter it during account creation. Ansible does not create the administrator or store this password.

After first login, enable two-factor authentication:

1. Navigate to **Settings** > **Security**.
2. Configure TOTP using an authenticator app such as [Aegis](https://getaegis.app/), [2FAS](https://2fas.com/), or [Bitwarden Authenticator](https://bitwarden.com/products/authenticator/).
3. Store recovery codes in a secure location.

## Trust proxy configuration

Uptime Kuma runs behind Nginx with TLS termination. Configure the trust-proxy setting to preserve the original client IP:

1. Navigate to **Settings** > **Reverse Proxy**.
2. Under **HTTP Headers**, set **Trust Proxy** to `Yes`.
3. Save the settings.

Kuma's logs, rate limiting, and access controls will then use the client address instead of the Nginx proxy address.

## Brevo notification configuration

Configure the native Brevo notification provider for alert emails. Store these values in your password manager; they are entered directly in Kuma and are not managed by Ansible or SOPS.

1. Navigate to **Settings** > **Notifications**.
2. Click **Setup Notification**.
3. Select **Brevo** as the notification type.
4. Configure the following settings using values from your password manager:

   | Field | Source |
   | --- | --- |
   | API Key | Brevo API key stored in the password manager |
   | From Address | Verified Brevo sender address stored in the password manager |
   | From Name | Sender display name stored in the password manager |

5. Click **Test** to send a confirmation email.
6. Verify the test email arrives before attaching the notification to monitors.

> [!WARNING]
> Do not commit the Brevo API key or include it in screenshots or logs.

## Monitor configuration

Create the `Homelab` monitor group:

1. Click **Add Group** on the dashboard.
2. Name the group `Homelab`.
3. Set **Heartbeat Interval** to `60` seconds.
4. Set **Retries** to `3`.
5. Save the group.

Add the following ten monitors to the `Homelab` group:

| Monitor name | Type | Target | Notes |
| --- | --- | --- | --- |
| Uptime Kuma HTTPS | HTTPS | `https://kuma.lab.canhdinh.com/` | Kuma self-check |
| Gitea HTTPS | HTTPS | `https://gitea.lab.canhdinh.com/` | Gitea web interface |
| Harbor HTTPS | HTTPS | `https://harbor.lab.canhdinh.com/api/v2.0/health` | Harbor API health |
| SeaweedFS S3 HTTPS | HTTPS | `https://s3.lab.canhdinh.com/` | Expected HTTP status: `403` without credentials |
| PostgreSQL TCP | Port | `postgres.lab.canhdinh.com:5432` | PostgreSQL listener |
| Technitium DNS Lookup | DNS | Hostname: `kuma.lab.canhdinh.com`<br>Resolver: `dns.lab.canhdinh.com`<br>Expected: current address assigned to `kuma.lab.canhdinh.com` | DNS resolution |
| Incus Host Ping | Ping | `debian-incus` or `10.205.234.1` | Incus host reachability |
| DNS Host Ping | Ping | `dns.lab.canhdinh.com` | DNS instance reachability |
| PostgreSQL Host Ping | Ping | `postgres.lab.canhdinh.com` | PostgreSQL instance reachability |
| Gitea Host Ping | Ping | `gitea.lab.canhdinh.com` | Gitea instance reachability |

For each monitor:

1. Click **Add New Monitor**.
2. Configure the monitor type and target from the table above.
3. Set **Heartbeat Interval** to `60` seconds.
4. Set **Retries** to `3`.
5. Under **Notifications**, attach the Brevo notification.
6. Save the monitor.

> [!IMPORTANT]
> The **Uptime Kuma HTTPS** monitor checks Kuma itself. Kuma cannot send alert notifications if its own service, database, or network is completely down; the alert will be delayed until service recovery.

All other monitors will send alert notifications through Brevo when they fail, subject to the retry policy.

## Backup operations

Uptime Kuma runs `uptime-kuma-backup.timer` daily with a one-hour randomized delay. The timer is persistent across reboots: `OnCalendar=daily`, `Persistent=true`, `RandomizedDelaySec=1h`.

Inspect the timer:

```sh
sudo systemctl status uptime-kuma-backup.timer
sudo systemctl list-timers uptime-kuma-backup.timer
```

View recent backup activity:

```sh
sudo journalctl -u uptime-kuma-backup.service --since today
```

Trigger a manual backup while Kuma is running:

```sh
sudo systemctl start uptime-kuma-backup.service
sudo journalctl -u uptime-kuma-backup.service -n 50 --no-pager
```

List available backup archives:

```sh
sudo ls -lh /var/backups/uptime-kuma/
```

Backup archives are stored as root-only gzipped SQLite database files under `/var/backups/uptime-kuma/` with names such as `kuma-20260810T020015Z.db.gz`. The timer retains the 14 newest backups.

> [!WARNING]
> Backup archives exist only on the Kuma host. Losing the host also loses the archives permanently.

## Restore procedure

> [!CAUTION]
> Restoration overwrites the current Kuma database. Confirm the backup timestamp before restoring.

Run all restore commands on the Kuma host:

1. Stop the Kuma service:

   ```sh
   sudo systemctl stop uptime-kuma.service
   ```

2. Verify the service is stopped:

   ```sh
   sudo systemctl is-active uptime-kuma.service
   ```

   Expected: `inactive`

3. Choose a backup archive to restore:

   ```sh
   sudo ls -lh /var/backups/uptime-kuma/
   ```

4. Decompress the selected backup to a temporary location and validate it:

   ```sh
   sudo gzip -dc /var/backups/uptime-kuma/kuma-YYYYMMDDTHHMMSSZ.db.gz > /tmp/kuma-restore.db
   sudo sqlite3 /tmp/kuma-restore.db 'PRAGMA quick_check;'
   ```

   Replace `YYYYMMDDTHHMMSSZ` with the actual backup timestamp. Expected validation output: `ok`

5. Preserve the current database as a local rollback copy:

   ```sh
   sudo cp -p /var/lib/uptime-kuma/kuma.db /var/lib/uptime-kuma/kuma.db.pre-restore
   ```

6. Install the validated restored database while Kuma is stopped:

   ```sh
   sudo install -o kuma -g kuma -m 0600 /tmp/kuma-restore.db /var/lib/uptime-kuma/kuma.db
   sudo rm /tmp/kuma-restore.db
   ```

7. Start the Kuma service:

   ```sh
   sudo systemctl start uptime-kuma.service
   ```

8. Verify service health:

   ```sh
   sudo systemctl status uptime-kuma.service
   sudo journalctl -u uptime-kuma.service -n 50 --no-pager
   curl -sSf https://kuma.lab.canhdinh.com/ >/dev/null && echo "HTTPS OK"
   ```

## Upgrade procedure

Before changing `uptime_kuma_version` or `uptime_kuma_release_commit`, take a manual backup:

```sh
sudo systemctl start uptime-kuma-backup.service
sudo journalctl -u uptime-kuma-backup.service -n 50 --no-pager
```

Update `uptime_kuma_version` and `uptime_kuma_release_commit` in the Kuma role defaults. Update the supported-version assertions in `roles/uptime_kuma/tasks/validate.yaml`, the expected versions in `verify-kuma.yaml`, and the role test expectations in `roles/uptime_kuma/tests/render-config.yml`. Then run the role test and deployment:

```sh
cd ansible
ansible-playbook kuma.yaml
```

The Kuma role performs these steps automatically:

1. Check out the pinned commit from the [Uptime Kuma GitHub repository](https://github.com/louislam/uptime-kuma) to `/opt/uptime-kuma/releases/<commit-sha>`.
2. Install locked production dependencies with `npm ci --omit=dev --no-audit`.
3. Download the matching frontend with `npm run download-dist`.
4. Verify the checked-out version matches `uptime_kuma_version` via `package.json`.
5. When release activation is required and the database exists, trigger a pre-activation SQLite backup through `uptime-kuma-backup.service`.
6. Update the `/opt/uptime-kuma/current` symlink to point to the new release directory.
7. Restart the service and verify the upgraded endpoint.

The role retains the active release and the newest previous release after a successful deployment. A failure before activation leaves the current release running. A restart or health-check failure after activation can leave the new release selected and the service failed; the role does not roll back the symlink automatically.

Recover the previous release manually by identifying the previous commit directory, then:

```sh
sudo systemctl stop uptime-kuma.service
sudo ln -snf /opt/uptime-kuma/releases/<previous-commit-sha> /opt/uptime-kuma/current
sudo systemctl start uptime-kuma.service
```

Replace `<previous-commit-sha>` with the actual commit hash. If the database schema migration is incompatible, restore the pre-upgrade SQLite backup from `/var/backups/uptime-kuma/` using the restore procedure.

## Troubleshooting

Check the Kuma service:

```sh
sudo systemctl status uptime-kuma.service
sudo journalctl -u uptime-kuma.service --since today
sudo journalctl -u uptime-kuma.service -n 100 --no-pager
```

Verify the Nginx reverse proxy:

```sh
sudo systemctl status nginx.service
sudo nginx -t
sudo journalctl -u nginx.service --since today
```

Verify the HTTPS listener:

```sh
sudo ss -tlnp | grep :443
curl -vI https://kuma.lab.canhdinh.com/ 2>&1 | grep -E '^(\*|>|<)'
```

Inspect the lego TLS certificate:

```sh
sudo systemctl status lego-renew.timer
sudo journalctl -u lego-renew.service --since today
sudo openssl x509 \
  -in /var/lib/lego/certificates/kuma.crt \
  -noout -subject -issuer -dates -ext subjectAltName
```

Verify DNS resolution:

```sh
getent hosts kuma.lab.canhdinh.com
dig +short kuma.lab.canhdinh.com
```

Check the Kuma data directory and database:

```sh
sudo ls -lh /var/lib/uptime-kuma/
sudo -u kuma sqlite3 /var/lib/uptime-kuma/kuma.db 'PRAGMA integrity_check;'
sudo -u kuma sqlite3 /var/lib/uptime-kuma/kuma.db 'SELECT COUNT(*) FROM monitor;'
```

Inspect the active TLS certificate deployed by lego:

```sh
sudo openssl x509 \
  -in /etc/uptime-kuma/tls/server.crt \
  -noout -subject -issuer -dates -ext subjectAltName
```

Do not print the SQLite database contents or the private key.
