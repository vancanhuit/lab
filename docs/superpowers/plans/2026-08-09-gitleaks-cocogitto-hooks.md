# Gitleaks and Cocogitto Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce conventional commit messages and block pushes when Gitleaks finds an unallowlisted secret.

**Architecture:** `mise.toml` pins both binaries and exposes setup and scan tasks. Cocogitto owns embedded `commit-msg` and `pre-push` hooks in `cog.toml`, while `.gitleaks.toml` extends the built-in rules and suppresses only reviewed fixture lines in specific files.

**Tech Stack:** mise, Cocogitto 7.0.0, Gitleaks 8.30.1, Git hooks, TOML

## Global Constraints

- Preserve Gitleaks' built-in rules with `[extend] useDefault = true`.
- Redact all detected secret values from command output.
- Do not allowlist whole files, commits, or broad secret patterns.
- Do not create a Git commit unless the user explicitly requests one.

---

### Task 1: Reproducible Secret Scan

**Files:**
- Modify: `mise.toml`
- Create: `.gitleaks.toml`

**Interfaces:**
- Consumes: mise's Aqua registry entries for `gitleaks` and `cocogitto`.
- Produces: `mise run security:secrets`, a zero-exit full-history secret scan used by the pre-push hook.

- [ ] **Step 1: Pin the security tools and add the scan task**

Add these tool entries under `[tools]`:

```toml
cocogitto = "7.0.0"
gitleaks = "8.30.1"
```

Add this task:

```toml
[tasks."security:secrets"]
description = "Scan Git history for leaked secrets"
run = "gitleaks git --redact --no-banner --log-opts='--all --full-history'"
```

- [ ] **Step 2: Add narrow false-positive handling**

Create `.gitleaks.toml` with the built-in rules enabled and two `generic-api-key` allowlists. Each allowlist must use `condition = "AND"`, `regexTarget = "line"`, an exact path set, and exact reviewed values for either the public Gitea signing fingerprint or deterministic render-test fixtures.

- [ ] **Step 3: Install the pinned tools**

Run: `mise install`

Expected: Cocogitto 7.0.0 and Gitleaks 8.30.1 are installed, and `mise.lock` records their resolved artifacts if lockfile generation applies.

- [ ] **Step 4: Verify the scan succeeds**

Run: `mise run security:secrets`

Expected: exit 0, 18 or more commits scanned, and no leaks reported.

- [ ] **Step 5: Verify real findings remain detectable**

Create a temporary Git repository outside the workspace containing a known fake provider-token shape, copy `.gitleaks.toml` into it, commit the fixture, and run the pinned Gitleaks binary against that repository with redaction.

Expected: exit 1 and the detected value remains redacted. Remove the temporary repository afterward.

### Task 2: Conventional Commit and Pre-push Enforcement

**Files:**
- Create: `cog.toml`
- Modify: `mise.toml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `mise run security:secrets` from Task 1 and Cocogitto's `cog verify --file` command.
- Produces: installable `commit-msg` and `pre-push` hooks plus the `mise run hooks:install` setup command.

- [ ] **Step 1: Declare embedded Cocogitto hooks**

Create `cog.toml`:

```toml
[git_hooks.commit-msg]
script = """#!/bin/sh
set -eu
cog verify --file "$1"
"""

[git_hooks.pre-push]
script = """#!/bin/sh
set -eu
mise run security:secrets
"""
```

- [ ] **Step 2: Add the hook installation task**

Add to `mise.toml`:

```toml
[tasks."hooks:install"]
description = "Install repository Git hooks"
run = "cog install-hook --all --overwrite"
```

- [ ] **Step 3: Document repository setup**

In README's tooling section, run `mise run hooks:install` after `mise install`, explain that the commit hook enforces Conventional Commits, and state that pre-push runs `mise run security:secrets`.

- [ ] **Step 4: Install the hooks**

Run: `mise run hooks:install`

Expected: `.git/hooks/commit-msg` and `.git/hooks/pre-push` are installed from `cog.toml`.

- [ ] **Step 5: Verify commit-message behavior without committing**

Run `cog verify "chore: verify hooks"`, then run `cog verify "verify hooks"` and capture its exit code.

Expected: the conventional message exits 0; the invalid message exits nonzero with a missing type-separator error.

- [ ] **Step 6: Verify installed hook behavior**

Invoke `.git/hooks/commit-msg` with temporary valid and invalid message files. Invoke `.git/hooks/pre-push` with empty standard input.

Expected: valid message and pre-push exit 0; invalid message exits nonzero. Remove temporary message files.

- [ ] **Step 7: Run final checks**

Run:

```sh
mise run security:secrets
cog check
git diff --check
git status --short
```

Expected: the scan, history check, and diff check pass; status lists only `.gitleaks.toml`, `cog.toml`, `mise.toml`, `mise.lock` if generated, README, and the approved spec/plan documents.
