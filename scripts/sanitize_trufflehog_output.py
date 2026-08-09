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
