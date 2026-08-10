# Homelab with Tailscale VPN

This repository contains the Ansible configuration for a Debian 13 homelab running Incus, Technitium DNS, [PostgreSQL](https://www.postgresql.org/docs/18/), [Gitea](https://docs.gitea.com/), and [Uptime Kuma](https://github.com/louislam/uptime-kuma) over a Tailscale VPN.

## Environment

| Component | Configuration |
| --- | --- |
| Hardware | Dell Optiplex 7000 Micro, Intel Core i7-12700T (14 cores, 20 threads), 64 GB RAM, 2 TB NVMe SSD |
| Public domain | `canhdinh.com`, hosted by [Cloudflare DNS](https://developers.cloudflare.com/dns/) |
| Private domain | `lab.canhdinh.com`, resolved through [Tailscale split DNS](https://tailscale.com/kb/1054/dns#restricted-nameservers) |
| Host OS | Debian 13 |
| Virtualization | [Incus](https://linuxcontainers.org/incus/docs/main/) with ZFS storage |

The Incus host uses Zabbly builds for:

- [Incus](https://github.com/zabbly/incus)
- [ZFS](https://github.com/zabbly/zfs)
- [Linux kernel](https://github.com/zabbly/linux)

## Prerequisites

- Install a minimal Debian 13 server with SSH access and sudo privileges.
- Install [Tailscale](https://tailscale.com/docs), join the tailnet, and configure split DNS for `lab.canhdinh.com`.
- Advertise the Incus bridge network from the Incus host through a [Tailscale subnet router](https://tailscale.com/kb/1019/subnets).
- Configure the Ansible inventory hosts in `ansible/inventory.yaml`.
- Add the required Cloudflare, PostgreSQL, Gitea, [IDrive e2](https://www.idrive.com/s3-storage-e2/), and [Brevo](https://developers.brevo.com/docs/send-a-transactional-email) secrets to `ansible/group_vars/all/secrets.sops.yaml`.

### Enable Tailscale SSH

Enable [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) on the Incus host so administrators can manage it remotely over the tailnet without distributing separate SSH user keys:

```sh
sudo tailscale set --ssh
```

> [!WARNING]
> Enabling Tailscale SSH can cause an existing SSH connection to the host's Tailscale IP to hang. Run the command from a local console or ensure another recovery path is available.

Enabling the host is only one half of the setup. The tailnet policy must also permit both network access to the Incus host and Tailscale SSH access from the authorized administrator identities to the existing local `lab` user. Tailscale SSH authenticates the tailnet identity but does not create local operating-system accounts.

With MagicDNS enabled and the policy applied, connect from another tailnet device:

```sh
ssh lab@debian-incus
```

Use a narrowly scoped SSH policy and require check mode for interactive administrative access where practical. If Ansible connects through Tailscale SSH, ensure the selected policy supports non-interactive automation; check mode can require browser re-authentication and interrupt unattended runs.

Commands in this runbook are executed from the repository root unless a step changes directory.

## Install Tooling

Install [`mise`](https://mise.jdx.dev/):

```sh
curl https://mise.run | sh
```

Install the pinned tools and Ansible collections:

```sh
mise install
mise run ansible:deps
mise run hooks:install
```

The one-time hook installation configures Cocogitto to reject non-conventional commit messages and runs Gitleaks plus [TruffleHog](https://github.com/trufflesecurity/trufflehog) before every push. Run both secret scanners directly with `mise run security:secrets`.

Gitleaks performs a redacted full-history pattern scan. TruffleHog blocks credentials that are verified as active and candidates whose verification could not complete because of a provider or network error. TruffleHog may contact credential-provider APIs during verification; its repository wrapper reports only detector, status, file, line, and commit metadata so matched values are not printed.

List the available repository tasks:

```sh
mise task ls
```

## Secret Management with SOPS and age

This repository uses [SOPS](https://getsops.io/) with [age](https://age-encryption.org/) to keep Ansible secrets encrypted in Git. SOPS encrypts the values in structured files while preserving enough YAML structure for useful reviews. age provides the asymmetric key pair that controls who can decrypt the file.

### Repository Configuration

The secret-management configuration consists of:

- `mise.toml`, which pins the `sops` and `age` versions and defines the `secrets:edit` and `secrets:view` tasks.
- [`ansible/.sops.yaml`](ansible/.sops.yaml), which applies its age recipient to files ending in `.sops.yaml`.
- [`ansible/group_vars/all/secrets.sops.yaml`](ansible/group_vars/all/secrets.sops.yaml), which contains the encrypted Ansible variables.
- `ansible/ansible.cfg`, which enables the [`community.sops.sops` vars plugin](https://docs.ansible.com/projects/ansible/latest/collections/community/sops/sops_vars.html).
- `ansible/requirements.yaml`, which pins the `community.sops` Ansible collection.

The age recipient in `ansible/.sops.yaml` is a public key and is safe to commit. The corresponding age identity is the private key and must never be committed, pasted into tickets or chat, or stored in shell history.

### How Encryption Works

SOPS uses envelope encryption for each file:

1. SOPS generates a random data key for the file.
2. It encrypts the YAML values with that data key. YAML keys remain readable, which keeps diffs understandable without revealing their values.
3. SOPS encrypts a copy of the data key to every configured age recipient and stores those encrypted copies under the top-level `sops` metadata block.
4. SOPS stores a message authentication code in the metadata so unauthorized value additions, removals, or modifications are detected during decryption.
5. A matching age identity decrypts the file data key, after which SOPS can decrypt and authenticate the values.

The encrypted data key and metadata can be committed safely, but losing every matching age identity makes the secrets unrecoverable. Possession of a matching private identity grants access to every file encrypted for that recipient.

### Configure an Operator Identity

SOPS looks for age identities at `${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt` by default. Create a new identity only if one has not already been provisioned:

```sh
identity_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age"
mkdir -p "$identity_dir"
chmod 700 "$identity_dir"
umask 077
age-keygen -o "$identity_dir/keys.txt"
```

> [!CAUTION]
> Do not overwrite an existing identity file. Before relying on it for production secrets, store the complete private identity in a protected [Bitwarden Secure Note](https://bitwarden.com/help/managing-items/#item-types) or an encrypted [Proton Pass](https://proton.me/pass) note. Losing the only copy makes the encrypted secrets unrecoverable and blocks deployments, maintenance, and disaster recovery.

[Proton Pass security](https://proton.me/pass/security) uses zero-knowledge, end-to-end encryption, and its free plan includes unlimited notes and devices. It is a good free alternative when Bitwarden is not used.

Treat the password-manager copy as an operational continuity requirement:

- Protect the selected password-manager account with a strong, unique master password and multi-factor authentication, such as [Bitwarden two-step login](https://bitwarden.com/help/setup-two-step-login/).
- Restrict the vault item or organization collection to operators authorized to decrypt homelab secrets.
- Preserve the complete identity file content and label it with the matching public age recipient.
- After storing or updating the item, restore it temporarily on a trusted system, verify decryption to `/dev/null`, and securely remove the temporary copy.
- Review access and recovery procedures when operators or devices change.

The local identity file remains the working copy for SOPS. Bitwarden or Proton Pass holds the recovery copy that prevents loss of one workstation from interrupting Ansible operations.

Print only the public recipient derived from the private identity:

```sh
age-keygen -y "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
```

The resulting `age1...` recipient must match the recipient in `ansible/.sops.yaml`. For a non-default identity location, set `SOPS_AGE_KEY_FILE` for direct SOPS commands and `ANSIBLE_SOPS_AGE_KEYFILE` for the Ansible vars plugin:

```sh
export SOPS_AGE_KEY_FILE=/secure/path/keys.txt
export ANSIBLE_SOPS_AGE_KEYFILE=/secure/path/keys.txt
```

Environment variables containing private key material, such as `SOPS_AGE_KEY`, are supported but are less suitable for interactive use because environment contents can leak through process inspection, debugging output, or shell configuration.

### Edit and Inspect Secrets

Edit the encrypted file through SOPS rather than decrypting it to a persistent plaintext file:

```sh
mise run secrets:edit
```

SOPS decrypts the values for the editor process, then validates and re-encrypts the file when the editor exits. Git continues to see only encrypted values.

Inspect decrypted values only when necessary:

```sh
mise run secrets:view
```

> [!WARNING]
> `secrets:view` prints every plaintext secret to the terminal. Do not run it in recorded terminals, CI logs, shared sessions, or commands whose output is redirected to an unencrypted file.

Test key access without displaying plaintext:

```sh
sops --decrypt ansible/group_vars/all/secrets.sops.yaml >/dev/null
```

After editing, review the encrypted diff and ensure no plaintext file was created:

```sh
git diff --check
git diff -- ansible/group_vars/all/secrets.sops.yaml
git status --short
```

### Ansible Decryption Flow

The `community.sops.sops` vars plugin runs on the Ansible controller:

1. Ansible discovers `group_vars/all/secrets.sops.yaml` while loading inventory variables.
2. The plugin invokes the local `sops` binary and obtains the age identity from the default key file or the configured environment override.
3. SOPS authenticates and decrypts the YAML values in memory.
4. Ansible merges those values into the normal `all` group variable set before roles and templates use them.
5. Only values required by a task are sent to managed hosts. The age private identity stays on the controller.

The encrypted file naming convention matters: the vars plugin loads `.sops.yaml`, `.sops.yml`, and `.sops.json` files, while this repository's creation rule targets `.sops.yaml` files. Run playbooks from `ansible/` so `ansible.cfg`, inventory, roles, and the vars plugin configuration are applied together.

### Add or Rotate Recipients

When onboarding another operator or rotating a key:

1. Generate or obtain the operator's public age recipient. Never exchange the private identity.
2. Add the recipient to the matching creation rule in `ansible/.sops.yaml`.
3. Update the existing encrypted file's recipient metadata so its data key is wrapped for the new recipient:

   ```sh
   sops updatekeys ansible/group_vars/all/secrets.sops.yaml
   ```

4. Confirm the new identity can decrypt to `/dev/null` before removing the old recipient.
5. Revoke and securely delete the old private identity only after every encrypted file has been updated and recovery access has been tested.

Changing `ansible/.sops.yaml` alone affects new encryption operations; it does not automatically rewrite recipient metadata in files that are already encrypted. Keep at least one tested recovery identity until rotation is complete.

## Bootstrap the Incus Host

The NVMe disk reserves approximately 1.8 TB for the Incus ZFS pool and keeps the host root filesystem small:

```text
NAME        MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0  1.8T  0 disk
├─nvme0n1p1 259:1    0  511M  0 part /boot/efi
├─nvme0n1p2 259:2    0    1G  0 part /boot
├─nvme0n1p3 259:3    0    4G  0 part [SWAP]
├─nvme0n1p4 259:4    0   50G  0 part /
└─nvme0n1p5 259:5    0  1.8T  0 part
```

Provision the Incus host:

```sh
cd ansible
ansible-playbook setup-incus.yaml --ask-become-pass
cd ..
```

### Incus Network Bridge

The Debian profile in [`incus-debian-profile.yaml`](incus-debian-profile.yaml) connects each instance's `eth0` device to `incusbr0`. The [Incus bridge network](https://linuxcontainers.org/incus/docs/main/reference/network_bridge/) itself is configured on the Incus host and is not created by the current Ansible playbook.

Expected `incusbr0` network configuration:

```yaml
config:
 dns.mode: none
 ipv4.address: 10.205.234.1/24
 ipv4.dhcp: "false"
 ipv4.firewall: "false"
 ipv4.nat: "true"
 ipv6.address: none
 ipv6.dhcp: "false"
```

This configuration has the following operational implications:

- `10.205.234.1` is the bridge gateway for the `10.205.234.0/24` instance network.
- Incus DHCP is disabled. The [built-in DHCP server in Technitium](https://technitium.com/dns/help.html#dhcp-server) provides dynamic leases for instances that use DHCP mode.
- Incus does not register DNS records for instances on the bridge. Static-mode instances receive the Technitium DNS address through cloud-init; DHCP-mode instances receive it from the Technitium scope.
- IPv4 NAT provides outbound connectivity through the Incus host.
- Incus bridge firewalling is disabled. Enforce access through host firewall rules and Tailscale access controls.
- IPv6 addressing and DHCP are disabled.
- The Incus host advertises `10.205.234.0/24` through its Tailscale subnet router so tailnet clients can reach instances directly.

The lab [disables SNAT for Tailscale subnet routes](https://tailscale.com/docs/features/subnet-routers#disable-snat) with `--snat-subnet-routes=false`. This preserves each connecting device's original Tailscale client IP, allowing services, logs, and access controls to identify the real client instead of the Incus subnet router.

Tailscale normally requires devices behind a non-SNAT subnet router to return `100.64.0.0/10` traffic through that router. No additional route-table entry is required inside these instances: their existing default route already uses `10.205.234.1`, which is the Incus host and Tailscale subnet router, so reply traffic follows the correct path.

Configure a Technitium DHCP scope for the Incus network with:

- Network: `10.205.234.0/24`
- Address pool: `10.205.234.100` through `10.205.234.200`
- Router (default gateway): `10.205.234.1`
- DNS server: the IPv4 address of `dns.lab.canhdinh.com`
- Domain name: `lab.canhdinh.com`

Keep static instance addresses outside `10.205.234.100` through `10.205.234.200`. The static-mode instance script checks addresses reported by Incus but does not inspect active or reserved Technitium DHCP leases.

Inspect the bridge on the Incus host:

```sh
incus network show incusbr0
ip -4 address show dev incusbr0
ip -4 route show 10.205.234.0/24
```

Confirm that the `10.205.234.0/24` route is advertised and approved in the Tailscale admin console before deploying services.

### Configure Instance SSH Keys

Tailscale SSH manages access to the Incus host as the local `lab` user. Internal Debian instances do not run Tailscale and use standard OpenSSH instead. This lab uses the default Ed25519 identity at `$HOME/.ssh/id_ed25519`. If it does not already exist, generate it on the administrator workstation:

```sh
ssh-keygen -t ed25519 -a 100 \
   -f "$HOME/.ssh/id_ed25519" \
   -C "homelab"
```

Do not overwrite an existing key pair. Protect the private key at `$HOME/.ssh/id_ed25519` and never add it to the repository or the Incus profile. Display the public key:

```sh
cat "$HOME/.ssh/id_ed25519.pub"
```

Replace `<your-ssh-key>` under `ssh_authorized_keys` in [`incus-debian-profile.yaml`](incus-debian-profile.yaml) with the complete, single-line public key. Apply the updated profile from the Incus host or a workstation configured to manage it as an Incus remote:

```sh
incus profile edit debian < incus-debian-profile.yaml
```

> [!IMPORTANT]
> Replace the placeholder and apply the profile before deployment. Cloud-init injects the key when an instance is first created; changing the profile later does not update `authorized_keys` in existing instances.

The profile creates the internal instance account as `admin`, which differs from the Incus host's `lab` account. After the instance starts and is reachable through the Tailscale subnet route, connect with:

```sh
ssh admin@<instance-hostname-or-ip>
```

OpenSSH and Ansible discover the default `id_ed25519` identity automatically. If a non-default key name is used and the key is not loaded into an SSH agent or selected by SSH client configuration, set its path explicitly in `ansible/ansible.cfg`:

```ini
[defaults]
private_key_file = ~/.ssh/homelab-incus
```

The setting applies to all hosts using that Ansible configuration. For a one-time run, use `--private-key ~/.ssh/homelab-incus`; when different hosts require different keys, prefer the host variable `ansible_ssh_private_key_file` in inventory instead of a global default.

### Create Incus Instances

Use [`create-incus-instance.py`](create-incus-instance.py) through `uv` to create containers or virtual machines with the required image, profiles, bridge, and network mode. View all supported options:

```sh
uv run --with pyyaml create-incus-instance.py --help
```

Static IPv4 configuration is the default. This command creates a container, selects the first IPv4 address on `incusbr0` that is not reported by an existing instance, and writes the address, gateway, and DNS settings to cloud-init:

```sh
uv run --with pyyaml create-incus-instance.py app01 \
   --nameserver 1.1.1.1 \
   --search-domain lab.canhdinh.com
```

Use the Technitium DNS server address instead of `1.1.1.1` when the instance must resolve private `lab.canhdinh.com` records. Repeat `--nameserver` or `--search-domain` to configure multiple values.

To skip static cloud-init networking and let the guest request DHCP configuration, add `--dhcp`:

```sh
uv run --with pyyaml create-incus-instance.py app02 --dhcp
```

> [!IMPORTANT]
> Incus DHCP is disabled on `incusbr0`. Before using `--dhcp`, enable the Technitium DHCP scope for `10.205.234.100` through `10.205.234.200` and ensure the instance can reach that DHCP service on the bridge; otherwise, it will not receive an IPv4 address.

Additional options include:

- `--image` selects the image; the default is `images:debian/13/cloud`.
- `--profile` adds an Incus profile and can be repeated; the `debian` profile is included by default.
- `--vm` creates a virtual machine instead of a container.
- `--incus-bridge` selects the bridge inspected for static address allocation; the applied profiles still determine which network the instance NIC uses.

The script uses `incus create`, so the new instance remains stopped. Inspect its configuration, then start it explicitly:

```sh
incus config show app01 --expanded
incus start app01
```

## Public TLS Certificates with Lego

The [`lego` Ansible role](ansible/roles/lego/) uses [Lego](https://go-acme.github.io/lego/) as an ACME client to obtain publicly trusted TLS certificates from [Let's Encrypt](https://letsencrypt.org/) for the internal Technitium DNS, PostgreSQL, and Gitea services.

The services are reachable only through the homelab network and Tailscale, but their names are subdomains of the publicly registered `canhdinh.com` domain. Clients therefore trust the normal Let's Encrypt certificate chain without installing a private certificate authority.

### Why DNS-01 Works for Internal Services

The role uses the [ACME DNS-01 challenge](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge) through the [Lego Cloudflare provider](https://go-acme.github.io/lego/dns/cloudflare/). Let's Encrypt validates control of each hostname by querying a temporary public TXT record at `_acme-challenge.<hostname>`.

Validation checks public DNS ownership, not service reachability. The service does not need a public IP address, a public A/AAAA record, an inbound port, or a reverse proxy. Tailscale split DNS can continue resolving `*.lab.canhdinh.com` to private addresses while Cloudflare publishes only the ACME challenge records required for issuance.

The role currently accepts explicit hostnames only and rejects wildcard entries. Every publicly trusted certificate is submitted to [Certificate Transparency logs](https://letsencrypt.org/docs/ct-logs/), so names such as `dns.lab.canhdinh.com`, `postgres.lab.canhdinh.com`, and `gitea.lab.canhdinh.com` are publicly discoverable and must not be considered secret.

### Role Inputs and Files

Each service playbook configures the shared role with:

| Variable | Purpose |
| --- | --- |
| `lego_domain_names` | Non-empty list of DNS names placed in the certificate SAN extension |
| `lego_certificate_name` | Stable local name for generated certificate files |
| `lego_server` | ACME server shortcode or URL; defaults to `letsencrypt` |
| `lego_renew_days` | Optional positive renewal threshold |
| `lego_pfx` | Optional password and format for PKCS#12/PFX output |
| `lego_hooks` | Optional `pre`, `deploy`, or `post` commands/scripts |

The role installs pinned Lego `5.3.1` and manages these root-owned paths on each service host:

| Path | Purpose | Mode |
| --- | --- | --- |
| `/usr/local/bin/lego` | ACME client binary | `0755` |
| `/etc/lego/config.yaml` | ACME account, challenge, certificate, PFX, and hook configuration | `0600` |
| `/etc/lego/cloudflare.env` | Cloudflare API token and DNS propagation settings | `0600` |
| `/etc/lego/hooks/` | Rendered service deployment scripts | directory `0750`, scripts `0750` |
| `/var/lib/lego/` | ACME account state, private keys, certificates, and PFX files | directory `0750` |

The Cloudflare token comes from the SOPS-encrypted `cloudflare_api_token` variable. It has only `Zone / Zone / Read` and `Zone / DNS / Edit` permissions and is scoped to `canhdinh.com`. Do not use a Cloudflare Global API Key or commit a decrypted token.

### Issuance and Reconciliation Flow

During each playbook run, the role:

1. Validates hostnames, certificate name, ACME server, renewal threshold, PFX settings, and hook definitions before changing the host.
2. Installs the pinned Lego binary and creates the configuration, state, and hook directories.
3. Renders a root-only Lego configuration using EC P-256 keys for the ACME account and leaf certificate.
4. Renders the root-only Cloudflare environment file.
5. Runs the same reconciliation command used by automatic renewal:

    ```sh
    /usr/local/bin/lego --config /etc/lego/config.yaml
    ```

6. Lego creates the `_acme-challenge` TXT record through the Cloudflare API and checks propagation through `1.1.1.1` and `1.0.0.1`. The role allows up to 180 seconds for propagation and polls every five seconds.
7. Let's Encrypt validates the TXT record and issues the certificate. Lego stores the certificate and private key under `/var/lib/lego/certificates/`, using `lego_certificate_name` for the filenames.
8. When certificate material changes, Lego runs the configured deploy hook so the target service receives the new identity.
9. The role enables the daily renewal timer.

Preserve `/var/lib/lego`; it contains the ACME account and certificate state needed for stable reconciliation. Repeatedly deleting this state and requesting replacement certificates can consume [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/).

### Service Deployment Hooks

The shared role owns issuance and renewal, while each service playbook owns the final certificate format, destination, permissions, validation, and reload behavior:

| Service | Lego output | Active destination and behavior |
| --- | --- | --- |
| Technitium DNS | `/var/lib/lego/certificates/dns.pfx` | Installs `/etc/dns/dns.pfx` as `dns-server:dns-server` with mode `0600`, then restarts `dns.service` |
| PostgreSQL 18 | `postgres.crt` and `postgres.key` | Validates expiry, certificate/key match, file readability, and PostgreSQL TLS configuration; stages and atomically swaps `/etc/postgresql/18/main/tls/server.crt` and `server.key`; reloads the cluster and rolls back if activation fails |
| Gitea | `gitea.crt` and `gitea.key` | Validates expiry and certificate/key match; atomically replaces `/etc/gitea/tls/server.crt` and `server.key`; runs `systemctl reload-or-restart gitea.service` |

Technitium requires a password-protected SHA-256 PFX. PostgreSQL and Gitea consume PEM certificate/key pairs with service-specific ownership and restrictive private-key permissions.

### Automatic Renewal

The role installs `lego-renew.service` as a oneshot unit that runs the reconciliation command and `lego-renew.timer` with:

- `OnCalendar=daily`
- `Persistent=true`, so a missed run executes after the host returns
- `RandomizedDelaySec=1h`, which avoids every host contacting the ACME service simultaneously

Lego renews only when the certificate enters its renewal window. Successful renewal invokes the same deploy hook used during initial issuance, so the service begins using the replacement certificate without a full Ansible run.

### Operations and Troubleshooting

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

## Deployment Sequence

Run these stages in order. DNS must resolve the service hostnames before PostgreSQL or Gitea requests certificates and starts accepting connections.

### 1. Deploy DNS

Technitium DNS is installed manually on `dns.lab.canhdinh.com`. On the DNS host, run:

```sh
curl -sSL https://download.technitium.com/dns/install.sh | sudo bash
```

Configure the `lab.canhdinh.com` zone and its host records in Technitium, then obtain and deploy its TLS certificate with `lego`:

```sh
cd ansible
ansible-playbook dns.yaml
```

There is no dedicated DNS verification playbook. Before continuing, confirm that all deployment hostnames resolve from the Ansible controller:

```sh
getent hosts dns.lab.canhdinh.com
getent hosts postgres.lab.canhdinh.com
getent hosts gitea.lab.canhdinh.com
getent hosts kuma.lab.canhdinh.com
```

### 2. Deploy PostgreSQL

Deploy PostgreSQL 18 and its `lego`-managed TLS certificate:

```sh
ansible-playbook postgres.yaml
```

Verify the PostgreSQL service, TLS endpoint, backup configuration, and timers:

```sh
ansible-playbook verify-postgres.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook postgres.yaml
```

The second deployment should report `changed=0` for the PostgreSQL host.

### 3. Deploy Gitea

Gitea depends on the PostgreSQL service from the previous stage. The Gitea playbook creates its PostgreSQL role and database before deploying Gitea with built-in HTTPS.

```sh
ansible-playbook gitea.yaml
```

Verify the Gitea service, listener, TLS endpoint, configuration, administrator, and doctor checks:

```sh
ansible-playbook verify-gitea.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook gitea.yaml
```

The second deployment should report `changed=0` for both the Gitea and PostgreSQL hosts.

### 4. Deploy Uptime Kuma

Uptime Kuma stores its state in a local SQLite database and has no PostgreSQL runtime dependency. The Kuma playbook deploys the native application behind Nginx with a Lego-managed TLS certificate.

```sh
ansible-playbook kuma.yaml
```

The first deployment installs the infrastructure but leaves Kuma waiting for one-time database setup through its web interface. Complete the [Uptime Kuma First Login and Setup](#first-login-and-setup) before running verification.

Verify the Kuma service, listener, TLS endpoint, backup configuration, and timers:

```sh
ansible-playbook verify-kuma.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook kuma.yaml
cd ..
```

The second deployment should report `changed=0` for `kuma`.

## Uptime Kuma Operations

### First Login and Setup

Open `https://kuma.lab.canhdinh.com/` and configure the initial administrator account:

- **Username:** `kuma-admin`
- **Password:** Retrieve from the SOPS key `uptime_kuma_admin_password`:

  ```sh
  sops --extract '["uptime_kuma_admin_password"]' \
    --decrypt ansible/group_vars/all/secrets.sops.yaml
  ```

Use a strong, unique password during account creation or change the password on first login if the Ansible role has pre-configured the account.

After first login, enable two-factor authentication:

1. Navigate to **Settings** > **Security**.
2. Configure TOTP using an authenticator app such as [Aegis](https://getaegis.app/), [2FAS](https://2fas.com/), or [Bitwarden Authenticator](https://bitwarden.com/products/authenticator/).
3. Store recovery codes in a secure location.

### Trust Proxy Configuration

Uptime Kuma runs behind Nginx with TLS termination. Configure the trust-proxy setting to preserve the original client IP:

1. Navigate to **Settings** > **Reverse Proxy**.
2. Under **HTTP Headers**, set **Trust Proxy** to `Yes`.
3. Save the settings.

This ensures logs, rate limiting, and access controls see the real client address instead of the Nginx proxy.

### SMTP Notification Configuration

Configure the Brevo SMTP service for alert notifications:

1. Navigate to **Settings** > **Notifications**.
2. Click **Setup Notification**.
3. Select **SMTP (Email)** as the notification type.
4. Configure the following settings using values from SOPS:

   | Field | SOPS Key | Retrieve Command |
   | --- | --- | --- |
   | **SMTP Host** | `gitea_smtp_host` | `sops --extract '["gitea_smtp_host"]' --decrypt ansible/group_vars/all/secrets.sops.yaml` |
   | **SMTP Port** | `gitea_smtp_port` | `sops --extract '["gitea_smtp_port"]' --decrypt ansible/group_vars/all/secrets.sops.yaml` |
   | **From Email** | `gitea_smtp_from` | `sops --extract '["gitea_smtp_from"]' --decrypt ansible/group_vars/all/secrets.sops.yaml` |
   | **Username** | `gitea_smtp_user` | `sops --extract '["gitea_smtp_user"]' --decrypt ansible/group_vars/all/secrets.sops.yaml` |
   | **Password** | `gitea_smtp_password` | `sops --extract '["gitea_smtp_password"]' --decrypt ansible/group_vars/all/secrets.sops.yaml` |

5. Enable **Secure** (TLS) if required by the SMTP provider.
6. Click **Test** to send a confirmation email.
7. Verify the test email arrives before attaching the notification to monitors.

> [!WARNING]
> Do not commit decrypted SMTP credentials or include them in screenshots or logs.

### Monitor Configuration

Create the `Homelab` monitor group:

1. Click **Add Group** on the dashboard.
2. Name the group `Homelab`.
3. Set **Heartbeat Interval** to `60` seconds.
4. Set **Retries** to `3`.
5. Save the group.

Add the following eight monitors to the `Homelab` group:

| Monitor Name | Type | Target | Notes |
| --- | --- | --- | --- |
| **Uptime Kuma HTTPS** | HTTPS | `https://kuma.lab.canhdinh.com/` | Kuma self-check |
| **Gitea HTTPS** | HTTPS | `https://gitea.lab.canhdinh.com/` | Gitea web interface |
| **PostgreSQL TCP** | Port | `postgres.lab.canhdinh.com:5432` | PostgreSQL listener |
| **Technitium DNS Lookup** | DNS | Hostname: `kuma.lab.canhdinh.com`<br>Resolver: `dns.lab.canhdinh.com`<br>Expected: `10.205.234.102` | DNS resolution |
| **Incus Host Ping** | Ping | `debian-incus` or `10.205.234.1` | Incus host reachability |
| **DNS Host Ping** | Ping | `dns.lab.canhdinh.com` | DNS instance reachability |
| **PostgreSQL Host Ping** | Ping | `postgres.lab.canhdinh.com` | PostgreSQL instance reachability |
| **Gitea Host Ping** | Ping | `gitea.lab.canhdinh.com` | Gitea instance reachability |

For each monitor:

1. Click **Add New Monitor**.
2. Configure the monitor type and target from the table above.
3. Set **Heartbeat Interval** to `60` seconds.
4. Set **Retries** to `3`.
5. Under **Notifications**, attach the Brevo SMTP notification.
6. Save the monitor.

> [!IMPORTANT]
> The **Uptime Kuma HTTPS** monitor checks Kuma itself. Kuma cannot send alert notifications if its own service, database, or network is completely down; the alert will be delayed until service recovery.

All other monitors will send alert notifications through Brevo SMTP when they fail, subject to the retry policy.

### Backup Operations

Uptime Kuma runs an automatic daily backup timer:

- **uptime-kuma-backup.timer:** Daily with a one-hour random delay, persistent across reboots
- Schedule: `OnCalendar=daily`, `Persistent=true`, `RandomizedDelaySec=1h`

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

Backup archives are stored as root-only gzipped SQLite database files under `/var/backups/uptime-kuma/` with names such as `kuma-20260810T020015Z.db.gz`. The newest 14 backups are retained by count.

> [!WARNING]
> Backup archives are stored locally and have no off-host replication. Loss of the Kuma host causes permanent backup loss.

### Restore Procedure

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

5. Preserve the current database as a backup:

   ```sh
   sudo cp -p /var/lib/uptime-kuma/kuma.db /var/lib/uptime-kuma/kuma.db.pre-restore
   ```

6. Atomically install the restored database:

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

### Upgrade Procedure

Before changing `uptime_kuma_version` or `uptime_kuma_release_commit`, take a manual backup:

```sh
sudo systemctl start uptime-kuma-backup.service
sudo journalctl -u uptime-kuma-backup.service -n 50 --no-pager
```

Update `uptime_kuma_version` and `uptime_kuma_release_commit` in the Kuma role defaults, then rerun the deployment:

```sh
cd ansible
ansible-playbook kuma.yaml
```

The Kuma role follows these upgrade steps automatically:

1. Check out the pinned commit from the [Uptime Kuma GitHub repository](https://github.com/louislam/uptime-kuma) to `/opt/uptime-kuma/releases/<commit-sha>`.
2. Install locked production dependencies with `npm ci --omit=dev --no-audit`.
3. Download the matching frontend with `npm run download-dist`.
4. Verify the checked-out version matches `uptime_kuma_version` via `package.json`.
5. If the database exists and release activation is required, trigger a pre-activation SQLite backup via `uptime-kuma-backup.service`.
6. Update the `/opt/uptime-kuma/current` symlink to point to the new release directory.
7. Restart the service and verify the upgraded endpoint.

The role retains the active release and the newest previous release. If the upgrade fails, the service remains stopped and the previous release is still available under `/opt/uptime-kuma/releases/<previous-commit-sha>/`.

Recover the previous release manually by identifying the previous commit directory, then:

```sh
sudo systemctl stop uptime-kuma.service
sudo ln -snf /opt/uptime-kuma/releases/<previous-commit-sha> /opt/uptime-kuma/current
sudo systemctl start uptime-kuma.service
```

Replace `<previous-commit-sha>` with the actual commit hash. If the database schema migration is incompatible, restore the pre-upgrade SQLite backup from `/var/backups/uptime-kuma/` using the restore procedure.

### Troubleshooting

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

Inspect the Lego TLS certificate:

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

Inspect the active TLS certificate deployed by Lego:

```sh
sudo openssl x509 \
  -in /etc/uptime-kuma/tls/server.crt \
  -noout -subject -issuer -dates -ext subjectAltName
```

Do not print the SQLite database contents or the private key.

## Gitea Operations

### First Login

Open `https://gitea.lab.canhdinh.com/` and sign in as `gitea-admin`. The initial password is stored in the SOPS key `gitea_admin_password`; Gitea requires an immediate password change on first login.

User registration is enabled, and new accounts must confirm their email address through the configured Brevo transactional mail service.

### Health Checks

Run these commands on the Gitea host:

```sh
sudo systemctl status gitea.service
sudo journalctl -u gitea.service --since today
sudo -u git /usr/local/bin/gitea doctor check --default --config /etc/gitea/app.ini
sudo systemctl status lego-renew.timer
```

### Upgrade Procedure

Stop Gitea and take a consistent backup before changing `gitea_version`:

```sh
sudo systemctl stop gitea.service
```

Do not upgrade until the repository and generated-state backup limitation below is acceptable.

## PostgreSQL Operations

### Backup and Health Checks

Run these commands on the PostgreSQL host:

```sh
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main info
sudo -u postgres pgbackrest --stanza=main check
```

## Backup Coverage

| Data | Coverage |
| --- | --- |
| PostgreSQL relational data | pgBackRest local backups only; no off-host replication |
| Gitea object storage | iDrive e2 stores LFS objects, avatars, attachments, and packages |
| Gitea repositories and generated state | `/var/lib/gitea` has no off-host backup |

> [!WARNING]
> Loss of the Gitea host causes permanent repository loss. The current PostgreSQL backups also do not survive loss of the PostgreSQL host or its storage.

## PostgreSQL Point-in-Time Restore

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
