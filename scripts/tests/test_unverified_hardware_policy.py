"""An enabled production 1x gate must name published attended-run evidence."""
from __future__ import annotations

import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def validated_run(source: str, release_notes: str) -> str | None:
    for node in ast.parse(source).body:
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            if node.target.id == "SINGLE_SAMPLE_VALIDATED_RUN":
                value = ast.literal_eval(node.value)
                if value is None:
                    return None
                if not isinstance(value, str) or not value.strip() or value not in release_notes:
                    raise ValueError("enabled 1x gate must name its attended run in release notes")
                return value
    raise ValueError("missing SINGLE_SAMPLE_VALIDATED_RUN gate")


class SingleSampleEvidencePolicyTests(unittest.TestCase):
    def test_current_gate_is_bound_to_release_evidence(self):
        source = (ROOT / "bridge/src/scanstudio_bridge/transport/coolscanpy_transport.py").read_text()
        notes = (ROOT / "docs/releases/v0.7.0-beta.17.md").read_text()
        validated_run(source, notes)

    def test_closed_gate_and_both_sides_of_evidence_binding(self):
        self.assertIsNone(validated_run("SINGLE_SAMPLE_VALIDATED_RUN: str | None = None", ""))
        source = 'SINGLE_SAMPLE_VALIDATED_RUN: str | None = "attended-20260908-junk-strip"'
        with self.assertRaisesRegex(ValueError, "attended run"):
            validated_run(source, "simulator passed")
        self.assertEqual(validated_run(source, "Evidence: attended-20260908-junk-strip"),
                         "attended-20260908-junk-strip")
        with self.assertRaisesRegex(ValueError, "missing"):
            validated_run("", "")


if __name__ == "__main__":
    unittest.main()
