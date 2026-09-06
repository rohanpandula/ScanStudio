from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_hardware_support_docs",
    ROOT / "scripts" / "verify_hardware_support_docs.py",
)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class HardwareSupportDocsTests(unittest.TestCase):
    def fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "docs" / "releases").mkdir(parents=True)
        (root / "app" / "ScanStudio").mkdir(parents=True)
        (root / "docs" / "releases" / "v0.7.0-beta.11.md").write_text("old\n")
        (root / "docs" / "releases" / "v0.7.0-beta.12.md").write_text("new\n")
        (root / "docs" / "HARDWARE-SUPPORT.md").write_text(
            "Latest release notes: [v0.7.0-beta.12]\n"
            "Package built | Device enumerated | Preview exercised | One-frame capture validated\n"
            "closed evidence #24\nclosed evidence #26\nissues/101\nissues/104\n"
        )
        (root / "README.md").write_text("See docs/HARDWARE-SUPPORT.md\n")
        (root / "app" / "ScanStudio" / "README.md").write_text(
            "See ../../docs/HARDWARE-SUPPORT.md\n"
        )
        return root

    def test_accepts_current_canonical_guidance(self) -> None:
        VERIFIER.verify_hardware_support_docs(self.fixture())

    def test_rejects_an_obsolete_release_promise(self) -> None:
        root = self.fixture()
        (root / "README.md").write_text(
            "See docs/HARDWARE-SUPPORT.md; previews ship with v0.3.0-beta.2\n"
        )
        with self.assertRaisesRegex(
            VERIFIER.HardwareSupportDocsError, "obsolete live guidance"
        ):
            VERIFIER.verify_hardware_support_docs(root)

    def test_rejects_closed_validation_issue_without_closed_marker(self) -> None:
        root = self.fixture()
        matrix = root / "docs" / "HARDWARE-SUPPORT.md"
        matrix.write_text(matrix.read_text().replace("closed evidence #24", "issue #24"))
        with self.assertRaisesRegex(
            VERIFIER.HardwareSupportDocsError, "closed validation issue #24"
        ):
            VERIFIER.verify_hardware_support_docs(root)

    def test_rejects_a_stale_current_release(self) -> None:
        root = self.fixture()
        matrix = root / "docs" / "HARDWARE-SUPPORT.md"
        matrix.write_text(matrix.read_text().replace("v0.7.0-beta.12", "v0.7.0-beta.11"))
        with self.assertRaisesRegex(
            VERIFIER.HardwareSupportDocsError, "newest documented release"
        ):
            VERIFIER.verify_hardware_support_docs(root)


if __name__ == "__main__":
    unittest.main()

