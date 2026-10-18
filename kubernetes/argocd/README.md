# Argo CD

Deploy Argo CD at **https://argocd.lab.canhdinh.com/** with the official
`argo-cd` Helm chart **10.10.5** (Argo CD **v3.5.5**), pinned by OCI digest below.
This is the chart's non-HA installation in namespace `argocd`. No Applications,
repository credentials, or SSO integration are configured.

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
`redirect.yaml` redirects HTTP to HTTPS. Retained CRDs do not
make uninstall harmless: back up Argo CD resources and Secrets before upgrades,
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

Log in as `admin`. Retrieve its generated initial password **only in a private,
unrecorded terminal**; this command prints a secret:

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

## References

- [Argo CD Gateway API and TLS termination](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/ingress/#gateway-api-example)
- [Pinned Helm chart documentation](https://github.com/argoproj/argo-helm/tree/argo-cd-10.10.5/charts/argo-cd)
- [Cilium multi-host Gateway example](https://docs.cilium.io/en/v1.20/network/servicemesh/ingress-to-gateway/tls-migration/)
