"""Tests for scanstudio_bridge.transport (the package's own __init__.py):
`timed_call`/`phased_call`, the shared call-boundary telemetry primitives
both Transport implementations build on. Isolated from any real or mock
Transport -- a bare recording `on_call` double is enough to pin the exact
contract `CoolscanPyTransport`/`MockTransport` both rely on.
"""

from __future__ import annotations

import pytest

from scanstudio_bridge.transport import phased_call, timed_call


class _RecordingOnCall:
    def __init__(self) -> None:
        self.entries: list[dict[str, object]] = []

    def __call__(
        self,
        phase: str,
        name: str,
        elapsed_seconds: float | None,
        kind: str = "call",
        *,
        call_outcome: str | None = None,
        exception_class: str | None = None,
    ) -> None:
        self.entries.append(
            {
                "phase": phase,
                "name": name,
                "elapsed_seconds": elapsed_seconds,
                "kind": kind,
                "call_outcome": call_outcome,
                "exception_class": exception_class,
            }
        )


# -- timed_call: basic enter/exit shape, unchanged from Plan 10-04 ------------------


def test_timed_call_returns_the_wrapped_functions_result() -> None:
    assert timed_call(None, "noop", lambda: 42) == 42


def test_timed_call_with_no_on_call_still_runs_fn() -> None:
    calls: list[int] = []
    result = timed_call(None, "noop", lambda: calls.append(1) or "done")
    assert result == "done"
    assert calls == [1]


def test_timed_call_emits_enter_then_exit_with_default_kind_call() -> None:
    on_call = _RecordingOnCall()
    timed_call(on_call, "some.op", lambda: None)

    assert [e["phase"] for e in on_call.entries] == ["enter", "exit"]
    assert on_call.entries[0]["kind"] == "call"
    assert on_call.entries[0]["elapsed_seconds"] is None
    assert on_call.entries[1]["kind"] == "call"
    assert isinstance(on_call.entries[1]["elapsed_seconds"], float)
    assert on_call.entries[1]["elapsed_seconds"] >= 0


def test_timed_call_honors_an_explicit_phase_kind() -> None:
    on_call = _RecordingOnCall()
    timed_call(on_call, "some.op", lambda: None, kind="phase")
    assert on_call.entries[0]["kind"] == "phase"
    assert on_call.entries[1]["kind"] == "phase"


# -- timed_call: raise-aware exit telemetry (Plan 10-09, coordinator addition) ------


def test_timed_call_exit_reports_call_outcome_return_on_success() -> None:
    on_call = _RecordingOnCall()
    timed_call(on_call, "some.op", lambda: "ok")
    exit_entry = on_call.entries[1]
    assert exit_entry["call_outcome"] == "return"
    assert exit_entry["exception_class"] is None


def test_timed_call_exit_reports_call_outcome_raise_and_exception_class() -> None:
    on_call = _RecordingOnCall()

    def _boom() -> None:
        raise ValueError("synthetic failure")

    with pytest.raises(ValueError, match="synthetic failure"):
        timed_call(on_call, "some.op", _boom)

    assert [e["phase"] for e in on_call.entries] == ["enter", "exit"]
    exit_entry = on_call.entries[1]
    assert exit_entry["call_outcome"] == "raise"
    assert exit_entry["exception_class"] == "ValueError"


def test_timed_call_reraises_the_original_exception_unchanged() -> None:
    """The exception itself must never be swallowed, wrapped, or replaced
    -- only observed for telemetry purposes."""
    on_call = _RecordingOnCall()
    original = RuntimeError("distinctive marker")

    def _boom() -> None:
        raise original

    with pytest.raises(RuntimeError) as excinfo:
        timed_call(on_call, "some.op", _boom)
    assert excinfo.value is original


def test_timed_call_exit_fires_even_with_no_on_call_when_fn_raises() -> None:
    """Never depends on telemetry being wired -- the exception path must
    work identically whether or not on_call is None."""
    with pytest.raises(KeyError):
        timed_call(None, "some.op", lambda: (_ for _ in ()).throw(KeyError("x")))


