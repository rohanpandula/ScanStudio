from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import adversarial_review_input as review_input_module  # noqa: E402
import check_adversarial_review as checker_module  # noqa: E402
from adversarial_review_input import (  # noqa: E402
    MAX_REQUEST_BYTES,
    ReviewInputError,
    automatic_shard_input,
    build_review_request,
    canonical_diff,
    changed_line_count,
    describe_semantic_plan,
    explicit_shard_input,
    file_patches,
    full_diff_input,
    plan_shards,
    read_regular_file,
)
from check_adversarial_review import (  # noqa: E402
    EvidenceError,
    require_path_without_symlink_ancestors,
    trusted_prompt_bytes,
    validate_manifest,
    validate_report,
)
from parse_opencode_review import (  # noqa: E402
    ParseError,
    parse_event_stream,
    parse_export,
    parse_failure_receipt,
)


def run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.PIPE)


def rev_parse(repository: Path, value: str = "HEAD") -> str:
    return subprocess.check_output(
        ["git", "rev-parse", value], cwd=repository, text=True
    ).strip()


def event_bytes(report: str = "Finding notes.\nVERDICT: PASS") -> bytes:
    events = [
        {
            "type": "step_start",
            "sessionID": "ses_TestA1",
            "part": {
                "id": "part_start",
                "messageID": "msg_test_a",
                "sessionID": "ses_TestA1",
                "type": "step-start",
            },
        },
        {
            "type": "reasoning",
            "sessionID": "ses_TestA1",
            "part": {
                "id": "part_reasoning",
                "messageID": "msg_test_a",
                "sessionID": "ses_TestA1",
                "type": "reasoning",
                "text": "must never be emitted",
            },
        },
        {
            "type": "text",
            "sessionID": "ses_TestA1",
            "part": {
                "id": "part_text",
                "messageID": "msg_test_a",
                "sessionID": "ses_TestA1",
                "type": "text",
                "text": report,
            },
        },
        {
            "type": "step_finish",
            "sessionID": "ses_TestA1",
            "part": {
                "id": "part_finish",
                "messageID": "msg_test_a",
                "sessionID": "ses_TestA1",
                "type": "step-finish",
                "reason": "stop",
            },
        },
    ]
    return b"\n".join(json.dumps(item).encode() for item in events) + b"\n"


def export_bytes(
    request: str,
    report: str = "Finding notes.\nVERDICT: PASS",
    *,
    finish: str | None = "stop",
    error: object | None = None,
) -> bytes:
    assistant_info = {
        "id": "msg_test_a",
        "parentID": "msg_user_a",
        "role": "assistant",
        "sessionID": "ses_TestA1",
        "providerID": "openrouter",
        "modelID": "deepseek/deepseek-v4-flash-0731",
        "variant": "high",
        "finish": finish,
    }
    if error is not None:
        assistant_info["error"] = error
    return json.dumps(
        {
            "info": {"id": "ses_TestA1"},
            "messages": [
                {
                    "info": {
                        "id": "msg_user_a",
                        "role": "user",
                        "sessionID": "ses_TestA1",
                        "model": {
                            "providerID": "openrouter",
                            "modelID": "deepseek/deepseek-v4-flash-0731",
                            "variant": "high",
                        },
                    },
                    "parts": [{"type": "text", "text": request}],
                },
                {
                    "info": assistant_info,
                    "parts": [
                        {"type": "step-start"},
                        {"type": "reasoning", "text": "must never be emitted"},
                        {"type": "text", "text": report},
                        {"type": "step-finish", "reason": finish},
                    ],
                },
            ],
        }
    ).encode()


