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
