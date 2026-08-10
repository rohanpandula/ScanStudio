from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
REPOSITORY = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import parse_opencode_review as parser  # noqa: E402


MODEL = "deepseek/deepseek-v4-flash-0731"
SESSION_ID = "ses_Hardening1"
MESSAGE_ID = "msg_hardening"
USER_MESSAGE_ID = "msg_user_hardening"


def substantive_report() -> str:
    return "\n".join(
        [
            "Scope: " + "a" * 72,
            "Finding analysis: " + "b" * 72,
            "Evidence checked: " + "c" * 72,
            "VERDICT: PASS",
        ]
    )


def event_bytes(report: str) -> bytes:
    parts = [
        ("step_start", "step-start", {"id": "part_start"}),
        ("reasoning", "reasoning", {"id": "part_reasoning", "text": "private"}),
        ("text", "text", {"id": "part_text", "text": report}),
        ("step_finish", "step-finish", {"id": "part_finish", "reason": "stop"}),
    ]
    events = []
    for event_type, part_type, fields in parts:
        events.append(
            {
                "type": event_type,
                "sessionID": SESSION_ID,
                "part": {
                    **fields,
                    "messageID": MESSAGE_ID,
                    "sessionID": SESSION_ID,
                    "type": part_type,
                },
            }
        )
    return b"\n".join(json.dumps(item).encode() for item in events) + b"\n"


def export_bytes(
    request: str,
    report: str,
    *,
    finish: str | None = "stop",
    error: object | None = None,
) -> bytes:
    assistant_info = {
        "id": MESSAGE_ID,
        "parentID": USER_MESSAGE_ID,
        "role": "assistant",
        "sessionID": SESSION_ID,
        "providerID": "openrouter",
        "modelID": MODEL,
        "variant": "high",
        "finish": finish,
    }
    if error is not None:
        assistant_info["error"] = error
    assistant_parts = [
        {"type": "step-start"},
        {"type": "reasoning", "text": "private"},
        {"type": "text", "text": report},
    ]
    if finish is not None:
        assistant_parts.append({"type": "step-finish", "reason": finish})
    return json.dumps(
        {
            "info": {"id": SESSION_ID},
            "messages": [
                {
                    "info": {
                        "id": USER_MESSAGE_ID,
                        "role": "user",
                        "sessionID": SESSION_ID,
                        "model": {
                            "providerID": "openrouter",
                            "modelID": MODEL,
                            "variant": "high",
                        },
                    },
                    "parts": [{"type": "text", "text": request}],
                },
                {"info": assistant_info, "parts": assistant_parts},
            ],
        }
    ).encode()


def failure_receipt(raw: bytes, *, outcome: str) -> dict[str, object]:
    return parser.parse_failure_receipt(
        raw,
        session_id=SESSION_ID,
        request=b"request",
        tool_version="1.18.15",
        base_commit="a" * 40,
        reviewed_commit="b" * 40,
        role="cross-layer-correctness",
        input_sha256="c" * 64,
        outcome=outcome,
        expected_provider="openrouter",
        expected_model=MODEL,
    )


class ReportSubstanceTests(unittest.TestCase):
    def test_rejects_short_or_single_line_pass_attestations(self) -> None:
        reports = [
            "VERDICT: PASS",
            "one\ntwo\nthree\nVERDICT: PASS",
            f"{'x' * 220}\nVERDICT: PASS",
        ]
        for report in reports:
            with self.subTest(report_length=len(report)):
                with self.assertRaisesRegex(parser.ParseError, "substantive"):
                    parser.validate_substantive_report(report)

    def test_accepts_three_line_pass_body_above_byte_floor(self) -> None:
        report = substantive_report()
        body = report.rsplit("\n", 1)[0]
        self.assertGreaterEqual(len(body.encode("utf-8")), parser.MIN_REPORT_BODY_BYTES)
        parser.validate_substantive_report(report)

    def test_cli_rejects_degenerate_pass_before_export_acceptance(self) -> None:
        report = "VERDICT: PASS"
        request = "request"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            events = root / "events.jsonl"
            exported = root / "export.json"
            request_file = root / "request.txt"
            events.write_bytes(event_bytes(report))
            exported.write_bytes(export_bytes(request, report))
            request_file.write_text(request, encoding="utf-8")
            argv = [
                "parse_opencode_review.py",
                "report",
                "--events",
                str(events),
                "--export",
                str(exported),
                "--request",
                str(request_file),
                "--tool-version",
                "1.18.15",
                "--provider",
                "openrouter",
                "--model",
                MODEL,
                "--variant",
                "high",
            ]
            stderr = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(stderr),
            ):
                status = parser.main()
        self.assertEqual(status, 1)
        self.assertIn("substantive", stderr.getvalue())


