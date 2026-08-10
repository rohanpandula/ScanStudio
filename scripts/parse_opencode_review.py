#!/usr/bin/env python3
"""Extract one request-bound assistant report from OpenCode JSON evidence."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterator


MAX_EVENT_BYTES = 16 * 1024 * 1024
MAX_EXPORT_BYTES = 64 * 1024 * 1024
MAX_EVENT_PARTS = 10_000
MAX_EXPORTED_PARTS = 10_000
MIN_REPORT_BODY_BYTES = 160
MIN_REPORT_BODY_LINES = 3
VERDICT = re.compile(r"^VERDICT: (PASS|REQUEST_CHANGES|BLOCK)$", re.MULTILINE)
CONTEXT_ID = re.compile(r"^ses_[A-Za-z0-9]+$")
TOOL_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
ROLES = {"security-reliability", "cross-layer-correctness"}
EVENT_TYPES = {
    "step-start": "step_start",
    "reasoning": "reasoning",
    "text": "text",
    "step-finish": "step_finish",
}
FAILURE_OUTCOMES = {"EMPTY_REPORT", "NO_FINAL_VERDICT", "OUTPUT_LIMIT"}


class ParseError(ValueError):
    pass


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ParseError(f"{label} must be a JSON object")
    return value


def parse_json_object(raw: bytes, label: str) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON key: {key}")
            value[key] = item
        return value

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON constant: {value}")

    try:
        value = json.loads(
            raw,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (
        ValueError,
        UnicodeDecodeError,
        RecursionError,
        MemoryError,
        OverflowError,
    ) as exc:
        raise ParseError(f"{label} is not safe valid JSON") from exc
    return require_object(value, label)


def event_lines(raw: bytes) -> Iterator[tuple[int, bytes]]:
    if not raw or len(raw) > MAX_EVENT_BYTES:
        raise ParseError("OpenCode event stream is empty or exceeds the size limit")
    part_count = 0
    for line_number, line in enumerate(io.BytesIO(raw), start=1):
        if not line.strip():
            continue
        part_count += 1
        if part_count > MAX_EVENT_PARTS:
            raise ParseError("OpenCode event stream exceeds the part count limit")
        yield line_number, line


def require_parts(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ParseError(f"{label} lacks parts")
    if len(value) > MAX_EXPORTED_PARTS:
        raise ParseError(f"{label} exceeds the exported part count limit")
    return value


def validate_substantive_report(report: str) -> None:
    """Reject a PASS attestation that contains no meaningful review body."""

    lines = report.splitlines()
    if not lines or lines[-1].strip() != "VERDICT: PASS":
        return
    body = "\n".join(lines[:-1]).strip()
    body_lines = [line for line in lines[:-1] if line.strip()]
    if (
        len(body.encode("utf-8")) < MIN_REPORT_BODY_BYTES
        or len(body_lines) < MIN_REPORT_BODY_LINES
    ):
        raise ParseError("PASS report must contain a substantive review body")


def extract_session_id(raw: bytes) -> str:
    sessions: set[str] = set()
    for line_number, line in event_lines(raw):
        event = parse_json_object(line, f"event line {line_number}")
        session = event.get("sessionID")
        if not isinstance(session, str) or CONTEXT_ID.fullmatch(session) is None:
            raise ParseError(f"event line {line_number} has invalid sessionID")
        sessions.add(session)
    if len(sessions) != 1:
        raise ParseError("OpenCode events must identify exactly one session")
    return next(iter(sessions))


def parse_event_stream(raw: bytes) -> tuple[str, str, str]:
    session_id: str | None = None
    message_id: str | None = None
    text_parts: list[str] = []
    seen_part_ids: set[str] = set()
    state = "before-start"
    for line_number, line in event_lines(raw):
        if state == "finished":
            raise ParseError("OpenCode emitted output after step-finish")
        event = parse_json_object(line, f"event line {line_number}")
        session = event.get("sessionID")
        if not isinstance(session, str) or CONTEXT_ID.fullmatch(session) is None:
            raise ParseError(f"event line {line_number} has invalid sessionID")
        if session_id is None:
            session_id = session
        elif session != session_id:
            raise ParseError("OpenCode events contain more than one session")
        part = require_object(event.get("part"), f"event line {line_number}.part")
        if part.get("sessionID") != session:
            raise ParseError(f"event line {line_number} has mismatched session IDs")
        current_message = part.get("messageID")
        if not isinstance(current_message, str) or not current_message.strip():
            raise ParseError(f"event line {line_number} lacks messageID")
        if message_id is None:
            message_id = current_message
        elif current_message != message_id:
            raise ParseError("OpenCode events contain more than one assistant message")
        part_id = part.get("id")
        if not isinstance(part_id, str) or not part_id.strip():
            raise ParseError(f"event line {line_number} lacks part.id")
        if part_id in seen_part_ids:
            raise ParseError(f"event line {line_number} repeats part.id")
        seen_part_ids.add(part_id)

        part_type = part.get("type")
        expected_event_type = EVENT_TYPES.get(part_type)
        if expected_event_type is None:
            raise ParseError(
                f"event line {line_number} contains forbidden/unknown part {part_type!r}"
            )
        if event.get("type") != expected_event_type:
            raise ParseError(
                f"event line {line_number} has mismatched event/part types"
            )
        if state == "before-start":
            if part_type != "step-start":
                raise ParseError("first OpenCode event must be step-start")
            state = "active"
            continue
        if part_type == "step-start":
            raise ParseError("OpenCode emitted more than one step-start")
        if part_type == "step-finish":
            if part.get("reason") != "stop":
                raise ParseError("OpenCode step-finish reason must be stop")
            state = "finished"
            continue
        if part_type == "text":
            value = part.get("text")
            if not isinstance(value, str):
                raise ParseError(f"event line {line_number} has non-string text")
            text_parts.append(value)

    if state != "finished" or session_id is None or message_id is None:
        raise ParseError(
            "OpenCode events must contain one ordered start/finish sequence"
        )
    report = "".join(text_parts).strip()
    if not report:
        raise ParseError("assistant report is empty")
    verdicts = VERDICT.findall(report)
    if (
        len(verdicts) != 1
        or report.splitlines()[-1].strip() != f"VERDICT: {verdicts[0]}"
    ):
        raise ParseError("assistant report must contain exactly one verdict at EOF")
    return session_id, message_id, report


def exported_text_parts(parts: Any, label: str) -> str:
    parts = require_parts(parts, label)
    values: list[str] = []
    for index, part in enumerate(parts):
        item = require_object(part, f"{label}.parts[{index}]")
        if item.get("type") != "text" or not isinstance(item.get("text"), str):
            raise ParseError(f"{label} must contain text parts only")
        values.append(item["text"])
    if not values:
        raise ParseError(f"{label} has no text")
    return "".join(values)


def exported_assistant_text(parts: Any) -> str:
    parts = require_parts(parts, "exported assistant")
    if len(parts) < 3:
        raise ParseError("exported assistant lacks its ordered parts")
    allowed = {"step-start", "reasoning", "text", "step-finish"}
    part_types: list[str] = []
    text: list[str] = []
    for index, part in enumerate(parts):
        item = require_object(part, f"assistant.parts[{index}]")
        part_type = item.get("type")
        if part_type not in allowed:
            raise ParseError(
                f"exported assistant contains forbidden part {part_type!r}"
            )
        part_types.append(part_type)
        if part_type == "text":
            value = item.get("text")
            if not isinstance(value, str):
                raise ParseError("exported assistant has non-string text")
            text.append(value)
        if part_type == "step-finish" and item.get("reason") != "stop":
            raise ParseError("exported assistant finish reason must be stop")
    if part_types[0] != "step-start" or part_types[-1] != "step-finish":
        raise ParseError("exported assistant parts are not start/finish bounded")
    if part_types.count("step-start") != 1 or part_types.count("step-finish") != 1:
        raise ParseError("exported assistant has repeated start/finish parts")
    if any(kind == "step-start" for kind in part_types[1:]):
        raise ParseError("exported assistant contains a late step-start")
    if not text:
        raise ParseError("exported assistant has no text")
    return "".join(text).strip()


def parse_export(
    raw: bytes,
    *,
    session_id: str,
    message_id: str,
    report: str,
    request: bytes,
    tool_version: str,
    expected_provider: str,
    expected_model: str,
    expected_variant: str,
) -> dict[str, str]:
    if not raw or len(raw) > MAX_EXPORT_BYTES:
        raise ParseError("OpenCode session export is empty or exceeds the size limit")
    if TOOL_VERSION.fullmatch(tool_version) is None:
        raise ParseError("OpenCode tool version is not semver-like")
    exported = parse_json_object(raw, "session export")
    try:
        request_text = request.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ParseError("review request is not UTF-8") from exc
    export_info = require_object(exported.get("info"), "session export info")
    if export_info.get("id") != session_id:
        raise ParseError("session export top-level ID does not match events")
    messages = exported.get("messages")
    if not isinstance(messages, list) or len(messages) != 2:
        raise ParseError("fresh review session must contain exactly two messages")
    entries: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(messages):
        item = require_object(entry, f"messages[{index}]")
        info = require_object(item.get("info"), f"messages[{index}].info")
        identifier = info.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise ParseError(f"messages[{index}] lacks info.id")
        if identifier in entries:
            raise ParseError("session export repeats a message ID")
        if info.get("sessionID") != session_id:
            raise ParseError("session export message belongs to another session")
        entries[identifier] = item

    assistant = entries.get(message_id)
    if assistant is None:
        raise ParseError("session export does not contain the event assistant message")
    assistant_info = require_object(assistant.get("info"), "assistant message info")
    if assistant_info.get("role") != "assistant":
        raise ParseError("event message is not an assistant message in session export")
    if assistant_info.get("error") is not None:
        raise ParseError("session export records an assistant error")
    if assistant_info.get("providerID") != expected_provider:
        raise ParseError("session export provider does not match the pinned provider")
    if assistant_info.get("modelID") != expected_model:
        raise ParseError("session export model does not match the pinned model")
    if assistant_info.get("variant") != expected_variant:
        raise ParseError("session export variant does not match the requested variant")
    if assistant_info.get("finish") != "stop":
        raise ParseError("session export finish reason is not stop")
    parent_id = assistant_info.get("parentID")
    if not isinstance(parent_id, str) or not parent_id:
        raise ParseError("assistant message lacks parentID")
    parent = entries.get(parent_id)
    if parent is None:
        raise ParseError("assistant parent user message is absent from export")
    parent_info = require_object(parent.get("info"), "parent user message info")
    if parent_info.get("role") != "user":
        raise ParseError("assistant parent is not a user message")
    user_model = require_object(parent_info.get("model"), "parent user model")
    if (
        user_model.get("providerID") != expected_provider
        or user_model.get("modelID") != expected_model
        or user_model.get("variant") != expected_variant
    ):
        raise ParseError("parent user message model metadata does not match request")
    parent_text = exported_text_parts(parent.get("parts"), "parent user message")
    if parent_text != request_text:
        raise ParseError("exported parent user message does not match request bytes")
    exported_text = exported_assistant_text(assistant.get("parts"))
    if exported_text != report:
        raise ParseError("event report does not match exported assistant text")
    return {
        "contextId": session_id,
        "finish": "stop",
        "model": expected_model.removeprefix("deepseek/"),
        "provider": expected_provider,
        "requestSha256": hashlib.sha256(request).hexdigest(),
        "toolVersion": tool_version,
        "variant": expected_variant,
    }


def parse_failure_receipt(
    raw: bytes,
    *,
    session_id: str,
    request: bytes,
    tool_version: str,
    base_commit: str,
    reviewed_commit: str,
    role: str,
    input_sha256: str,
    outcome: str,
    expected_provider: str,
    expected_model: str,
) -> dict[str, Any]:
    if outcome not in FAILURE_OUTCOMES:
        raise ParseError("failure receipt outcome is invalid")
    if (
        FULL_COMMIT.fullmatch(base_commit) is None
        or FULL_COMMIT.fullmatch(reviewed_commit) is None
        or base_commit == reviewed_commit
    ):
        raise ParseError("failure receipt commits are invalid")
    if role not in ROLES or HEX_SHA256.fullmatch(input_sha256) is None:
        raise ParseError("failure receipt role or input hash is invalid")
    if TOOL_VERSION.fullmatch(tool_version) is None:
        raise ParseError("OpenCode tool version is not semver-like")
    if not raw or len(raw) > MAX_EXPORT_BYTES:
        raise ParseError("OpenCode session export is empty or exceeds the size limit")
    exported = parse_json_object(raw, "session export")
    try:
        request_text = request.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ParseError("review request is not UTF-8") from exc
    export_info = require_object(exported.get("info"), "session export info")
    if export_info.get("id") != session_id:
        raise ParseError("session export top-level ID does not match events")
    messages = exported.get("messages")
    if not isinstance(messages, list) or len(messages) != 2:
        raise ParseError(
            "failed fresh review session must contain exactly two messages"
        )
    user_entries: dict[str, dict[str, Any]] = {}
    assistants: list[dict[str, Any]] = []
    for index, entry in enumerate(messages):
        item = require_object(entry, f"messages[{index}]")
        info = require_object(item.get("info"), f"messages[{index}].info")
        if info.get("sessionID") != session_id:
            raise ParseError("failure export message belongs to another session")
        if info.get("role") == "user":
            identifier = info.get("id")
            if not isinstance(identifier, str) or not identifier:
                raise ParseError("failure export user message lacks ID")
            user_entries[identifier] = item
        elif info.get("role") == "assistant":
            assistants.append(item)
        else:
            raise ParseError("failure export contains an unknown message role")
    if len(user_entries) != 1 or len(assistants) != 1:
        raise ParseError("failure export must contain one user and one assistant")
    assistant = assistants[0]
    assistant_info = require_object(assistant.get("info"), "assistant message info")
    parent_id = assistant_info.get("parentID")
    if parent_id not in user_entries:
        raise ParseError("failed assistant is not bound to exported user request")
    parent = user_entries[parent_id]
    parent_info = require_object(parent.get("info"), "parent user message info")
    user_model = require_object(parent_info.get("model"), "parent user model")
    if (
        user_model.get("providerID") != expected_provider
        or user_model.get("modelID") != expected_model
        or user_model.get("variant") != "high"
        or assistant_info.get("providerID") != expected_provider
        or assistant_info.get("modelID") != expected_model
        or assistant_info.get("variant") != "high"
    ):
        raise ParseError("failure export does not use the pinned high model")
    if assistant_info.get("error") is not None:
        raise ParseError("failed assistant records a provider error")
    if exported_text_parts(parent.get("parts"), "parent user message") != request_text:
        raise ParseError("failure export parent does not match request bytes")
    assistant_parts = require_parts(assistant.get("parts"), "failed assistant")
    allowed_parts = {"step-start", "reasoning", "text", "step-finish"}
    part_types: list[str] = []
    assistant_text_parts: list[str] = []
    for index, raw_part in enumerate(assistant_parts):
        part = require_object(raw_part, f"failed assistant.parts[{index}]")
        part_type = part.get("type")
        if part_type not in allowed_parts:
            raise ParseError("failed assistant contains forbidden/unknown parts")
        assert isinstance(part_type, str)
        part_types.append(part_type)
        if part_type in {"reasoning", "text"}:
            value = part.get("text")
            if not isinstance(value, str):
                raise ParseError(
                    f"failed assistant {part_type} part must contain string text"
                )
            if part_type == "text":
                assistant_text_parts.append(value)
    assistant_text = "".join(assistant_text_parts).strip()
    finish = assistant_info.get("finish")
    if (
        not part_types
        or part_types[0] != "step-start"
        or part_types.count("step-start") != 1
    ):
        raise ParseError("failed assistant must begin with exactly one step-start")
    finish_parts = [
        part
        for part in assistant_parts
        if isinstance(part, dict) and part.get("type") == "step-finish"
    ]
    if (
        len(finish_parts) != 1
        or assistant_parts[-1] is not finish_parts[0]
        or finish_parts[0].get("reason") != finish
    ):
        raise ParseError("failed assistant finish part does not match message finish")
    if outcome == "OUTPUT_LIMIT":
        if finish != "length":
            raise ParseError("OUTPUT_LIMIT requires finish=length")
    elif outcome == "EMPTY_REPORT":
        if finish != "stop" or assistant_text:
            raise ParseError("EMPTY_REPORT requires finish=stop and empty text")
    elif outcome == "NO_FINAL_VERDICT":
        if finish != "stop" or not assistant_text or VERDICT.search(assistant_text):
            raise ParseError(
                "NO_FINAL_VERDICT requires non-empty finish=stop text without verdict"
            )
    return {
        "baseCommit": base_commit,
        "contextId": session_id,
        "finish": finish,
        "inputSha256": input_sha256,
        "model": expected_model.removeprefix("deepseek/"),
        "outcome": outcome,
        "provider": expected_provider,
        "requestSha256": hashlib.sha256(request).hexdigest(),
        "reviewedCommit": reviewed_commit,
        "role": role,
        "schemaVersion": 1,
        "tool": "opencode",
        "toolVersion": tool_version,
        "variant": "high",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    session = subparsers.add_parser("session-id")
    session.add_argument("--events", type=Path, required=True)
    report = subparsers.add_parser("report")
    report.add_argument("--events", type=Path, required=True)
    report.add_argument("--export", type=Path, required=True)
    report.add_argument("--request", type=Path, required=True)
    report.add_argument("--tool-version", required=True)
    report.add_argument("--provider", required=True)
    report.add_argument("--model", required=True)
    report.add_argument("--variant", required=True)
    receipt = subparsers.add_parser("failure-receipt")
    receipt.add_argument("--events", type=Path, required=True)
    receipt.add_argument("--export", type=Path, required=True)
    receipt.add_argument("--request", type=Path, required=True)
    receipt.add_argument("--tool-version", required=True)
    receipt.add_argument("--base", required=True)
    receipt.add_argument("--reviewed", required=True)
    receipt.add_argument("--role", required=True)
    receipt.add_argument("--input-sha256", required=True)
    receipt.add_argument("--outcome", required=True)
    receipt.add_argument("--provider", required=True)
    receipt.add_argument("--model", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        event_bytes = args.events.read_bytes()
        if args.command == "session-id":
            session_id = extract_session_id(event_bytes)
            print(session_id)
            return 0
        if args.command == "failure-receipt":
            receipt = parse_failure_receipt(
                args.export.read_bytes(),
                session_id=extract_session_id(event_bytes),
                request=args.request.read_bytes(),
                tool_version=args.tool_version,
                base_commit=args.base,
                reviewed_commit=args.reviewed,
                role=args.role,
                input_sha256=args.input_sha256,
                outcome=args.outcome,
                expected_provider=args.provider,
                expected_model=args.model,
            )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        session_id, message_id, report = parse_event_stream(event_bytes)
        validate_substantive_report(report)
        metadata = parse_export(
            args.export.read_bytes(),
            session_id=session_id,
            message_id=message_id,
            report=report,
            request=args.request.read_bytes(),
            tool_version=args.tool_version,
            expected_provider=args.provider,
            expected_model=args.model,
            expected_variant=args.variant,
        )
        sys.stdout.write(report + "\n")
        print(
            "REVIEW_METADATA " + json.dumps(metadata, sort_keys=True), file=sys.stderr
        )
        return 0
    except (OSError, ParseError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
