from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile


PACKAGING_ROOT = Path(__file__).resolve().parents[1]
VERIFIER_PATH = PACKAGING_ROOT / "verify_python_artifact_lock.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_python_artifact_lock", VERIFIER_PATH
)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PythonArtifactLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.wheel = self.artifacts / "demo-1.0-py3-none-any.whl"
        with zipfile.ZipFile(
            self.wheel, "w", compression=zipfile.ZIP_DEFLATED
        ) as archive:
            archive.writestr("demo/__init__.py", "VALUE = 1\n")
            archive.writestr(
                "demo-1.0.dist-info/METADATA", "Name: demo\nVersion: 1.0\n"
            )
        self.sdist = self.artifacts / "python_sane-2.9.2.tar.gz"
        self._write_sdist()
        self.lock = self.root / "lock.json"
        self.wheel_requirements = self.root / "wheels.txt"
        self.sdist_requirements = self.root / "sdist.txt"
        self.combined_requirements = self.root / "combined.txt"
        self.ledger = self.root / "SHA256SUMS"
        self._write_lock()

    def _write_sdist(
        self, unsafe_name: str | None = None, symlink: bool = False
    ) -> None:
        with tarfile.open(self.sdist, "w:gz") as archive:
            root = tarfile.TarInfo("python_sane-2.9.2")
            root.type = tarfile.DIRTYPE
            root.mode = 0o755
            archive.addfile(root)
            payload = b"GPL fixture\n"
            member = tarfile.TarInfo(unsafe_name or "python_sane-2.9.2/COPYING")
            if symlink:
                member.type = tarfile.SYMTYPE
                member.linkname = "../outside"
                archive.addfile(member)
            else:
                member.size = len(payload)
                member.mode = 0o644
                archive.addfile(member, io.BytesIO(payload))
            metadata = b"Name: python-sane\nVersion: 2.9.2\n"
            member = tarfile.TarInfo("python_sane-2.9.2/PKG-INFO")
            member.size = len(metadata)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(metadata))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_lock(self) -> None:
        wheel_hash = sha256(self.wheel)
        sdist_hash = sha256(self.sdist)
        payload = {
            "schemaVersion": 1,
            "target": {
                "implementation": "cp",
                "pythonVersion": "313",
                "abi": "cp313",
                "platform": "manylinux_2_28_x86_64",
            },
            "artifacts": [
                {
                    "name": "demo",
                    "version": "1.0",
                    "kind": "wheel",
                    "roles": ["runtime"],
                    "filename": self.wheel.name,
                    "size": self.wheel.stat().st_size,
                    "sha256": wheel_hash,
                },
                {
                    "name": "python-sane",
                    "version": "2.9.2",
                    "kind": "sdist",
                    "roles": ["build", "runtime"],
                    "filename": self.sdist.name,
                    "size": self.sdist.stat().st_size,
                    "sha256": sdist_hash,
                },
            ],
        }
        self.lock.write_text(json.dumps(payload), encoding="utf-8")
        wheel_line = f"demo==1.0 --hash=sha256:{wheel_hash}\n"
        sdist_line = f"python-sane==2.9.2 --hash=sha256:{sdist_hash}\n"
        self.wheel_requirements.write_text(wheel_line, encoding="utf-8")
        self.sdist_requirements.write_text(sdist_line, encoding="utf-8")
        self.combined_requirements.write_text(wheel_line + sdist_line, encoding="utf-8")
        entries = sorted(((self.wheel.name, wheel_hash), (self.sdist.name, sdist_hash)))
        self.ledger.write_text(
            "".join(f"{digest}  {filename}\n" for filename, digest in entries),
            encoding="ascii",
        )

    def args(self, *extra: str) -> list[str]:
        return [
            "--lock",
            str(self.lock),
            "--wheel-requirements",
            str(self.wheel_requirements),
            "--sdist-requirements",
            str(self.sdist_requirements),
            "--combined-requirements",
            str(self.combined_requirements),
            "--sha256sums",
            str(self.ledger),
            "--directory",
            str(self.artifacts),
            *extra,
        ]

    def test_accepts_exact_set_and_extracts_bounded_regular_files(self) -> None:
        destination = self.root / "extracted"
        self.assertEqual(
            VERIFIER.main(
                self.args(
                    "--extract-wheels", str(destination), "--wheel-role", "runtime"
                )
            ),
            0,
        )
        self.assertEqual(
            (destination / "demo" / "__init__.py").read_text(), "VALUE = 1\n"
        )
        self.assertFalse((destination / "demo" / "__init__.py").is_symlink())
        sdist_destination = self.root / "sdist-extracted"
        self.assertEqual(
            VERIFIER.main(self.args("--extract-sdist", str(sdist_destination))),
            0,
        )
        self.assertEqual(
            (sdist_destination / "python_sane-2.9.2" / "COPYING").read_text(),
            "GPL fixture\n",
        )

    def test_rejects_tampered_artifact(self) -> None:
        self.wheel.write_bytes(self.wheel.read_bytes() + b"tamper")
        self.assertEqual(VERIFIER.main(self.args()), 1)

    def test_bounded_reader_rejects_different_second_held_read(self) -> None:
        path = self.root / "bounded.txt"
        path.write_bytes(b"first")
        real_read = VERIFIER.os.read
        calls = 0

        def changing_read(descriptor: int, size: int) -> bytes:
            nonlocal calls
            calls += 1
            chunk = real_read(descriptor, size)
            # Each five-byte pass is followed by its EOF read. Return different
            # bytes on the second pass while preserving the snapshotted size.
            if calls == 3 and chunk == b"first":
                return b"other"
            return chunk

        with mock.patch.object(VERIFIER.os, "read", side_effect=changing_read):
            with self.assertRaisesRegex(VERIFIER.LockError, "changed while"):
                VERIFIER.bounded_bytes(path, 64, "fixture")

    def test_bounded_reader_ignores_unstable_windows_fstat_identity_fields(
        self,
    ) -> None:
        path = self.root / "bounded-windows.txt"
        path.write_bytes(b"stable")
        real_fstat = VERIFIER.os.fstat
        calls = 0

        def windows_style_fstat(descriptor: int) -> os.stat_result:
            nonlocal calls
            calls += 1
            value = list(real_fstat(descriptor))
            # Windows hosted runners can expose different synthetic st_dev and
            # st_ino values for repeated fstat calls on the same held handle.
            value[1] = calls
            value[2] = calls + 100
            return os.stat_result(value)

        with mock.patch.object(VERIFIER.os, "fstat", side_effect=windows_style_fstat):
            self.assertEqual(VERIFIER.bounded_bytes(path, 64, "fixture"), b"stable")

    def test_all_low_level_artifact_io_requests_windows_binary_mode(self) -> None:
        source = VERIFIER_PATH.read_text(encoding="utf-8")
        self.assertEqual(source.count('getattr(os, "O_BINARY", 0)'), 5)
        self.assertNotRegex(
            source,
            r"os\.open\([^\n]+os\.O_RDONLY\s*\|\s*nofollow\s*\)",
        )
        self.assertNotIn("st_mtime_ns", source)

    def test_rejects_unexpected_artifact(self) -> None:
        (self.artifacts / "surprise.whl").write_bytes(b"unexpected")
        self.assertEqual(VERIFIER.main(self.args()), 1)

    def test_rejects_wrong_combined_requirement_hash(self) -> None:
        self.combined_requirements.write_text(
            "demo==1.0 --hash=sha256:"
            + "0" * 64
            + "\n"
            + self.sdist_requirements.read_text(),
            encoding="utf-8",
        )
        self.assertEqual(VERIFIER.main(self.args()), 1)

    def test_rejects_traversal_before_extraction(self) -> None:
        with zipfile.ZipFile(self.wheel, "w") as archive:
            archive.writestr("../outside", "escape")
        self._write_lock()
        destination = self.root / "extract-traversal"
        self.assertEqual(
            VERIFIER.main(self.args("--extract-wheels", str(destination))),
            1,
        )
        self.assertFalse((self.root / "outside").exists())

    def test_rejects_sdist_traversal_before_extraction(self) -> None:
        self._write_sdist("../outside")
        self._write_lock()
        destination = self.root / "extract-sdist-traversal"
        self.assertEqual(
            VERIFIER.main(self.args("--extract-sdist", str(destination))),
            1,
        )
        self.assertFalse((self.root / "outside").exists())

    def test_rejects_sdist_links(self) -> None:
        self._write_sdist(symlink=True)
        self._write_lock()
        destination = self.root / "extract-sdist-link"
        self.assertEqual(
            VERIFIER.main(self.args("--extract-sdist", str(destination))),
            1,
        )
        self.assertFalse((self.root / "outside").exists())

    def test_committed_lock_and_requirements_are_coherent(self) -> None:
        self.assertEqual(
            VERIFIER.main(
                [
                    "--lock",
                    str(
                        PACKAGING_ROOT / "python-artifacts-linux-cp313-x86_64.lock.json"
                    ),
                    "--wheel-requirements",
                    str(
                        PACKAGING_ROOT
                        / "python-wheels-linux-cp313-x86_64.requirements.txt"
                    ),
                    "--sdist-requirements",
                    str(
                        PACKAGING_ROOT
                        / "python-sane-linux-cp313-x86_64.requirements.txt"
                    ),
                    "--sha256sums",
                    str(PACKAGING_ROOT / "python-artifacts-linux-cp313-x86_64.sha256"),
                ]
            ),
            0,
        )

    def test_both_assemblers_use_one_exact_hash_required_target_download(self) -> None:
        for relative in ("windows/assemble-staging.sh", "linux/assemble-staging.sh"):
            source = (PACKAGING_ROOT / relative).read_text(encoding="utf-8")
            self.assertEqual(
                source.count("--no-cache-dir download --require-hashes"), 1, relative
            )
            self.assertIn("--no-deps --only-binary=:all:", source, relative)
            self.assertIn(
                "--python-version 313 --implementation cp --abi cp313", source, relative
            )
            self.assertIn("--platform manylinux_2_28_x86_64", source, relative)
            self.assertIn("--index-url https://pypi.org/simple", source, relative)
            self.assertIn(
                '--directory "$python_artifacts"',
                source.replace("$wheelhouse", "$python_artifacts"),
                relative,
            )


if __name__ == "__main__":
    unittest.main()
