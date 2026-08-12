from __future__ import annotations

import importlib.util
import io
import os
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPOSITORY_ROOT / "scripts" / "check_github_action_pins.py"
GENERIC_ACTION = "owner/action@0123456789abcdef0123456789abcdef01234567"
CHECKOUT_ACTION = "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
SETUP_UV_ACTION = "astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9"
SETUP_PYTHON_ACTION = "actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065"
SETUP_NODE_ACTION = "actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020"
RUST_TOOLCHAIN_ACTION = (
    "dtolnay/rust-toolchain@4360b52568e2003a75bf9bc1d59f33a8e3fc893c"
)


def load_checker():
    spec = importlib.util.spec_from_file_location(
        "check_github_action_pins", CHECKER_PATH
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GitHubActionPinPolicyTests(unittest.TestCase):
    def run_policy_data(self, workflow: bytes) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            workflow_root = root / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            (workflow_root / "test.yml").write_bytes(workflow)
            checker = load_checker()
            checker.REPOSITORY_ROOT = root
            checker.WORKFLOW_ROOT = workflow_root
            output = io.StringIO()
            with redirect_stdout(output), redirect_stderr(output):
                result = checker.main()
            return result, output.getvalue()

    def run_policy(self, workflow: str) -> tuple[int, str]:
        return self.run_policy_data(workflow.encode("utf-8"))

    def assert_rejected(self, workflow: str, expected: str) -> None:
        result, output = self.run_policy(workflow)
        self.assertEqual(result, 1, output)
        self.assertIn(expected, output)

    def test_canonical_checkout_rust_and_literal_path_pass(self) -> None:
        result, output = self.run_policy(
            f"""name: Canonical
on:
  push:
jobs:
  test:
    env:
      UV_PYTHON_PREFERENCE: only-managed
      UV_PYTHON_CPYTHON_BUILD: "20260718"
    steps:
      - uses: {CHECKOUT_ACTION}
        with:
          persist-credentials: false
      - uses: {RUST_TOOLCHAIN_ACTION}
        with:
          toolchain: '1.97.1'
      - uses: {GENERIC_ACTION}
        with:
          path: |
            first artifact
            second artifact
"""
        )
        self.assertEqual(result, 0, output)
        self.assertIn("3 external uses entries", output)

    def test_every_mutable_abbreviated_or_uppercase_sha_ref_is_rejected(self) -> None:
        for unsafe_ref in (
            "v4",
            "main",
            "release",
            "v4.2.2",
            "0123456789abcdef0123456789abcdef0123456",
            "0123456789ABCDEF0123456789ABCDEF01234567",
        ):
            with self.subTest(unsafe_ref=unsafe_ref):
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - uses: owner/action@{unsafe_ref}
""",
                    "not pinned to a full lowercase commit SHA",
                )

    def test_reusable_job_uses_is_structurally_inspected(self) -> None:
        result, output = self.run_policy(
            """jobs:
  delegated:
    uses: owner/repository/.github/workflows/build.yml@0123456789abcdef0123456789abcdef01234567
"""
        )
        self.assertEqual(result, 0, output)
        self.assert_rejected(
            """jobs:
  delegated:
    uses: owner/repository/.github/workflows/build.yml@main
""",
            "not pinned to a full lowercase commit SHA",
        )

    def test_literal_run_block_cannot_create_a_uses_decoy(self) -> None:
        result, output = self.run_policy(
            f"""jobs:
  test:
    steps:
      - name: Text that resembles workflow YAML
        run: |
          - uses: attacker/action@main
          uses: attacker/action@0123456789abcdef0123456789abcdef01234567
          with:
            persist-credentials: false
      - uses: {GENERIC_ACTION}
"""
        )
        self.assertEqual(result, 0, output)
        self.assertIn("1 external uses entries", output)

    def test_literal_block_decoy_does_not_satisfy_action_requirement(self) -> None:
        self.assert_rejected(
            """jobs:
  test:
    steps:
      - run: |
          uses: owner/action@0123456789abcdef0123456789abcdef01234567
""",
            "no external workflow actions were found",
        )

    def test_quoted_uses_and_quoted_mapping_key_are_rejected(self) -> None:
        for workflow in (
            f"""jobs:
  test:
    steps:
      - uses: "{GENERIC_ACTION}"
""",
            f"""jobs:
  test:
    steps:
      - 'uses': {GENERIC_ACTION}
""",
        ):
            with self.subTest(workflow=workflow):
                self.assert_rejected(workflow, "policy failed")

    def test_flow_mapping_and_flow_steps_cannot_hide_actions(self) -> None:
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - {{uses: {GENERIC_ACTION}}}
""",
            "flow mappings are forbidden",
        )
        self.assert_rejected(
            f"""jobs:
  test:
    steps: ["uses: {GENERIC_ACTION}"]
""",
            "steps must be a block sequence of mappings",
        )

    def test_folded_and_unexpected_block_scalars_are_rejected(self) -> None:
        for indicator in (">", ">-", "|-"):
            with self.subTest(indicator=indicator):
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - run: {indicator}
          uses: {GENERIC_ACTION}