class OpenCodeParserTests(unittest.TestCase):
    def test_exact_parent_request_and_metadata_are_bound(self) -> None:
        request = b"trusted prompt\n--- BEGIN ---\ninput\n"
        session, message, report = parse_event_stream(event_bytes())
        self.assertNotIn("reasoning", report)
        metadata = parse_export(
            export_bytes(request.decode()),
            session_id=session,
            message_id=message,
            report=report,
            request=request,
            tool_version="1.18.15",
            expected_provider="openrouter",
            expected_model="deepseek/deepseek-v4-flash-0731",
            expected_variant="high",
        )
        self.assertEqual(metadata["contextId"], "ses_TestA1")
        self.assertEqual(metadata["toolVersion"], "1.18.15")
        self.assertEqual(metadata["requestSha256"], hashlib.sha256(request).hexdigest())

    def test_rejects_wrong_parent_request_and_top_level_session(self) -> None:
        request = b"expected"
        session, message, report = parse_event_stream(event_bytes())
        with self.assertRaises(ParseError):
            parse_export(
                export_bytes("different"),
                session_id=session,
                message_id=message,
                report=report,
                request=request,
                tool_version="1.18.15",
                expected_provider="openrouter",
                expected_model="deepseek/deepseek-v4-flash-0731",
                expected_variant="high",
            )
        exported = json.loads(export_bytes(request.decode()))
        exported["info"]["id"] = "ses_Other1"
        with self.assertRaises(ParseError):
            parse_export(
                json.dumps(exported).encode(),
                session_id=session,
                message_id=message,
                report=report,
                request=request,
                tool_version="1.18.15",
                expected_provider="openrouter",
                expected_model="deepseek/deepseek-v4-flash-0731",
                expected_variant="high",
            )

    def test_rejects_unknown_parts_and_post_finish_output(self) -> None:
        events = [json.loads(line) for line in event_bytes().splitlines()]
        events[1]["type"] = "tool_use"
        events[1]["part"]["type"] = "tool"
        with self.assertRaises(ParseError):
            parse_event_stream(b"\n".join(json.dumps(item).encode() for item in events))
        events = [json.loads(line) for line in event_bytes().splitlines()]
        events.append(events[2] | {"part": events[2]["part"] | {"id": "part_late"}})
        with self.assertRaises(ParseError):
            parse_event_stream(b"\n".join(json.dumps(item).encode() for item in events))

    def test_rejects_multiple_verdicts(self) -> None:
        with self.assertRaises(ParseError):
            parse_event_stream(event_bytes("VERDICT: PASS\nVERDICT: PASS"))

    def test_generates_sanitized_output_limit_receipt(self) -> None:
        request = b"request"
        receipt = parse_failure_receipt(
            export_bytes(request.decode(), "partial", finish="length"),
            session_id="ses_TestA1",
            request=request,
            tool_version="1.18.15",
            base_commit="a" * 40,
            reviewed_commit="b" * 40,
            role="cross-layer-correctness",
            input_sha256="c" * 64,
            outcome="OUTPUT_LIMIT",
            expected_provider="openrouter",
            expected_model="deepseek/deepseek-v4-flash-0731",
        )
        self.assertEqual(receipt["finish"], "length")
        self.assertNotIn("partial", json.dumps(receipt))
        with self.assertRaises(ParseError):
            parse_failure_receipt(
                export_bytes(request.decode(), "partial", finish="stop"),
                session_id="ses_TestA1",
                request=request,
                tool_version="1.18.15",
                base_commit="a" * 40,
                reviewed_commit="b" * 40,
                role="cross-layer-correctness",
                input_sha256="c" * 64,
                outcome="OUTPUT_LIMIT",
                expected_provider="openrouter",
                expected_model="deepseek/deepseek-v4-flash-0731",
            )


class GitRepositoryTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.previous_cwd = Path.cwd()
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary.name)
        os.chdir(self.repository)
        run("git", "init", "-q")
        run("git", "config", "user.email", "test@example.invalid")
        run("git", "config", "user.name", "Test")

    def tearDown(self) -> None:
        os.chdir(self.previous_cwd)
        self.temporary.cleanup()


