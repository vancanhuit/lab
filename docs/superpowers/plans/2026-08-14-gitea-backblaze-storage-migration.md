# Gitea Backblaze Storage Migration Implementation Plan

## Status

Completed on 2026-08-14. The checklist below is retained as the approved
execution procedure.

- Copied 2 objects totaling 4,887 bytes from IDrive e2 to Backblaze.
- Final source and destination object counts and byte totals matched.
- `rclone check --download --one-way` reported 2 matching files and no
  differences.
- Gitea deployment completed with no failed or unreachable hosts.
- `ansible-playbook verify-gitea.yaml` passed all 17 tasks.
- Both migrated avatars returned HTTP 200 through Gitea with exact source sizes.
- Transient migration files were removed; the source bucket remains intact for
  rollback retention.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Copy every Gitea object to Backblaze, cut Gitea over to the new S3-compatible bucket, and verify the live deployment.

**Architecture:** Use pinned `rclone` 1.75.0 with transient environment-based remotes. Run one online copy, stop Gitea, run a final copy and content check, then redeploy with the modified SOPS file. Keep the source bucket unchanged for rollback.

**Tech Stack:** SOPS 3.13.3, rclone 1.75.0, mise, Ansible, systemd, S3-compatible object storage

## Global Constraints

- Never print decrypted SOPS values or place credentials in shell history.
- Never persist plaintext credentials in the repository or home directory.
- Use `copy`, never `sync`, so no destination or source object is deleted.
- Stop Gitea before the final copy and keep it stopped until cutover or rollback.
- Do not delete or modify the source bucket.
- Do not commit changes unless the user explicitly requests a commit.

---

### Task 1: Prepare Secret-Safe rclone Remotes

**Files:**
- Read: `ansible/group_vars/all/secrets.sops.yaml`
- Create temporarily: `/dev/shm/gitea-s3-migration/old-secrets.sops.yaml`
- Create temporarily: `/dev/shm/gitea-s3-migration/run-rclone`

**Interfaces:**
- Consumes: committed source S3 settings from Git `HEAD` and modified Backblaze settings from the working tree
- Produces: a transient runner exposing `source:` and `destination:` rclone remotes without plaintext configuration files

- [ ] **Step 1: Install pinned rclone**

```bash
mise install rclone@1.75.0
mise x rclone@1.75.0 -- rclone version
```

Expected: output begins with `rclone v1.75.0`.

- [ ] **Step 2: Create encrypted source snapshot and transient runner**

Create `/dev/shm/gitea-s3-migration` with mode `0700`. Write the Git `HEAD`
version of the SOPS file to `old-secrets.sops.yaml`; it remains encrypted.
Create `run-rclone` with mode `0700` and this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

current_secrets="$PWD/ansible/group_vars/all/secrets.sops.yaml"

if [[ ${MIGRATION_SECRET_PHASE:-source} == source ]]; then
  export SOURCE_S3_ENDPOINT=$gitea_s3_endpoint
  export SOURCE_S3_REGION=$gitea_s3_region
  export SOURCE_S3_BUCKET=$gitea_s3_bucket
  export SOURCE_S3_ACCESS_KEY=$gitea_s3_access_key
  export SOURCE_S3_SECRET_KEY=$gitea_s3_secret_key
  export MIGRATION_SECRET_PHASE=destination
  exec sops exec-env "$current_secrets" "$0"
fi

export RCLONE_CONFIG_SOURCE_TYPE=s3
export RCLONE_CONFIG_SOURCE_PROVIDER=IDrive
export RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID=$SOURCE_S3_ACCESS_KEY
export RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY=$SOURCE_S3_SECRET_KEY
export RCLONE_CONFIG_SOURCE_ENDPOINT="https://$SOURCE_S3_ENDPOINT"
export RCLONE_CONFIG_SOURCE_REGION=$SOURCE_S3_REGION

export RCLONE_CONFIG_DESTINATION_TYPE=s3
export RCLONE_CONFIG_DESTINATION_PROVIDER=Other
export RCLONE_CONFIG_DESTINATION_ACCESS_KEY_ID=$gitea_s3_access_key
export RCLONE_CONFIG_DESTINATION_SECRET_ACCESS_KEY=$gitea_s3_secret_key
export RCLONE_CONFIG_DESTINATION_ENDPOINT="https://$gitea_s3_endpoint"
export RCLONE_CONFIG_DESTINATION_REGION=$gitea_s3_region

rclone=(mise x rclone@1.75.0 -- rclone)

case ${MIGRATION_ACTION:?MIGRATION_ACTION is required} in
  preflight)
    "${rclone[@]}" lsd "source:$SOURCE_S3_BUCKET"
    "${rclone[@]}" lsd "destination:$gitea_s3_bucket"
    ;;
  size)
    "${rclone[@]}" size "source:$SOURCE_S3_BUCKET" --json
    "${rclone[@]}" size "destination:$gitea_s3_bucket" --json
    ;;
  copy)
    "${rclone[@]}" copy \
      "source:$SOURCE_S3_BUCKET" \
      "destination:$gitea_s3_bucket" \
      --fast-list --transfers 8 --checkers 16 --metadata --progress
    ;;
  check)
    "${rclone[@]}" check \
      "source:$SOURCE_S3_BUCKET" \
      "destination:$gitea_s3_bucket" \
      --download --one-way
    ;;
  *)
    printf 'unsupported MIGRATION_ACTION: %s\n' "$MIGRATION_ACTION" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 3: Validate both bucket connections**