""",
                    "block",
                )
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - uses: {GENERIC_ACTION}
        with:
          manifest: |
            unreviewed
""",
            "block scalars are allowed only for run and path",
        )

    def test_yaml_invalid_plain_scalar_indicators_are_rejected(self) -> None:
        for value, expected in (
            ("python -c release: 1.97.1", "colon followed by whitespace"),
            ("@mutable", "reserved YAML indicator"),
            ("`mutable`", "reserved YAML indicator"),
        ):
            with self.subTest(value=value):
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - run: {value}
      - uses: {GENERIC_ACTION}
""",
                    expected,
                )

    def test_local_and_docker_action_wrappers_are_forbidden(self) -> None:
        for action, expected in (
            ("./.github/actions/wrapper", "local action wrappers are forbidden"),
            ("docker://alpine:3.22", "docker action wrappers are forbidden"),
        ):
            with self.subTest(action=action):
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - uses: {action}
""",
                    expected,
                )

    def test_duplicate_keys_are_rejected_at_every_security_boundary(self) -> None:
        for duplicate_fragment, expected in (
            (
                f"""      - uses: {GENERIC_ACTION}
        uses: owner/other@fedcba9876543210fedcba9876543210fedcba98
""",
                "duplicate mapping key: uses",
            ),
            (
                f"""      - uses: {SETUP_UV_ACTION}
        with:
          version: "0.11.30"
          version: "0.12.3"
          python-version: "3.13.14"
          enable-cache: false
""",
                "duplicate mapping key: version",
            ),
            (
                f"""      - uses: {GENERIC_ACTION}
        with:
          name: first
        with:
          name: second
""",
                "duplicate mapping key: with",
            ),
        ):
            with self.subTest(expected=expected):
                self.assert_rejected(
                    "jobs:\n  test:\n    steps:\n" + duplicate_fragment,
                    expected,
                )
        self.assert_rejected(
            f"""jobs:
  first:
    steps:
      - uses: {GENERIC_ACTION}
jobs:
  second:
    steps:
      - uses: {GENERIC_ACTION}
""",
            "duplicate mapping key: jobs",
        )
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - uses: {GENERIC_ACTION}
  test:
    steps:
      - uses: {GENERIC_ACTION}
""",
            "duplicate mapping key: test",
        )

    def test_yaml_directives_documents_properties_and_special_keys_fail_closed(
        self,
    ) -> None:
        base = f"""jobs:
  test:
    steps:
      - uses: {GENERIC_ACTION}
