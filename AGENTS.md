# Repository Guide

## Tooling

- `mise.toml` and `mise.lock` are the tooling source of truth. Bootstrap with `mise install` and `mise run ansible:deps`; list repository tasks with `mise task ls`.
- Run Ansible commands from `ansible/`. That is required for `ansible.cfg` to select `inventory.yaml`, `roles/`, the `admin` remote user, and the `community.sops.sops` vars plugin.
- Install the repository hooks once with `mise run hooks:install`. Cocogitto enforces Conventional Commit messages; pre-push runs `mise run security:secrets`, which scans full Git history and may contact credential-provider APIs.

## Structure

- `ansible/{dns,postgres,s3,harbor,gitea,gitea-runner,kuma}.yaml` are live service deployment entrypoints. `setup-incus.yaml` targets the Incus host as remote user `lab`, unlike the default `admin` used for instances.
- `ansible/verify-{postgres,s3,harbor,gitea,gitea-runner,kuma}.yaml` inspect live hosts after deployment. There is no DNS verification playbook.
- `ansible/roles/*/tests/render-config.yml` are controller-local role contract and template tests. `ansible/verify-inventory-vars.yaml` locally checks that encrypted variables are visible only to their intended inventory hosts.
- `create-incus-instance.py` is a PEP 723 script run with `uv run create-incus-instance.py --help`; normal execution calls Incus and creates a stopped instance.

## Verification

- For an Ansible role change, run its focused local test from `ansible/`: `mise exec -- ansible-playbook roles/<role>/tests/render-config.yml`.
- For inventory variable ownership changes, run `mise exec -- ansible-playbook verify-inventory-vars.yaml`. This requires access to the configured age identity because inventory loading decrypts SOPS files.
- Syntax-check each affected playbook with `mise exec -- ansible-playbook --syntax-check <playbook>.yaml`, then lint affected Ansible paths with `mise exec -- ansible-lint <paths>`.
- For the TruffleHog output filter, run `mise exec -- python -m unittest scripts.tests.test_sanitize_trufflehog_output` from the repository root.
- Finish with `git diff --check`. Run `mise run security:secrets` when secret handling, scanner configuration, or commit-ready verification warrants the slower full-history networked scan.
- Do not use deployment or live verification playbooks as routine local tests: they connect to and may mutate the homelab. When deployment is intended, preserve the dependency order `dns.yaml` -> `postgres.yaml` -> `s3.yaml` -> `harbor.yaml` -> `gitea.yaml` -> `gitea-runner.yaml` -> `kuma.yaml`; rerun a deployment playbook to check idempotence (`changed=0`).

## Secrets And Operations

- Never decrypt secrets into repository files or print them in shared or recorded output. Edit encrypted files with `SOPS_FILE=<path-relative-to-ansible> mise run secrets:edit`; `secrets:view` prints plaintext and should normally be avoided.
- Keep secrets in the narrowest ownership-scoped `.sops.yaml` file under `ansible/group_vars/` or `ansible/host_vars/`. If ownership changes, update and run `verify-inventory-vars.yaml`.
- Changing an S3 backend in inventory changes configuration only; it does not migrate existing Gitea objects. Follow `README.md`'s Gitea object-storage migration procedure before switching providers.
- Do not casually delete `/var/lib/lego` or weaken certificate/private-key permissions. The directory contains ACME account and certificate state, and repeated replacement issuance can consume Let's Encrypt rate limits.
