# Deploy and operate HashiCorp Vault

Deploy and operate a single-node Vault **systemd service in the Debian 13 Linux
container (LXC)** at [vault.lab.canhdinh.com](https://vault.lab.canhdinh.com/), not
in Kubernetes. The Ansible role pins Vault **2.2.0** for amd64 and verifies its
release archive against the committed SHA-256 digest. Vault runs as the unprivileged `vault` account, with only
`CAP_NET_BIND_SERVICE` to serve TLS directly on port 443. There is no reverse
proxy, HTTP listener, development mode, or external database.
The Vault-specific systemd drop-in preserves `NoNewPrivileges=true` despite
LXC's global service overrides.

## Deploy and verify

The private DNS record must resolve to the LXC. From `ansible/`, run:

```sh
mise exec -- ansible-playbook vault.yaml
mise exec -- ansible-playbook verify-vault.yaml
mise exec -- ansible-playbook vault.yaml
```

The second deployment should report `changed=0`. Vault depends on working DNS
and the existing lab-scoped Cloudflare credential, but not PostgreSQL or S3.
The [lego role](tls.md) issues and renews its Let's Encrypt certificate through
DNS-01; no public port or DNS address record is required. Renewal deploys a
validated certificate/key pair and sends SIGHUP, never a restart that would
reseal Vault. The certificate key is root-owned, readable by group `vault` only.

The verification playbook checks the binary, service, renewal timer, trusted
HTTPS, UI, Raft storage type, listener boundaries, log rotation configuration,
and protected file permissions. Health HTTP `501` means uninitialized, `503`
means sealed, and `200` means initialized and unsealed. These are distinct
operational states, not permission to ignore arbitrary HTTP failures.

### Verified installation

On **2026-10-18**, Vault 2.2.0 was installed on the existing LXC at
`10.205.234.111`. Live verification passed with `changed=0`, and a repeat
deployment also reported `changed=0`. The service was enabled and running as
`vault` with effective `NoNewPrivileges=yes`. Trusted HTTPS, a complete
compressed UI transfer, the renewal timer, protected paths, and logrotate
configuration passed. A real browser reached the Raft initialization screen.
The instance remained **uninitialized and sealed**; no bootstrap keys or tokens
were generated, and no audit device or data backup was created.

## Control-node CLI

`mise.toml` pins the matching Vault CLI **2.2.0** and sets
`VAULT_ADDR=https://vault.lab.canhdinh.com` within this repository. From the
repository root:

```sh
mise install vault
mise exec -- vault status
```

To log in interactively without displaying the token:

```sh
mise exec -- vault login -no-print
```

Enter the token at the hidden prompt, never as a command-line argument. The
default token helper caches it in `~/.vault-token`; keep that file mode `0600`
and do not copy it into the repository. Avoid unfiltered `vault token lookup`
output in recorded sessions because it includes credentials.

On **2026-10-18**, after operator initialization and unsealing, the control-node
CLI authenticated with the SOPS-stored root token without displaying it.
Status showed initialized, unsealed, active Vault 2.2.0 with Raft storage.
Authenticated peer inspection confirmed one voter/leader, node `vault`, with
equal committed/applied indexes. The root token remains cached locally; replace
routine root use with a least-privilege auth method when configured.

## Initialize and unseal privately

The live lab is already initialized and unsealed. The initialization steps below
apply only to a fresh instance; never reinitialize an existing data directory.

Installation **does not initialize Vault**, generate keys, or save a root token.
On a fresh instance, initialize promptly using the HTTPS UI, or run the following in
a **private, unrecorded terminal** on the LXC. The initialization command prints
unseal keys and a root token; do not paste its output into chat, logs, or Git.
In the UI, choose **Create a new Raft cluster**, not **Join an existing Raft
cluster**, for this single-node installation.

```sh
export VAULT_ADDR=https://vault.lab.canhdinh.com
vault operator init -key-shares=5 -key-threshold=3
```

Keep the five Shamir unseal shares in independent protected custody, with at
least three available for recovery. Store the initial root token separately.
Do not keep these only inside this Vault, on its LXC, or in this repository.
Losing the threshold of shares makes the encrypted data unrecoverable even with
a storage backup. The UI also offers initialization if using a password manager
is more convenient than terminal output.

The initialization download is backed up as
[`secrets/vault/bootstrap.sops.json`](../secrets/vault/bootstrap.sops.json), with
all values SOPS-encrypted to the repository's age recipient. It stays outside
Ansible inventory and is covered by `mise run secrets:check`. This combined copy
does not provide independent share custody: its decrypting identity can recover
all shares and the initial root token. Keep a separate protected recovery copy
and revoke the initial root token once non-root administration works.

Unseal using three different shares, each entered at the hidden prompt:

```sh
vault operator unseal
vault operator unseal
vault operator unseal
vault status
vault login -no-print
```

Enter the initial root token at the hidden login prompt, never in a command-line
argument. The CLI stores a token in `~/.vault-token`; protect it with mode `0600`.
Before storing real secrets, enable auditing, configure a least-privilege auth
method and policies, verify non-root administrative access, then revoke the
initial root token. No users, auth methods, policies, or secrets engines are
created automatically.

For file auditing, the role prepares a protected log directory and logrotate
configuration. After logging in, enable the device once:

```sh
vault audit enable file file_path=/var/log/vault/audit.log
vault audit list
```

Logs rotate daily (or at 100 MiB when logrotate next runs), retain 14 rotations,
and reopen on SIGHUP. These are local logs, not off-host audit retention. Monitor
free disk: audit-write failure can block requests.

## Storage, restarts, and recovery

- Integrated Raft data lives under `/var/lib/vault/raft` with mode `0700` on the
  persistent LXC root filesystem. It survives service/container restarts, but
  not container deletion or loss of the Incus storage pool. There is no separate
  data volume or automatic backup job.
- This is **one node**, not a highly available cluster. The Raft cluster listener
  is restricted to `127.0.0.1:8201`; only HTTPS on port 443 is exposed.
- The seal is Shamir; there is **no auto-unseal**. After a service/container
  restart or a configuration/binary upgrade, an operator must unseal it again.
  Ordinary certificate renewal does not require unsealing.
- `disable_mlock = true` follows HashiCorp's Raft guidance. The role rejects
  enabled swap and the service checks `/proc/swaps` at startup. Keep swap disabled
  on the Incus host as well as in the LXC; do not enable it while Vault runs.
- The container currently has a small root disk. Monitor both Raft and audit
  growth, and increase its disk quota before it fills.

Take a Raft snapshot after setup and before upgrades, using an authorized token
in a private control-node terminal. From the repository root, save a timestamped
snapshot outside the repository:

```sh
umask 077
backup_dir="$HOME/.local/state/lab/backups/vault"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
snapshot="$backup_dir/vault-$(date -u +%Y%m%dT%H%M%SZ).snap"
mise exec -- vault operator raft snapshot save "$snapshot"
mise exec -- vault operator raft snapshot inspect "$snapshot"
```

Copy snapshots to protected **off-host** storage, separately from the unseal
shares, and test recovery before relying on them. Snapshots contain encrypted
Vault data but are still sensitive. They do not back up TLS/ACME state,
configuration, or audit logs. Do not copy the live Raft database as a backup.

For disaster recovery, restore the same pinned Vault version and configuration,
initialize and unseal the empty replacement in a private terminal, then use its
temporary root token for `vault operator raft snapshot restore -force vault.snap`
**only on that empty recovery instance**. Restore replaces its contents. Unseal
using the **original** shares belonging to the snapshot, then authenticate using
credentials from the restored Vault. Restore acceptance is asynchronous; wait
for the post-unseal completion messages in the server logs before resuming use.
Consult the snapshot restore documentation before executing; no restore has
been tested by this installation.

For upgrades, take a verified off-host snapshot, read the release-specific
upgrade notes, update the version and checksum together with their contract
tests, run local checks, then deploy and unseal. Do not blindly downgrade the
binary against a newer Raft database. Rollback requires the matching pre-upgrade
snapshot and its original unseal shares on an isolated recovery instance; never
delete `/var/lib/vault` or `/var/lib/lego` as a repair step.

## Troubleshooting

On the LXC:

```sh
sudo systemctl status vault.service lego-renew.timer
sudo journalctl -u vault.service -n 100 --no-pager
VAULT_ADDR=https://vault.lab.canhdinh.com vault status
```

`vault status` exits with code `2` while sealed; this does not mean systemd failed.
Do not disable TLS verification to fix a DNS or certificate problem. Inspect
lego's renewal logs without printing `/etc/lego/cloudflare.env` or private keys.

Vault 2.2.0 has an upstream UI response-length bug when compression is not
negotiated: Content Security Policy (CSP) nonce injection changes the HTML body
without updating its length. Normal browsers offer gzip/zstd; the tested browser
loaded successfully. For a complete UI transfer check, use
`curl --compressed --fail https://vault.lab.canhdinh.com/ui/`.
This does not affect JSON API endpoints. No custom binary or proxy workaround
is installed; recheck uncompressed UI transfers when upgrading Vault.

## References

- [Vault 2.2.0 release checksums](https://releases.hashicorp.com/vault/2.2.0/vault_2.2.0_SHA256SUMS)
- [Integrated storage deployment guide](https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-deployment-guide)
- [Configuration and mlock guidance](https://developer.hashicorp.com/vault/docs/configuration)
- [TCP listener and TLS reload](https://developer.hashicorp.com/vault/docs/configuration/listener/tcp)
- [Initialization](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [File audit device and rotation](https://developer.hashicorp.com/vault/docs/audit/file)
- [Raft snapshot operations](https://developer.hashicorp.com/vault/docs/commands/operator/raft#snapshot)
