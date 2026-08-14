# Ansible Variable Organization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move homelab configuration and encrypted credentials to ownership-scoped Ansible group and host variables without changing deployed services or credential values.

**Architecture:** Keep `lab` as the parent service group and add nested `gitea_stack` ownership for values shared by PostgreSQL and Gitea. Put one-host values under `host_vars`, stream decrypted SOPS data through memory while producing independently authenticated destination files, and verify visibility using variable names only.

**Tech Stack:** Ansible 14.3.0, ansible-core, community.sops, SOPS 3.13.3, age 1.3.1, Python 3.14.7, PyYAML 6.0.3, mise

## Global Constraints

- Never print decrypted SOPS values or write plaintext credentials to persistent files.
- Never place credential values in command arguments, shell history, logs, or test output.
- Each `.sops.yaml` destination must have independent SOPS metadata and a valid MAC.
- Preserve every credential value, service behavior, role order, and host connection target.
- Keep reusable versions, package identities, paths, ports, and retention policies in role defaults.
- Put homelab FQDNs, URLs, email addresses, administrator names, and provider settings in inventory variables.
- Do not commit changes unless the user explicitly requests a commit.
- Run Ansible commands from `ansible/` through `mise exec --` so repository configuration and pinned tools apply.

---

### Task 1: Move Normal Inventory Variables

**Files:**
- Modify: `ansible/inventory.yaml`
- Create: `ansible/group_vars/gitea_stack/vars.yaml`
- Create: `ansible/host_vars/dns/vars.yaml`
- Create: `ansible/host_vars/postgres/vars.yaml`
- Create: `ansible/host_vars/gitea/vars.yaml`
- Create: `ansible/host_vars/kuma/vars.yaml`
- Modify: `ansible/dns.yaml`
- Modify: `ansible/postgres.yaml`
- Modify: `ansible/gitea.yaml`
- Modify: `ansible/kuma.yaml`
- Modify: `ansible/verify-gitea.yaml`
- Modify: `ansible/roles/gitea/defaults/main.yaml`
- Modify: `ansible/roles/gitea/tests/render-config.yml`
- Modify: `ansible/roles/uptime_kuma/defaults/main.yaml`
- Modify: `ansible/roles/uptime_kuma/tests/render-config.yml`

**Interfaces:**
- Consumes: existing host aliases, role defaults, play-level variables, and encrypted provider settings
- Produces: `lab` parent membership, `gitea_stack` membership, normal group/host variable files, and orchestration-only deployment playbooks

- [ ] **Step 1: Nest the shared Gitea stack under `lab`**

Replace `inventory.yaml` with this structure, preserving the separate Incus host:

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

incus:
  hosts:
    debian-incus:
```

- [ ] **Step 2: Add shared normal database values**

Create `group_vars/gitea_stack/vars.yaml`:

```yaml
---
gitea_database_name: gitea
gitea_database_user: gitea
```

- [ ] **Step 3: Move DNS and PostgreSQL play variables to host ownership**

Move the complete `vars` mappings from `dns.yaml` and `postgres.yaml` into their matching host files. Preserve Jinja expressions and hook bodies byte-for-byte:

```yaml
# host_vars/dns/vars.yaml
---
lego_domain_names:
  - dns.lab.canhdinh.com
lego_certificate_name: dns
lego_pfx:
  password: "{{ technitium_pfx_password }}"
  format: SHA256
lego_hooks:
  deploy:
    script: |
      #!/bin/sh
      set -eu

      install -o dns-server -g dns-server -m 0600 \
        /var/lib/lego/certificates/dns.pfx /etc/dns/dns.pfx
      systemctl restart dns.service
```

```yaml
# host_vars/postgres/vars.yaml
---
postgresql_allowed_cidrs:
  - 10.205.234.0/24
  - 100.64.0.0/10
lego_domain_names:
  - postgres.lab.canhdinh.com
lego_certificate_name: postgres
lego_hooks:
  deploy:
    script: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/roles/postgresql/files/lego-deploy-hook.sh') }}"
