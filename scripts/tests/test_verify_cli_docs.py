from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verify_cli_docs", ROOT / "scripts/verify_cli_docs.py")
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class CLIDocsTests(unittest.TestCase):
    def test_repository_passes(self) -> None:
        if not (ROOT / "docs/CLI.md").exists():
            self.skipTest("CLI guide is not present yet")
        VERIFIER.verify_cli_docs(ROOT)

    def test_command_parser_handles_multiple_forms(self) -> None:
        self.assertEqual(
            VERIFIER.parse_command_paths("`frames list` / `frames select <range>|--all|--none`"),
            {"frames list", "frames select"},
        )

    def test_enum_parser_ignores_comment_case(self) -> None:
        self.assertEqual(VERIFIER.parse_exit_codes("// case fake = 1\npublic enum ControlCLIExitCode {\n case ok = 0\n}\n"), {0})

    def fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for relative in (VERIFIER.CONTROL_DOC, VERIFIER.CLI_DOC, VERIFIER.EXIT_SOURCE):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
        control = (ROOT / VERIFIER.CONTROL_DOC).read_text()
        cli = (ROOT / VERIFIER.CLI_DOC).read_text()
        source = (ROOT / VERIFIER.EXIT_SOURCE).read_text()
        (root / VERIFIER.CONTROL_DOC).write_text(control)
        (root / VERIFIER.CLI_DOC).write_text(cli)
        (root / VERIFIER.EXIT_SOURCE).write_text(source)
        return root

    def test_missing_command_names_path(self) -> None:
        root = self.fixture()
        path = root / VERIFIER.CLI_DOC
        path.write_text(path.read_text().replace("roll run", "roll walk"))
        with self.assertRaisesRegex(VERIFIER.CLIDocsError, "roll run"):
            VERIFIER.verify_cli_docs(root)

    def test_extra_exit_code_names_number(self) -> None:
        root = self.fixture()
        path = root / VERIFIER.CLI_DOC
        path.write_text(path.read_text().replace("| 78 |", "| 76 |", 1))
        with self.assertRaisesRegex(VERIFIER.CLIDocsError, "76"):
            VERIFIER.verify_cli_docs(root)

    def test_meaning_mismatch_names_code(self) -> None:
        root = self.fixture()
        path = root / VERIFIER.CLI_DOC
        path.write_text(path.read_text().replace("| 77 | Confirmation required |", "| 77 | Wrong |", 1))
        with self.assertRaisesRegex(VERIFIER.CLIDocsError, "77"):
            VERIFIER.verify_cli_docs(root)

    def test_not_yet_implemented_method_is_allowed(self) -> None:
        root = self.fixture()
        cli_path = root / VERIFIER.CLI_DOC
        cli_path.write_text(cli_path.read_text().replace("review.approve", "review.removed"))
        control_path = root / VERIFIER.CONTROL_DOC
        control = control_path.read_text()
        control_path.write_text(control.replace("## Not yet implemented", "## Not yet implemented\n\n- `review.approve`"))
        VERIFIER.verify_cli_docs(root)


if __name__ == "__main__":
    unittest.main()