Run from repository root:

```bash
MIGRATION_ACTION=preflight \
  sops exec-env /dev/shm/gitea-s3-migration/old-secrets.sops.yaml \
  /dev/shm/gitea-s3-migration/run-rclone
```

Expected: exit code `0` for both remotes. Stop before migration on any
authentication, endpoint, region, or bucket error.

### Task 2: Run Online Bulk Copy

**Files:**
- Read: `/dev/shm/gitea-s3-migration/run-rclone`

**Interfaces:**
- Consumes: validated source and destination remotes from Task 1
- Produces: first complete Backblaze copy while Gitea remains available

- [ ] **Step 1: Record initial inventories**

```bash
MIGRATION_ACTION=size \
  sops exec-env /dev/shm/gitea-s3-migration/old-secrets.sops.yaml \
  /dev/shm/gitea-s3-migration/run-rclone
```

Expected: two JSON inventory records containing `count` and `bytes`.

- [ ] **Step 2: Copy all current objects**

```bash
MIGRATION_ACTION=copy \
  sops exec-env /dev/shm/gitea-s3-migration/old-secrets.sops.yaml \
  /dev/shm/gitea-s3-migration/run-rclone
```

Expected: exit code `0`, no failed transfers, and no deleted objects.

### Task 3: Freeze Writes and Verify Final Copy

**Files:**
- Read: `ansible/inventory.yaml`
- Read: `/dev/shm/gitea-s3-migration/run-rclone`

**Interfaces:**
- Consumes: online bulk copy from Task 2
- Produces: quiescent, content-verified destination bucket ready for cutover

- [ ] **Step 1: Stop Gitea and confirm inactivity**

Run from `ansible/`:

```bash
mise exec -- ansible gitea -b -m ansible.builtin.systemd_service \
  -a 'name=gitea state=stopped'
mise exec -- ansible gitea -b -m ansible.builtin.shell \
  -a 'test "$(systemctl is-active gitea)" = inactive'
```

Expected: both commands succeed. Do not continue if Gitea remains active.

- [ ] **Step 2: Capture final delta**

Run from repository root:

```bash
MIGRATION_ACTION=copy \
  sops exec-env /dev/shm/gitea-s3-migration/old-secrets.sops.yaml \
  /dev/shm/gitea-s3-migration/run-rclone
```

Expected: exit code `0` and no failed transfers.

- [ ] **Step 3: Compare final inventories and content**

```bash
MIGRATION_ACTION=size \
  sops exec-env /dev/shm/gitea-s3-migration/old-secrets.sops.yaml \
  /dev/shm/gitea-s3-migration/run-rclone
MIGRATION_ACTION=check \
  sops exec-env /dev/shm/gitea-s3-migration/old-secrets.sops.yaml \
  /dev/shm/gitea-s3-migration/run-rclone
```

Expected: source and destination `count` and `bytes` match; `rclone check`
reports no differences or errors. On failure, restart Gitea without deploying
the modified secrets and investigate.

### Task 4: Redeploy and Verify Gitea

**Files:**
- Modify: `ansible/group_vars/all/secrets.sops.yaml` (already modified by user)
- Test: `ansible/verify-gitea.yaml`

**Interfaces:**
- Consumes: verified Backblaze bucket from Task 3
- Produces: live Gitea deployment using Backblaze object storage

- [ ] **Step 1: Deploy Backblaze configuration**

Run from `ansible/`:

```bash
mise exec -- ansible-playbook gitea.yaml
```

Expected: configuration changes, Gitea restarts, HTTPS readiness succeeds, and
play recap contains `failed=0` and `unreachable=0` for both hosts.

- [ ] **Step 2: Run deployment verification**

```bash
mise exec -- ansible-playbook verify-gitea.yaml
```

Expected: every task passes, including version, service state, HTTPS, config,
administrator, and doctor checks.

- [ ] **Step 3: Validate object-backed content**

Open existing Gitea records that exercise storage categories present in this
installation: avatar, issue or release attachment, Git LFS object, and package.
Each existing object must download successfully through Gitea.

- [ ] **Step 4: Remove transient files**

```bash
rm -rf /dev/shm/gitea-s3-migration
```

Expected: transient encrypted snapshot and runner are removed. Keep the old
bucket unchanged for the agreed rollback-retention period.

## Rollback

If post-cutover verification fails, stop Gitea, restore the five
`gitea_s3_*` values from Git `HEAD` with SOPS, run `ansible-playbook gitea.yaml`,
and rerun `verify-gitea.yaml`. Do not copy Backblaze objects back automatically;
first determine whether writes occurred after cutover.