```

Remove only the `vars` blocks from both playbooks.

- [ ] **Step 4: Move Gitea and Kuma environment values**

Create the static portion of `host_vars/gitea/vars.yaml`; Task 2 adds the seven non-secret provider values from the encrypted source:

```yaml
---
gitea_domain: gitea.lab.canhdinh.com
gitea_root_url: https://gitea.lab.canhdinh.com/
gitea_database_host: postgres.lab.canhdinh.com:5432
gitea_admin_username: gitea-admin
gitea_admin_email: gitea-admin@canhdinh.com
lego_domain_names:
  - gitea.lab.canhdinh.com
lego_certificate_name: gitea
lego_hooks:
  deploy:
    script: "{{ lookup('ansible.builtin.template', playbook_dir ~ '/roles/gitea/templates/lego-deploy-hook.sh.j2') }}"
```

Create `host_vars/kuma/vars.yaml`:

```yaml
---
uptime_kuma_admin_username: kuma-admin
uptime_kuma_domain: kuma.lab.canhdinh.com
lego_domain_names:
  - kuma.lab.canhdinh.com
lego_certificate_name: kuma
lego_hooks:
  deploy:
    script: "{{ lookup('ansible.builtin.template', playbook_dir ~ '/roles/uptime_kuma/templates/lego-deploy-hook.sh.j2') }}"
```

Remove the Gitea and Kuma play-level `vars` blocks. Do not copy `gitea_tls_cert_path` or `gitea_tls_key_path`; their play overrides duplicate reusable role defaults. In `verify-gitea.yaml`, remove only `gitea_domain` and `gitea_admin_username` so verification consumes host ownership while keeping its verification-specific paths and expected version.

- [ ] **Step 5: Remove environment values from role defaults and make render tests explicit**

Remove these Gitea defaults:

```yaml
gitea_domain: gitea.lab.canhdinh.com
gitea_root_url: "https://gitea.lab.canhdinh.com/"
gitea_database_host: postgres.lab.canhdinh.com:5432
gitea_database_name: gitea
gitea_database_user: gitea
gitea_admin_username: gitea-admin
gitea_admin_email: gitea-admin@canhdinh.com
```

Add equivalent explicit test values to the top-level `vars` in `roles/gitea/tests/render-config.yml`, then remove their seven `default(gitea_role_defaults.*)` backfills:

```yaml
gitea_domain: gitea.example.invalid
gitea_root_url: https://gitea.example.invalid/
gitea_database_host: postgres.example.invalid:5432
gitea_database_name: gitea
gitea_database_user: gitea
gitea_admin_username: gitea-admin
gitea_admin_email: gitea-admin@example.invalid
```

Remove `uptime_kuma_admin_username` and `uptime_kuma_domain` from Uptime Kuma defaults. Add explicit values to `roles/uptime_kuma/tests/render-config.yml` and remove their two role-default backfills:

```yaml
uptime_kuma_admin_username: kuma-admin
uptime_kuma_domain: kuma.lab.canhdinh.com
```

Keep the existing Kuma domain contract assertion unchanged because production host variables still supply its approved value.

- [ ] **Step 6: Verify normal variable structure**

Run from `ansible/`:

```bash
mise exec -- ansible-inventory --graph
mise exec -- ansible-playbook roles/gitea/tests/render-config.yml
mise exec -- ansible-playbook roles/uptime_kuma/tests/render-config.yml
for playbook in dns.yaml postgres.yaml gitea.yaml kuma.yaml verify-gitea.yaml; do
  mise exec -- ansible-playbook --syntax-check "$playbook"
done
```

Expected: graph shows `gitea_stack` under `lab` with `postgres` and `gitea`; both render tests pass; every syntax check exits `0`. Secret scope is not yet correct because the original global encrypted file still exists.

- [ ] **Step 7: Review the task diff**

```bash
git diff --check
git diff -- ansible/inventory.yaml ansible/group_vars/gitea_stack/vars.yaml \
  ansible/host_vars ansible/dns.yaml ansible/postgres.yaml ansible/gitea.yaml \
  ansible/kuma.yaml ansible/verify-gitea.yaml ansible/roles/gitea \
  ansible/roles/uptime_kuma
