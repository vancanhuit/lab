# TruffleHog Secret Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add TruffleHog classification and active verification to the existing Gitleaks-backed secret-scanning command and pre-push gate without printing matched credentials.

**Architecture:** A focused Python JSON-lines filter renders only approved TruffleHog finding metadata. The existing `security:secrets` mise task runs Gitleaks first, then pipes TruffleHog JSON through that filter with Bash `pipefail`, so Cocogitto's unchanged pre-push hook receives the original scanner failure status.

**Tech Stack:** mise, Gitleaks 8.30.1, TruffleHog 3.96.0, Python 3.14.7 standard library, Cocogitto 7.0.0, Bash

## Global Constraints

- Keep `mise run security:secrets` as the public scan command and pre-push entry point.
- Scan TruffleHog results with `--results=verified,unknown` and active verification enabled.
- Fail on selected findings and scan errors.
- Never print raw, redacted, decoded, or provider metadata fields from TruffleHog JSON.
- JSON-escape metadata strings before rendering them to prevent terminal control-sequence injection.
- Preserve the existing Gitleaks command, `.gitleaks.toml`, and `cog.toml` behavior.
- Do not create a Git commit unless the user explicitly requests one.

---

### Task 1: Sanitized TruffleHog Finding Renderer

**Files:**
- Modify: `.gitignore`
- Create: `scripts/sanitize_trufflehog_output.py`
- Create: `scripts/tests/test_sanitize_trufflehog_output.py`

**Interfaces:**
- Consumes: newline-delimited TruffleHog JSON objects on standard input.
- Produces: one safe text line per finding on standard output and exit 0, or a generic parse error on standard error and exit 1.

- [ ] **Step 1: Write failing renderer tests**

Create `scripts/tests/test_sanitize_trufflehog_output.py`:

```python
import json
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sanitize_trufflehog_output.py"


class SanitizeTruffleHogOutputTests(unittest.TestCase):
    def run_filter(self, payload: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=payload,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_emits_only_approved_finding_metadata(self) -> None:
        finding = {
            "DetectorName": "AWS",
            "Verified": True,
            "Raw": "raw-secret-sentinel",
            "RawV2": "raw-v2-secret-sentinel",
            "Redacted": "redacted-secret-sentinel",
            "Decoded": "decoded-secret-sentinel",
            "ExtraData": {"account": "provider-account-sentinel"},
            "SourceMetadata": {
                "Data": {
                    "Git": {
                        "file": "config.yml",
                        "line": 9,
                        "commit": "abc123",
                    }
                }
            },
        }

        result = self.run_filter(json.dumps(finding) + "\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "TruffleHog verified finding: detector=AWS "
            "file=config.yml line=9 commit=abc123\n",
        )
        combined_output = result.stdout + result.stderr
        self.assertNotIn("raw-secret-sentinel", combined_output)
        self.assertNotIn("raw-v2-secret-sentinel", combined_output)
        self.assertNotIn("redacted-secret-sentinel", combined_output)
        self.assertNotIn("decoded-secret-sentinel", combined_output)
        self.assertNotIn("provider-account-sentinel", combined_output)

    def test_escapes_terminal_control_characters_in_metadata(self) -> None:
        finding = {
            "DetectorName": "AWS\x1b",
            "Verified": True,
            "SourceMetadata": {
                "Data": {
                    "Git": {
                        "file": "safe.yml\nforged-output",
                        "line": 9,
                        "commit": "abc\r123",
                    }
                }
            },
        }

        result = self.run_filter(json.dumps(finding) + "\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "TruffleHog verified finding: detector=AWS\\u001b "
            "file=safe.yml\\nforged-output line=9 commit=abc\\r123\n",
        )

    def test_labels_non_verified_selected_results_as_unknown(self) -> None:
        finding = {
            "DetectorName": "Cloudflare",
            "Verified": False,
            "VerificationError": "verification-error-sentinel",
            "SourceMetadata": {
                "Data": {
                    "Git": {
                        "file": "vars.yml",
                        "line": 4,
                        "commit": "def456",
                    }
                }
            },
        }

        result = self.run_filter(json.dumps(finding) + "\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TruffleHog unknown finding", result.stdout)
        self.assertNotIn(
            "verification-error-sentinel",
            result.stdout + result.stderr,
        )

    def test_rejects_malformed_json_without_echoing_input(self) -> None:
        malformed = '{"Raw":"do-not-echo"'

        result = self.run_filter(malformed + "\n")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "TruffleHog emitted malformed JSON\n")
        self.assertNotIn("do-not-echo", result.stderr)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```sh
mise exec -- python -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

Expected: all four tests fail because `scripts/sanitize_trufflehog_output.py` does not exist.

- [ ] **Step 3: Implement the minimal renderer**

Create `scripts/sanitize_trufflehog_output.py`:

```python
import json
import sys
from typing import Any


def mapping(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def safe_scalar(value: object, default: str) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)[1:-1]
    if isinstance(value, int):
        return str(value)
    return default


def render_finding(finding: dict[str, Any]) -> str:
    source_metadata = mapping(finding.get("SourceMetadata"))
    source_data = mapping(source_metadata.get("Data"))
    git_metadata = mapping(source_data.get("Git"))

    status = "verified" if finding.get("Verified") is True else "unknown"
    detector = safe_scalar(finding.get("DetectorName"), "unknown")
    file_name = safe_scalar(git_metadata.get("file"), "unknown")
    line = safe_scalar(git_metadata.get("line"), "unknown")
    commit = safe_scalar(git_metadata.get("commit"), "unknown")

    return (
        f"TruffleHog {status} finding: detector={detector} "
        f"file={file_name} line={line} commit={commit}"
    )


def main() -> int:
    for input_line in sys.stdin:
        if not input_line.strip():
            continue

        try:
            finding = json.loads(input_line)
            if not isinstance(finding, dict):
                raise ValueError
        except (json.JSONDecodeError, ValueError):
            print("TruffleHog emitted malformed JSON", file=sys.stderr)
            return 1

        print(render_finding(finding))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the focused renderer tests**

Run:

```sh
mise exec -- python -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

