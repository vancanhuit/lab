# Repository Guide

## Tooling

- `mise.toml` and `mise.lock` are the tooling source of truth. Bootstrap with `mise install` and `mise run ansible:deps`; list repository tasks with `mise task ls`.
- Run Ansible commands from `ansible/`. That is required for `ansible.cfg` to select `inventory.yaml`, `roles/`, the `admin` remote user, and the `community.sops.sops` vars plugin.
- Install the repository hooks once with `mise run hooks:install`. Cocogitto enforces Conventional Commit messages; pre-push runs `mise run security:secrets`, which scans full Git history and may contact credential-provider APIs.

## Structure

- `ansible/{dns,postgres,s3,harbor,gitea,gitea-runner,kuma,vault}.yaml` are live service deployment entrypoints. `setup-incus.yaml` targets the Incus host as remote user `lab`, unlike the default `admin` used for instances.
- `ansible/kubernetes.yaml` deploys the four-node kubeadm/containerd/Cilium cluster; `verify-kubernetes.yaml` is read-only. Kubernetes inventory hosts deliberately do not inherit the `lab` group's secrets.
- `ansible/kubernetes-gateway.yaml` includes the base cluster and configures HAProxy on `k8s-gateway-api`; it does not deploy applications or run their live verification. Node TCP 80/443 listeners trust HAProxy only. `verify-kubernetes-gateway.yaml` is read-only and requires the applications to be installed first.
- `kubernetes/` owns cert-manager and Argo CD Helm values and plain issuer, Certificate, shared Gateway, and route manifests. `kubernetes/gateway/gateway.yaml` defines the shared `kube-system/lab-gateway` Gateway on ports 80/443, with per-app listeners; Hubble routes are separate in `hubble-ui/routes.yaml`. Apply using `kubernetes/README.md`; Ansible must not reconcile applications. The Cloudflare credential is an encrypted Kubernetes Secret, not an inventory variable.
- `ansible/verify-{postgres,s3,harbor,gitea,gitea-runner,kuma,vault}.yaml` inspect live hosts after deployment. Vault verification is read-only and accepts uninitialized/sealed states without handling bootstrap keys. There is no DNS verification playbook.
- `vault/` owns post-initialization OIDC roles and ACL policies, applied directly with the Vault CLI; Ansible does not reconcile them. The confidential Gitea client configuration is encrypted in `secrets/vault/oidc.sops.json`, outside inventory.
- `ansible/roles/*/tests/render-config.yml` are controller-local role contract and template tests. `ansible/verify-inventory-vars.yaml` locally checks that encrypted variables are visible only to their intended inventory hosts.
- `create-incus-instance.py` is a PEP 723 script run with `uv run create-incus-instance.py --help`; normal execution calls Incus and creates a stopped instance.
- `docs/diagrams/*.excalidraw` are editable architecture sources; their matching SVG previews are embedded in `docs/kubernetes.md`. Update each source/preview pair together; see `docs/diagrams/README.md` for style and export conventions.

## Verification

- Run all controller-local Ansible tests with `mise run ansible:test`; this includes the Kuma backup behavior test and Kubernetes manifest/Helm contract tests and uses an isolated localhost inventory. Helm tests require registry access, not cluster access or an age identity.
- For an Ansible role change, run its focused local test from `ansible/`: `mise exec -- ansible-playbook -i localhost, roles/<role>/tests/render-config.yml`. For Kuma backup changes, also run `sh roles/uptime_kuma/tests/test-backup-behavior.sh`.
- For inventory variable ownership changes, run `mise exec -- ansible-playbook verify-inventory-vars.yaml`. This requires access to the configured age identity because inventory loading decrypts SOPS files.
- Syntax-check each affected playbook with `mise exec -- ansible-playbook --syntax-check <playbook>.yaml`, then lint affected Ansible paths with `mise exec -- ansible-lint <paths>`.
- For Python helper changes, run the matching test module from the repository root: `mise exec -- python -m unittest scripts.tests.test_create_incus_instance` or `mise exec -- python -m unittest scripts.tests.test_sanitize_trufflehog_output`.
- Finish with `git diff --check`. Run `mise run security:secrets` when secret handling, scanner configuration, or commit-ready verification warrants the slower full-history networked scan.
- Do not use deployment or live verification playbooks as routine local tests: they connect to and may mutate the homelab. When deployment is intended, preserve the dependency order `dns.yaml` -> `postgres.yaml` -> `s3.yaml` -> `harbor.yaml` -> `gitea.yaml` -> `gitea-runner.yaml` -> `kuma.yaml`; rerun a deployment playbook to check idempotence (`changed=0`).

## Secrets And Operations

- Never decrypt secrets into repository files or print them in shared or recorded output. Edit encrypted files with `SOPS_FILE=<path-relative-to-ansible> mise run secrets:edit`; `secrets:view` prints plaintext and should normally be avoided.
- `secrets/vault/bootstrap.sops.json` is an operator-only encrypted initialization backup, not inventory. Keep it outside Ansible variable loading; `mise run secrets:check` includes recovery JSON files. Never display its unseal shares or root token.
- Keep Ansible secrets in the narrowest ownership-scoped `.sops.yaml` file under `ansible/group_vars/` or `ansible/host_vars/`. If ownership changes, update and run `verify-inventory-vars.yaml`. Kubernetes Secrets belong under `kubernetes/` with only `data`/`stringData` encrypted using `kubernetes/.sops.yaml`; edit with `mise exec -- sops <path>` and decrypt only into `kubectl` stdin.
- Changing an S3 backend in inventory changes configuration only; it does not migrate existing Gitea objects. Follow `docs/gitea.md`'s object-storage migration procedure before switching providers.
- Do not casually delete `/var/lib/lego` or weaken certificate/private-key permissions. The directory contains ACME account and certificate state, and repeated replacement issuance can consume Let's Encrypt rate limits.