```

Expected: only ownership moves and corresponding test setup changes. Commit only after explicit user approval.

---

### Task 2: Split SOPS Secrets And Prove Visibility

**Files:**
- Create: `ansible/verify-inventory-vars.yaml`
- Create: `ansible/group_vars/lab/secrets.sops.yaml`
- Create: `ansible/group_vars/gitea_stack/secrets.sops.yaml`
- Create: `ansible/host_vars/dns/secrets.sops.yaml`
- Create: `ansible/host_vars/gitea/secrets.sops.yaml`
- Modify: `ansible/host_vars/gitea/vars.yaml`
- Delete: `ansible/group_vars/all/vars.yaml`
- Delete: `ansible/group_vars/all/secrets.sops.yaml`
- Create temporarily: `/dev/shm/split-ansible-secrets.py`

**Interfaces:**
- Consumes: 18 authenticated values from the original global SOPS file and static Gitea host variables from Task 1
- Produces: four independently encrypted ownership files, seven normal provider settings, and a key-name-only inventory contract test

- [ ] **Step 1: Add a failing inventory ownership test**

Create `verify-inventory-vars.yaml`:

```yaml
---
- name: Verify inventory variable ownership
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    inventory_secret_names:
      - cloudflare_api_token
      - technitium_pfx_password
      - gitea_database_password
      - gitea_s3_access_key
      - gitea_s3_secret_key
      - gitea_smtp_password
      - gitea_secret_key
      - gitea_internal_token
      - gitea_lfs_jwt_secret
      - gitea_admin_password
      - gitea_oauth2_jwt_secret
    inventory_secret_contract:
      dns:
        - cloudflare_api_token
        - technitium_pfx_password
      postgres:
        - cloudflare_api_token
        - gitea_database_password
      gitea:
        - cloudflare_api_token
        - gitea_database_password
        - gitea_s3_access_key
        - gitea_s3_secret_key
        - gitea_smtp_password
        - gitea_secret_key
        - gitea_internal_token
        - gitea_lfs_jwt_secret
        - gitea_admin_password
        - gitea_oauth2_jwt_secret
      kuma:
        - cloudflare_api_token
      debian-incus: []
  tasks:
    - name: Assert each secret is visible only to its owners
      ansible.builtin.assert:
        that:
          - >-
            (item.1 in hostvars[item.0.key]) ==
            (item.1 in item.0.value)
        fail_msg: "{{ item.0.key }} has incorrect ownership for {{ item.1 }}"
        quiet: true
      loop: "{{ query('nested', inventory_secret_contract | dict2items, inventory_secret_names) }}"
      loop_control:
        label: "{{ item.0.key }} / {{ item.1 }}"
```

- [ ] **Step 2: Run the test and confirm global scope fails**

```bash
mise exec -- ansible-playbook verify-inventory-vars.yaml
```

Expected: FAIL because `group_vars/all/secrets.sops.yaml` exposes secrets to non-owners. Output contains variable names but no values.

- [ ] **Step 3: Create the memory-only migration helper**

Write this non-secret helper to `/dev/shm/split-ansible-secrets.py` with mode `0700`:

```python
#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

import yaml


source = yaml.safe_load(sys.stdin)
expected_keys = {
    "technitium_pfx_password",
    "gitea_s3_endpoint",
    "gitea_s3_region",
    "gitea_s3_bucket",
    "gitea_s3_access_key",
    "gitea_s3_secret_key",
    "gitea_smtp_host",
    "gitea_smtp_port",
    "gitea_smtp_from",
    "gitea_smtp_user",
    "gitea_smtp_password",
    "gitea_database_password",
    "gitea_secret_key",
    "gitea_internal_token",
    "gitea_lfs_jwt_secret",
    "gitea_admin_password",
    "gitea_oauth2_jwt_secret",
    "cloudflare_api_token",
}
if set(source) != expected_keys:
    missing = sorted(expected_keys - set(source))
    unexpected = sorted(set(source) - expected_keys)
    raise SystemExit(f"secret key mismatch; missing={missing}, unexpected={unexpected}")

