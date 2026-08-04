"""Tests for scanstudio_bridge.cli: the NDJSON stdin/stdout dispatch loop
and console entry point. Drives `main()` directly with monkeypatched
`sys.stdin`/`sys.stdout` (an in-process StringIO session, not a real
subprocess -- the subprocess path is covered by scripts/smoke_bridge.sh)
and `SCANSTUDIO_BRIDGE_TRANSPORT=mock` so no test here ever touches real
hardware. Every test redirects `SCANSTUDIO_BRIDGE_BASE_DIR` to `tmp_path`,
never the real `~/.scanstudio` (see safety.py's own module docstring).
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

from scanstudio_bridge import cli


def _read_telemetry_entries(base_dir: Path) -> list[dict]:
    files = list((base_dir / "hw-telemetry").glob("*.jsonl"))
    assert len(files) == 1, f"expected exactly one telemetry file, found {files}"
    return [json.loads(line) for line in files[0].read_text().splitlines() if line.strip()]


def _run_main_with_session(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, request_lines: list[dict]
) -> str:
    """Drives `cli.main()` with `request_lines` fed through a StringIO
    stdin (each dict one NDJSON line) and captures stdout to a StringIO,
    returning its full text. Always ends with `bridge.shutdown` so
    `main()`'s stdin loop terminates deterministically (mirrors
    scripts/smoke_bridge.sh's own session shape)."""
    monkeypatch.setenv("SCANSTUDIO_BRIDGE_TRANSPORT", "mock")
    monkeypatch.setenv("SCANSTUDIO_BRIDGE_BASE_DIR", str(tmp_path))
    stdin_text = "".join(json.dumps(line) + "\n" for line in request_lines)
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin_text))
    captured_stdout = io.StringIO()
    monkeypatch.setattr(sys, "stdout", captured_stdout)

    with pytest.raises(SystemExit) as excinfo:
        cli.main()
    assert excinfo.value.code == 0
    return captured_stdout.getvalue()


# -- bridge.provenance telemetry (Plan 10-09) ---------------------------------------


def test_main_records_bridge_provenance_telemetry_before_any_request(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _run_main_with_session(
        monkeypatch,
        tmp_path,
        [
            {"id": 1, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
            {"id": 2, "method": "bridge.shutdown", "params": {}},
        ],
    )

    entries = _read_telemetry_entries(tmp_path)
    assert entries, "expected at least one telemetry entry"
    # "at bridge startup": the very first telemetry line written, strictly
    # before bridge.hello (or anything else) is even read off stdin.
    assert entries[0]["method"] == "bridge.provenance"
    assert entries[0]["outcome"] == "ok"

    provenance_entries = [e for e in entries if e["method"] == "bridge.provenance"]
    assert len(provenance_entries) == 1
    entry = provenance_entries[0]
    assert isinstance(entry["file"], str) and entry["file"]
    assert isinstance(entry["version"], str) and entry["version"]
    assert entry["head_sha"] is None or isinstance(entry["head_sha"], str)
    assert "timestamp" in entry


def test_main_records_bridge_provenance_even_when_no_request_is_ever_sent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Provenance is a startup fact, not a response to bridge.hello --
    still recorded even if the session is immediately shut down."""
    _run_main_with_session(
        monkeypatch, tmp_path, [{"id": 1, "method": "bridge.shutdown", "params": {}}]
    )
    entries = _read_telemetry_entries(tmp_path)
    assert entries[0]["method"] == "bridge.provenance"


def test_main_records_bridge_provenance_with_mock_transport_selected(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """coolscanpy is imported transitively regardless of
    SCANSTUDIO_BRIDGE_TRANSPORT (cli.py imports CoolscanPyTransport
    unconditionally at module level) -- provenance must be reported even
    when MockTransport is what actually answers requests this session."""
    output = _run_main_with_session(
        monkeypatch,
        tmp_path,
        [
            {"id": 1, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
            {"id": 2, "method": "device.list"},
            {"id": 3, "method": "bridge.shutdown"},
        ],
    )
    assert '"protocolVersion"' in output
    assert "mock-ls5000-0" in output
    entries = _read_telemetry_entries(tmp_path)
    assert entries[0]["method"] == "bridge.provenance"
