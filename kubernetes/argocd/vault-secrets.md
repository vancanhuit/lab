# Argo CD SSO credential in Vault

ESO maintains Secret `argocd/argocd-gitea-oidc`, key `client-secret`, from Vault
KV v2 path `secret/kubernetes/argocd/gitea-oidc`. This is Gitea's confidential
**web** client credential; the public CLI client has no secret to migrate.
Client IDs, PKCE, scopes, and Argo RBAC in `values.yaml` are unchanged, as are the
registered callback URLs.

`gitea-oidc.sops.yaml` remains an encrypted **backup**, not an active second writer.
The existing `$argocd-gitea-oidc:client-secret` reference is preserved. The
ExternalSecret has label `app.kubernetes.io/part-of: argocd`, which ESO inherits
onto the target Secret so Argo can discover the credential. Like Cloudflare's
mapping, it deliberately has no target template: ESO also inherits Argo's
tracking annotation, making the generated Secret visible without putting its
data under Argo management. No secret value enters Helm release history.

## Setup or recovery

Run from the repository root after creating namespace `argocd` in
[installation step 2](README.md#2-install-or-update-argo-cd). Install
[ESO and the shared Vault Kubernetes auth mount](../external-secrets/README.md)
(steps 1–2); the demo ExternalSecret is not required. Use a non-root Vault
administrator SSO session and the configured SOPS age identity.

The [Vault integrations Application](README.md#vault-integrations-application)
tracks these Kubernetes manifests. The commands below remain bootstrap/recovery
procedures; after adoption, use Git/manual Argo sync for routine manifest changes.
Vault values and the encrypted backup remain operator-managed.

### 1. Import the encrypted backup once

On an existing deployment, first privately compare the backup with the live
Secret; stop if they differ. Never print credentials or run Secret diffs.
Use Bash with `pipefail`, without shell tracing, `tee`, or plaintext files:

```bash
mise exec -- bash <<'SH'
set -euo pipefail
sops --decrypt --output-type json kubernetes/argocd/gitea-oidc.sops.yaml |
  python -c 'import base64,json,sys; s=json.load(sys.stdin); print(json.dumps({"client-secret":base64.b64decode(s["data"]["client-secret"],validate=True).decode()}))' |
  vault kv put -mount=secret -cas=0 kubernetes/argocd/gitea-oidc -
SH
```

The pipeline decrypts/authenticates SOPS, decodes Kubernetes base64, and writes
JSON through stdin. Create-only CAS refuses to overwrite an existing Vault key.
If the key already exists, privately verify it and skip import if it matches;
do not remove CAS or delete the key to force the import.

### 2. Configure the dedicated role and SecretStore

```sh
mise exec -- vault policy write eso-argocd vault/kubernetes/eso-argocd.hcl
mise exec -- vault write auth/kubernetes/role/eso-argocd @vault/kubernetes/eso-argocd.json
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/argocd/vault-auth.yaml -f kubernetes/argocd/secret-store.yaml
mise exec -- kubectl --context lab-kubeadm -n argocd wait secretstore/vault \
  --for=condition=Ready --timeout=120s
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/argocd/gitea-oidc-external-secret.yaml
mise exec -- kubectl --context lab-kubeadm -n argocd wait externalsecret/argocd-gitea-oidc \
  --for=condition=Ready --timeout=120s
```

Only `argocd/vault-auth` can assume `eso-argocd`. Its policy reads the exact
`secret/data/kubernetes/argocd/gitea-oidc` path, plus own-token lookup/renew/revoke.
It cannot write, list metadata, read the Cloudflare/demo paths, or administer Vault.
It has no default policy. Tokens start at ten minutes with a one-hour hard maximum.
ESO can request JWTs only for that named account in `argocd`, not for the Argo
server/controller accounts. The account uses the existing TokenReview ClusterRole;
no static Vault or reviewer token is stored.

Synchronization runs every minute. `creationPolicy: Orphan` updates the existing
Secret in place, creates it if absent, and leaves it when the ExternalSecret is
deleted. `deletionPolicy: Retain` also retains it if the Vault source disappears.
Vault outages stop refresh, not existing SSO access with the last synchronized
credential. This migration copies the same value, so it requires no Argo restart.
Do not recursively apply the directory: it also contains Helm values and backups.

## Rotation

Follow [web client rotation](README.md#rotate-the-web-client-secret). After Gitea
regenerates the value, privately edit `data.client-secret` (base64-encoded) with
`mise exec -- sops kubernetes/argocd/gitea-oidc.sops.yaml`. Read the current Vault
version using `vault kv metadata get`, then run the import pipeline with `-cas=0`
replaced by that version. Stop on CAS conflicts. Verify that ESO has synchronized
the new value before the documented Argo API-server restart and a fresh **web**
login. CLI login alone does not exercise this confidential credential.

Gitea regeneration immediately invalidates the old secret, so new web logins can
fail during propagation/reload. Keep the separate local-admin recovery path
available. A stale SOPS backup cannot restore a credential Gitea has invalidated.
Vault/ESO does not rotate provider credentials or update the SOPS backup
automatically. Run `mise run secrets:check` and commit encrypted backup changes.

## Emergency SOPS fallback

Verify the backup still matches the active Gitea application. Stop this one
ExternalSecret before restoring SOPS, so it cannot overwrite the fallback:

```bash
mise exec -- bash <<'SH'
set -euo pipefail
kubectl --context lab-kubeadm -n argocd delete externalsecret argocd-gitea-oidc --ignore-not-found --wait=true
sops --decrypt kubernetes/argocd/gitea-oidc.sops.yaml |
  kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps -f -
SH
```

`Orphan` preserves the target Secret when synchronization is removed. Do not force
ownership conflicts or delete `argocd-secret`, Applications, TLS Secrets, or Helm
releases. If restoring a different value, complete the documented API-server
restart and fresh web login. Restore the matching Vault source and ready
SecretStore before reapplying `gitea-oidc-external-secret.yaml`. Retain the
dedicated identity, role, and policy during a temporary fallback.

## Verification

```sh
mise exec -- kubectl --context lab-kubeadm -n argocd get secretstore,externalsecret
mise exec -- argocd account get-user-info --argocd-context lab-argocd-sso
mise exec -- argocd account can-i sync applications 'default/*' --argocd-context lab-argocd-sso
```

Privately compare Vault/SOPS/Kubernetes values, verify the discovery label and
existing Secret UID, and perform a fresh web SSO login. Do not print Secret YAML,
JWTs, cookies, or tokens. Local contracts run from `ansible/` with
`mise exec -- ansible-playbook -i localhost, tests/external-secrets.yml` and
`mise exec -- ansible-playbook -i localhost, tests/kubernetes-manifests.yml`.

### Verified migration

On **2026-10-18**, the credential was imported with create-only CAS. The dedicated
SecretStore and ExternalSecret reported `Ready=True`, and a normal periodic
refresh succeeded. Private comparisons confirmed matching Vault, Kubernetes, and
SOPS values; the encrypted backup was byte-for-byte unchanged. The OIDC Secret
kept its UID and discovery label without an owner reference. Argo's other protected
credentials, Cloudflare/ACME and TLS Secrets, SSO/RBAC ConfigMaps, and Pod identities
and restart counts were unchanged.

A fresh web SSO login completed as `vancanhuit@gmail.com` with the Gitea issuer,
exercising the confidential web client. The existing CLI SSO session also remained
valid. Live policy checks confirmed exact-key read-only access, no default policy,
isolation from the demo and cert-manager roles, and rejection of all cross-namespace
role assumptions. Temporary Vault tokens and test Secrets were cleaned up.
The emergency SOPS fallback passed a server dry run with the historical field
manager. No provider credential was rotated and no Argo restart or Helm upgrade
was needed.