class ParserCountLimitTests(unittest.TestCase):
    def test_event_part_limit_applies_to_identification_and_parsing(self) -> None:
        raw = event_bytes(substantive_report())
        with mock.patch.object(parser, "MAX_EVENT_PARTS", 3):
            with self.assertRaisesRegex(parser.ParseError, "part count"):
                parser.extract_session_id(raw)
            with self.assertRaisesRegex(parser.ParseError, "part count"):
                parser.parse_event_stream(raw)

    def test_success_export_rejects_excessive_assistant_parts(self) -> None:
        report = substantive_report()
        with mock.patch.object(parser, "MAX_EXPORTED_PARTS", 3):
            with self.assertRaisesRegex(parser.ParseError, "part count"):
                parser.parse_export(
                    export_bytes("request", report),
                    session_id=SESSION_ID,
                    message_id=MESSAGE_ID,
                    report=report,
                    request=b"request",
                    tool_version="1.18.15",
                    expected_provider="openrouter",
                    expected_model=MODEL,
                    expected_variant="high",
                )

    def test_success_export_rejects_excessive_user_parts(self) -> None:
        report = substantive_report()
        exported = json.loads(export_bytes("request", report))
        exported["messages"][0]["parts"] = [
            {"type": "text", "text": "request"} for _ in range(4)
        ]
        with mock.patch.object(parser, "MAX_EXPORTED_PARTS", 3):
            with self.assertRaisesRegex(parser.ParseError, "part count"):
                parser.parse_export(
                    json.dumps(exported).encode(),
                    session_id=SESSION_ID,
                    message_id=MESSAGE_ID,
                    report=report,
                    request=b"request",
                    tool_version="1.18.15",
                    expected_provider="openrouter",
                    expected_model=MODEL,
                    expected_variant="high",
                )

    def test_failure_export_rejects_excessive_assistant_parts(self) -> None:
        with mock.patch.object(parser, "MAX_EXPORTED_PARTS", 3):
            with self.assertRaisesRegex(parser.ParseError, "part count"):
                failure_receipt(
                    export_bytes("request", "partial", finish="length"),
                    outcome="OUTPUT_LIMIT",
                )


class ProviderErrorFallbackTests(unittest.TestCase):
    def test_parser_rejects_provider_error_outcome(self) -> None:
        raw = export_bytes(
            "request",
            "",
            finish=None,
            error={"name": "ProviderUnavailable"},
        )
        with self.assertRaisesRegex(parser.ParseError, "outcome is invalid"):
            failure_receipt(raw, outcome="PROVIDER_ERROR")

    def test_provider_error_cannot_be_relabelled_output_limit(self) -> None:
        raw = export_bytes(
            "request",
            "partial",
            finish="length",
            error={"name": "ProviderUnavailable"},
        )
        with self.assertRaisesRegex(parser.ParseError, "provider error"):
            failure_receipt(raw, outcome="OUTPUT_LIMIT")

    def test_wrapper_rejects_provider_error_before_review_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / "receipt.json"
            result = subprocess.run(
                [
                    str(SCRIPTS / "run_adversarial_review.sh"),
                    "a" * 40,
                    "b" * 40,
                    "openrouter/deepseek/deepseek-v4-flash-0731",
                    str(
                        REPOSITORY
                        / "docs/adversarial-review-prompts/security-reliability.txt"
                    ),
                    "Provider error rejection",
                    "--full",
                    "--variant",
                    "high",
                    "--failure-receipt",
                    str(receipt),
                    "--failure-outcome",
                    "PROVIDER_ERROR",
                ],
                cwd=REPOSITORY,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertFalse(receipt.exists())
        self.assertEqual(result.returncode, 2)
        self.assertIn("unsupported failure outcome: PROVIDER_ERROR", result.stderr)


if __name__ == "__main__":
    unittest.main()