encrypted_destinations = {
    Path("group_vars/lab/secrets.sops.yaml"): ["cloudflare_api_token"],
    Path("group_vars/gitea_stack/secrets.sops.yaml"): ["gitea_database_password"],
    Path("host_vars/dns/secrets.sops.yaml"): ["technitium_pfx_password"],
    Path("host_vars/gitea/secrets.sops.yaml"): [
        "gitea_s3_access_key",
        "gitea_s3_secret_key",
        "gitea_smtp_password",
        "gitea_secret_key",
        "gitea_internal_token",
        "gitea_lfs_jwt_secret",
        "gitea_admin_password",
        "gitea_oauth2_jwt_secret",
    ],
}

for destination, keys in encrypted_destinations.items():
    destination.parent.mkdir(parents=True, exist_ok=True)
    plaintext = yaml.safe_dump(
        {key: source[key] for key in keys},
        sort_keys=False,
    ).encode()
    encrypted = subprocess.run(
        [
            "sops",
            "encrypt",
            "--filename-override",
            str(destination),
            "/dev/stdin",
        ],
        input=plaintext,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout
    destination.write_bytes(encrypted)

gitea_vars_path = Path("host_vars/gitea/vars.yaml")
gitea_vars = yaml.safe_load(gitea_vars_path.read_text())
for key in (
    "gitea_s3_endpoint",
    "gitea_s3_region",
    "gitea_s3_bucket",
    "gitea_smtp_host",
    "gitea_smtp_port",
    "gitea_smtp_from",
    "gitea_smtp_user",
):
    gitea_vars[key] = source[key]
gitea_vars_path.write_text(
    "---\n" + yaml.safe_dump(gitea_vars, sort_keys=False),
)
```

The helper checks the complete source key set before writing anything. It sends plaintext to SOPS only through stdin and writes only encrypted SOPS output plus the seven deliberately non-secret provider settings.

- [ ] **Step 4: Run the split without exposing plaintext**

Run from `ansible/`:

```bash
umask 077
sops --decrypt group_vars/all/secrets.sops.yaml |
  mise exec -- python /dev/shm/split-ansible-secrets.py
rm /dev/shm/split-ansible-secrets.py
```

Expected: command exits `0`; four destination files exist with encrypted values and individual `sops` metadata blocks. Do not use `tee`, shell tracing, or output redirection on the decrypted side of the pipeline.

- [ ] **Step 5: Validate destination files before deleting the source**

```bash
for secret_file in \
  group_vars/lab/secrets.sops.yaml \
  group_vars/gitea_stack/secrets.sops.yaml \
  host_vars/dns/secrets.sops.yaml \
  host_vars/gitea/secrets.sops.yaml; do
  sops --decrypt "$secret_file" >/dev/null
done
```

Expected: all four decrypt and authenticate with exit code `0` and no plaintext output.

- [ ] **Step 6: Remove obsolete global files and rerun ownership test**

Delete `group_vars/all/vars.yaml` and `group_vars/all/secrets.sops.yaml`, then run:

```bash
mise exec -- ansible-playbook verify-inventory-vars.yaml
```

Expected: PASS for all 55 host/secret ownership combinations; labels show names only.

- [ ] **Step 7: Run deployment syntax and role render checks**

```bash
for playbook in \
  dns.yaml postgres.yaml gitea.yaml kuma.yaml \
  verify-gitea.yaml verify-kuma.yaml verify-postgres.yaml; do
  mise exec -- ansible-playbook --syntax-check "$playbook"
done
for role_test in \
  roles/gitea/tests/render-config.yml \
  roles/lego/tests/render-config.yml \
  roles/postgresql/tests/render-config.yml \
  roles/uptime_kuma/tests/render-config.yml; do
  mise exec -- ansible-playbook "$role_test"
done
```

Expected: every command exits `0`.

- [ ] **Step 8: Scan encrypted diff without displaying values**

```bash
git diff --check
git status --short
rg -n --glob '*.yaml' --glob '!*.sops.yaml' \
  '^(cloudflare_api_token|technitium_pfx_password|gitea_.*(password|secret|token|access_key)):' \
  group_vars host_vars
```

Expected: `rg` finds no secret-valued definitions in normal YAML. Review SOPS files only through encrypted `git diff`; commit only after explicit user approval.

---

### Task 3: Update Secret Tooling And Operations Documentation

**Files:**
- Modify: `mise.toml`
- Modify: `README.md`
- Read only: historical completed plans and specs under `docs/superpowers/`

**Interfaces:**
- Consumes: four destination SOPS paths from Task 2
- Produces: operator commands that select one encrypted file for editing/viewing and validate all encrypted inventory files

- [ ] **Step 1: Make secret tasks multi-file aware**

Replace the fixed-path secret tasks in `mise.toml` with:

```toml
[tasks."secrets:edit"]
description = "Edit one sops-encrypted secrets file selected by SOPS_FILE"
dir = "ansible"
run = 'sops "${SOPS_FILE:?set SOPS_FILE to a path relative to ansible/}"'

[tasks."secrets:view"]
description = "Decrypt one secrets file selected by SOPS_FILE"
dir = "ansible"
run = 'sops --decrypt "${SOPS_FILE:?set SOPS_FILE to a path relative to ansible/}"'

[tasks."secrets:check"]
description = "Authenticate every sops-encrypted inventory file"
dir = "ansible"
run = '''
#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r -d '' secret_file; do
  sops --decrypt "$secret_file" >/dev/null
done < <(find group_vars host_vars -type f -name '*.sops.yaml' -print0 | sort -z)
'''
```

- [ ] **Step 2: Update current README operations**

Update only current operational documentation, not historical completed design/plan records. Make these points explicit:

- List all four encrypted files and explain their ownership.
- Use `SOPS_FILE=host_vars/gitea/secrets.sops.yaml mise run secrets:edit` as the edit example.
- Use `SOPS_FILE=host_vars/gitea/secrets.sops.yaml mise run secrets:view` as the plaintext warning example.
- Use `mise run secrets:check` for non-disclosing authentication of every file.
- Explain that `host_group_vars` merges `lab`, `gitea_stack`, and host scope before the community SOPS vars plugin decrypts matching files.
- Replace single-file `sops updatekeys` guidance with this loop:

```bash
find ansible/group_vars ansible/host_vars -type f -name '*.sops.yaml' -print0 |
  while IFS= read -r -d '' secret_file; do
    sops updatekeys "$secret_file"
  done
```

- [ ] **Step 3: Validate tooling and docs**

Run from repository root:

```bash
mise task ls | rg 'secrets:(edit|view|check)'
mise run secrets:check
rg -n 'group_vars/all/secrets\.sops\.yaml' README.md mise.toml
git diff --check
```

Expected: all three tasks are listed; all encrypted files authenticate; the obsolete global path has no matches in current operational files; diff check exits `0`.

- [ ] **Step 4: Run final repository verification**

Run from `ansible/`:

```bash
mise exec -- ansible-inventory --graph
mise exec -- ansible-playbook verify-inventory-vars.yaml
for playbook in \
  dns.yaml postgres.yaml gitea.yaml kuma.yaml \
  verify-gitea.yaml verify-kuma.yaml verify-postgres.yaml; do
  mise exec -- ansible-playbook --syntax-check "$playbook"
done
for role_test in \
  roles/gitea/tests/render-config.yml \
  roles/lego/tests/render-config.yml \
  roles/postgresql/tests/render-config.yml \
  roles/uptime_kuma/tests/render-config.yml; do
  mise exec -- ansible-playbook "$role_test"
done
```

Then run from repository root:

```bash
mise run secrets:check
git diff --check
git status --short
```

Expected: inventory ownership test, seven syntax checks, four role render tests, all SOPS authentication checks, and diff validation pass. Review status for only planned files and commit only after explicit user approval.
