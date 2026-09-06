from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_scanner_contract_docs",
    ROOT / "scripts" / "verify_scanner_contract_docs.py",
)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class ScannerContractDocsTests(unittest.TestCase):
    def fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for relative in VERIFIER.CURRENT_DOCS:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("current guidance\n")
        (root / "app/ScanStudio/protocol/PROTOCOL.md").write_text(
            "re-reads the fresh manifest while holding the project lock\n"
            "refuses rather than publish if fresh-disk receipt coverage would be lost\n"
        )
        (root / "app/ScanStudio/protocol/BRIDGE.md").write_text(
            "leading and trailing edges are intentionally asymmetric\n"
            "exactly one preview row\n"
            "trailing frame with at least 90%\n"
            "Eject does not require SANE or `scanimage`\n"
            "legacy plain-scan path\n"
        )
        return root

    def test_accepts_current_contracts(self) -> None:
        VERIFIER.verify_scanner_contract_docs(self.fixture())

    def test_rejects_stale_receipt_warning(self) -> None:
        root = self.fixture()
        path = root / "README.md"
        path.write_text("mutators do not re-read the manifest before writing\n")
        with self.assertRaisesRegex(
            VERIFIER.ScannerContractDocsError, "obsolete contract text"
        ):
            VERIFIER.verify_scanner_contract_docs(root)

    def test_rejects_sane_eject_dependency(self) -> None:
        root = self.fixture()
        path = root / "app/ScanStudio/README.md"
        path.write_text("real eject needs the [scanner] extra plus SANE\n")
        with self.assertRaisesRegex(
            VERIFIER.ScannerContractDocsError, "obsolete contract text"
        ):
            VERIFIER.verify_scanner_contract_docs(root)

    def test_requires_leading_trailing_asymmetry(self) -> None:
        root = self.fixture()
        path = root / "app/ScanStudio/protocol/BRIDGE.md"
        path.write_text(path.read_text().replace(
            "leading and trailing edges are intentionally asymmetric\n", ""
        ))
        with self.assertRaisesRegex(
            VERIFIER.ScannerContractDocsError, "intentionally asymmetric"
        ):
            VERIFIER.verify_scanner_contract_docs(root)


if __name__ == "__main__":
    unittest.main()

