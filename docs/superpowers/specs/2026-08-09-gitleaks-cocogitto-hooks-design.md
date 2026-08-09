# Gitleaks and Cocogitto Hooks Design

## Goal

Prevent non-conventional commit messages and secret-bearing pushes with repository-managed tooling.

## Tooling

- Pin Cocogitto 7.0.0 and Gitleaks 8.30.1 in `mise.toml`.
- Keep installation reproducible through the existing `mise install` workflow.

## Tasks and Hooks

- Add a `security:secrets` mise task that runs Gitleaks against Git history with redacted output.
- Add a `hooks:install` mise task that installs all hooks declared in `cog.toml`.
- Configure Cocogitto's `commit-msg` hook to validate the proposed message with `cog verify --file "$1"`.
- Configure Cocogitto's `pre-push` hook to run `mise run security:secrets` and block the push on a real finding.
- Use embedded hook scripts because both hooks are short and need no standalone script lifecycle.

## False Positives

Extend Gitleaks' default rules and allowlist only the exact public signing fingerprint and deterministic test fixtures already reviewed in this repository. Do not allowlist entire files or broad secret-like patterns.

## Setup and Verification

Document `mise run hooks:install` as a one-time step after cloning. Verify the configuration by installing tools and hooks, running the secret scan, accepting a valid conventional message, rejecting an invalid message, and confirming the worktree contains only intended files.
