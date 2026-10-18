# Argo CD

Deploy Argo CD at **https://argocd.lab.canhdinh.com/** with the official
`argo-cd` Helm chart **10.10.5** (Argo CD **v3.5.5**), pinned by OCI digest below.
This is the chart's non-HA installation in namespace `argocd`, using direct
Gitea OIDC for SSO. No Applications or repository credentials are configured.

`mise install` also installs the matching Argo CD CLI **3.5.5**. Run commands
from the repository root after the
[cluster and cert-manager setup](../README.md). These files do not deploy
anything until you run the commands.

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
backend HTTPS redirect loop and does **not** disable login. The Gateway admits
Argo routes only from the `argocd` namespace. Hubble's listeners remain restricted
to their original namespace. No cross-namespace Secret grant is needed because
the Certificate and Gateway both live in `kube-system`.

Cilium must have `gatewayAPI.enableAppProtocol: true`, as configured in the
Ansible Cilium values template. Its gRPC-Web filter converts CLI requests into
native gRPC, so the Helm-owned HTTPRoute sends `application/grpc*` requests to
the Service's HTTP/2 port `8080` (`appProtocol: kubernetes.io/h2c`). Browser and
REST requests continue to use HTTP/1 on port `80`. One HTTPRoute handles both;
no overlapping GRPCRoute or new external port is needed. The chart's built-in
HTTPRoute fixes all backends to port 80, so `extraObjects` supplies this route
while retaining Helm ownership and its existing name.

## 1. Prepare certificates and the shared Gateway

