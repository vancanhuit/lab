# PostgreSQL Lego Hook Extraction Design

## Goal

Move the PostgreSQL lego deploy hook out of `ansible/postgres.yaml` without changing its deployed content or behavior.

## Design

- Store the static hook at `ansible/roles/postgresql/files/lego-deploy-hook.sh` because the hook configures PostgreSQL certificate activation and contains no Jinja expressions.
- Keep the existing `lego_hooks.deploy.script` interface used by the lego role.
- Load the script in `ansible/postgres.yaml` with `lookup('ansible.builtin.file', playbook_dir ~ '/roles/postgresql/files/lego-deploy-hook.sh')`.
- Preserve the hook body byte-for-byte during extraction.

## Validation

- Run an Ansible syntax check for `ansible/postgres.yaml`.
- Run the PostgreSQL and lego role render checks to detect regressions in the affected role boundaries.