"""
        cases = (
            ("---\n" + base, "document markers"),
            ("%YAML 1.2\n" + base, "directives"),
            ("jobs: &shared\n", "anchors"),
            ("jobs: *shared\n", "aliases"),
            ("jobs: !custom value\n", "tags"),
            ("? jobs\n: value\n", "explicit"),
            ("jobs:\n  <<: *shared\n", "merge"),
        )
        for workflow, expected in cases:
            with self.subTest(expected=expected):
                self.assert_rejected(workflow, expected)

    def test_noncanonical_bytes_and_line_endings_fail_closed(self) -> None:
        canonical = (
            f"jobs:\n  test:\n    steps:\n      - uses: {GENERIC_ACTION}\n"
        ).encode()
        cases = (
            (b"\xef\xbb\xbf" + canonical, "BOM"),
            (canonical.replace(b"\n", b"\r\n"), "control characters"),
            (canonical.replace(b"  test", b"\ttest"), "tabs"),
            (canonical.replace(b"jobs", b"jo\x00bs"), "NUL"),
            (canonical[:-1], "end with an LF"),
            (b"\xff\n", "strict UTF-8"),
        )
        for workflow, expected in cases:
            with self.subTest(expected=expected):
                result, output = self.run_policy_data(workflow)
                self.assertEqual(result, 1, output)
                self.assertIn(expected, output)

    def test_checkout_requires_direct_plain_false_not_a_block_decoy(self) -> None:
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - uses: {CHECKOUT_ACTION}
        with:
          persist-credentials: true
        run: |
          persist-credentials: false
""",
            "actions/checkout must set persist-credentials: false",
        )
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - uses: {CHECKOUT_ACTION}
        with:
          persist-credentials: "false"
""",
            "plain scalar",
        )

    def test_external_setup_actions_are_categorically_forbidden(self) -> None:
        cases = (
            (
                SETUP_UV_ACTION,
                """          version: "0.11.30"
          python-version: "3.13.14"
          activate-environment: true
          enable-cache: false
""",
            ),
            (SETUP_PYTHON_ACTION, "          python-version: '3.13.14'\n"),
            (
                SETUP_NODE_ACTION,
                """          node-version: '22.23.2'
          cache: npm
          cache-dependency-path: ports/tauri/app/package-lock.json
""",
            ),
        )
        for action, inputs in cases:
            with self.subTest(action=action):
                action_name = action.split("@", 1)[0]
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - uses: {action}
        with:
{inputs}""",
                    f"{action_name} is forbidden",
                )
        self.assert_rejected(
            """jobs:
  test:
    steps:
      - uses: actions/setup-node/internal@0123456789abcdef0123456789abcdef01234567
""",
            "actions/setup-node/internal is forbidden",
        )
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - uses: {SETUP_PYTHON_ACTION}
        with:
          python-version: '3.13'
