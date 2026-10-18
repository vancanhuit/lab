# External Secrets Operator with external Vault

External Secrets Operator (ESO) 2.13.0 connects `lab-kubeadm` to Vault at
https://vault.lab.canhdinh.com. Vault runs in an external LXC; this integration
leaves its Gitea SSO configuration unchanged. Helm bootstraps the operator, then
the [Argo CD Application](../argocd/README.md#external-secrets-operator-application)
manages the same chart and values through manual syncs. The separate
[Vault integrations Application](../argocd/README.md#vault-integrations-application)
manages authentication and secret-mapping manifests. Ansible manages neither
the operator nor these integration resources.

[cert-manager](../cert-manager/README.md) has a separate SecretStore, service
account binding, and exact-key Vault role for its Cloudflare credential.
[Argo CD](../argocd/vault-secrets.md) has its own equivalent integration for the
confidential Gitea web client secret. The roles cannot read each other's keys.

## Access boundaries

The integration limits Vault access by namespace and service account:

- The Helm release and its three controller Deployments live in `external-secrets`.
- `vault-secrets/vault` is a namespaced SecretStore. Only
  ExternalSecrets in `vault-secrets` can reference it.
- ESO can request short-lived JWTs for `vault-secrets/vault-auth`,
  `cert-manager/vault-auth`, and `argocd/vault-auth` through namespace-scoped Roles.
  The chart's cluster-wide `serviceaccounts/token` permission is disabled; each
  namespaced Role grants this capability for its named account only.
- Vault's `kubernetes/` auth mount accepts role `eso-vault-secrets` only for that
  service account and namespace. Identity aliases use the service-account UID.
- The Vault policy reads only `secret/data/kubernetes/vault-secrets/*`, plus
  own-token lookup/renew/revoke. It grants no writes, metadata/list access,
  administration, or cubbyhole access. Tokens have no default policy, start at
  ten minutes, and have a hard one-hour maximum.
- Client JWTs double as TokenReview credentials. The service account can only
  create `authentication.k8s.io/tokenreviews`, not SubjectAccessReviews. No
  static Vault token, long-lived reviewer JWT, or service-account-token Secret is
  stored. Vault validates tokens with the private Kubernetes API over trusted TLS.

The JWT requests both `vault` and the API audience
`https://kubernetes.default.svc.cluster.local`. Vault requires the former; the
API requires the latter when the JWT authenticates the TokenReview request.
Do not remove either without changing the authentication design. Vault's HTTPS
certificate is publicly trusted; there is no TLS verification bypass or custom
Vault CA Secret. The Kubernetes API uses its own public cluster CA certificate.

Cluster-wide stores, cluster external secrets, cluster generators, and push
secrets are disabled. Namespaced generator CRDs still ship with the upstream
chart but are not used by this integration. ESO itself retains upstream
cluster-wide Kubernetes Secret permissions: treat its service account and
Deployment as privileged infrastructure. Anyone able to run Pods as `vault-auth`,
mint its tokens, or edit this namespace's ESO resources can potentially access
the authorized Vault prefix. A namespace is the workload trust boundary.

## 1. Bootstrap ESO with Helm

Run from the repository root with `lab-kubeadm` access. The official OCI chart
is pinned by version and digest, and Helm retains CRDs on uninstall. Use this
Helm procedure only before Argo adoption. The lab adopted ESO into Argo on
2026-10-18; make subsequent chart changes through Git and manual Argo syncs.
Do not alternate Helm upgrades and Argo syncs.

```sh
mise exec -- helm --kube-context lab-kubeadm upgrade --install external-secrets \
  oci://ghcr.io/external-secrets/charts/external-secrets@sha256:77744a13f72022d9193556df4b7e9d338ba281553a0cef31f6a8ec9924425e65 \
  --version 2.13.0 --namespace external-secrets --create-namespace \
  --values kubernetes/external-secrets/values.yaml --wait --timeout 5m
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/external-secrets/vault-auth.yaml
```

The authentication manifest creates namespace `vault-secrets`, its dedicated
service account, the TokenReview grant, and ESO's scoped TokenRequest grant.
Do not recursively apply this directory: the optional example needs a source
secret. To register the running operator without changing it, apply the
[ESO Application](../argocd/README.md#external-secrets-operator-application).
Use the separate [Vault integrations Application](../argocd/README.md#vault-integrations-application)
for the authentication resources, stores, and real credential mappings. Its
allowlist excludes this directory's optional dummy example. Use the Kubernetes
commands below for bootstrap or recovery. After adoption, edit the selected
manifests in Git and sync through Argo. Manage Vault configuration separately
with the Vault CLI.

## 2. Configure Vault Kubernetes authentication

Use an authorized [administrator SSO session](../../vault/README.md#sign-in),
not the root token. Enable the auth mount once on a fresh instance:

```sh
mise exec -- vault auth list
mise exec -- vault auth enable -path=kubernetes -description="lab-kubeadm service accounts" kubernetes
```

Skip enablement if `kubernetes/` already has type `kubernetes`. Do not disable an
existing mount to reapply configuration: that revokes its issued Vault tokens.
This mount is dedicated to `lab-kubeadm`; a second cluster needs its own mount.

Apply the public API CA, policy, and bound role. The CA pipeline contains no
credentials and does not copy the administrator kubeconfig into Vault. Vault
must reach `k8s-control-plane.lab.canhdinh.com:6443`; Pods must resolve and reach
Vault on TCP 443. The integration needs no new Gateway, public listener, or DNS record.

```bash
mise exec -- bash <<'SH'
set -euo pipefail
kubectl --context lab-kubeadm -n kube-public get configmap kube-root-ca.crt \
  -o 'jsonpath={.data.ca\.crt}' |
  vault write auth/kubernetes/config \
    kubernetes_host=https://k8s-control-plane.lab.canhdinh.com:6443 \
    disable_local_ca_jwt=true kubernetes_ca_cert=-
vault policy write eso-vault-secrets vault/kubernetes/eso-vault-secrets.hcl
vault write auth/kubernetes/role/eso-vault-secrets @vault/kubernetes/eso-vault-secrets.json
SH
```

Leave `token_reviewer_jwt` unset. When adopting an existing configuration, check
`token_reviewer_jwt_set` first and investigate any stored reviewer credential
before clearing it. Reapply the public CA after cluster CA replacement. When
rebuilding the cluster, check the API endpoint and audience; do not copy old
service-account tokens.

## 3. Apply the SecretStore

```sh
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/external-secrets/secret-store.yaml
mise exec -- kubectl --context lab-kubeadm -n vault-secrets wait secretstore/vault \
  --for=condition=Ready --timeout=120s
```

For another application namespace, add its own service account, explicit
TokenRequest Role/RoleBinding, TokenReview binding, Vault policy/role with a
different namespace and KV prefix, and same-namespace SecretStore. Do not
broaden this role to wildcard service accounts, namespaces, or all KV data.
The policy deliberately does not support `dataFrom.find` or listing source keys.

## 4. Optional dummy-data example

`example.yaml` maps two fields from Vault key
`secret/kubernetes/vault-secrets/example` into Kubernetes Secret
`vault-secrets/vault-example`. It refreshes every minute and owns that target
Secret. ESO retains the target if the source temporarily disappears. Deleting
the ExternalSecret owner deletes the target Secret.

Use only dummy values below. First ensure neither the example key nor the
example Kubernetes resources are somebody else's existing data. Create-only
CAS refuses to overwrite a pre-existing Vault key; stop if it fails.

```sh
mise exec -- vault kv put -mount=secret -cas=0 kubernetes/vault-secrets/example \
  username=demo-user password=dummy-sync-v1
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/external-secrets/example.yaml
mise exec -- kubectl --context lab-kubeadm -n vault-secrets wait externalsecret/vault-example \
  --for=condition=Ready --timeout=120s
mise exec -- kubectl --context lab-kubeadm -n vault-secrets get secretstore,externalsecret,secret
mise exec -- vault kv put -mount=secret -cas=1 kubernetes/vault-secrets/example \
  username=demo-user password=dummy-sync-v2
```

Allow the next periodic refresh to run. Inspect readiness and refresh time with
`kubectl describe externalsecret`, not unfiltered Secret YAML or controller debug
logs. For real credentials, write JSON into Vault through stdin from a protected
source, never command arguments or plaintext repository files.

Remove only the demo resources you created. The first command garbage-collects
the owned Kubernetes Secret; the second permanently deletes all demo versions:

```sh
mise exec -- kubectl --context lab-kubeadm -n vault-secrets delete externalsecret vault-example --wait=true
mise exec -- vault kv metadata delete -mount=secret kubernetes/vault-secrets/example
```

Synced values are ordinary Kubernetes Secrets. Protect Kubernetes RBAC, etcd,
and backups; ESO does not add etcd encryption. Secret updates do not restart
workloads. Applications using environment variables need a controlled restart;
file-mounted secrets need application reload support. If Vault is sealed or
unreachable, existing target Secrets remain, but synchronization and rotation
stop. Revoking source access does not erase already synchronized credentials.

## Verification and recovery

Local chart, RBAC, role, and policy contracts need registry access but no cluster
or credentials. They run in `mise run ansible:test`. For a focused run, use the
following from `ansible/`:

```sh
mise exec -- ansible-playbook -i localhost, tests/external-secrets.yml
```

For live inspection without printing secret values:

```sh
mise exec -- helm --kube-context lab-kubeadm status external-secrets -n external-secrets
mise exec -- kubectl --context lab-kubeadm -n external-secrets get deployments,pods
mise exec -- kubectl --context lab-kubeadm -n vault-secrets get secretstore,externalsecret
```

After Argo adoption, Helm status shows only the bootstrap release record. Check
the ESO Application for the managed chart's current sync and health status.

If readiness fails, inspect the SecretStore/ExternalSecret conditions and Events,
then check Vault seal state, trusted DNS/TLS, audience, bound service account,
TokenRequest/TokenReview RBAC, and source path. Do not print JWTs or client tokens
or disable TLS validation as a workaround. Issued Vault tokens are independent
of their login JWT: removing a Kubernetes credential does not revoke previously
issued Vault tokens, which must be revoked separately or expire.

Before upgrades, back up ESO resources and encrypt any Secret backups. If an
upgrade fails before Argo adoption, inspect Helm status and retry or roll back to
the previous known revision with its matching values. After adoption, revert
the chart digest/values in Git and manually sync Argo instead; the Helm release
history does not track Argo changes. Do not delete CRDs to fix reconciliation.
To remove this integration deliberately, stop its ExternalSecrets first and
decide whether their target Secrets should be retained before deleting owners.
Then remove the dedicated SecretStore/RBAC, Vault role, and policy only after
confirming no consumers depend on them. Never disable the shared KV mount.

### Verified deployment

On 2026-10-18, Helm installed release `external-secrets`, revision 1,
chart/app 2.13.0. All three Deployments were ready, and SecretStore
`vault-secrets/vault` reported `Ready=True`. A dummy two-field Vault secret
synced into an owned Kubernetes Secret; the normal one-minute refresh propagated
a new Vault version without replacing the target Secret's UID.

Direct Kubernetes login verified the ten-minute TTL, absence of the default
policy, and read-only KV prefix. Vault denied writes, other prefixes,
metadata/list access, administration, token creation, and cubbyhole access.
It rejected wrong service accounts and Vault audiences. A JWT bound to a deleted
test Secret failed after approximately ten seconds of TokenReview propagation;
do not rely on instantaneous credential revocation.

Cleanup removed the example ExternalSecret and owned Secret, dummy Vault keys
and all versions, and token-bound test Secrets. Temporary Vault login tokens
were revoked. The operator, RBAC, namespace, Vault auth/policy/role, and
SecretStore stayed configured; the example was not left running.

At that point, the CLI had a refreshed non-root administrator SSO session.
This initial deployment migrated no existing application credentials and did
not restart or reseal Vault. The later credential migrations and Argo adoption
are recorded in the linked application guides.

## References

- [ESO installation](https://external-secrets.io/latest/introduction/getting-started/)
- [ESO Vault provider and Kubernetes authentication](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [ESO security boundaries](https://external-secrets.io/latest/guides/security-best-practices/)
- [Vault Kubernetes authentication and client-JWT reviewers](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Kubernetes auth API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
