from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "create-incus-instance.py"


class CreateIncusInstanceTests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "test-instance", *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_block_storage_requires_vm(self) -> None:
        result = self.run_script(
            "--storage-type",
            "block",
            "--storage-pool",
            "pool1",
            "--storage-size",
            "100GiB",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("block storage requires --vm", result.stderr)

    def test_block_storage_rejects_guest_path(self) -> None:
        result = self.run_script(
            "--vm",
            "--storage-type",
            "block",
            "--storage-pool",
            "pool1",
            "--storage-size",
            "100GiB",
            "--storage-path",
            "/var/lib/docker",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("does not accept --storage-path", result.stderr)


if __name__ == "__main__":
    unittest.main()