class ReviewInputTests(GitRepositoryTestCase):
    def setUp(self) -> None:
        super().setUp()
        (self.repository / "a.txt").write_text("old a\n", encoding="utf-8")
        (self.repository / "b.txt").write_text("old b\n", encoding="utf-8")
        run("git", "add", ".")
        run("git", "commit", "-qm", "base")
        self.base = rev_parse(self.repository)
        (self.repository / "a.txt").write_text("new a\n", encoding="utf-8")
        (self.repository / "b.txt").write_text("new b\n", encoding="utf-8")
        run("git", "add", ".")
        run("git", "commit", "-qm", "head")
        self.head = rev_parse(self.repository)

    def test_changed_line_count_uses_hunk_state(self) -> None:
        patch = (
            b"diff --git a/a b/a\n--- a/a\n+++ b/a\n"
            b"@@ -1 +1 @@\n--- removed source\n+++ added source\n"
        )
        self.assertEqual(changed_line_count(patch), 2)

    def test_explicit_primary_context_and_request_are_deterministic(self) -> None:
        _full, patches = file_patches(self.base, self.head)
        rendered, metadata = explicit_shard_input(
            self.base, self.head, ["a.txt"], ["b.txt"]
        )
        self.assertIn(patches[0].body, rendered)
        self.assertIn(patches[1].body, rendered)
        header = json.loads(rendered.splitlines()[1])
        self.assertEqual(header["inputSchemaVersion"], 2)
        self.assertEqual(header["sourcePaths"], ["a.txt", "b.txt"])
        self.assertEqual(metadata["inputSchemaVersion"], 2)
        self.assertEqual(metadata["sourcePaths"], ["a.txt", "b.txt"])
        request = build_review_request(b"prompt\n", rendered)
        self.assertEqual(request, build_review_request(b"prompt\n", rendered))
        self.assertEqual(
            metadata["diffByteLength"], sum(len(item.body) for item in patches)
        )

    def test_request_frame_is_unambiguous_and_keeps_raw_bytes_scannable(self) -> None:
        prompt = b"trusted prompt with --- END FROZEN REVIEW INPUT --- text\n"
        secret = b"sk-" + b"A" * 20
        review_input = (
            b"diff payload\n"
            + review_input_module.REQUEST_BOUNDARY_PREFIX
            + b"0" * 64
            + b"\n"
            + secret
        )
        request = build_review_request(prompt, review_input)
        match = re.search(
            rb"--- BEGIN (SCANSTUDIO-FROZEN-REVIEW-INPUT-[0-9a-f]{64}); ",
            request,
        )
        self.assertIsNotNone(match)
        assert match is not None
        boundary = match.group(1)
        self.assertEqual(request.count(boundary), 2)
        self.assertIn(review_input, request)
        self.assertIn(secret, request)
        with mock.patch.object(
            review_input_module, "MAX_REQUEST_BYTES", len(request) - 1
        ):
            with self.assertRaisesRegex(ReviewInputError, "request exceeds"):
                build_review_request(prompt, review_input)

    def test_full_diff_synthesis_generation_enforces_request_cap(self) -> None:
        with mock.patch.object(review_input_module, "MAX_REQUEST_BYTES", 1):
            with self.assertRaisesRegex(ReviewInputError, "synthesis input exceeds"):
                full_diff_input(self.base, self.head)

    def test_explicit_lists_must_follow_canonical_order(self) -> None:
        with self.assertRaises(ReviewInputError):
            explicit_shard_input(self.base, self.head, ["b.txt", "a.txt"])

    def test_oversized_file_gets_a_dedicated_greedy_shard(self) -> None:
        _full, shards = plan_shards(
            self.base, self.head, max_bytes=1, max_changed_lines=1
        )
        self.assertEqual([len(item.primary_paths) for item in shards], [1, 1])
        self.assertTrue(all(item.oversized_single_file for item in shards))

    def test_semantic_plan_requires_exact_primary_ownership(self) -> None:
        plan = self.repository / "plan.json"
        plan.write_text(
            json.dumps(
                {
                    "shards": [
                        {"primaryPaths": ["a.txt"], "contextPaths": ["b.txt"]},
                        {"primaryPaths": ["b.txt"], "contextPaths": []},
                    ]
                }
            ),
            encoding="utf-8",
        )
        _specs, described = describe_semantic_plan(self.base, self.head, plan)
        self.assertEqual(len(described), 2)
        plan.write_text(
            json.dumps(
                {
                    "shards": [
                        {"primaryPaths": ["a.txt"], "contextPaths": []},
                        {"primaryPaths": ["a.txt"], "contextPaths": []},
                    ]
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaises(ReviewInputError):
            describe_semantic_plan(self.base, self.head, plan)

    def test_auto_context_preflight_rejects_combined_oversize(self) -> None:
        (self.repository / "a.txt").write_text(
            "".join(f"a {index}\n" for index in range(1_100)), encoding="utf-8"
        )
        (self.repository / "b.txt").write_text(
            "".join(f"b {index}\n" for index in range(1_100)), encoding="utf-8"
        )
        run("git", "add", ".")
        run("git", "commit", "-qm", "large")
        large_head = rev_parse(self.repository)
        with self.assertRaises(ReviewInputError):
            automatic_shard_input(self.head, large_head, 1, ["b.txt"])

    def test_binary_change_is_rejected_before_review(self) -> None:
        (self.repository / "image.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00payload")
        run("git", "add", "image.png")
        run("git", "commit", "-qm", "binary", cwd=self.repository)
        binary_head = rev_parse(self.repository)
        with self.assertRaisesRegex(ReviewInputError, "binary changes"):
            file_patches(self.head, binary_head)

    def test_binary_marker_text_is_still_reviewable(self) -> None:
        (self.repository / "a.txt").write_text(
            "GIT binary patch\nBinary files a and b differ\n", encoding="utf-8"
        )
        run("git", "add", "a.txt")
        run("git", "commit", "-qm", "marker text")
        marker_head = rev_parse(self.repository)
        _full, patches = file_patches(self.head, marker_head)
        self.assertEqual([item.path for item in patches], ["a.txt"])

    def test_git_output_is_bounded_and_injected_git_dir_is_ignored(self) -> None:
        with mock.patch.object(review_input_module, "MAX_GIT_STDOUT_BYTES", 1):
            with self.assertRaisesRegex(ReviewInputError, "stdout exceeds 1 bytes"):
                canonical_diff(self.base, self.head)
        with mock.patch.dict(os.environ, {"GIT_DIR": "/definitely/not/a/repository"}):
            self.assertTrue(canonical_diff(self.base, self.head))

    def test_fd_reader_retries_interrupted_syscall(self) -> None:
        with mock.patch.object(
            review_input_module.os,
            "read",
            side_effect=[InterruptedError(), b"retried"],
        ):
            self.assertEqual(
                review_input_module.read_fd_with_eintr_retry(123, 7), b"retried"
            )

    def test_preflight_requires_clean_reviewed_head(self) -> None:
        command = [
            sys.executable,
            str(SCRIPTS / "adversarial_review_input.py"),
            "preflight",
            self.base,
            self.head,
        ]
        clean = subprocess.run(
            command, cwd=self.repository, check=False, capture_output=True, text=True
        )
        self.assertEqual(clean.returncode, 0, clean.stderr)
        (self.repository / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        dirty = subprocess.run(
            command, cwd=self.repository, check=False, capture_output=True, text=True
        )
        self.assertEqual(dirty.returncode, 1)
        self.assertIn("clean worktree", dirty.stderr)


class EvidenceHardeningTests(unittest.TestCase):
    def test_common_private_key_headers_are_rejected(self) -> None:
        marker_start = "-----" + "BEGIN "
        marker_end = "-----"
        key_kinds = (
            "PRIVATE KEY",
            "RSA PRIVATE KEY",
            "OPENSSH PRIVATE KEY",
            "EC PRIVATE KEY",
            "DSA PRIVATE KEY",
            "ENCRYPTED PRIVATE KEY",
            "PGP PRIVATE KEY BLOCK",
        )
        for key_kind in key_kinds:
            with self.subTest(key_kind=key_kind):
                with self.assertRaisesRegex(EvidenceError, "private key"):
                    checker_module.require_safe_artifact(
                        f"{marker_start}{key_kind}{marker_end}".encode(), "artifact"
                    )

    def test_aws_long_lived_and_temporary_access_keys_are_rejected(self) -> None:
        for prefix in ("AKIA", "ASIA"):
            with self.subTest(prefix=prefix):
                with self.assertRaisesRegex(EvidenceError, "AWS access key"):
                    checker_module.require_safe_artifact(
                        f"{prefix}ABCDEFGHIJKLMNOP".encode(), "artifact"
                    )

    def test_high_confidence_service_tokens_are_rejected(self) -> None:
        service_tokens = (
            ("API key", "sk-" + "proj-" + "A" * 24),
            ("API key", "sk-" + "123e4567-e89b-12d3-a456-426614174000"),
            ("API key", "sk-" + "A" * 19 + "-"),
            ("Stripe secret key", "sk_" + "live_" + "A" * 24),
            ("Stripe secret key", "sk_" + "test_" + "A" * 24),
            ("Google API key", "AI" + "za" + "A" * 35),
            ("Google API key", "AI" + "za" + "A" * 34 + "-"),
            ("Google OAuth token", "ya" + "29." + "A" * 24),
            ("Google OAuth token", "ya" + "29.d." + "A" * 24),
            ("Google OAuth token", "ya" + "29." + "A_9-" * 5),
        )
        for label, token in service_tokens:
            with self.subTest(label=label):
                with self.assertRaisesRegex(EvidenceError, label):
                    checker_module.require_safe_artifact(token.encode(), "artifact")
        checker_module.require_safe_artifact(
            ("AI" + "za" + "A" * 34 + "-B").encode(), "artifact"
        )

    def test_degenerate_pass_report_is_rejected(self) -> None:
        with self.assertRaisesRegex(EvidenceError, "substantive review"):
            validate_report(b"VERDICT: PASS\n", "report")

    def test_unicode_separator_cannot_hide_a_conflicting_report_verdict(self) -> None:
        report = (
            "Scope: reviewed the complete packet.\n"
            "Evidence: a conflicting verdict follows a Unicode separator.\n"
            "Result: this must fail closed.\u2028VERDICT: BLOCK\n"
            "VERDICT: PASS\n"
        ).encode()
        with self.assertRaisesRegex(EvidenceError, "control or line separator"):
            validate_report(report, "report")

    def test_semantic_plan_rejects_duplicate_keys_and_nonstandard_constants(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(os.path.realpath(directory)) / "plan.json"
            for raw in (
                b'{"shards":[],"shards":[]}',
                b'{"shards":NaN}',
            ):
                with self.subTest(raw=raw):
                    path.write_bytes(raw)
                    with self.assertRaisesRegex(ReviewInputError, "valid UTF-8 JSON"):
                        review_input_module.load_semantic_plan(path)

    def test_bounded_reader_rejects_symlinks_and_oversized_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_bytes(b"safe")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises(ReviewInputError):
                read_regular_file(link, "link", MAX_REQUEST_BYTES)
            oversized = root / "oversized"
            oversized.write_bytes(b"x" * 5)
            with self.assertRaisesRegex(ReviewInputError, "exceeds"):
                read_regular_file(oversized, "oversized", 4)

    def test_bounded_reader_rejects_fifo_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory) / "fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(ReviewInputError, "regular file"):
                read_regular_file(fifo, "fifo", MAX_REQUEST_BYTES)

    def test_symlinked_evidence_ancestor_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            outside = root / "outside"
            outside.mkdir()
            docs = root / "docs"
            docs.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(EvidenceError, "non-symlink repository"):
                require_path_without_symlink_ancestors(
                    docs / "adversarial-reviews" / "test" / "manifest.json",
                    root,
                    "manifest",
                )

    def test_git_timeout_is_reported_as_review_input_error(self) -> None:
        with mock.patch("adversarial_review_input.GIT_TIMEOUT_SECONDS", 0):
            with self.assertRaisesRegex(ReviewInputError, "exceeded 0 seconds"):
                canonical_diff("a" * 40, "b" * 40)

    def test_git_ignores_repository_local_fsmonitor_command(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            run("git", "init", "-q", cwd=repository)
            hook = repository / "fsmonitor.sh"
            marker = repository / "fsmonitor-ran"
            hook.write_text(
                f"#!/bin/sh\ntouch {str(marker)!r}\nprintf '\\n'\n",
                encoding="utf-8",
            )
            hook.chmod(0o700)
            run("git", "config", "core.fsmonitor", str(hook), cwd=repository)

            review_input_module.git_bytes(
                "-C",
                str(repository),
                "status",
                "--porcelain=v1",
                "--untracked-files=no",
            )

            self.assertFalse(marker.exists())

    def test_git_accepts_eof_from_process_already_done_at_deadline(self) -> None:
        completed = subprocess.Popen(
            [sys.executable, "-c", "pass"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        completed.wait(timeout=5)
        with (
            mock.patch.object(
                review_input_module.subprocess, "Popen", return_value=completed
            ),
            mock.patch.object(review_input_module, "GIT_TIMEOUT_SECONDS", 0),
        ):
            self.assertEqual(review_input_module.git_bytes("version"), b"")

    def test_git_accepts_final_output_from_process_done_at_deadline(self) -> None:
        completed = subprocess.Popen(
            [sys.executable, "-c", "print('final', end='')"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        completed.wait(timeout=5)
        with (
            mock.patch.object(
                review_input_module.subprocess, "Popen", return_value=completed
            ),
            mock.patch.object(review_input_module, "GIT_TIMEOUT_SECONDS", 0),
        ):
            self.assertEqual(review_input_module.git_bytes("version"), b"final")

    def test_git_reaps_child_that_closes_pipes_then_exceeds_deadline(self) -> None:
        real_popen = subprocess.Popen
        spawned: list[subprocess.Popen[bytes]] = []

        def close_pipes_then_sleep(
            _command: list[str], **kwargs: object
        ) -> subprocess.Popen[bytes]:
            process = real_popen(
                [
                    sys.executable,
                    "-c",
                    "import os,time; os.close(1); os.close(2); time.sleep(60)",
                ],
                **kwargs,
            )
            spawned.append(process)
            return process

        started = time.monotonic()
        try:
            with (
                mock.patch.object(
                    review_input_module.subprocess,
                    "Popen",
                    side_effect=close_pipes_then_sleep,
                ),
                mock.patch.object(review_input_module, "GIT_TIMEOUT_SECONDS", 0.05),
                mock.patch.object(review_input_module, "GIT_KILL_REAP_SECONDS", 0.5),
                mock.patch.object(
                    review_input_module.os, "killpg", wraps=os.killpg
                ) as kill_process_group,
            ):
                with self.assertRaisesRegex(ReviewInputError, "exceeded"):
                    review_input_module.git_bytes("version")
            self.assertLess(time.monotonic() - started, 1.0)
            self.assertEqual(len(spawned), 1)
            self.assertIsNotNone(spawned[0].poll())
            self.assertEqual(kill_process_group.call_count, 1)
        finally:
            for process in spawned:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_git_timeout_applies_to_continuously_ready_output(self) -> None:
        real_popen = subprocess.Popen
        spawned: list[subprocess.Popen[bytes]] = []

        def continuously_write(
            _command: list[str], **kwargs: object
        ) -> subprocess.Popen[bytes]:
            process = real_popen(
                [sys.executable, "-c", "import os\nwhile True:\n os.write(1,b'x')\n"],
                **kwargs,
            )
            spawned.append(process)
            return process

        started = time.monotonic()
        try:
            with (
                mock.patch.object(
                    review_input_module.subprocess,
                    "Popen",
                    side_effect=continuously_write,
                ),
                mock.patch.object(review_input_module, "GIT_TIMEOUT_SECONDS", 0.05),
                mock.patch.object(review_input_module, "GIT_KILL_REAP_SECONDS", 0.5),
            ):
                with self.assertRaisesRegex(ReviewInputError, "exceeded"):
                    review_input_module.git_bytes("version")
            self.assertLess(time.monotonic() - started, 1.0)
            self.assertEqual(len(spawned), 1)
            self.assertIsNotNone(spawned[0].poll())
        finally:
            for process in spawned:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_git_kills_descendant_that_keeps_capture_pipes_open(self) -> None:
        real_popen = subprocess.Popen
        spawned: list[subprocess.Popen[bytes]] = []
        with tempfile.TemporaryDirectory() as temporary:
            child_pid_path = Path(temporary) / "child.pid"

            def parent_exits_with_inherited_pipes(
                _command: list[str], **kwargs: object
            ) -> subprocess.Popen[bytes]:
                script = (
                    "import pathlib,subprocess,sys; "
                    "child=subprocess.Popen([sys.executable,'-c',"
                    "'import time; time.sleep(60)']); "
                    f"pathlib.Path({str(child_pid_path)!r}).write_text(str(child.pid))"
                )
                process = real_popen([sys.executable, "-c", script], **kwargs)
                spawned.append(process)
                return process

            started = time.monotonic()
            try:
                with (
                    mock.patch.object(
                        review_input_module.subprocess,
                        "Popen",
                        side_effect=parent_exits_with_inherited_pipes,
                    ),
                    mock.patch.object(review_input_module, "GIT_TIMEOUT_SECONDS", 0.1),
                    mock.patch.object(
                        review_input_module, "GIT_KILL_REAP_SECONDS", 0.5
                    ),
                ):
                    with self.assertRaisesRegex(ReviewInputError, "exceeded"):
                        review_input_module.git_bytes("version")
                self.assertLess(time.monotonic() - started, 1.0)
                self.assertEqual(len(spawned), 1)
                self.assertIsNotNone(spawned[0].poll())
                self.assertTrue(child_pid_path.exists())
                child_pid = int(child_pid_path.read_text(encoding="utf-8"))
                child_gone = False
                for _attempt in range(50):
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        child_gone = True
                        break
                    time.sleep(0.01)
                self.assertTrue(child_gone, "captured-pipe descendant survived timeout")
            finally:
                if child_pid_path.exists():
                    try:
                        os.kill(int(child_pid_path.read_text(encoding="utf-8")), 9)
                    except ProcessLookupError:
                        pass
                for process in spawned:
                    try:
                        os.killpg(process.pid, 9)
                    except (ProcessLookupError, PermissionError):
                        pass
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)

    def test_git_cleans_up_process_group_after_selector_error(self) -> None:
        real_popen = subprocess.Popen
        spawned: list[subprocess.Popen[bytes]] = []

        def sleeping_process(
            _command: list[str], **kwargs: object
        ) -> subprocess.Popen[bytes]:
            process = real_popen(
                [sys.executable, "-c", "import time; time.sleep(60)"], **kwargs
            )
            spawned.append(process)
            return process

        try:
            with (
                mock.patch.object(
                    review_input_module.subprocess,
                    "Popen",
                    side_effect=sleeping_process,
                ),
                mock.patch.object(
                    review_input_module.selectors.DefaultSelector,
                    "select",
                    side_effect=OSError("selector failed"),
                ),
            ):
                with self.assertRaisesRegex(OSError, "selector failed"):
                    review_input_module.git_bytes("version")
            self.assertEqual(len(spawned), 1)
            self.assertIsNotNone(spawned[0].poll())
        finally:
            for process in spawned:
                try:
                    os.killpg(process.pid, 9)
                except (ProcessLookupError, PermissionError):
                    pass
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_git_cleans_up_when_selector_registration_fails(self) -> None:
        real_popen = subprocess.Popen
        spawned: list[subprocess.Popen[bytes]] = []

        def sleeping_process(
            _command: list[str], **kwargs: object
        ) -> subprocess.Popen[bytes]:
            process = real_popen(
                [sys.executable, "-c", "import time; time.sleep(60)"], **kwargs
            )
            spawned.append(process)
            return process

        try:
            with (
                mock.patch.object(
                    review_input_module.subprocess,
                    "Popen",
                    side_effect=sleeping_process,
                ),
                mock.patch.object(
                    review_input_module.selectors.DefaultSelector,
                    "register",
                    side_effect=OSError("registration failed"),
                ),
            ):
                with self.assertRaisesRegex(OSError, "registration failed"):
                    review_input_module.git_bytes("version")
            self.assertEqual(len(spawned), 1)
            self.assertIsNotNone(spawned[0].poll())
        finally:
            for process in spawned:
                try:
                    os.killpg(process.pid, 9)
                except (ProcessLookupError, PermissionError):
                    pass
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)


class SubmoduleDiffTests(GitRepositoryTestCase):
    def test_gitmodules_ignore_all_cannot_hide_base_to_reviewed_gitlink(self) -> None:
        subrepo = self.repository.parent / f"{self.repository.name}-sub"
        subrepo.mkdir()
        run("git", "init", "-q", cwd=subrepo)
        run("git", "config", "user.email", "test@example.invalid", cwd=subrepo)
        run("git", "config", "user.name", "Test", cwd=subrepo)
        (subrepo / "value.txt").write_text("one\n", encoding="utf-8")
        run("git", "add", ".", cwd=subrepo)
        run("git", "commit", "-qm", "one", cwd=subrepo)
        first = rev_parse(subrepo)
        (subrepo / "value.txt").write_text("two\n", encoding="utf-8")
        run("git", "add", ".", cwd=subrepo)
        run("git", "commit", "-qm", "two", cwd=subrepo)
        second = rev_parse(subrepo)

        run(
            "git",
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            str(subrepo),
            "vendor",
        )
        run("git", "-C", "vendor", "checkout", "-q", first)
        run("git", "config", "-f", ".gitmodules", "submodule.vendor.ignore", "all")
        run("git", "add", ".")
        run("git", "commit", "-qm", "base")
        base = rev_parse(self.repository)
        run("git", "-C", "vendor", "checkout", "-q", second)
        run("git", "add", "vendor")
        run("git", "commit", "-qm", "advance gitlink")
        reviewed = rev_parse(self.repository)
        diff = canonical_diff(base, reviewed)
        self.assertIn(b"diff --git a/vendor b/vendor", diff)
        self.assertIn(second.encode(), diff)


class ManifestFixture(GitRepositoryTestCase):
    def build_bundle(
        self,
        *,
        intermediate_revert: bool = False,
        hidden_gitlink: bool = False,
        synthesis_low: bool = False,
        synthesis_role: str = "cross-layer-correctness",
    ) -> tuple[Path, str, str, str]:
        (self.repository / "source.txt").write_text("before\n", encoding="utf-8")
        if hidden_gitlink:
            (self.repository / ".gitmodules").write_text(
                '[submodule "hidden-module"]\n'
                "\tpath = hidden-module\n"
                "\turl = ../unused\n"
                "\tignore = all\n",
                encoding="utf-8",
            )
        run("git", "add", ".")
        run("git", "commit", "-qm", "base")
        base = rev_parse(self.repository)
        (self.repository / "source.txt").write_text("after\n", encoding="utf-8")
        run("git", "add", ".")
        run("git", "commit", "-qm", "reviewed")
        reviewed = rev_parse(self.repository)
        if intermediate_revert:
            (self.repository / "transient.txt").write_text("hidden\n", encoding="utf-8")
            run("git", "add", ".")
            run("git", "commit", "-qm", "transient")
            (self.repository / "transient.txt").unlink()

        shard_input, metadata = explicit_shard_input(base, reviewed, ["source.txt"])
        synthesis_input, synthesis_metadata = full_diff_input(base, reviewed)
        prompts = trusted_prompt_bytes()
        bundle = self.repository / "docs/adversarial-reviews/test"
        bundle.mkdir(parents=True)

        def passing_report(scope: str) -> bytes:
            return (
                f"Review scope: {scope}\n"
                "The frozen change was traced through its declared contract and failure paths.\n"
                "No actionable regression remains in this bounded fixture; hashes and ordering agree.\n"
                "Material residual risk is limited to the procedural provenance documented by the gate.\n"
                "VERDICT: PASS\n"
            ).encode()

        files = {
            "shard-001.input.txt": shard_input,
            "synthesis.input.txt": synthesis_input,
            "security.prompt.txt": prompts["security-reliability"],
            "correctness.prompt.txt": prompts["cross-layer-correctness"],
            "shard-security.report.md": passing_report("shard security"),
            "shard-correctness.report.md": passing_report("shard correctness"),
            "synthesis.report.md": passing_report("integration correctness"),
        }
        if synthesis_low:
            receipt = {
                "baseCommit": base,
                "contextId": "ses_FailedHigh1",
                "finish": "length",
                "inputSha256": synthesis_metadata["inputSha256"],
                "model": "deepseek-v4-flash-0731",
                "outcome": "OUTPUT_LIMIT",
                "provider": "openrouter",
                "requestSha256": hashlib.sha256(
                    build_review_request(prompts[synthesis_role], synthesis_input)
                ).hexdigest(),
                "reviewedCommit": reviewed,
                "role": synthesis_role,
                "schemaVersion": 1,
                "tool": "opencode",
                "toolVersion": "1.18.15",
                "variant": "high",
            }
            files["failed-high.receipt.json"] = (
                json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
        for name, contents in files.items():
            (bundle / name).write_bytes(contents)

        def digest(name: str) -> str:
            return hashlib.sha256(files[name]).hexdigest()

        def review(
            role: str,
            context: str,
            prompt: str,
            report: str,
            review_input: bytes,
            variant: str = "high",
        ) -> dict:
            return {
                "role": role,
                "contextId": context,
                "tool": "opencode",
                "toolVersion": "1.18.15",
                "provider": "openrouter",
                "model": "deepseek-v4-flash-0731",
                "variant": variant,
                "finish": "stop",
                "independent": True,
                "sawOtherReport": False,
                "verdict": "PASS",
                "inputSha256": hashlib.sha256(review_input).hexdigest(),
                "requestSha256": hashlib.sha256(
                    build_review_request(prompts[role], review_input)
                ).hexdigest(),
                "prompt": prompt,
                "promptSha256": digest(prompt),
                "report": report,
                "reportSha256": digest(report),
            }

        manifest = {
            "schemaVersion": 2,
            "baseCommit": base,
            "reviewedCommit": reviewed,
            "sourceDiffSha256": metadata["sourceDiffSha256"],
            "shardPolicy": {
                "maxDiffBytes": 102400,
                "maxChangedLines": 2000,
                "fileBoundaryOnly": True,
            },
            "shards": [
                {
                    "index": 1,
                    "primaryPaths": ["source.txt"],
                    "contextPaths": [],
                    "input": "shard-001.input.txt",
                    "inputSha256": metadata["inputSha256"],
                    "byteLength": metadata["byteLength"],
                    "diffSha256": metadata["diffSha256"],
                    "diffByteLength": metadata["diffByteLength"],
                    "changedLines": metadata["changedLines"],
                    "primaryDiffSha256": metadata["primaryDiffSha256"],
                    "primaryDiffByteLength": metadata["primaryDiffByteLength"],
                    "primaryChangedLines": metadata["primaryChangedLines"],
                    "contextDiffSha256": metadata["contextDiffSha256"],
                    "contextDiffByteLength": metadata["contextDiffByteLength"],
                    "contextChangedLines": metadata["contextChangedLines"],
                    "oversizedSingleFile": False,
                    "reviews": [
                        review(
                            "security-reliability",
                            "ses_ShardSecurity1",
                            "security.prompt.txt",
                            "shard-security.report.md",
                            shard_input,
                        ),
                        review(
                            "cross-layer-correctness",
                            "ses_ShardCorrect1",
                            "correctness.prompt.txt",
                            "shard-correctness.report.md",
                            shard_input,
                        ),
                    ],
                }
            ],
            "synthesis": {
                "rationale": "Review cross-shard integration over canonical full diff.",
                "input": "synthesis.input.txt",
                "inputSha256": synthesis_metadata["inputSha256"],
                "byteLength": synthesis_metadata["byteLength"],
                "reviews": [
                    review(
                        synthesis_role,
                        "ses_Synthesis1",
                        (
                            "correctness.prompt.txt"
                            if synthesis_role == "cross-layer-correctness"
                            else "security.prompt.txt"
                        ),
                        "synthesis.report.md",
                        synthesis_input,
                        "low" if synthesis_low else "high",
                    )
                ],
            },
            "unresolvedBlockers": 0,
        }
        if synthesis_low:
            manifest["synthesis"]["fallback"] = {
                "rationale": "High synthesis reached the provider output limit.",
                "failedHighAttempts": [
                    {
                        "receipt": "failed-high.receipt.json",
                        "receiptSha256": digest("failed-high.receipt.json"),
                    }
                ],
            }
        manifest_path = bundle / "manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        run("git", "add", ".")
        if hidden_gitlink:
            run(
                "git",
                "update-index",
                "--add",
                "--cacheinfo",
                f"160000,{reviewed},hidden-module",
            )
        run("git", "commit", "-qm", "evidence")
        tip = rev_parse(self.repository)
        return Path("docs/adversarial-reviews/test/manifest.json"), base, reviewed, tip


class ManifestValidationTests(ManifestFixture):
    def amend_manifest(self, manifest: Path, contents: bytes) -> str:
        (self.repository / manifest).write_bytes(contents)
        run("git", "add", manifest.as_posix())
        run("git", "commit", "--amend", "--no-edit", "-q")
        return rev_parse(self.repository)

    def test_complete_schema_v2_bundle_is_recomputed(self) -> None:
        manifest, base, _reviewed, tip = self.build_bundle()
        self.assertTrue(validate_manifest(manifest, base, tip))

    def test_validation_reads_artifacts_from_expected_tip_not_checkout(self) -> None:
        manifest, base, _reviewed, tip = self.build_bundle()
        committed_manifests = checker_module.committed_manifest_paths(tip)
        self.assertEqual(committed_manifests, [manifest])
        (self.repository / manifest).write_text("not valid JSON\n", encoding="utf-8")
        report = self.repository / manifest.parent / "shard-security.report.md"
        report.write_text("tampered checkout report\n", encoding="utf-8")
        self.assertTrue(validate_manifest(manifest, base, tip))

    def test_manifest_rejects_duplicate_keys(self) -> None:
        manifest, base, _reviewed, _tip = self.build_bundle()
        raw = (self.repository / manifest).read_bytes()
        duplicate = raw.replace(b"{\n", b'{\n  "unresolvedBlockers": 999,\n', 1)
        tip = self.amend_manifest(manifest, duplicate)
        with self.assertRaisesRegex(EvidenceError, "duplicate JSON key"):
            validate_manifest(manifest, base, tip)

    def test_manifest_rejects_boolean_numeric_and_integer_boolean_fields(self) -> None:
        manifest, base, _reviewed, _tip = self.build_bundle()
        value = json.loads((self.repository / manifest).read_text(encoding="utf-8"))
        value["unresolvedBlockers"] = False
        value["shardPolicy"]["fileBoundaryOnly"] = 1
        value["shards"][0]["contextDiffByteLength"] = False
        value["shards"][0]["contextChangedLines"] = False
        tip = self.amend_manifest(
            manifest,
            (json.dumps(value, indent=2, sort_keys=True) + "\n").encode(),
        )
        with self.assertRaises(EvidenceError):
            validate_manifest(manifest, base, tip)

    def test_manifest_unhashable_synthesis_variant_fails_cleanly(self) -> None:
        manifest, base, _reviewed, _tip = self.build_bundle()
        value = json.loads((self.repository / manifest).read_text(encoding="utf-8"))
        value["synthesis"]["reviews"][0]["variant"] = []
        tip = self.amend_manifest(
            manifest,
            (json.dumps(value, indent=2, sort_keys=True) + "\n").encode(),
        )
        with self.assertRaisesRegex(EvidenceError, "variant"):
            validate_manifest(manifest, base, tip)

    def test_wrapper_uses_physical_single_temp_work_directory(self) -> None:
        wrapper = (SCRIPTS / "run_adversarial_review.sh").read_text(encoding="utf-8")
        self.assertIn('review_work_dir="$(cd "$review_work_dir" && pwd -P)"', wrapper)
        self.assertNotIn('review_input_file="$(mktemp)"', wrapper)

    def test_synthesis_requires_cross_layer_correctness(self) -> None:
        manifest, base, _reviewed, tip = self.build_bundle(
            synthesis_role="security-reliability"
        )
        with self.assertRaises(EvidenceError):
            validate_manifest(manifest, base, tip)

    def test_edit_and_revert_intermediate_commit_is_rejected(self) -> None:
        manifest, base, _reviewed, tip = self.build_bundle(intermediate_revert=True)
        with self.assertRaises(EvidenceError):
            validate_manifest(manifest, base, tip)

    def test_gitmodules_ignore_all_cannot_hide_post_review_gitlink(self) -> None:
        manifest, base, _reviewed, tip = self.build_bundle(hidden_gitlink=True)
        with self.assertRaises(EvidenceError):
            validate_manifest(manifest, base, tip)

    def test_low_synthesis_requires_canonical_same_head_high_receipt(self) -> None:
        manifest, base, _reviewed, tip = self.build_bundle(synthesis_low=True)
        self.assertTrue(validate_manifest(manifest, base, tip))

    def test_low_synthesis_receipt_unhashable_outcome_fails_cleanly(self) -> None:
        manifest, base, _reviewed, _tip = self.build_bundle(synthesis_low=True)
        receipt_path = self.repository / manifest.parent / "failed-high.receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["outcome"] = []
        receipt_bytes = (
            json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode()
        receipt_path.write_bytes(receipt_bytes)
        manifest_path = self.repository / manifest
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
        value["synthesis"]["fallback"]["failedHighAttempts"][0]["receiptSha256"] = (
            hashlib.sha256(receipt_bytes).hexdigest()
        )
        manifest_path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        run("git", "add", ".")
        run("git", "commit", "--amend", "--no-edit", "-q")
        tip = rev_parse(self.repository)
        with self.assertRaisesRegex(EvidenceError, "outcome"):
            validate_manifest(manifest, base, tip)


if __name__ == "__main__":
    unittest.main()
