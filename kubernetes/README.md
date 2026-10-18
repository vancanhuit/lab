# Kubernetes applications

Manage applications here with Helm and `kubectl`, independently of Ansible.
Ansible still owns kubeadm, containerd, Cilium (including Hubble UI and Relay),
Gateway API CRDs, edge labels, node firewalls, and HAProxy.

Run commands from the repository root. `mise install` provides Helm 4 and a
cluster-matched `kubectl`. You need the `lab-kubeadm` kubeconfig context, access
to the private API, and the configured SOPS age identity for the Cloudflare Secret.
The [Kubernetes guide](../docs/kubernetes.md) covers infrastructure and access.

## 1. Install or update cert-manager

Use the [official OCI chart](https://cert-manager.io/docs/installation/helm/),
pinned to **v1.21.2** and its OCI digest. `cert-manager/values.yaml` enables CRDs,
keeps them on uninstall, and preserves the public DNS-over-HTTPS self-checks. Do not change
`crds.keep` to `false`: deleting CRDs also deletes their custom resources.

For a fresh installation or an existing Helm release:

The live lab was adopted into this Helm release on **2026-10-18**. Use the
command below for subsequent updates; it does not need `--take-ownership`.

```sh
helm --kube-context lab-kubeadm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager@sha256:634dce9c13b56677a2c05e2ab76c312d0be2664022d5dd05815da67e1fd5f610 \
  --version v1.21.2 \
  --namespace cert-manager --create-namespace \
  --values kubernetes/cert-manager/values.yaml \
  --server-side=false --wait --timeout 5m
```

### Adopt the existing static-manifest installation once

For a cluster still running cert-manager from static manifests rather than a Helm
release, adopt it once. Before switching, back up etcd or take an **encrypted** backup of cert-manager
resources and Secrets. Confirm there is no cert-manager Helm release with
`helm --kube-context lab-kubeadm list --namespace cert-manager`.
Helm 4 lists all release states by default; it no longer accepts `--all`.
If another release owns it, stop and investigate rather than taking it over.

Run the same install command above with **`--take-ownership` added once**. This
adopts the existing controller resources at the same version, without deleting
CRDs, Certificates, the ACME account Secret, or TLS Secrets. The controller Pods
may roll during adoption. Client-side Helm patching (`--server-side=false`)
avoids conflicts with fields previously managed through Ansible's server-side
apply. Omit `--take-ownership` on subsequent upgrades.

Do not uninstall/reinstall or add cleanup/automatic rollback flags to the initial
adoption. If it fails, inspect `helm status` and controller events and retry after
fixing the problem; deleting adopted resources is not a safe rollback.
Old `/etc/kubernetes/apps/` files on the control plane are inert and are no longer
reconciled. Do not apply those stale copies or use them to delete live resources.

## 2. Apply the Cloudflare credential and issuer

The encrypted file is already a Kubernetes Secret, not an Ansible variable.
Decrypt only into the pipe; do not use `tee`, shell tracing, or Secret diffs.
Use Bash with `pipefail` so decryption failures cannot be hidden:

```bash
set -euo pipefail
mise exec -- sops --decrypt kubernetes/cert-manager/cloudflare-api-token.sops.yaml |
  kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps -f -
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/cert-manager/issuer.yaml
kubectl --context lab-kubeadm wait clusterissuer/letsencrypt-cloudflare \
  --for=condition=Ready --timeout=180s
```

The historical `lab-ansible-apps` field manager is retained for these plain
resources to preserve ownership across the move. Its name does not run or
require Ansible. Do not routinely force ownership conflicts.

To rotate the token, edit the encrypted Secret and rerun only the Secret pipeline:

```sh
mise exec -- sops kubernetes/cert-manager/cloudflare-api-token.sops.yaml
mise run secrets:check
```

The `data.api-token` value is base64-encoded, as required by a Kubernetes Secret.
Keep plaintext tokens out of command arguments, shell history, and Git.
See [Cloudflare permissions and renewal](../docs/kubernetes.md#certificates-and-renewal).

## 3. Apply frontend certificates and the shared Gateway

The Gateway is shared by Hubble UI and Argo CD. Wait for both certificates before
exposing their HTTPS listeners on a new cluster:

```sh
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/hubble-ui/certificate.yaml \
  -f kubernetes/argocd/certificate.yaml
kubectl --context lab-kubeadm -n kube-system wait certificate/hubble-ui certificate/argocd \
  --for=condition=Ready --timeout=600s
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/gateway/gateway.yaml \
  -f kubernetes/hubble-ui/routes.yaml
kubectl --context lab-kubeadm -n kube-system wait gateway/hubble-ui \
  --for=condition=Programmed --timeout=180s
```

The shared Gateway retains the live name `kube-system/hubble-ui` and its original
Hubble listener names. Its Argo listeners accept routes only from namespace
`argocd`. This avoids competing host-network Gateways on ports 80/443; do not
delete the live Gateway when moving from the former `hubble-ui/gateway.yaml` file.

For later Hubble routing changes, edit `hubble-ui/routes.yaml` and apply that
file only. Listener changes belong in `gateway/gateway.yaml`. Helm manages
cert-manager and Argo CD; Ansible manages infrastructure only. Never recursively
apply this directory: it contains Helm values and an encrypted Secret, and
installation order matters.

## 4. Install Argo CD

Follow [Argo CD deployment](argocd/README.md) for the pinned Helm command, HTTP
redirect, private DNS record, and secure initial login at
`https://argocd.lab.canhdinh.com/`. The chart owns its HTTPS HTTPRoute; the shared
Gateway and certificates remain plain manifests.

## Verify

```sh
kubectl --context lab-kubeadm -n cert-manager get deployments
kubectl --context lab-kubeadm get clusterissuer letsencrypt-cloudflare
kubectl --context lab-kubeadm -n kube-system get certificate,gateway,httproute
curl --ipv4 --noproxy '*' --fail https://hubble-ui.lab.canhdinh.com/
```

For host firewall, HAProxy backend, route, and HTTPS checks, optionally run
`mise exec -- ansible-playbook verify-kubernetes-gateway.yaml` from `ansible/`.
It is read-only and is no longer part of infrastructure deployment.

Local contract tests run with `mise run ansible:test`. They render the pinned
cert-manager and Argo CD Helm charts (requiring registry access) and validate plain
manifests and encrypted Secret references without contacting a cluster or
decrypting credentials.

Do not delete the ACME account or TLS Secrets to retry issuance. Correct DNS or
credentials and allow reconciliation. To undo a routing change, restore the
previous route manifest or Helm values revision and reapply it; do not delete
cert-manager or the shared Gateway.
