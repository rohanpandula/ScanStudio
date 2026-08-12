from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFIER_PATH = REPOSITORY_ROOT / "scripts" / "verify_release_notes.py"
COMMITTED_NOTES = REPOSITORY_ROOT / "docs" / "releases" / "v0.7.0-beta.6.md"
TAG = "v0.7.0-beta.6"
VERSION = "0.7.0-beta.6"

_SPEC = importlib.util.spec_from_file_location("verify_release_notes", VERIFIER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
_VERIFIER = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_VERIFIER)


class VerifyReleaseNotesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.valid_text = COMMITTED_NOTES.read_text(encoding="utf-8")

    def make_repository(
        self, text: str | bytes | None = None
    ) -> tuple[tempfile.TemporaryDirectory[str], Path, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        releases = root / "docs" / "releases"
        releases.mkdir(parents=True)
        notes = releases / f"{TAG}.md"
        payload = self.valid_text if text is None else text
        if isinstance(payload, bytes):
            notes.write_bytes(payload)
        else:
            notes.write_text(payload, encoding="utf-8")
        return temporary, root, notes

    def verify(
        self, notes: Path, root: Path, *, tag: str = TAG, version: str = VERSION
    ) -> tuple[int, str]:
        return _VERIFIER.verify_release_notes(
            notes,
            tag,
            version,
            repository_root=root,
        )

    def test_committed_beta6_notes_pass_cli_verification(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(VERIFIER_PATH),
                str(COMMITTED_NOTES),
                TAG,
                VERSION,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn(f"tag={TAG}", completed.stdout)

    def test_release_workflow_binds_draft_and_published_bodies(self) -> None:
        workflow = (
            REPOSITORY_ROOT / ".github" / "workflows" / "release.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'RELEASE_NOTES_PATH="$GITHUB_WORKSPACE/docs/releases/$GITHUB_REF_NAME.md"',
            workflow,
        )
        self.assertEqual(workflow.count('--notes-file "$RELEASE_NOTES"'), 2)
        self.assertEqual(
            workflow.count(
                'assert payload["body"] == notes_path.read_text(encoding="utf-8")'
            ),
            2,
        )
        self.assertNotIn("Write release notes", workflow)

    def test_tag_and_version_must_match_exactly(self) -> None:
        temporary, root, notes = self.make_repository()
        with temporary:
            with self.assertRaisesRegex(
                _VERIFIER.ReleaseNotesError, "tag/version mismatch"
            ):
                self.verify(notes, root, tag="v0.7.0-beta.7")

    def test_version_must_use_the_release_filename_grammar(self) -> None:
        temporary, root, notes = self.make_repository()
        with temporary:
            with self.assertRaisesRegex(
                _VERIFIER.ReleaseNotesError, "invalid release version"
            ):
                self.verify(notes, root, tag="v../../beta.6", version="../../beta.6")

    def test_filename_is_derived_from_the_validated_tag(self) -> None:
        temporary, root, notes = self.make_repository()
        with temporary:
            wrong = notes.with_name("release-notes.md")
            wrong.write_text(self.valid_text, encoding="utf-8")
            with self.assertRaisesRegex(
                _VERIFIER.ReleaseNotesError, "path must be exactly"
            ):
                self.verify(wrong, root)

    def test_symlinked_note_is_rejected(self) -> None:
        temporary, root, notes = self.make_repository()
        with temporary:
            target = root / "outside.md"
            target.write_text(self.valid_text, encoding="utf-8")
            notes.unlink()
            notes.symlink_to(target)
            with self.assertRaisesRegex(
                _VERIFIER.ReleaseNotesError, "must not be a symlink"
            ):
                self.verify(notes, root)

    def test_symlinked_release_directory_is_rejected(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            root = Path(temporary.name)
            docs = root / "docs"
            outside = root / "outside"
            docs.mkdir()
            outside.mkdir()
            notes = outside / f"{TAG}.md"
            notes.write_text(self.valid_text, encoding="utf-8")
            (docs / "releases").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(
                _VERIFIER.ReleaseNotesError, "non-symlink directory"
            ):
                self.verify(notes, root)

    def test_short_or_oversized_notes_are_rejected(self) -> None:
        for payload in (b"short\n", b"x" * (_VERIFIER.MAX_RELEASE_NOTES_BYTES + 1)):
            with self.subTest(size=len(payload)):
                temporary, root, notes = self.make_repository(payload)
                with temporary:
                    with self.assertRaisesRegex(
                        _VERIFIER.ReleaseNotesError, "size must be between"
                    ):
                        self.verify(notes, root)

    def test_invalid_utf8_is_rejected(self) -> None:
        payload = b"\xff" + b"x" * _VERIFIER.MIN_RELEASE_NOTES_BYTES
        temporary, root, notes = self.make_repository(payload)
        with temporary:
            with self.assertRaisesRegex(_VERIFIER.ReleaseNotesError, "not valid UTF-8"):
                self.verify(notes, root)

    def test_nul_and_crlf_are_rejected(self) -> None:
        cases = {
            "NUL byte": self.valid_text.replace(
                "This is a security", "This is a\x00 security", 1
            ),
            "LF line endings": self.valid_text.replace("\n", "\r\n"),
        }
        for message, payload in cases.items():
            with self.subTest(message=message):
                temporary, root, notes = self.make_repository(payload)
                with temporary:
                    with self.assertRaisesRegex(_VERIFIER.ReleaseNotesError, message):
                        self.verify(notes, root)

    def test_exact_title_and_required_sections_are_enforced(self) -> None:
        cases = {
            "bad title": self.valid_text.replace(
                f"# ScanStudio {TAG}", "# ScanStudio wrong", 1
            ),
            "missing section": self.valid_text.replace(
                "## Validation", "## Test results", 1
            ),
            "out of order": self.valid_text.replace(
                "## Everything that changed", "## SECTION-SWAP", 1
            )
            .replace("## Validation", "## Everything that changed", 1)
            .replace("## SECTION-SWAP", "## Validation", 1),
        }
        for name, payload in cases.items():
            with self.subTest(name=name):
                temporary, root, notes = self.make_repository(payload)
                with temporary:
                    with self.assertRaises(_VERIFIER.ReleaseNotesError):
                        self.verify(notes, root)

    def test_required_sections_cannot_be_empty(self) -> None:
        validation_start = self.valid_text.index("## Validation")
        platform_start = self.valid_text.index("## Platform support and installation")
        payload = (
            self.valid_text[:validation_start]
            + "## Validation\n\n"
            + self.valid_text[platform_start:]
        )
        temporary, root, notes = self.make_repository(payload)
        with temporary:
            with self.assertRaisesRegex(
                _VERIFIER.ReleaseNotesError, "section.*is empty"
            ):
                self.verify(notes, root)

    def test_placeholder_tokens_are_rejected(self) -> None:
        payload = self.valid_text.replace(
            "This is a security", "TODO: This is a security", 1
        )
        temporary, root, notes = self.make_repository(payload)
        with temporary:
            with self.assertRaisesRegex(_VERIFIER.ReleaseNotesError, "placeholder"):
                self.verify(notes, root)

    def test_file_requires_lf_termination(self) -> None:
        temporary, root, notes = self.make_repository(self.valid_text.rstrip("\n"))
        with temporary:
            with self.assertRaisesRegex(_VERIFIER.ReleaseNotesError, "end with one LF"):
                self.verify(notes, root)


if __name__ == "__main__":
    unittest.main()
