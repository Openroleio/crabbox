"""Regression for the sibling archive/fingerprint exclusion boundary."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class SiblingExclusionsTest(unittest.TestCase):
    def test_secrets_and_caches_neither_transfer_nor_change_fingerprint(self):
        source = Path(__file__).with_name("converge.sh").read_text()
        excludes = next(line for line in source.splitlines() if line.startswith("SIBLING_EXCLUDES="))
        functions = source.split("stream_sibling_archive() {", 1)[1].split('\nfor sib in ', 1)[0]
        harness = excludes + "\nstream_sibling_archive() {" + functions
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "tools"
            root.mkdir()
            (root / "source.ex").write_text("original")

            def run(command):
                return subprocess.check_output(
                    ["bash", "-c", "set -euo pipefail\n" + harness + "\n" + command, "_", str(root)],
                    text=True
                )

            original = run('sibling_content_hash "$1"')
            for name in (".env", "nested/.env.local", "nested/key.pem", "secret.key",
                         "nested/deps/cache", ".dev_tools/cache", "_build/beam", "tmp/log",
                         "nested/target/object", "nested/__pycache__/bytecode"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("excluded fixture")
            self.assertEqual(run('sibling_content_hash "$1"'), original)
            entries = run('stream_sibling_archive "$1" tools | tar -tzf -').splitlines()
            files = [entry for entry in entries if not entry.endswith("/")]
            self.assertEqual(files, ["tools/source.ex"])
            (root / "source.ex").write_text("working tree change")
            self.assertNotEqual(run('sibling_content_hash "$1"'), original)


if __name__ == "__main__":
    unittest.main()
