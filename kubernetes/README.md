# Kubernetes applications

Manage applications here with Helm and `kubectl`, independently of Ansible.
Ansible still owns kubeadm, containerd, Cilium (including Hubble UI and Relay),
Gateway API CRDs, edge labels, node firewalls, and HAProxy.

Run commands from the repository root. `mise install` provides Helm 4 and a
cluster-matched `kubectl`. You need the `lab-kubeadm` kubeconfig context, access
to the private API, and the configured SOPS age identity for credential recovery.
Cloudflare and Argo CD OIDC credentials are sourced from Vault through ESO;
their encrypted SOPS copies are retained as backups.
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

Follow the [Cloudflare Vault integration](cert-manager/README.md) first to install
ESO, import the retained SOPS backup once, and configure cert-manager's dedicated
Vault role and SecretStore. ESO maintains Secret `cert-manager/cloudflare-api-token`
without changing the issuer's credential reference. Wait for the ExternalSecret
to be ready, then apply the issuer:

```sh
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/cert-manager/issuer.yaml
kubectl --context lab-kubeadm wait clusterissuer/letsencrypt-cloudflare \
  --for=condition=Ready --timeout=180s
```

The historical `lab-ansible-apps` field manager is retained for these plain
resources to preserve ownership across the move. Its name does not run or
require Ansible. Do not routinely force ownership conflicts.

Do not routinely apply `cloudflare-api-token.sops.yaml`: it is a backup, not a
second active writer. The integration guide covers [rotation](cert-manager/README.md#rotation-and-backup)
and [emergency SOPS fallback](cert-manager/README.md#emergency-sops-fallback).
Keep plaintext tokens out of command arguments, shell history, and Git.
See [Cloudflare permissions and renewal](../docs/kubernetes.md#certificates-and-renewal).

## 3. Apply frontend certificates and the shared Gateway

The Gateway is shared by Hubble UI and Argo CD. Wait for both certificates before
exposing their HTTPS listeners on a new cluster. If Gateway `hubble-ui` still
exists, complete the [one-time rename](#one-time-rename-from-hubble-ui) first:

```sh
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/hubble-ui/certificate.yaml \
  -f kubernetes/argocd/certificate.yaml
kubectl --context lab-kubeadm -n kube-system wait certificate/hubble-ui certificate/argocd \
  --for=condition=Ready --timeout=600s
kubectl --context lab-kubeadm apply --server-side --field-manager=lab-ansible-apps \
  -f kubernetes/gateway/gateway.yaml \
  -f kubernetes/hubble-ui/routes.yaml
kubectl --context lab-kubeadm -n kube-system wait gateway/lab-gateway \
  --for=condition=Programmed --timeout=180s
```

The shared Gateway is named `kube-system/lab-gateway`. Its original Hubble listener
names are unchanged; its Argo listeners accept routes only from namespace
`argocd`. Only this Gateway may own the edge nodes' host-network ports 80/443.

For later Hubble routing changes, edit `hubble-ui/routes.yaml` and apply that
file only. Listener changes belong in `gateway/gateway.yaml`. Helm manages
cert-manager and Argo CD; Ansible manages infrastructure only. Never recursively
apply this directory: it contains Helm values and an encrypted Secret, and
installation order matters.

### One-time rename from `hubble-ui`

The lab completed this migration on **2026-10-18**; its live Gateway is now
`kube-system/lab-gateway`. The procedure below is only for clusters still using
the old name.

Kubernetes cannot rename a Gateway in place. Replacing `kube-system/hubble-ui`
with `kube-system/lab-gateway` briefly interrupts **both Hubble UI and Argo CD**.
Do not apply the new Gateway alongside the old one: their host-network listeners
would compete for ports 80/443. New clusters do not need this migration.

Before starting, save the existing Gateway and all four HTTPRoutes, record the
current Argo Helm revision, and keep the previous Helm values for rollback. Do
not include Secret data in plaintext backups; leave Certificates and TLS Secrets
in place. Render/test the new Helm values before the interruption.

1. Delete only the old Gateway and wait for its generated resources to be removed:

   ```sh
   kubectl --context lab-kubeadm -n kube-system delete gateway hubble-ui \
     --cascade=foreground --wait=true --timeout=180s
   kubectl --context lab-kubeadm -n kube-system get ciliumenvoyconfig,service,endpointslice \
     --selector=gateway.networking.k8s.io/gateway-name=hubble-ui
   ```

   The second command must report no resources.

2. Confirm ports 80/443 are released on all edge nodes, then run the apply/wait
   commands above to create `lab-gateway` and update the Hubble routes.
3. Run the [Argo Helm upgrade and redirect apply](argocd/README.md#2-install-or-update-argo-cd).
   Use Helm for its owned `argocd-server` route; do not patch it out of band.
4. Verify all four routes have `Accepted=True` and `ResolvedRefs=True` for
   `lab-gateway` at their current generation. Check both applications' HTTPS,
   HTTP redirects, and authenticated Argo CLI access.

If migration fails, remove `lab-gateway` and wait for its generated resources and
edge sockets to disappear **before** restoring the saved old Gateway and plain
routes. Roll Argo back to the recorded Helm revision to restore its owned route.
Do not delete either application's Certificates, Secrets, or workloads.

## 4. Install Argo CD

Follow [Argo CD deployment](argocd/README.md) for the Vault-sourced Gitea OIDC
credential and retained SOPS backup, pinned Helm command, HTTP redirect, private DNS record, and SSO login at
`https://argocd.lab.canhdinh.com/`. The chart owns its HTTPS HTTPRoute; the shared
Gateway and certificates remain plain manifests.

## 5. Connect External Secrets Operator to Vault

Follow [External Secrets Operator](external-secrets/README.md) for the pinned
Helm release, namespace-scoped Vault SecretStore, and short-lived Kubernetes
authentication against the existing Vault LXC. The demo role reads only
`secret/kubernetes/vault-secrets/*`; cert-manager uses a separate exact-key role
for its Cloudflare credential (step 2), and Argo CD has its own exact-key SSO
credential role (step 4). The dummy-data example is optional and
is not left running.

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
cert-manager, Argo CD, and External Secrets Helm charts (requiring registry access) and validate plain
manifests and encrypted Secret references without contacting a cluster or
decrypting credentials.

Do not delete the ACME account or TLS Secrets to retry issuance. Correct DNS or
credentials and allow reconciliation. To undo a routing change, restore the
previous route manifest or Helm values revision and reapply it; do not delete
cert-manager or the shared Gateway.
