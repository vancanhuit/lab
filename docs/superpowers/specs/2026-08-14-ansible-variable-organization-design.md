# Ansible Variable Organization Design

**Date:** 2026-08-14
**Status:** Approved for planning

## Goal

Organize inventory variables by ownership so each host receives only the normal variables and secrets it needs. Keep playbooks focused on orchestration and keep reusable role defaults independent of this homelab environment.

## Inventory Structure

The `lab` group remains the parent for all service hosts. A nested `gitea_stack` group contains `postgres` and `gitea`, which are the only hosts that share Gitea database credentials. The `incus` group remains separate.

```yaml
lab:
  hosts:
    dns:
      ansible_host: dns.lab.canhdinh.com
    kuma:
      ansible_host: kuma.lab.canhdinh.com
  children:
    gitea_stack:
      hosts:
        postgres:
          ansible_host: postgres.lab.canhdinh.com
        gitea:
          ansible_host: gitea.lab.canhdinh.com
```

This gives `postgres` and `gitea` both `lab` and `gitea_stack` membership without defining connection data in multiple locations.

## Variable Ownership

### Shared Group Variables

`group_vars/lab/secrets.sops.yaml` contains only `cloudflare_api_token`. Every current `lab` host runs the Lego role and needs this token; `debian-incus` does not.

`group_vars/gitea_stack/vars.yaml` contains `gitea_database_name` and `gitea_database_user`. `group_vars/gitea_stack/secrets.sops.yaml` contains `gitea_database_password`. Both Gitea deployment and PostgreSQL provisioning consume these values.

The empty `group_vars/all/vars.yaml` and obsolete `group_vars/all/secrets.sops.yaml` are removed after migration. No application credential remains globally visible.

### Host Variables

`host_vars/dns/vars.yaml` owns the DNS certificate names, PFX format, and deploy hook. `host_vars/dns/secrets.sops.yaml` owns `technitium_pfx_password`.

`host_vars/postgres/vars.yaml` owns PostgreSQL allowed CIDRs, certificate names, and deploy hook.

`host_vars/gitea/vars.yaml` owns Gitea environment identity, database endpoint, certificate names, deploy hook, S3 endpoint/region/bucket, and SMTP host/port/from/user. `host_vars/gitea/secrets.sops.yaml` owns the S3 access key and secret key, SMTP password, application secret key, internal token, OAuth secret, LFS secret, and administrator password.

`host_vars/kuma/vars.yaml` owns Uptime Kuma environment identity, certificate names, and deploy hook.

Role versions, package identities, filesystem paths, ports, retention policies, and other reusable operational defaults remain in each role's `defaults/main.yaml`. Homelab FQDNs, URLs, email addresses, and administrator names move from role defaults to the relevant host variables. A play-level override that exactly duplicates a role default is removed rather than copied.

## Playbook Boundary

Deployment playbooks retain play names, host selection, privilege escalation, tasks, and role ordering. Fixed inventory data moves out of each play's `vars` block. This keeps playbooks readable while preserving the existing execution flow, including the two-play Gitea deployment.

Lookup expressions used by certificate deploy hooks remain lazily evaluated inventory variables. They continue to use `playbook_dir`, which is available when Ansible renders the value during play execution.

## Secret Migration

Existing SOPS values are split into destination files and re-encrypted under the repository's Age recipient. Migration must not write decrypted secrets to repository files, command arguments, logs, or terminal output. Each destination file must carry its own valid SOPS metadata and MAC; encrypted YAML entries cannot be copied between files as ciphertext.

After destination files are validated, the original global encrypted file is removed. Documentation references are updated to describe the new files and to use a path-agnostic SOPS check where appropriate.

## Precedence And Failure Behavior

Ansible applies `lab` variables to all service hosts, then the more specific `gitea_stack` variables to its members, then host variables. No variable name is intentionally defined at multiple inventory precedence levels.

Missing secrets continue to fail through existing role validation or at their first required task. Inventory validation must additionally prove that:

- `debian-incus` cannot resolve `cloudflare_api_token`.
- `dns` cannot resolve Gitea credentials.
- `postgres` resolves only the shared Gitea database values, not Gitea application secrets.
- `gitea` resolves shared database values and its host-only application secrets.
- `kuma` cannot resolve DNS, PostgreSQL, or Gitea secrets.

Validation output must report secret presence by variable name only and never print decrypted values.

## Verification

1. Run `ansible-inventory --graph` to verify group membership.
2. Use scoped inventory assertions to verify expected variable presence and absence without displaying values.
3. Run `ansible-playbook --syntax-check` for deployment and verification playbooks.
4. Run existing role render tests.
5. Run `sops --decrypt <file> >/dev/null` for every encrypted destination file to verify metadata, MAC, and key access.
6. Run `git diff --check` and inspect the diff for plaintext or unrelated changes.

No service behavior, credential value, role execution order, or host connection target changes as part of this reorganization.
