from __future__ import annotations

import importlib.util
import io
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPOSITORY_ROOT / "scripts" / "check_github_action_pins.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_github_action_pins", CHECKER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GitHubActionPinPolicyTests(unittest.TestCase):
    def run_policy(self, workflow: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            workflow_root = root / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            (workflow_root / "test.yml").write_text(workflow, encoding="utf-8")
            checker = load_checker()
            checker.REPOSITORY_ROOT = root
            checker.WORKFLOW_ROOT = workflow_root
            output = io.StringIO()
            with redirect_stdout(output), redirect_stderr(output):
                result = checker.main()
            return result, output.getvalue()

    def test_full_sha_and_checkout_credential_fence_pass(self) -> None:
        result, output = self.run_policy(
            """jobs:
  test:
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          persist-credentials: false
      - uses: owner/action@0123456789abcdef0123456789abcdef01234567
"""
        )
        self.assertEqual(result, 0, output)

    def test_every_mutable_or_abbreviated_ref_is_rejected(self) -> None:
        for unsafe_ref in (
            "v4",
            "main",
            "release",
            "v4.2.2",
            "0123456789abcdef0123456789abcdef0123456",
        ):
            with self.subTest(unsafe_ref=unsafe_ref):
                result, output = self.run_policy(
                    f"""jobs:
  test:
    steps:
      - uses: owner/action@{unsafe_ref}
"""
                )
                self.assertEqual(result, 1)
                self.assertIn("not pinned to a full lowercase commit SHA", output)

    def test_checkout_must_disable_persisted_credentials(self) -> None:
        result, output = self.run_policy(
            """jobs:
  test:
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
"""
        )
        self.assertEqual(result, 1)
        self.assertIn("persist-credentials: false", output)


if __name__ == "__main__":
    unittest.main()
