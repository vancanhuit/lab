# PostgreSQL Lego Hook Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the PostgreSQL lego deploy hook out of the playbook while preserving its content and deployment behavior.

**Architecture:** The PostgreSQL role owns the static shell script under its `files` directory. The playbook reads that file into the existing `lego_hooks.deploy.script` variable, so the lego role contract and remote `/etc/lego/hooks/deploy` path remain unchanged.

**Tech Stack:** Ansible, YAML, POSIX shell

## Global Constraints

- Preserve the hook body byte-for-byte during extraction.
- Keep the existing `lego_hooks.deploy.script` interface.
- Do not change the deployed hook path or runtime behavior.

---

### Task 1: Extract the PostgreSQL deploy hook

**Files:**
- Create: `ansible/roles/postgresql/files/lego-deploy-hook.sh`
- Modify: `ansible/postgres.yaml`

**Interfaces:**
- Consumes: `ansible.builtin.file` lookup and the lego role's `lego_hooks.deploy.script` string variable.
- Produces: The unchanged deploy-hook content supplied to the lego role from a role-owned static file.

- [ ] **Step 1: Capture the current inline hook content**

Copy the complete scalar body below `lego_hooks.deploy.script: |` from `ansible/postgres.yaml`, removing only YAML's ten-space block indentation. Save that exact content as `ansible/roles/postgresql/files/lego-deploy-hook.sh`.

- [ ] **Step 2: Validate the extracted shell script**

Run:

```bash
sh -n ansible/roles/postgresql/files/lego-deploy-hook.sh
```

Expected: exit code 0 with no output.

- [ ] **Step 3: Replace the inline YAML scalar with the file lookup**

Replace the entire `script: |` block in `ansible/postgres.yaml` with:

```yaml
        script: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/roles/postgresql/files/lego-deploy-hook.sh') }}"
```

- [ ] **Step 4: Run focused Ansible validation**

Run:

```bash
cd ansible
ansible-playbook postgres.yaml --syntax-check
ansible-playbook roles/postgresql/tests/render-config.yml
ansible-playbook roles/lego/tests/render-config.yml
```

Expected: the syntax check and both render playbooks complete successfully.

- [ ] **Step 5: Review extraction scope**

Run:

```bash
git diff --check
git diff -- ansible/postgres.yaml ansible/roles/postgresql/files/lego-deploy-hook.sh
```

Expected: no whitespace errors; the diff contains only removal of the inline hook, addition of the lookup, and the identical hook content in the new file.
