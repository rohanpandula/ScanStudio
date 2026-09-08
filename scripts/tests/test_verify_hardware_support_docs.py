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
            "## Model compatibility\n"
            "| Model | Adapter | Verified on | Evidence | Status |\n"
            "| --- | --- | --- | --- | --- |\n"
            "| LS-5000 ED | SA-30 | macOS | run | Verified — supported |\n"
            "| LS-50 ED | unknown | none | none | unverified |\n"
            "| LS-4000 ED | unknown | none | none | Recognized by name only |\n"
            "## Testing an unverified scanner\n"
        )
        driver = root / "coolscanpy/src/coolscanpy/_device.py"
        driver.parent.mkdir(parents=True)
        driver.write_text(
            '_CANONICAL_LS5000_MODEL = "LS-5000 ED"\n'
            '_LS5000_USB_VENDOR_ID = 0x04B0\n_LS5000_USB_PRODUCT_ID = 0x4002\n'
            '_NIKON_COOLSCAN_USB_MODELS: dict = {_LS5000_USB_VENDOR_ID: '
            '{_LS5000_USB_PRODUCT_ID: "LS-5000 ED", 0x4001: "LS-50 ED"}}\n'
            '_SANE_COOLSCAN_MODEL_MARKERS: tuple = (("LS-4000", "LS-4000 ED"),)\n'
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

    def test_model_evidence_and_driver_structure_fail_closed(self) -> None:
        for old, new, error in (
            ("| LS-50 ED |", "| Imaginary model |", "LS-50 ED"),
            ("Verified — supported", "unverified", "LS-5000 ED"),
            ("## Testing an unverified scanner", "", "Testing an unverified"),
        ):
            with self.subTest(change=old):
                root = self.fixture()
                matrix = root / "docs/HARDWARE-SUPPORT.md"
                matrix.write_text(matrix.read_text().replace(old, new))
                with self.assertRaisesRegex(VERIFIER.HardwareSupportDocsError, error):
                    VERIFIER.verify_hardware_support_docs(root)
        root = self.fixture()
        driver = root / "coolscanpy/src/coolscanpy/_device.py"
        driver.write_text(driver.read_text() + "\n_NIKON_COOLSCAN_USB_MODELS = dynamic()\n")
        with self.assertRaisesRegex(VERIFIER.HardwareSupportDocsError, "no longer a literal"):
            VERIFIER.verify_hardware_support_docs(root)


if __name__ == "__main__":
    unittest.main()