Apply both frontend certificates before the complete shared Gateway. The existing
Hubble certificate resource is reconciled in place, not replaced. If the cluster
still uses Gateway `hubble-ui`, follow the [one-time rename](../README.md#one-time-rename-from-hubble-ui)
before applying these commands:

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
ECDSA P-256 with automatic key rotation. Hubble and Argo routes reference the
same shared Gateway; their listener names and certificates are unchanged.

## 2. Install or update Argo CD

The [Gitea OAuth applications](#gitea-sso) must exist before using these values.
Create the namespace on a fresh cluster, then decrypt the credential only into
`kubectl` stdin. Use Bash with `pipefail`; do not use `tee`, shell tracing, or
Secret diffs:

```bash
set -euo pipefail
kubectl --context lab-kubeadm create namespace argocd --dry-run=client -o yaml |
  kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps -f -
mise exec -- sops --decrypt kubernetes/argocd/gitea-oidc.sops.yaml |
  kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps -f -
```

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
SOPS-managed Secret, not a Helm value or part of Helm release history.
Retained CRDs do not make uninstall harmless: back up Argo CD resources and Secrets before upgrades,
and never delete an Application casually because its finalizer may delete the
workloads it manages.

## 3. Verify and log in

```sh
kubectl --context lab-kubeadm -n argocd get pods,services,httproutes
kubectl --context lab-kubeadm -n argocd describe httproute argocd-server argocd-redirect
curl --ipv4 --noproxy '*' --fail https://argocd.lab.canhdinh.com/
```

Both routes should report `Accepted=True` and `ResolvedRefs=True`. HTTPS should
validate without `--insecure`; HTTP should redirect to HTTPS.

For normal access, open the UI and choose **Log in via Gitea**, or use the
[SSO CLI command](#cli-login). The local `admin` account remains enabled for
recovery during the SSO rollout. Retrieve its generated initial password
**only in a private, unrecorded terminal**; this command prints a secret:

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
hang behind this Gateway; it does **not** disable certificate verification. Do
not add `--insecure` or `--plaintext`. The saved CLI context enables gRPC-Web for
subsequent commands, and `~/.config/argocd/config` must remain mode `0600` because
it stores a session token. Rotate the password and log in again when the session
expires or is invalidated.

Keep the HAProxy lab/Tailscale allowlist and Tailscale ACLs in place. Argo CD receives
powerful cluster-wide permissions; restrict AppProjects before allowing untrusted
repositories or users to deploy applications. Only the client-to-Gateway leg is
TLS-encrypted; the Gateway-to-server leg uses the trusted cluster network.

## Verified deployment

On **2026-10-18**, the lab deployed chart 10.10.5 / Argo CD v3.5.5, release
`argocd` revision 2. Cilium stayed on 1.20.3, revision 6, with backend
`appProtocol` support enabled; agent and operator rollouts completed.

HTTPS returned `200` with a trusted certificate, HTTP redirected with `301`, and
anonymous application API requests returned `401`. All Gateway listeners and
routes were accepted with resolved references. Hubble UI remained reachable;
its Gateway identity, original listeners, routes, certificate identity, and TLS
Secret contents were preserved. The existing Argo route identity and application
credential Secrets were also preserved during the protocol fix; Helm release
history was updated normally.

The matching CLI logged in as `admin` under context `lab-argocd`, without logging
the password or session token. User info, applications, projects, clusters,
repositories, ApplicationSets, and an authorization check succeeded. No GitOps
Applications, repositories, or test workloads were created. The in-cluster target
reports `Unknown` until an application uses it, because unused clusters are not
monitored; this is not a connectivity failure.

Later on **2026-10-18**, the shared Gateway was replaced under the neutral name
`kube-system/lab-gateway`, and Argo CD was upgraded to Helm revision **3** to
update its route parent. All four route identities, both Certificate identities
and specs, and application/TLS Secret identities and contents were preserved.
Gateway listener settings and Cilium configuration were unchanged. Both UIs,
HTTP redirects, login enforcement, and authenticated Argo CLI operations passed
after the rename.

Later that day, Helm revision **4** enabled direct Gitea OIDC and removed the
unused Dex deployment. The login page offered **Log in via Gitea**; web and CLI
login initiation both requested PKCE S256, the registered callbacks, and the
restricted scopes. Live RBAC checks granted subject `2` admin and other subjects
read-only. Anonymous API access still returned `401`; trusted HTTPS, redirects,
the existing local-admin CLI session, all nodes/workloads, and all four routes
passed. The Gateway, Hubble routes, both Certificates/TLS Secrets, and existing
Argo credential identities and contents were preserved. Temporary bootstrap
tokens were removed. The operator subsequently confirmed that browser SSO works.
The operator then logged in with the CLI; `lab-argocd-sso` reported
`vancanhuit@gmail.com`, issuer `https://gitea.lab.canhdinh.com`, and permission to
sync `default/*`. The local Argo admin password has not been rotated.

Helm revision **5** subsequently switched to instance-wide Gitea OAuth
applications **8** and **9**, created through Site Administration using
`gitea-admin` credentials. Real web and CLI SSO passed with that account, and
Argo correctly allowed reads but denied sync for its subject `1`. The `2` admin
binding and other RBAC settings were unchanged. The old user-owned clients
**6** and **7**, their grants, and the temporary verification grants were removed.
Existing sessions issued to the old client IDs must log in again. The operator
completed post-migration CLI SSO; `get-user-info` confirmed `vancanhuit@gmail.com`
with the Gitea issuer, and the sync authorization check returned `yes`.
The Gateway, certificates, TLS Secrets, and other application credentials were
preserved; the external OIDC Secret retained its identity while its credential
rotated.

## Gitea SSO

Argo CD uses Gitea at `https://gitea.lab.canhdinh.com` directly through
`configs.cm.oidc.config`; Dex is disabled. Both web and CLI authentication use
the authorization-code flow with PKCE S256. TLS certificate and token audience
validation remain enabled. No Gateway, certificate, DNS, or Ansible service
deployment changes are needed.

### Provider registration and credentials

Two **instance-wide** OAuth applications are managed under Gitea's Site
Administration at `https://gitea.lab.canhdinh.com/-/admin/applications`. Sign in
with a Gitea site administrator such as `gitea-admin`; the applications belong
to the instance, not that account. Do not create them under personal settings
or through the user-scoped `/api/v1/user/applications/oauth2` endpoint.

| Application | Client type | Registered redirect URI |
| --- | --- | --- |
| Argo CD (ID 8) | Confidential | `https://argocd.lab.canhdinh.com/auth/callback` |
| Argo CD CLI (ID 9) | Public | `http://localhost:8085/auth/callback` |

Keep user consent enabled. The public CLI client uses a separate `cliClientID`
and no client secret. The confidential web client secret is in
`gitea-oidc.sops.yaml`, referenced as `$argocd-gitea-oidc:client-secret`. Its
`app.kubernetes.io/part-of: argocd` label lets Argo CD resolve the external Secret.
Client IDs are public and live in `values.yaml`.

The instance-level migration required new registrations because Gitea does not
provide an ownership-transfer operation. The original user-owned registrations
were removed after the replacements passed real web and CLI login checks.
Do not restore the old client IDs from Git without also restoring their provider
registrations and matching encrypted credential.

If rebuilding Gitea without its database, recreate both applications, update the
client IDs and encrypted credential, and rerun the controller-local tests before
deployment. Replacing these registrations invalidates their previous grants.
Do not recreate them during routine Helm upgrades.

The requested scopes are `openid profile email public-only`. Gitea's ordinary
OIDC scopes alone also grant broad Gitea API access; `public-only` avoids that
default. No repository or write scopes, or group claims, are requested.
If scopes change, users may need to revoke the previous authorization in Gitea
and consent again.

To rotate the web client secret, regenerate it in the existing Gitea application,
under Site Administration, then immediately edit the encrypted Secret in a
private terminal:

```sh
mise exec -- sops kubernetes/argocd/gitea-oidc.sops.yaml
mise run secrets:check
```

`data.client-secret` must contain the new value base64-encoded once. Reapply only
the Secret pipeline from step 2, then restart the Argo API server to reload it:

```sh
kubectl --context lab-kubeadm -n argocd rollout restart deployment/argocd-server
kubectl --context lab-kubeadm -n argocd rollout status deployment/argocd-server --timeout=180s
```

Do not print the secret or put it in command arguments. Regeneration immediately
invalidates the old secret, so new web logins can fail until this update finishes.

### Access policy

- Gitea account `vancanhuit`, resolved from `vancanhuit@gmail.com`, has Argo CD
  `role:admin` through its stable OIDC subject **`2`**.
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

Run this on the same workstation as the browser, with local port **8085** free:

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

After the instance-level migration, rerun the login command above to replace the
old `lab-argocd-sso` token. Its issuer and user are unchanged, but its audience
must be the new CLI client ID.

Gitea does not advertise an OIDC logout endpoint. Logging out of Argo CD does not
log the browser out of Gitea; end that session in Gitea separately when using a
shared workstation.

### Rollback

The pre-SSO Helm release is revision **3**. If the SSO change blocks access, use
the Kubernetes administrator context rather than relying on SSO:

```sh
helm --kube-context lab-kubeadm rollback argocd 3 --namespace argocd --wait --timeout 5m
```

This restores the pre-SSO configuration and the unused Dex deployment without
changing the Gateway or application data. Leave the external Secret and Gitea
registrations in place while investigating. Restore repository values from the
pre-SSO commit before another upgrade, or it will re-enable SSO. The encrypted
pre-change backup is under `~/.local/state/lab/backups/before-argocd-gitea-sso-*.json.age`;
it was decrypt-verified, not restore-tested. Do not apply an entire backup over
newer Application resources or Secrets.

Do not roll back only to revision **4** after the instance-level migration: it
references deleted user-owned clients, and Helm does not restore the external
OIDC Secret. The migration's encrypted backup is
`~/.local/state/lab/backups/before-argocd-instance-oidc-*.json.age`, containing the
old registration/grant records, live Argo resources, and matching credential.
It was decrypt-verified, not restore-tested. Prefer revision 3's local-admin
recovery path unless deliberately restoring the entire former OIDC integration.

## References

- [Argo CD Gateway API and TLS termination](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/ingress/#gateway-api-example)
- [Pinned Helm chart documentation](https://github.com/argoproj/argo-helm/tree/argo-cd-10.10.5/charts/argo-cd)
- [Argo CD existing OIDC provider and Secret references](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/user-management/#existing-oidc-provider)
- [Argo CD RBAC](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/rbac/)
- [Gitea OAuth2 provider and granular scopes](https://docs.gitea.com/development/oauth2-provider)
- [Cilium multi-host Gateway example](https://docs.cilium.io/en/v1.20/network/servicemesh/ingress-to-gateway/tls-migration/)
