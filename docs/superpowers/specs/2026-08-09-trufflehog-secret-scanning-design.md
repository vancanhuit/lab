# TruffleHog Secret Scanning Design

## Goal

Complement Gitleaks with TruffleHog's credential classification and active verification while preserving one repository-managed secret-scanning gate.

## Tooling and Integration

- Pin TruffleHog 3.96.0 in `mise.toml` through mise's official Aqua registry entry.
- Keep `mise run security:secrets` as the public scan command used by operators and the existing Cocogitto pre-push hook.
- Run the existing redacted Gitleaks full-history scan first, then scan the local Git repository with TruffleHog.
- Do not change `.gitleaks.toml` or `cog.toml`; TruffleHog complements the current detector and inherits the existing hook path.

## TruffleHog Policy

Run TruffleHog against `file://.` with these controls:

- `--results=verified,unknown` blocks credentials confirmed active and candidates whose verification failed because of a provider or network error.
- `--fail` returns exit code 183 when a selected result is found.
- `--fail-on-scan-errors` blocks a push when the scan is incomplete or encounters an operational error.
- `--no-update` prevents a pinned invocation from performing an update check.
- `--json` provides structured findings for safe rendering.

TruffleHog may contact credential-provider APIs to verify candidates. This network behavior is intentional and must be documented for operators.

## Output Safety

TruffleHog's native text and JSON output can contain the raw matched credential. Add a small Python JSON-lines filter under `scripts/` that emits only:

- detector name;
- verification status;
- repository-relative file and line;
- commit identifier.

The filter must never print raw, redacted, decoded, or provider metadata fields. The mise task must execute the TruffleHog-to-filter pipeline with Bash `pipefail` so a finding's exit code 183 or a scan error remains nonzero after filtering.

All rendered metadata strings must use JSON-style escaping so repository-controlled filenames and other Git metadata cannot inject new terminal lines or ANSI/OSC control sequences.

Malformed JSON from TruffleHog is an integration error. The filter must report the parsing failure without echoing the input line and exit nonzero.

## Documentation

Update the tooling section of `README.md` to state that `mise run security:secrets` and the pre-push hook run both Gitleaks and TruffleHog. Document the `verified,unknown` blocking policy, active provider verification, and sanitized finding output.

## Verification

- Install the pinned TruffleHog release and confirm `mise.lock` records it.
- Feed representative TruffleHog JSON into the filter and confirm only approved metadata appears.
- Confirm newlines and terminal control characters in metadata are escaped onto one safe output line.
- Confirm malformed JSON fails without reproducing the malformed input.
- Confirm a Bash `pipefail` check preserves an upstream exit code 183 through the filter.
- Run `mise run security:secrets` against the repository and require a clean exit.
- Invoke the installed pre-push hook and require the combined gate to pass.
- Run the existing repository checks and inspect the final diff for unintended changes or exposed test credentials.
