# Kubernetes applications

Manage applications with Helm, `kubectl`, and the Argo CD Applications described
below. Ansible owns kubeadm, containerd, Cilium (including Hubble UI and Relay),
Gateway API CRDs, edge labels, node firewalls, and HAProxy.

Run commands from the repository root. `mise install` provides Helm 4 and a
cluster-matched `kubectl`. You need the `lab-kubeadm` kubeconfig context, access
to the private API, and the configured SOPS age identity for credential recovery.
External Secrets Operator (ESO) synchronizes Cloudflare and Argo CD OIDC
credentials from Vault. Keep their encrypted SOPS copies as recovery backups.
The [Kubernetes guide](../docs/kubernetes.md) covers infrastructure and access.

## 1. Install or update cert-manager

Use the [official OCI chart](https://cert-manager.io/docs/installation/helm/),
pinned to v1.21.2 and its OCI digest. `cert-manager/values.yaml` enables CRDs,
keeps them on uninstall, and preserves the public DNS-over-HTTPS self-checks. Do not change
`crds.keep` to `false`: deleting CRDs also deletes their custom resources.

Use the command below for fresh installations and updates before Argo adoption.
After the first manual sync of the
[cert-manager Application](argocd/README.md#cert-manager-gateway-and-hubble-ui-applications),
use Git and Argo for chart changes instead of Helm upgrades.

```sh
helm --kube-context lab-kubeadm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager@sha256:634dce9c13b56677a2c05e2ab76c312d0be2664022d5dd05815da67e1fd5f610 \
  --version v1.21.2 \
  --namespace cert-manager --create-namespace \
  --values kubernetes/cert-manager/values.yaml \
  --server-side=false --wait --timeout 5m
```

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

Keep the existing `lab-ansible-apps` field manager for these plain resources to
preserve ownership. The field manager's name does not run or require Ansible.
Do not routinely force ownership conflicts.
After adopting the issuer into the cert-manager Application, use Git and manual
Argo sync for routine issuer changes; these apply commands remain for bootstrap/recovery.

Do not routinely apply `cloudflare-api-token.sops.yaml`: it is a backup, not a
second active writer. The integration guide covers [rotation](cert-manager/README.md#rotation-and-backup)
and [emergency SOPS fallback](cert-manager/README.md#emergency-sops-fallback).
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
kubectl --context lab-kubeadm -n kube-system wait gateway/lab-gateway \
  --for=condition=Programmed --timeout=180s
```

The shared Gateway is named `kube-system/lab-gateway`. Hubble listeners accept
routes from `kube-system`; Argo listeners accept routes from `argocd`. Only this
Gateway may own the edge nodes' host-network ports 80/443.

Hubble routing changes belong in `hubble-ui/routes.yaml`; listener changes belong
in `gateway/gateway.yaml`. Before Argo adoption, apply only the changed manifest.
After adoption, push the change to Git and manually sync the corresponding
Application. Ansible retains infrastructure ownership, including Hubble UI/Relay
workloads. Never recursively apply this directory: it contains Helm values and
encrypted Secrets, and installation order matters.

## 4. Install Argo CD

Follow [Argo CD deployment](argocd/README.md) for the Vault-sourced Gitea OIDC
credential, retained SOPS backup, and pinned Helm installation. It also covers
the HTTP redirect, private DNS record, and SSO login at
`https://argocd.lab.canhdinh.com/`. The chart owns its HTTPS HTTPRoute; manage the
shared Gateway and certificates as plain manifests.

## 5. Register ESO and Vault integrations with Argo CD

With ESO and the credential integrations ready from steps 2 and 4, register the
[ESO Application](argocd/README.md#external-secrets-operator-application)
with the same chart digest and Git-hosted values. Registration leaves the running
operator unchanged. After the first manual sync, use Argo for chart changes;
do not alternate it with Helm upgrades. Automatic sync and pruning remain off.

The separate [Vault integrations Application](argocd/README.md#vault-integrations-application)
manages authentication resources and the Argo/Cloudflare ExternalSecrets.
ESO manages generated Secret values; SOPS files remain recovery backups.
Use the [ESO runbook](external-secrets/README.md) when adding another namespace
or testing the optional dummy-data example.

## 6. Register cert-manager, Gateway, and Hubble UI with Argo CD

Follow the [Application registration guide](argocd/README.md#cert-manager-gateway-and-hubble-ui-applications)
to add three manual-sync Applications. They select the existing cert-manager
chart and issuer, shared Gateway, and Hubble Certificate/routes without claiming
the Cilium-owned Hubble workloads or Vault mappings. Registration runs no sync;
review diffs before adoption. Automatic sync, pruning, and deletion finalizers stay off.

## Verify

```sh
kubectl --context lab-kubeadm -n cert-manager get deployments
kubectl --context lab-kubeadm get clusterissuer letsencrypt-cloudflare
kubectl --context lab-kubeadm -n kube-system get certificate,gateway,httproute
curl --ipv4 --noproxy '*' --fail https://hubble-ui.lab.canhdinh.com/
```

For host firewall, HAProxy backend, route, and HTTPS checks, optionally run
`mise exec -- ansible-playbook verify-kubernetes-gateway.yaml` from `ansible/`.
It is read-only and runs separately from infrastructure deployment.

Local contract tests run with `mise run ansible:test`. They render the pinned
cert-manager, Argo CD, and External Secrets Helm charts (requiring registry access) and validate plain
manifests and encrypted Secret references without contacting a cluster or
decrypting credentials.

Do not delete the ACME account or TLS Secrets to retry issuance. Correct DNS or
credentials and allow reconciliation. To undo a routing change, restore the
previous route manifest or Helm values revision. For adopted resources, revert
the Git change and manually sync Argo; otherwise use the original apply/Helm
procedure. Do not delete cert-manager or the shared Gateway.

After a service version upgrade passes readiness, application access, and its
deployment workflow's verification checks, remove the upgrade-specific encrypted
resource backups and staging files by their recorded paths. Preserve SOPS
credential backups, ACME/TLS Secrets, Helm release records, and routine backups.
