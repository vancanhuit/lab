# Argo CD SSO credential in Vault

External Secrets Operator (ESO) maintains Secret `argocd/argocd-gitea-oidc`, key
`client-secret`, from Vault KV v2 path `secret/kubernetes/argocd/gitea-oidc`.
The credential belongs to Gitea's confidential web client; the public CLI client
has no secret. Manage client IDs, PKCE, scopes, Argo RBAC in `values.yaml`, and
registered callback URLs through the [SSO runbook](README.md#gitea-sso).

Keep `gitea-oidc.sops.yaml` as an encrypted backup; ESO is the active writer.
Argo still uses `$argocd-gitea-oidc:client-secret`. ESO copies the ExternalSecret's
`app.kubernetes.io/part-of: argocd` label onto the target Secret so Argo can discover
the credential. Both this mapping and Cloudflare's omit the target template, so
ESO also copies Argo's tracking annotation. Argo displays the generated Secret
while ESO controls its data. Secret values stay out of Helm release history.

## Setup or recovery

Run from the repository root after creating namespace `argocd` in
[installation step 2](README.md#2-install-or-update-argo-cd). Install
[ESO and the shared Vault Kubernetes auth mount](../external-secrets/README.md)
(steps 1 and 2); the demo ExternalSecret is not required. Use a non-root Vault
administrator SSO session and the configured SOPS age identity.

The [Vault integrations Application](README.md#vault-integrations-application)
tracks these Kubernetes manifests. Use the commands below for bootstrap or
recovery. After adoption, edit manifests in Git and sync through Argo. Manage
Vault values and the encrypted backup separately.

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

The pipeline decrypts and authenticates SOPS, decodes Kubernetes base64, and
writes JSON through stdin. Create-only check-and-set (CAS) refuses to overwrite an existing Vault key.
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

Only `argocd/vault-auth` can assume `eso-argocd`. The policy allows reads from the
exact `secret/data/kubernetes/argocd/gitea-oidc` path and own-token lookup/renew/revoke.
It denies writes, metadata listing, Cloudflare/demo reads, and Vault administration.
Tokens have no default policy, start at ten minutes, and have a one-hour hard maximum.

ESO can request JWTs only for that named account in `argocd`; it cannot request
tokens for Argo's server/controller accounts. The account uses the existing
TokenReview ClusterRole. The integration stores no static Vault or reviewer token.

Synchronization runs every minute. `creationPolicy: Orphan` updates the existing
Secret in place, creates it if absent, and leaves it when the ExternalSecret is
deleted. `deletionPolicy: Retain` also retains it if the Vault source disappears.
During Vault outages, existing SSO uses the last synchronized credential while
refresh stops. Copying an unchanged value into this mapping requires no Argo restart.
Do not recursively apply the directory: it also contains Helm values and backups.

## Rotation

Follow [web client rotation](README.md#rotate-the-web-client-secret). After Gitea
regenerates the value, privately edit `data.client-secret` (base64-encoded) with
`mise exec -- sops kubernetes/argocd/gitea-oidc.sops.yaml`. Read the current Vault
version using `vault kv metadata get`, then run the import pipeline with `-cas=0`
replaced by that version. Stop on CAS conflicts. Verify that ESO has synchronized
the new value before the documented Argo API-server restart and a fresh web
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

Do not sync the Vault integrations Application during fallback: a manual sync
can recreate the ExternalSecret and overwrite the restored value. Confirm the
intended Vault value before resuming Argo syncs.

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

Require `Ready=True` on the SecretStore and ExternalSecret and an advancing
refresh time. The target Secret must retain its discovery label and have no
owner reference. Updating an existing installation should preserve its UID.

Verify that `eso-argocd` has exact-key read-only access and no default policy.
The demo and cert-manager roles must not read this key, and cross-namespace role
logins must fail. Remove temporary test Secrets and revoke test tokens afterward.
Rehearse emergency fallback with a server dry run before an outage, without
displaying Secret data.