Expected: four tests pass.

- [ ] **Step 5: Ignore generated Python bytecode**

Add these entries to `.gitignore` and remove any cache generated by the test run:

```gitignore
__pycache__/
*.py[cod]
```

Run:

```sh
rm -rf scripts/tests/__pycache__
git check-ignore -v scripts/tests/__pycache__/test_sanitize_trufflehog_output.cpython-314.pyc
```

Expected: the generated cache is removed and Git reports that the `__pycache__/` rule covers the bytecode path.

### Task 2: Combined Repository Secret Gate

**Files:**
- Modify: `mise.toml`
- Modify: `mise.lock`

**Interfaces:**
- Consumes: `scripts/sanitize_trufflehog_output.py`, Gitleaks 8.30.1, and TruffleHog 3.96.0.
- Produces: `mise run security:secrets`, which exits nonzero for either scanner's findings or operational errors and never emits a raw TruffleHog match.

- [ ] **Step 1: Pin TruffleHog**

Add the tool beside Gitleaks in `mise.toml`:

```toml
trufflehog = "3.96.0"
```

- [ ] **Step 2: Install the pinned release**

Run:

```sh
mise install
mise exec -- trufflehog --version
```

Expected: installation succeeds, `mise.lock` records the Aqua artifact, and the version command reports 3.96.0.

- [ ] **Step 3: Extend the existing scan task**

Replace the current `security:secrets` task body in `mise.toml` with:

```toml
[tasks."security:secrets"]
description = "Scan Git history for leaked secrets"
run = '''
#!/usr/bin/env bash
set -euo pipefail

gitleaks git --redact --no-banner --log-opts='--all --full-history'
trufflehog git file://. \
  --results=verified,unknown \
  --fail \
  --fail-on-scan-errors \
  --no-update \
  --json | \
  python scripts/sanitize_trufflehog_output.py
'''
```

- [ ] **Step 4: Run the focused combined scan**

Run:

```sh
mise run security:secrets
```

Expected: Gitleaks and TruffleHog both complete and the task exits 0 with no findings.

- [ ] **Step 5: Verify real TruffleHog findings are sanitized and blocking**

Run the official public test repository through the same output path:

```sh
set -o pipefail
mise exec -- trufflehog git https://github.com/trufflesecurity/test_keys \
  --results=verified \
  --fail \
  --fail-on-scan-errors \
  --no-update \
  --json | \
    mise exec -- python scripts/sanitize_trufflehog_output.py
trufflehog_exit=$?
set +o pipefail
[[ "$trufflehog_exit" -eq 183 ]]
```

Expected: output contains only detector/status/file/line/commit lines, no raw credential values, and the final assertion exits 0 because the pipeline preserved TruffleHog exit code 183.

### Task 3: Operator Documentation and End-to-End Verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the combined `mise run security:secrets` task from Task 2.
- Produces: operator guidance that accurately describes both scanners, blocking policy, output handling, and active verification.

- [ ] **Step 1: Update the tooling guidance**

Replace the paragraph after the tooling installation commands with:

```markdown
The one-time hook installation configures Cocogitto to reject non-conventional commit messages and runs Gitleaks plus [TruffleHog](https://github.com/trufflesecurity/trufflehog) before every push. Run both secret scanners directly with `mise run security:secrets`.

Gitleaks performs a redacted full-history pattern scan. TruffleHog blocks credentials that are verified as active and candidates whose verification could not complete because of a provider or network error. TruffleHog may contact credential-provider APIs during verification; its repository wrapper reports only detector, status, file, line, and commit metadata so matched values are not printed.
```

- [ ] **Step 2: Re-run focused tests after documentation changes**

Run:

```sh
mise exec -- python -m unittest discover -s scripts/tests -p 'test_*.py' -v
mise run security:secrets
```

Expected: all renderer tests pass and both repository scanners exit 0.

- [ ] **Step 3: Verify the installed pre-push path**

Run:

```sh
.git/hooks/pre-push </dev/null
```

Expected: the hook invokes `mise run security:secrets`; Gitleaks and TruffleHog both pass.

- [ ] **Step 4: Run final repository checks**

Run:

```sh
cog check
git diff --check
git status --short
```

Expected: Cocogitto history and diff checks pass. Status lists only `mise.toml`, `mise.lock`, `README.md`, the renderer and its tests, and the approved spec and plan documents.

- [ ] **Step 5: Inspect the final diff for output-safety regressions**

Run:

```sh
git diff -- README.md mise.toml mise.lock scripts docs/superpowers/specs/2026-08-09-trufflehog-secret-scanning-design.md docs/superpowers/plans/2026-08-09-trufflehog-secret-scanning.md
```

Expected: the diff contains only the approved integration, tests use obvious sentinel strings rather than usable credentials, and no command can print TruffleHog `Raw`, `RawV2`, `Redacted`, decoded, or provider metadata fields.
