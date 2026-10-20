# Argo CD

Deploy Argo CD at https://argocd.lab.canhdinh.com/ with the official
`argo-cd` Helm chart 10.10.5 (Argo CD v3.5.5), pinned by OCI digest below.
The non-HA installation runs in namespace `argocd` and uses Gitea OpenID Connect
(OIDC) for single sign-on (SSO). The [ESO Application](#external-secrets-operator-application)
tracks the External Secrets Operator deployment. [Vault integrations](#vault-integrations-application)
tracks its credential mappings and authentication resources. Both Applications
use public sources without repository credentials.

The [cert-manager, Gateway, and Hubble UI Applications](#cert-manager-gateway-and-hubble-ui-applications)
track the existing certificate controller, issuer, shared Gateway, and Hubble
routing/TLS configuration. Cilium retains the Hubble UI and Relay workloads.

`mise install` installs the matching Argo CD CLI 3.5.5. Run commands from the
repository root after the [cluster and cert-manager setup](../README.md).
Adding these files to Git does not deploy Argo CD; run the installation commands below.

## DNS and traffic

Create a private DNS CNAME:

```text
argocd.lab.canhdinh.com -> k8s-gateway-api.lab.canhdinh.com
```

Traffic follows HAProxy TCP passthrough and Proxy Protocol v2 to the existing
edge-node Envoy listeners. The shared Gateway is `kube-system/lab-gateway`, with
separate hostname-specific listeners for each app.
Do not create another Gateway on ports 80/443.

TLS terminates at Envoy using `kube-system/argocd-tls`. The Argo CD API server
uses HTTP on its internal ClusterIP (`server.insecure: true`); this avoids a
backend HTTPS redirect loop and leaves login enabled. The Gateway admits
Argo routes only from the `argocd` namespace. Hubble's listeners remain restricted
to `kube-system`. No cross-namespace Secret grant is needed because
the Certificate and Gateway both live in `kube-system`.

Cilium must have `gatewayAPI.enableAppProtocol: true`, as configured in the
Ansible Cilium values template. Its gRPC-Web filter converts CLI requests into
native gRPC, so the Helm-owned HTTPRoute sends `application/grpc*` requests to
the Service's HTTP/2 port `8080` (`appProtocol: kubernetes.io/h2c`). Browser and
REST requests continue to use HTTP/1 on port `80`. One HTTPRoute handles both;
no overlapping GRPCRoute or new external port is needed. The chart's built-in
HTTPRoute fixes all backends to port 80, so `extraObjects` supplies this route
under Helm ownership.

## 1. Prepare certificates and the shared Gateway

Apply both frontend certificates before the shared `kube-system/lab-gateway`
Gateway. Update existing certificate resources in place.

These apply commands are for bootstrap/recovery. After adopting the Gateway and
Hubble configuration into Argo, change those resources through Git and manual
syncs. Argo CD's own Certificate remains an explicit manifest.

```sh
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/hubble-ui/certificate.yaml \
  -f kubernetes/argocd/certificate.yaml
kubectl --context lab-kubeadm -n kube-system wait certificate/hubble-ui certificate/argocd \
  --for=condition=Ready --timeout=600s
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/gateway/gateway.yaml
kubectl --context lab-kubeadm -n kube-system wait gateway/lab-gateway \
  --for=condition=Programmed --timeout=180s
```

`certificate.yaml` uses the existing `letsencrypt-cloudflare` ClusterIssuer and
ECDSA P-256 with automatic key rotation. Hubble and Argo routes select their
hostname-specific listeners on the shared Gateway.

## 2. Install or update Argo CD

Before updating an existing release, keep Kubernetes administrator access and a
working local-admin recovery login available. Back up Argo resources and encrypt
any Secret backups. Record the deployed Helm revision and its matching Git values
for rollback:

```sh
helm --kube-context lab-kubeadm history argocd --namespace argocd
```

The [Gitea OAuth applications](#gitea-sso) must exist before using these values.
Create the namespace on a fresh cluster:

```bash
set -euo pipefail
kubectl --context lab-kubeadm create namespace argocd --dry-run=client -o yaml |
  kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps -f -
```

Then follow the [Vault credential setup](vault-secrets.md) to import the retained
SOPS backup once and configure the dedicated ESO role, SecretStore, and
ExternalSecret. Wait for the ExternalSecret to be ready before installing Argo.
Do not routinely apply `gitea-oidc.sops.yaml`; it is now a backup, not a second writer.

```sh
helm --kube-context lab-kubeadm upgrade --install argocd \
  oci://ghcr.io/argoproj/argo-helm/argo-cd@sha256:89429c1de7a63860df9092464d97e6ad34c263c834b457a379dc9f866c63d612 \
  --version 10.10.5 --namespace argocd --create-namespace \
  --values kubernetes/argocd/values.yaml --wait --timeout 5m
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/argocd/redirect.yaml
```

Helm owns the Argo CD workloads, RBAC, CRDs, and HTTPS HTTPRoute to
`argocd-server:80` (UI/REST) or `argocd-server:8080` (RPC).
`redirect.yaml` redirects HTTP to HTTPS. The SSO credential is a separate
Vault-sourced, ESO-managed Secret, not a Helm value or part of Helm release history.
Uninstall can remove resources even when CRDs are retained. Back up Argo CD
resources and Secrets before upgrades. Check an Application's finalizer before
deleting it: the finalizer may delete the workloads it manages.

## 3. Verify and log in

```sh
kubectl --context lab-kubeadm -n argocd get pods,services,httproutes
kubectl --context lab-kubeadm -n argocd describe httproute argocd-server argocd-redirect
curl --ipv4 --noproxy '*' --fail https://argocd.lab.canhdinh.com/
```

Require ready Pods, `Accepted=True` and `ResolvedRefs=True` on both routes, trusted
HTTPS, and HTTP redirection to HTTPS. Anonymous application API requests must
return `401`. Check Hubble UI as well because both applications share the Gateway.

For normal access, open the UI and choose **Log in via Gitea**, or use the
[SSO CLI command](#cli-login). Verify the expected subject-based permissions in
both the web and CLI sessions after an update.

The local `admin` account is the recovery path. On a fresh installation, retrieve
its generated initial password **only in a private, unrecorded terminal**;
this command prints a secret:

```sh
kubectl --context lab-kubeadm -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

Rotate the admin password after first login, then delete the initial-password
Secret. For the pinned CLI, use gRPC-Web on the same host:

```sh
mise exec -- argocd login argocd.lab.canhdinh.com --grpc-web --skip-test-tls \
  --username admin --name lab-argocd
mise exec -- argocd account get-user-info --argocd-context lab-argocd
mise exec -- argocd app list --argocd-context lab-argocd
mise exec -- argocd proj list --argocd-context lab-argocd
mise exec -- argocd cluster list --argocd-context lab-argocd
```

Enter the password at the hidden prompt, not with `--password` or a shell-history
literal. `--skip-test-tls` skips the CLI's initial TLS-detection probe, which can
hang behind this Gateway. Certificate verification remains enabled. Do not add
`--insecure` or `--plaintext`. The saved CLI context enables gRPC-Web for later
commands. Keep `~/.config/argocd/config` at mode `0600` because it stores a session
token. Log in again when the session expires or is invalidated.

An unused in-cluster target reports `Unknown` until an Application uses it;
check actual application health before diagnosing a connectivity failure.

Keep the HAProxy lab/Tailscale allowlist and Tailscale ACLs in place. Argo CD has
cluster-wide permissions; restrict AppProjects before allowing untrusted
repositories or users to deploy applications. Only the client-to-Gateway leg is
TLS-encrypted; the Gateway-to-server leg uses the trusted cluster network.

After a version upgrade passes these checks, remove its temporary encrypted
resource backups and staging files by their recorded paths. Keep the SOPS
credential backups and Helm release records used by ongoing operations.

## External Secrets Operator application

After Argo CD and [ESO](../external-secrets/README.md) are installed, register
the existing operator for drift and health tracking:

```sh
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/argocd/applications/external-secrets.yaml
mise exec -- argocd app get external-secrets --hard-refresh --argocd-context lab-argocd-sso
```

The Application uses the existing release name and namespace `external-secrets`,
the exact ESO 2.13.0 OCI digest, and `kubernetes/external-secrets/values.yaml` from
`main` in the public GitHub repository. Its Git source has no `path` and supplies
only Helm values. Argo therefore excludes Vault authentication resources,
ExternalSecrets, examples, and SOPS backups from this Application.

Push values changes to `main` before syncing. Apply the Application manifest
explicitly; no app-of-apps manages it.

Automatic sync, self-healing, and pruning are off. Registration alone leaves ESO
unchanged. Review Argo's diff before a manual sync; Helm-installed resources may
be `OutOfSync` until adoption. Manual sync uses server-side apply (SSA) to avoid
the client-side last-applied annotation size limit on large CRDs. Do not use
Replace, Force, or pruning to resolve adoption differences. Never delete ESO CRDs.

After the first manual sync, use Argo for all routine chart-resource changes.
Argo uses Helm to render the chart, but does not update the old Helm release
record. Do not alternate Helm upgrades/rollbacks and Argo syncs. The Application
has no deletion finalizer; remove it without cascading to stop tracking. Choose
cascading deletion only when deliberately uninstalling this shared operator.

After registration, require Healthy status and no comparison errors. Review any
OutOfSync resources before adoption. After an intended manual sync, require
Synced / Healthy and ready ESO Deployments. Check that credential Secrets and
CRDs retain their identities; do not sync merely to verify registration.

References: [OCI digest sources](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/oci/)
and [Git-hosted Helm values](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/multiple_sources/).

## Vault integrations application

`applications/vault-integrations.yaml` tracks the integration separately from
the ESO operator chart. Its recursive directory source selects eight existing
files: `vault-auth.yaml` and `secret-store.yaml` in `external-secrets/`, `argocd/`,
and `cert-manager/`, plus the Argo OIDC and Cloudflare ExternalSecrets.

The files define 19 resources: the demo namespace, three dedicated service
accounts, the shared TokenReview role and bindings, scoped TokenRequest grants,
three SecretStores, and two ExternalSecrets. Each namespaced resource specifies
its namespace; the Application defaults to `vault-secrets`.

The allowlist excludes generated Kubernetes Secrets, SOPS backups, the optional
dummy example, Helm values, and application/operator workloads. Manage Vault
policies, authentication roles, and source values separately through the Vault CLI.

```sh
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/argocd/applications/vault-integrations.yaml
mise exec -- argocd app get vault-integrations --hard-refresh --argocd-context lab-argocd-sso
```

Registration leaves existing resources unchanged. Automatic sync, self-healing,
and pruning are off, and the Application has no deletion finalizer. Review the
diff before a manual sync. After adoption, edit the selected manifests in Git
and sync through Argo; stop using routine `kubectl apply` for those resources.

During emergency SOPS fallback, remove the affected ExternalSecret to stop ESO
writes. Argo will not recreate it automatically. Restore Vault's intended value
before manually syncing again. Never prune the namespace or authentication
resources to troubleshoot. Remove the Application without cascading to stop tracking.

Argo CD 3.5.5's bundled health checks map `Ready=True` to Healthy and
`Ready=False` to Degraded for both SecretStore and ExternalSecret. Sync status
tracks Git mappings; Vault manages secret values and history. ESO alone writes
target Secret data.

Both real ExternalSecrets omit the target template, so ESO copies their labels
and annotations onto the generated Secrets. This includes Argo's tracking ID and
the OIDC discovery label. The copied tracking ID identifies the ExternalSecret,
so Argo displays each generated Secret at the top level without comparing its
data, affecting sync status, or marking it for pruning. Both mappings keep
`Orphan`/`Retain`, and their Secrets have no owner references. Do not add Secret
manifests or self-referencing tracking IDs to make generated Secrets visible.

After registration, check that Argo selects exactly the 19 allowlisted resources
and reports no comparison errors. After an intended sync, require Synced / Healthy,
three ready SecretStores, and two ready ExternalSecrets. Confirm the generated
credential Secrets are visible, retain their UIDs, and privately match Vault.
Automatic sync and pruning must remain off.

See [directory allowlists](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/directory/)
and [resource health](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/health/),
plus [copied tracking annotations](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/resource_tracking/#non-self-referencing-annotations).

## cert-manager, Gateway, and Hubble UI applications

Register these Applications after the services are running. Each Application
selects the resources listed below:

| Application | Desired resources | Excluded resources |
| --- | --- | --- |
| `cert-manager` | Existing v1.21.2 OCI chart/digest and Git-hosted values, plus `cert-manager/issuer.yaml` | Vault authentication, SecretStore, ExternalSecret, SOPS backup, generated Secrets |
| `gateway` | Only `gateway/gateway.yaml`, defining `kube-system/lab-gateway` | GatewayClass, Gateway API CRDs, generated Envoy resources, Cilium, HAProxy, node firewalls |
| `hubble-ui` | Only `hubble-ui/certificate.yaml` and `hubble-ui/routes.yaml`: one Certificate and two HTTPRoutes | Hubble UI/Relay Deployments, Services, RBAC, Cilium TLS resources, generated frontend TLS Secret |

The cert-manager Git source supplies both Helm values and the allowlisted issuer.
Its values path remains relative to the repository root. The two directory
Applications also use explicit file allowlists. All sources are public; no
repository credentials are required. Apply the Application manifests explicitly:

```sh
mise exec -- kubectl --context lab-kubeadm apply --server-side --field-manager=lab-apps \
  -f kubernetes/argocd/applications/cert-manager.yaml \
  -f kubernetes/argocd/applications/gateway.yaml \
  -f kubernetes/argocd/applications/hubble-ui.yaml
mise exec -- argocd app get cert-manager --hard-refresh --argocd-context lab-argocd-sso
mise exec -- argocd app get gateway --hard-refresh --argocd-context lab-argocd-sso
mise exec -- argocd app get hubble-ui --hard-refresh --argocd-context lab-argocd-sso
```

Keep API-defaulted reference groups/kinds, route matches, and backend weight
explicit in Gateway API manifests. If OutOfSync persists after an SSA sync with
an empty CLI diff, check those defaults. Do not hide route or listener differences
with ignore rules.

Registration runs no sync. Automatic sync, self-healing, and pruning are off;
none of these Applications has a deletion finalizer. Manual sync uses server-side
apply. Review diffs and chart hooks before adoption, and do not use Force,
Replace, or pruning to resolve ownership differences. Never delete cert-manager
CRDs, ACME account Secrets, or TLS Secrets to make an adoption succeed.

After adoption, push selected manifest or values changes to Git and sync through
Argo. Stop using routine Helm upgrades/rollbacks for cert-manager or direct
applies for the adopted issuer, Gateway, Hubble Certificate, and routes. The old
cert-manager Helm release record will not reflect later Argo changes. Keep the
[Vault mappings](#vault-integrations-application) in their existing Application;
ESO continues to write the Cloudflare credential.

Ansible/Cilium still manages Hubble UI/Relay and the Gateway infrastructure.
Argo CD's own Certificate and redirect remain explicit manifests, and its chart
still owns the HTTPS HTTPRoute. No second Application should claim those resources.

The Gateway serves Argo CD itself. Keep Kubernetes administrator access available
before changing its listeners, and never replace it merely to fix drift. On a
fresh cluster, follow the bootstrap order in the [application guide](../README.md):
ready issuer and certificates before exposing the HTTPS listeners. To stop
tracking any of these Applications, remove it without cascading.

After registration, require Healthy status and no comparison errors. Review
selected resources against the ownership table before syncing. Check the issuer,
both frontend Certificates, Gateway, routes, Vault stores, and ExternalSecrets
are ready. Both UIs must pass trusted HTTPS and HTTP-redirect checks, and the
ESO and Vault integrations Applications must remain healthy. Registration alone
must not restart workloads or replace credentials.

See [Git values sources that also render manifests](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/multiple_sources/)
and [directory allowlists](https://argo-cd.readthedocs.io/en/release-3.5/user-guide/directory/).

## Gitea SSO

Argo CD uses Gitea at `https://gitea.lab.canhdinh.com` directly through
`configs.cm.oidc.config`; Dex is disabled. Both web and CLI authentication use
the authorization-code flow with PKCE S256. TLS certificate and token audience
validation remain enabled. No Gateway, certificate, DNS, or Ansible service
deployment changes are needed.

### Provider registration and credentials

Manage the two instance-wide OAuth applications under Gitea's Site Administration
at `https://gitea.lab.canhdinh.com/-/admin/applications`. Sign in with a Gitea site
administrator such as `gitea-admin`. The applications belong to the instance;
do not create them under personal settings or through the user-scoped
`/api/v1/user/applications/oauth2` endpoint.

| Application | Client type | Registered redirect URI |
| --- | --- | --- |
| Argo CD (ID 8) | Confidential | `https://argocd.lab.canhdinh.com/auth/callback` |
| Argo CD CLI (ID 9) | Public | `http://localhost:8085/auth/callback` |

Keep user consent enabled. The public CLI client uses a separate `cliClientID`
and no client secret. The confidential web client secret is in Vault KV v2 at
`secret/kubernetes/argocd/gitea-oidc`, property `client-secret`. ESO maintains
Secret `argocd-gitea-oidc`, referenced as `$argocd-gitea-oidc:client-secret`. Its
`app.kubernetes.io/part-of: argocd` label lets Argo CD resolve the external Secret.
Client IDs are public and live in `values.yaml`.
Keep `gitea-oidc.sops.yaml` as an encrypted backup. See
[Vault setup and emergency fallback](vault-secrets.md).

If rebuilding Gitea without its database, recreate both applications, update the
client IDs, Vault source, and encrypted backup, and rerun the controller-local tests before
deployment. Replacing these registrations invalidates their previous grants.
Do not recreate them during routine Helm upgrades.

The requested scopes are `openid profile email public-only`. Gitea's ordinary
OIDC scopes alone also grant broad Gitea API access; `public-only` avoids that
default. No repository or write scopes, or group claims, are requested.
If scopes change, users may need to revoke the previous authorization in Gitea
and consent again.

### Rotate the web client secret

Regenerate it in the existing Gitea application under Site Administration, then
immediately update the encrypted backup and Vault through the
[CAS-protected stdin pipeline](vault-secrets.md#rotation), in a private terminal:

```sh
mise exec -- sops kubernetes/argocd/gitea-oidc.sops.yaml
mise run secrets:check
```

`data.client-secret` in SOPS must contain the new value base64-encoded once;
Vault stores the decoded value. Wait for ESO to synchronize the new credential,
then restart the Argo API server to reload it:

```sh
kubectl --context lab-kubeadm -n argocd rollout restart deployment/argocd-server
kubectl --context lab-kubeadm -n argocd rollout status deployment/argocd-server --timeout=180s
```

Do not print the secret or put it in command arguments. Regeneration immediately
invalidates the old secret, so new web logins can fail until this update finishes.
Verify a fresh web SSO login afterward; the public CLI client does not test this
secret. Keep SOPS and Vault aligned, and do not apply the backup while ESO runs.

### Access policy

Gitea identity determines Argo CD permissions:

- Gitea account `vancanhuit`, resolved from `vancanhuit@gmail.com`, has Argo CD
  `role:admin` through its stable OIDC subject `2`.
- Every other authenticated account receives `role:readonly`. This exposes
  application configuration and other readable Argo resources to all Gitea users,
  including future email-confirmed registrations; it does not allow sync or
  application creation/deletion.
- RBAC checks only the subject, not mutable email, username, or organization/team
  claims (`scopes: '[]'`). A Gitea site administrator is not automatically an
  Argo administrator. Recreating the selected Gitea account gives it a new ID and
  requires an explicit policy update.
- Anonymous access remains disabled. Keep local `admin` enabled until a real
  SSO login and admin authorization check succeed. Then rotate its unchanged
  initial password, remove `argocd-initial-admin-secret`, and decide whether to
  retain a secured recovery account or disable it with `configs.cm.admin.enabled`.

### CLI login

Run this on the same workstation as the browser, with local port 8085 free:

```sh
mise exec -- argocd login argocd.lab.canhdinh.com --sso --grpc-web --skip-test-tls \
  --name lab-argocd-sso
mise exec -- argocd account get-user-info --argocd-context lab-argocd-sso
mise exec -- argocd account can-i sync applications 'default/*' --argocd-context lab-argocd-sso
mise exec -- argocd app list --argocd-context lab-argocd-sso
```

The browser signs in to Gitea and obtains consent before returning to the local
CLI callback. Do not change `--sso-port` without updating the registered redirect
URI. Both client IDs are accepted as token audiences; no missing-audience or TLS
bypass is enabled. The existing `lab-argocd` password context is kept separate.
The CLI configuration contains tokens and must remain mode `0600`.

After replacing a CLI registration, rerun the login command to refresh
`lab-argocd-sso`. Confirm its audience matches the configured CLI client ID.

Gitea does not advertise an OIDC logout endpoint. Logging out of Argo CD does not
log the browser out of Gitea; end that session in Gitea separately when using a
shared workstation.

### Rollback

If an upgrade or SSO change blocks access, use the Kubernetes administrator
context and the protected local-admin login. Inspect Helm history and select
the known-good revision recorded before the change. Confirm its client IDs and
callbacks still match Gitea before restoring it. Replace the placeholder below
with that revision:

```sh
revision='<known-good-revision>'
helm --kube-context lab-kubeadm rollback argocd "$revision" --namespace argocd --wait --timeout 5m
```

Restore the matching repository values before another Helm upgrade. Helm does
not restore the external OIDC Secret or Gitea registrations; recover those through
the [Vault credential runbook](vault-secrets.md) if they changed. Do not select a
revision that references deleted provider clients, or apply an entire resource
backup over newer Applications or Secrets. Recheck HTTPS, routes, web SSO, CLI
SSO, and subject-based permissions before returning to normal use.

## References

- [Argo CD Gateway API and TLS termination](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/ingress/#gateway-api-example)
- [Pinned Helm chart documentation](https://github.com/argoproj/argo-helm/tree/argo-cd-10.10.5/charts/argo-cd)
- [Argo CD existing OIDC provider and Secret references](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/user-management/#existing-oidc-provider)
- [Argo CD RBAC](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/rbac/)
- [Gitea OAuth2 provider and granular scopes](https://docs.gitea.com/development/oauth2-provider)
- [Cilium multi-host Gateway example](https://docs.cilium.io/en/v1.20/network/servicemesh/ingress-to-gateway/tls-migration/)
