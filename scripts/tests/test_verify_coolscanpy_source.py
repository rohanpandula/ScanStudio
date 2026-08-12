from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import tomllib
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFIER = REPOSITORY_ROOT / "scripts" / "verify_coolscanpy_source.py"
VENDORED_SOURCE = REPOSITORY_ROOT / "ports" / "tauri" / "vendor" / "coolscanpy"
with (VENDORED_SOURCE / "pyproject.toml").open("rb") as _pyproject_handle:
    PROJECT_VERSION = tomllib.load(_pyproject_handle)["project"]["version"]


class VerifyCoolscanPySourceTests(unittest.TestCase):
    def run_verifier(
        self, source: Path, *arguments: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(VERIFIER),
                str(source),
                *arguments,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_exact_vendored_source_passes(self) -> None:
        completed = self.run_verifier(VENDORED_SOURCE)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_one_byte_source_mutation_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "coolscanpy"
            shutil.copytree(VENDORED_SOURCE, source)
            usb_backend = (
                source
                / "src"
                / "coolscanpy"
                / "protocol"
                / "ls5000_single_pass"
                / "usb_backend.py"
            )
            payload = bytearray(usb_backend.read_bytes())
            payload[-1] ^= 1
            usb_backend.write_bytes(payload)

            completed = self.run_verifier(source)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("usb_backend.py SHA-256 mismatch", completed.stderr)

    def test_generated_metadata_and_provenance_must_match_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            metadata_root = root / "site-packages"
            dist_info = metadata_root / f"coolscanpy-{PROJECT_VERSION}.dist-info"
            dist_info.mkdir(parents=True)
            (dist_info / "METADATA").write_text(
                "Metadata-Version: 2.1\nName: coolscanpy\n"
                f"Version: {PROJECT_VERSION}\n",
                encoding="utf-8",
            )
            provenance = root / "provenance.json"
            provenance.write_text(
                json.dumps(
                    {"sources": {"coolscanpy": {"version": PROJECT_VERSION}}}
                ),
                encoding="utf-8",
            )

            completed = self.run_verifier(
                VENDORED_SOURCE,
                "--metadata-root",
                str(metadata_root),
                "--provenance",
                str(provenance),
            )
            self.assertEqual(
                completed.returncode, 0, completed.stdout + completed.stderr
            )

            provenance.write_text(
                json.dumps({"sources": {"coolscanpy": {"version": "0.0.0"}}}),
                encoding="utf-8",
            )
            completed = self.run_verifier(
                VENDORED_SOURCE,
                "--metadata-root",
                str(metadata_root),
                "--provenance",
                str(provenance),
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("does not report CoolscanPy project version", completed.stderr)


if __name__ == "__main__":
    unittest.main()