""",
            "actions/setup-python is forbidden",
        )

    def test_setup_action_input_variants_cannot_restore_a_forbidden_action(
        self,
    ) -> None:
        cases = (
            (SETUP_UV_ACTION, "manifest-file"),
            (SETUP_UV_ACTION, "checksum"),
            (SETUP_UV_ACTION, "version-file"),
            (SETUP_UV_ACTION, "download-url"),
            (SETUP_UV_ACTION, "custom-input"),
            (SETUP_PYTHON_ACTION, "check-latest"),
            (SETUP_PYTHON_ACTION, "python-version-file"),
            (SETUP_NODE_ACTION, "mirror"),
            (SETUP_NODE_ACTION, "mirror-token"),
            (SETUP_NODE_ACTION, "node-version-file"),
        )
        for action, input_name in cases:
            with self.subTest(action=action, input_name=input_name):
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - uses: {action}
        with:
          {input_name}: attacker-controlled
""",
                    "is forbidden",
                )

    def test_rust_toolchain_requires_exact_patch_and_reviewed_inputs(self) -> None:
        result, output = self.run_policy(
            f"""jobs:
  test:
    steps:
      - uses: {RUST_TOOLCHAIN_ACTION}
        with:
          toolchain: '1.97.1'
"""
        )
        self.assertEqual(result, 0, output)
        for inputs, expected in (
            ("          toolchain: stable\n", "must equal 1.97.1"),
            ("          toolchain: '1.97'\n", "must equal 1.97.1"),
            ("          profile: minimal\n", "only the reviewed toolchain input"),
            (
                "          toolchain: '1.97.1'\n          override: true\n",
                "only the reviewed toolchain input",
            ),
            (
                "          toolchain: '1.97.1'\n          targets: x86_64-pc-windows-gnu\n",
                "only the reviewed toolchain input",
            ),
            (
                "          toolchain: '1.97.1'\n          components: clippy\n",
                "only the reviewed toolchain input",
            ),
        ):
            with self.subTest(inputs=inputs):
                self.assert_rejected(
                    f"""jobs:
  test:
    steps:
      - uses: {RUST_TOOLCHAIN_ACTION}
        with:
{inputs}""",
                    expected,
                )

    def test_only_exact_reviewed_uv_environment_is_allowed(self) -> None:
        approved_env = """    env:
      UV_PYTHON_PREFERENCE: only-managed
      UV_PYTHON_CPYTHON_BUILD: "20260718"
"""
        result, output = self.run_policy(
            f"""jobs:
  test:
{approved_env}    steps:
      - uses: {GENERIC_ACTION}
"""
        )
        self.assertEqual(result, 0, output)
        for key in (
            "UV_PYTHON_DOWNLOADS_JSON_URL",
            "UV_PYTHON_INSTALL_MIRROR",
            "UV_ASTRAL_MIRROR_URL",
            "UV_CACHE_DIR",
            "uv_python_preference",
        ):
            with self.subTest(key=key):
                self.assert_rejected(
                    f"""jobs:
  test:
    env:
      {key}: https://attacker.invalid/input
    steps:
      - uses: {GENERIC_ACTION}
""",
                    "unreviewed uv environment key",
                )
        self.assert_rejected(
            f"""jobs:
  test:
    env:
      UV_PYTHON_CPYTHON_BUILD: latest
    steps:
      - uses: {GENERIC_ACTION}
""",
            "UV_PYTHON_CPYTHON_BUILD must equal 20260718",
        )

    def test_step_level_uv_environment_is_inspected(self) -> None:
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - uses: {GENERIC_ACTION}
        env:
          UV_PYTHON_DOWNLOADS_JSON_URL: https://attacker.invalid/manifest.json
""",
            "unreviewed uv environment key",
        )

    def test_workflow_level_uv_environment_is_inspected(self) -> None:
        self.assert_rejected(
            f"""env:
  UV_ASTRAL_MIRROR_URL: https://attacker.invalid
jobs:
  test:
    steps:
      - uses: {GENERIC_ACTION}
""",
            "unreviewed uv environment key",
        )

    def test_decoded_control_characters_and_excessive_nesting_are_rejected(
        self,
    ) -> None:
        self.assert_rejected(
            f"""name: "bad\\u0000value"
jobs:
  test:
    steps:
      - uses: {GENERIC_ACTION}
""",
            "decoded scalar contains a control character",
        )
        nested = ""
        for depth in range(66):
            nested += "  " * depth + f"level{depth}:\n"
        self.assert_rejected(nested, "nesting exceeds")

    def test_oversize_and_nonregular_workflow_inputs_fail_closed(self) -> None:
        checker = load_checker()
        result, output = self.run_policy_data(
            b"#" * (checker.MAX_WORKFLOW_BYTES + 1) + b"\n"
        )
        self.assertEqual(result, 1, output)
        self.assertIn("exceeds", output)

        with tempfile.TemporaryDirectory() as temporary_directory:
            target = Path(temporary_directory) / "target.yml"
            target.write_text("jobs:\n", encoding="utf-8")
            link = Path(temporary_directory) / "link.yml"
            link.symlink_to(target)
            with self.assertRaises(checker.PolicyError):
                checker._read_workflow(link)

            if not hasattr(os, "mkfifo"):
                return
            fifo = Path(temporary_directory) / "workflow.yml"
            os.mkfifo(fifo)
            with self.assertRaises(checker.PolicyError):
                checker._read_workflow(fifo)

    def test_steps_and_step_items_must_have_canonical_structure(self) -> None:
        self.assert_rejected(
            f"""jobs:
  test:
    steps: {GENERIC_ACTION}
""",
            "steps must be a block sequence of mappings",
        )
        self.assert_rejected(
            f"""jobs:
  test:
    steps:
      - {GENERIC_ACTION}
""",
            "each step must be a block mapping",
        )


if __name__ == "__main__":
    unittest.main()
