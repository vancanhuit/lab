# Public TLS certificates with lego

The [`lego` Ansible role](../ansible/roles/lego/) uses [lego](https://go-acme.github.io/lego/) as an Automated Certificate Management Environment (ACME) client. It obtains publicly trusted Transport Layer Security (TLS) certificates from [Let's Encrypt](https://letsencrypt.org/) for Technitium DNS, PostgreSQL, SeaweedFS S3, Harbor, Gitea, and Uptime Kuma.

The services are reachable only through the homelab network and Tailscale, but their names are subdomains of the publicly registered `canhdinh.com` domain. Clients therefore trust the normal Let's Encrypt certificate chain without installing a private certificate authority.

## Why DNS-01 works for internal services

The role uses the [ACME DNS-01 challenge](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge) through the [lego Cloudflare provider](https://go-acme.github.io/lego/dns/cloudflare/). Let's Encrypt validates control of each hostname by querying a temporary public TXT record at `_acme-challenge.<hostname>`.

Validation checks public DNS ownership, not service reachability. The service does not need a public IP address, a public A/AAAA record, an inbound port, or a reverse proxy. Tailscale split DNS can continue resolving `*.lab.canhdinh.com` to private addresses while Cloudflare publishes only the ACME challenge records required for issuance.

The role currently accepts explicit hostnames only and rejects wildcard entries. Every publicly trusted certificate is submitted to [Certificate Transparency logs](https://letsencrypt.org/docs/ct-logs/), so names such as `dns.lab.canhdinh.com`, `postgres.lab.canhdinh.com`, and `gitea.lab.canhdinh.com` are publicly discoverable and must not be considered secret.

## Role inputs and files

Each service playbook configures the shared role with:

| Variable | Purpose |
| --- | --- |
| `lego_domain_names` | Non-empty list of DNS names placed in the certificate SAN extension |
| `lego_certificate_name` | Stable local name for generated certificate files |
| `lego_server` | ACME server shortcode or URL; defaults to `letsencrypt` |
| `lego_renew_days` | Optional positive renewal threshold |
| `lego_pfx` | Optional password and format for PKCS#12/PFX output |
| `lego_hooks` | Optional `pre`, `deploy`, or `post` commands/scripts |

The role installs the pinned `lego` 5.3.1 binary and manages these root-owned paths on each service host:

| Path | Purpose | Mode |
| --- | --- | --- |
| `/usr/local/bin/lego` | ACME client binary | `0755` |
| `/etc/lego/config.yaml` | ACME account, challenge, certificate, PFX, and hook configuration | `0600` |
| `/etc/lego/cloudflare.env` | Cloudflare API token and DNS propagation settings | `0600` |
| `/etc/lego/hooks/` | Rendered service deployment scripts | directory `0750`, scripts `0750` |
| `/var/lib/lego/` | ACME account state, private keys, certificates, and PFX files | directory `0750` |

The Cloudflare token comes from the SOPS-encrypted `cloudflare_api_token` variable. It has only `Zone / Zone / Read` and `Zone / DNS / Edit` permissions and is scoped to `canhdinh.com`. Do not use a Cloudflare Global API Key or commit a decrypted token.

## Issuance and reconciliation flow

During each playbook run, the role:

1. Validates hostnames, certificate name, ACME server, renewal threshold, PFX settings, and hook definitions before changing the host.
2. Installs the pinned `lego` binary and creates the configuration, state, and hook directories.
3. Renders a root-only lego configuration using EC P-256 keys for the ACME account and leaf certificate.
4. Renders the root-only Cloudflare environment file.
5. Runs the same reconciliation command used by automatic renewal:

    ```sh
    /usr/local/bin/lego --config /etc/lego/config.yaml
    ```

6. The `lego` client creates the `_acme-challenge` TXT record through the Cloudflare API and checks propagation through `1.1.1.1` and `1.0.0.1`. The role allows up to 180 seconds for propagation and polls every five seconds.
7. Let's Encrypt validates the TXT record and issues the certificate. The `lego` client stores the certificate and private key under `/var/lib/lego/certificates/`, using `lego_certificate_name` for the filenames.
8. When certificate material changes, the `lego` client runs the configured deploy hook so the target service receives the new identity.
9. The role enables the daily renewal timer.

Preserve `/var/lib/lego`; it contains the ACME account and certificate state needed for stable reconciliation. Repeatedly deleting this state and requesting replacement certificates can consume [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/).

## Service deployment hooks

The shared role owns issuance and renewal, while each service playbook owns the final certificate format, destination, permissions, validation, and reload behavior:

| Service | lego output | Active destination and behavior |
| --- | --- | --- |
| Technitium DNS | `/var/lib/lego/certificates/dns.pfx` | Installs `/etc/dns/dns.pfx` as `dns-server:dns-server` with mode `0600`, then restarts `dns.service` |
| PostgreSQL 18 | `postgres.crt` and `postgres.key` | Validates expiry, certificate/key match, file readability, and PostgreSQL TLS configuration; stages and renames each file under `/etc/postgresql/18/main/tls/`; reloads the cluster and rolls back if activation fails |
| SeaweedFS S3 | `s3.crt` and `s3.key` | Validates expiry and certificate/key match; stages and renames each file under `/etc/seaweedfs/tls/`; validates and reloads Nginx |
| Harbor | `harbor.crt` and `harbor.key` | Validates expiry and certificate/key match; updates `/etc/harbor/tls/` and runtime copies under `/var/lib/harbor/secret/cert/`; restarts the Harbor proxy container |
| Gitea | `gitea.crt` and `gitea.key` | Validates expiry and certificate/key match; stages and renames each file under `/etc/gitea/tls/`; runs `systemctl reload-or-restart gitea.service` |
| Uptime Kuma | `kuma.crt` and `kuma.key` | Validates expiry and certificate/key match; stages and renames each file under `/etc/uptime-kuma/tls/`; validates and reloads Nginx |

Technitium requires a password-protected SHA-256 PFX. PostgreSQL, SeaweedFS S3, Harbor, Gitea, and Uptime Kuma consume PEM certificate and key pairs with service-specific ownership and restrictive private-key permissions.

## Automatic renewal

The role installs `lego-renew.service` as a oneshot unit that runs the reconciliation command. It configures `lego-renew.timer` with:

- `OnCalendar=daily`
- `Persistent=true`, so a missed run executes after the host returns
- `RandomizedDelaySec=1h`, which prevents all hosts from contacting the ACME service simultaneously

The `lego` client renews a certificate only when it enters its renewal window. Successful renewal invokes the same deploy hook used during initial issuance, so the service begins using the replacement certificate without a full Ansible run.

## Operations and troubleshooting

Inspect the timer and recent renewal activity on a service host:

```sh
sudo systemctl status lego-renew.timer
sudo systemctl list-timers lego-renew.timer
sudo journalctl -u lego-renew.service --since today
```

Trigger the same reconciliation path manually and then inspect its logs:

```sh
sudo systemctl start lego-renew.service
sudo journalctl -u lego-renew.service -n 100 --no-pager
```

Inspect a generated certificate without displaying its private key:

```sh
sudo openssl x509 \
   -in /var/lib/lego/certificates/gitea.crt \
   -noout -subject -issuer -dates -ext subjectAltName
```

If issuance or renewal fails:

1. Check `lego-renew.service` logs before retrying.
2. Confirm the host can reach Let's Encrypt, the Cloudflare API, and public DNS resolvers.
3. Confirm the Cloudflare token is current, scoped to `canhdinh.com`, and has `Zone / Zone / Read` plus `Zone / DNS / Edit`.
4. Query the public `_acme-challenge` TXT record and allow for propagation:

   ```sh
   dig +short TXT _acme-challenge.gitea.lab.canhdinh.com @1.1.1.1
   ```

5. Validate the deploy-hook destination directory, ownership, service account, and reload command.
6. Set `lego_server: letsencrypt-staging` while debugging repeated authorization failures; staging certificates are intentionally not publicly trusted. Restore `lego_server: letsencrypt` before production issuance.

Do not print `/etc/lego/cloudflare.env`, copy private keys into logs, or loosen key permissions to troubleshoot access. The role marks secret-rendering tasks with `no_log`, but operators must apply the same discipline to manual commands.
