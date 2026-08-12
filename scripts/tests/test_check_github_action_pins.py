from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from scripts.check_github_action_pins import check_workflows


FULL_SHA = "11d5960a326750d5838078e36cf38b85af677262"


class GitHubActionPinPolicyTests(unittest.TestCase):
    def check(self, source: str) -> tuple[list[str], int]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflow = root / ".github" / "workflows" / "ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(source, encoding="utf-8")
            return check_workflows([workflow], repository_root=root)

    def test_accepts_full_sha_and_local_actions(self) -> None:
        violations, count = self.check(
            f"""steps:
  - uses: actions/checkout@{FULL_SHA} # v4.4.0
    with:
      persist-credentials: false
  - uses: ./local-action
"""
        )
        self.assertEqual(violations, [])
        self.assertEqual(count, 1)

    def test_rejects_mutable_and_abbreviated_refs(self) -> None:
        for ref in ("main", "release", "v4", "deadbee"):
            with self.subTest(ref=ref):
                violations, count = self.check(
                    f"steps:\n  - uses: example/action@{ref}\n"
                )
                self.assertEqual(count, 1)
                self.assertEqual(len(violations), 1)
                self.assertIn("not pinned to a full lowercase commit SHA", violations[0])

    def test_rejects_checkout_that_persists_credentials(self) -> None:
        violations, count = self.check(
            f"steps:\n  - uses: actions/checkout@{FULL_SHA}\n"
        )
        self.assertEqual(count, 1)
        self.assertEqual(len(violations), 1)
        self.assertIn("persist-credentials: false", violations[0])

    def test_accepts_named_checkout_step_with_credentials_disabled(self) -> None:
        violations, count = self.check(
            f"""steps:
  - name: Checkout
    uses: actions/checkout@{FULL_SHA}
    with:
      persist-credentials: false
"""
        )
        self.assertEqual(violations, [])
        self.assertEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