def test_timed_call_works_against_an_on_call_that_only_declares_kind_with_a_default() -> None:
    """`timed_call` always sends `kind` positionally (4 args on "enter", 4
    args + call_outcome/exception_class kwargs on "exit") -- any `on_call`
    implementation actually PASSED INTO `timed_call`/`phased_call` (as
    opposed to a hand-written Transport double that calls `on_call(...)`
    directly, bypassing timed_call entirely, e.g.
    tests/test_scan_worker_telemetry.py's `_HangingTransport`) must accept
    at least 4 positional args plus `**kwargs` to avoid a TypeError on
    "exit" -- exactly the shape service.py's real `on_call` closure has."""
    received: list[tuple] = []

    def minimal_on_call(
        phase: str, name: str, elapsed_seconds: float | None, kind: str = "call", **_kwargs: object
    ) -> None:
        received.append((phase, name, elapsed_seconds, kind))

    timed_call(minimal_on_call, "legacy.call", lambda: None)
    assert received[0] == ("enter", "legacy.call", None, "call")
    assert received[1][0:2] == ("exit", "legacy.call")
    assert received[1][3] == "call"


def test_a_transport_double_calling_on_call_directly_with_three_args_is_a_separate_concern() -> None:
    """Documents the OTHER backward-compat axis (see
    tests/test_scan_worker_telemetry.py's `_HangingTransport`, which is
    exactly this shape against the real service.py): a Transport that calls
    `on_call(...)` directly, bypassing `timed_call`, may pass as few
    positional args as it likes -- that works because the RECEIVING
    `on_call` (service.py's real closure) defaults every parameter beyond
    the first three. `timed_call` itself is not involved in that path at
    all, so it is not exercised here -- this test only pins that a 3-arg
    direct call against a defaults-having `on_call` doesn't raise."""

    def defaults_having_on_call(
        phase: str,
        name: str,
        elapsed_seconds: float | None,
        kind: str = "call",
        *,
        call_outcome: str | None = None,
        exception_class: str | None = None,
    ) -> None:
        pass

    defaults_having_on_call("enter", "roll.scan:slot1", None)  # must not raise


# -- phased_call: dual scan.call + scan.phase tagging under one name ----------------


def test_phased_call_returns_the_wrapped_functions_result() -> None:
    assert phased_call(None, "write.rgb", lambda: "written") == "written"


def test_phased_call_emits_both_a_call_and_a_phase_boundary_under_the_same_name() -> None:
    on_call = _RecordingOnCall()
    phased_call(on_call, "file_write.rgb:slot1", lambda: None)

    kinds_and_phases = [(e["kind"], e["phase"]) for e in on_call.entries]
    assert ("phase", "enter") in kinds_and_phases
    assert ("call", "enter") in kinds_and_phases
    assert ("call", "exit") in kinds_and_phases
    assert ("phase", "exit") in kinds_and_phases
    assert all(e["name"] == "file_write.rgb:slot1" for e in on_call.entries)


def test_phased_call_nests_call_boundary_fully_inside_phase_boundary() -> None:
    on_call = _RecordingOnCall()
    phased_call(on_call, "file_write.rgb:slot1", lambda: None)

    order = [(e["kind"], e["phase"]) for e in on_call.entries]
    assert order == [
        ("phase", "enter"),
        ("call", "enter"),
        ("call", "exit"),
        ("phase", "exit"),
    ]


def test_phased_call_propagates_exceptions_and_tags_both_boundaries_as_raise() -> None:
    on_call = _RecordingOnCall()

    def _boom() -> None:
        raise ValueError("phased failure")

    with pytest.raises(ValueError, match="phased failure"):
        phased_call(on_call, "file_write.rgb:slot1", _boom)

    exit_entries = [e for e in on_call.entries if e["phase"] == "exit"]
    assert len(exit_entries) == 2
    for entry in exit_entries:
        assert entry["call_outcome"] == "raise"
        assert entry["exception_class"] == "ValueError"
