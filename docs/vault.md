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
equal committed/applied indexes. [Gitea OIDC SSO](../vault/README.md) now provides non-root administrator
login for subject `2` and sign-in-only access for other Gitea accounts. Identities
use verified email addresses, independently of the administrator subject check.
The CLI now caches the non-root SSO login as `oidc-vancanhuit@gmail.com` with the
`gitea-admin` policy, replacing the cached root login. The initial root token
remains in the encrypted bootstrap backup and has not been revoked.

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
initial root token. The server deployment creates no users, auth methods,
policies, or secrets engines; configure [Gitea SSO](../vault/README.md) separately
after initialization. The live instance already has this auth configuration.

## Audit logging

The role prepares a protected log directory and logrotate configuration; audit
devices are configured separately through the Vault API, not by Ansible. From
the repository root, after an administrator login, enable the device once:

```sh
mise exec -- vault audit enable file file_path=/var/log/vault/audit.log mode=0600 log_raw=false
mise exec -- vault audit list -detailed
```

The live `file/` audit device was enabled on **2026-10-18** using the non-root
Gitea SSO administrator session. It writes JSON request/response events to
`/var/log/vault/audit.log`, owned by `vault:vault` with mode `0600`, inside the
mode `0700` log directory. Sensitive values retain Vault's default HMAC protection;
do not enable `log_raw`. Audit configuration persists in Vault storage and does
not need to be enabled again after unsealing.

Logs rotate daily (or at 100 MiB when logrotate next runs), retain 14 rotations,
and reopen on SIGHUP. A forced rotation verified that a fresh authenticated
request and its response reached the new log, with token values HMAC-protected.
The logrotate timer was active and enabled, and Vault's PID remained unchanged;
no restart or reseal was needed.

These are local logs, not off-host audit retention, and Raft snapshots do not
include them. Treat audit logs as sensitive: paths and some metadata remain
readable. Monitor free disk and audit errors: requests can block or fail if no
enabled audit device can write successfully. This installation has only one
audit device; off-host forwarding and disk-space alerting were not added here.

## KV v2 secrets

The versioned key/value secrets engine is enabled at **`secret/`**. Like OIDC
and audit devices, it is configured through the Vault API, not by Ansible.
On a fresh instance, after an administrator login, enable it once from the
repository root:

```sh
mise exec -- vault secrets enable -path=secret -description="Versioned lab secrets" kv-v2
mise exec -- vault secrets list -detailed
```

If `secret/` already exists, confirm its type is `kv` with option `version=2`;
do not disable it to reapply configuration, because disabling a secrets engine
deletes its data. The live engine retains the defaults: ten versions per key
(`max_versions=0` means ten), no automatic version deletion, and optional
check-and-set (CAS). Use CAS to protect writes from stale updates; it can also
be required per key. Static KV values do not rotate or expire automatically.

### Disposable CLI exercise

Run this with the administrator SSO session. All values are deliberately fake;
do not put real credentials in command arguments or display them in recorded
output. For real writes, supply JSON through stdin using `vault kv put
-mount=secret <path> -` from a protected source.

The exercise creates a unique key with create-only CAS, then removes all of its
versions and metadata on exit. Destructive commands below target only that key.

```bash
mise exec -- bash <<'SH'
set -euo pipefail
demo="demo/cli-$(date -u +%Y%m%dT%H%M%SZ)-$$"
vault kv put -mount=secret -cas=0 "$demo" username=demo password=dummy-v1
trap 'vault kv metadata delete -mount=secret "$demo" >/dev/null' EXIT
vault kv metadata put -mount=secret -cas-required=true "$demo"
vault kv get -mount=secret "$demo"
vault kv list -mount=secret demo
vault kv put -mount=secret -cas=1 "$demo" username=demo password=dummy-v2
vault kv patch -mount=secret -method=patch -cas=2 "$demo" password=dummy-v3
vault kv get -mount=secret -version=1 "$demo"
vault kv metadata get -mount=secret "$demo"
vault kv rollback -mount=secret -version=1 "$demo"
vault kv delete -mount=secret "$demo"
vault kv undelete -mount=secret -versions=4 "$demo"
vault kv get -mount=secret "$demo"
vault kv destroy -mount=secret -versions=2 "$demo"
vault kv metadata get -mount=secret "$demo"
SH
```

`put` replaces the complete value; `patch` preserves unspecified fields. Each
successful write creates a version. Rollback copies an older value into a new
version (v4 here), rather than deleting history. Soft deletion is reversible
with `undelete`; `destroy` permanently removes selected version data, and
`metadata delete` permanently removes every version and the key's metadata.
Neither destructive operation removes earlier copies from existing backups.

On **2026-10-18**, live CLI checks passed for create/read/list, replacement and
partial updates, metadata and historical reads, stale/missing CAS rejection,
rollback, latest/specific-version soft deletion and recovery, permanent version
destruction, and full-key cleanup. A temporary `login`-role SSO token received
HTTP `403` for KV data, listing, metadata, and deletion/recovery operations;
administrator access remained intact. Test keys and histories were removed,
the temporary token was revoked, and the cached administrator login was preserved.
That initial KV exercise added no production credentials or workload policies;
the later Cloudflare integration below uses a real credential.

### Kubernetes consumption

[External Secrets Operator](../kubernetes/external-secrets/README.md) connects
`lab-kubeadm` to this external Vault through the `kubernetes/` auth mount, using
short-lived service-account JWTs and TokenReview without a stored reviewer JWT.
Its initial namespace-scoped role can read only
`secret/data/kubernetes/vault-secrets/*`, with no default policy or write access.
The integration does not replace Gitea SSO or deploy another Vault server.

[cert-manager's Cloudflare credential](../kubernetes/cert-manager/README.md) now
lives at `secret/kubernetes/cert-manager/cloudflare-api-token`. A separate
`eso-cert-manager` role can read only that exact data key from
`cert-manager/vault-auth`; the demo role cannot access it. ESO maintains the
existing Kubernetes Secret, and the original SOPS-encrypted file remains a backup.

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
- [KV v2 API, versioning, CAS, and deletion](https://developer.hashicorp.com/vault/api-docs/secret/kv/kv-v2)
- [Raft snapshot operations](https://developer.hashicorp.com/vault/docs/commands/operator/raft#snapshot)
