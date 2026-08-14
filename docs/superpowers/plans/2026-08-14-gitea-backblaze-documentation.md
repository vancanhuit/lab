# Gitea Backblaze Documentation Implementation Plan

## Status

Completed on 2026-08-14. README now documents Backblaze as the current provider,
dated IDrive e2 documents carry scoped supersession notices, and all local links
across 16 Markdown files resolve.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make README and Gitea documentation accurately describe Backblaze as the current object-storage provider while preserving IDrive e2 migration history.

**Architecture:** Treat README as the current operations runbook. Keep dated design and plan files immutable except for explicit status, completion evidence, and supersession notices that point readers to the Backblaze migration record.

**Tech Stack:** Markdown, Ansible runbook documentation, Git

## Global Constraints

- Do not expose decrypted SOPS values, endpoints, bucket names, or credentials.
- Preserve original historical design and plan text.
- Describe IDrive e2 only as the previous provider or historical context.
- Describe Backblaze S3-compatible storage as the current provider.
- Do not commit changes unless explicitly requested.

---

### Task 1: Update Current Operations Runbook

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed migration evidence from `docs/superpowers/specs/2026-08-14-gitea-backblaze-storage-migration-design.md`
- Produces: current prerequisites, deployment instructions, operations guidance, and backup coverage

- [ ] **Step 1: Update provider prerequisites**

Replace IDrive e2 with Backblaze S3-compatible object storage in the required
secret list. Keep the existing SOPS file reference and link Backblaze's S3 API
documentation.

- [ ] **Step 2: Clarify deployment behavior**

State that `gitea.yaml` renders the five `gitea_s3_*` values into Gitea's
`minio` storage backend. Warn that changing those values does not migrate
existing objects and link the completed migration design and plan.

- [ ] **Step 3: Add object-storage operations**

Under Gitea operations, document Backblaze as current storage, list covered
object classes, state that Git repositories remain local, and require
stop-copy-check-redeploy sequencing for future provider changes.

- [ ] **Step 4: Correct backup coverage**

Replace the IDrive e2 backup-coverage row with Backblaze. Explicitly state that
object storage is off-host storage but not an independent backup unless bucket
versioning or replication is configured.

### Task 2: Preserve and Annotate Historical Documents

**Files:**
- Modify: `docs/superpowers/plans/2026-08-14-gitea-backblaze-storage-migration.md`
- Modify: `docs/superpowers/specs/2026-08-09-gitea-1.27-deployment-design.md`
- Modify: `docs/superpowers/plans/2026-08-09-gitea-1.27-deployment.md`

**Interfaces:**
- Consumes: verified migration results already recorded in the 2026-08-14 design
- Produces: visible completion and supersession markers without rewriting history

- [ ] **Step 1: Record migration-plan completion**

Add a completed status and concise results: 2 objects, 4,887 bytes, no content
differences, 17 verification tasks passed, and both avatars served through
Gitea with HTTP 200.

- [ ] **Step 2: Mark old design object-storage section superseded**

Add a notice near the title stating that the 2026-08-14 Backblaze migration
supersedes only current object-storage provider details. Preserve all original
IDrive e2 text as historical design context.

- [ ] **Step 3: Mark old plan object-storage details superseded**

Add the same scoped notice near the title of the 2026-08-09 implementation
plan. Do not alter its original tasks or evidence.

### Task 3: Validate Documentation

**Files:**
- Test: `README.md`
- Test: `docs/superpowers/**/*.md`

**Interfaces:**
- Consumes: Tasks 1 and 2 documentation changes
- Produces: clean Markdown references and no ambiguous current-provider claims

- [ ] **Step 1: Check formatting**

Run:

```bash
git diff --check
```

Expected: exit code 0 with no output.

- [ ] **Step 2: Check local links**

Parse Markdown links with a script and verify every repository-relative target
exists. Ignore HTTPS and fragment-only links.

- [ ] **Step 3: Audit provider references**

Run:

```bash
rg -n 'IDrive|iDrive|Backblaze' README.md docs
```

Expected: README uses Backblaze for current state; IDrive references occur only
in dated historical documents or migration source-provider context.
