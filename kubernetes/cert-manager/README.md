# Cloudflare credential in Vault

cert-manager reads Secret `cert-manager/cloudflare-api-token`, key `api-token`.
External Secrets Operator (ESO) now maintains that same Secret from KV v2 path
`secret/kubernetes/cert-manager/cloudflare-api-token`, property `api-token`.
The issuer and certificate manifests do not change.

`cloudflare-api-token.sops.yaml` remains an encrypted **backup**, not a second
active writer. Do not routinely apply it while ESO is reconciling. Ansible/lego's
separate inventory credential is unchanged; this migration does not rotate or
revoke the existing Cloudflare token.

## Set up or recover the integration

Run from the repository root. Install cert-manager using the
[application guide](../README.md#1-install-or-update-cert-manager), then install
[ESO and its shared Vault Kubernetes auth mount](../external-secrets/README.md)
(steps 1–2). You do not need the demo ExternalSecret. Use an authorized non-root
Vault administrator SSO session and the configured SOPS age identity.

### 1. Import the backup once

First confirm the SOPS backup contains the intended current token. On an
existing cluster, compare it privately with the live Secret before importing;
never print either value or use `kubectl diff` on the Secret. The initial live
migration checked equality in memory before making any change.

This pipeline authenticates/decrypts SOPS, decodes Kubernetes' base64 value, and
writes JSON through stdin. It does not create a plaintext file or put the token
in command arguments. Use Bash with `pipefail` and never enable shell tracing:

```bash
mise exec -- bash <<'SH'
set -euo pipefail
sops --decrypt --output-type json kubernetes/cert-manager/cloudflare-api-token.sops.yaml |
  python -c 'import base64,json,sys; s=json.load(sys.stdin); print(json.dumps({"api-token":base64.b64decode(s["data"]["api-token"],validate=True).decode()}))' |
  vault kv put -mount=secret -cas=0 kubernetes/cert-manager/cloudflare-api-token -
SH
```

Create-only CAS refuses to overwrite any existing Vault key. If it already
exists, verify it privately and skip the import if it matches. Do not remove
CAS or delete an existing key to make the command succeed.

### 2. Apply the dedicated Vault policy and role

```sh
mise exec -- vault policy write eso-cert-manager vault/kubernetes/eso-cert-manager.hcl
mise exec -- vault write auth/kubernetes/role/eso-cert-manager @vault/kubernetes/eso-cert-manager.json
```

Only `cert-manager/vault-auth` can use this role. It reads the **exact** Cloudflare
KV data path, not all of `secret/` or even the entire cert-manager prefix. It has
no default policy, metadata/list/write access, or administration. Own-token
lookup/renew/revoke is allowed. Tokens start at ten minutes with a one-hour hard
maximum. The demo `vault-secrets` role remains isolated from this credential.

### 3. Apply Kubernetes authentication and synchronization

```sh
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/cert-manager/vault-auth.yaml \
  -f kubernetes/cert-manager/secret-store.yaml
mise exec -- kubectl --context lab-kubeadm -n cert-manager wait secretstore/vault \
  --for=condition=Ready --timeout=120s
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/cert-manager/cloudflare-external-secret.yaml
mise exec -- kubectl --context lab-kubeadm -n cert-manager wait externalsecret/cloudflare-api-token \
  --for=condition=Ready --timeout=120s
```

The account can create TokenReviews using the existing `vault-tokenreviewer`
ClusterRole. ESO's TokenRequest permission is limited to the name `vault-auth`
in namespace `cert-manager`, not the cert-manager controller's service account.
The namespaced SecretStore uses both the Vault and Kubernetes API audiences;
no static Vault or reviewer token is stored.

ESO refreshes every minute. `creationPolicy: Orphan` updates the existing Secret
without setting an owner reference and creates it on a new cluster if absent.
`deletionPolicy: Retain` preserves it if the Vault source is deleted. Removing
the ExternalSecret also leaves the credential available for certificate renewal.
Vault outages stop refresh, but do not remove the last synchronized token.

Do not recursively apply this directory: it contains Helm values and an encrypted
backup. Do not delete the credential, ACME account, or TLS Secrets to test recovery.

## Rotation and backup

Vault is the active source. To rotate while keeping this SOPS backup current:

1. Prepare the replacement token with `Zone:DNS:Edit` and `Zone:Zone:Read` for
   `canhdinh.com`. Do not revoke the working token yet.
2. Privately update `data.api-token` (base64-encoded) with
   `mise exec -- sops kubernetes/cert-manager/cloudflare-api-token.sops.yaml`.
3. Read the current Vault version using `vault kv metadata get`, then use the
   import pipeline above with `-cas=0` replaced by that version. Stop on a CAS
   conflict rather than overwriting somebody else's update.
4. Wait for ESO's next refresh and privately verify that Vault, the backup, and
   the Kubernetes Secret match. Readiness alone does not prove the DNS API token
   can create a challenge. Validate the replacement before revoking the old one.
5. Run `mise run secrets:check` and commit the encrypted backup update.

The initial token is shared with lab services. Revoking it affects Ansible/lego
consumers too; migrate those separately before revocation. A Vault-only rotation
does not update SOPS automatically. Neither Vault nor ESO rotates the Cloudflare
token at the provider.

## Emergency SOPS fallback

If ESO or Vault cannot be recovered promptly, first stop reconciliation for this
credential, then restore the verified current encrypted backup. This does not
delete the existing target because it uses `Orphan`:

```bash
mise exec -- bash <<'SH'
set -euo pipefail
kubectl --context lab-kubeadm -n cert-manager delete externalsecret cloudflare-api-token --ignore-not-found --wait=true
sops --decrypt kubernetes/cert-manager/cloudflare-api-token.sops.yaml |
  kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps -f -
SH
```

Do not force ownership conflicts. If one occurs, investigate Secret field
ownership without displaying data. Restore the Vault source and readiness before
reapplying `cloudflare-external-secret.yaml`; otherwise ESO could overwrite the
fallback with a stale token. Retain the namespace/auth role/policy during a
temporary fallback. A fresh-cluster recovery can also use this pipeline to
bootstrap cert-manager before ESO is available.

## Verify without exposing credentials

```sh
mise exec -- kubectl --context lab-kubeadm -n cert-manager get secretstore,externalsecret
mise exec -- kubectl --context lab-kubeadm get clusterissuer letsencrypt-cloudflare
mise exec -- kubectl --context lab-kubeadm -n kube-system get certificates
```

Local credential-free contracts run from `ansible/`:

```sh
mise exec -- ansible-playbook -i localhost, tests/external-secrets.yml
mise exec -- ansible-playbook -i localhost, tests/kubernetes-manifests.yml
```

See [ESO target lifecycle semantics](https://external-secrets.io/latest/api/externalsecret/)
and the [shared integration's security notes](../external-secrets/README.md#access-boundaries).

### Verified migration

On **2026-10-18**, the token was imported with create-only CAS and the dedicated
SecretStore and ExternalSecret both reported `Ready=True`. Private comparisons
confirmed that Vault, SOPS, and Kubernetes contained the same token; the encrypted
backup was byte-for-byte unchanged. The existing Cloudflare, ACME account, Hubble,
and Argo CD TLS Secrets retained their UIDs and contents. The issuer and both
Certificates remained ready. ESO's normal periodic refresh also succeeded.

Live checks verified exact-key read-only access, denial of the token to the demo
role, rejection of cross-namespace role logins, and the scoped TokenRequest grant.
Temporary login tokens and test resources were cleaned up. The SOPS fallback
passed a server dry run with the historical field manager. No certificate was
reissued and no Cloudflare credential was rotated or revoked.
