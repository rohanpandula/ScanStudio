"""Focused tests for the trusted journal-to-manifest capture-timing
normalization at the CoolscanPy boundary.

Covers the exact contract the real receipt-timing bug requires:

- the worker's new explicit ``started_at`` / ``capture_duration_ms`` fields
  are trusted exactly;
- legacy ``started_unix`` / ``finished_unix`` journals derive a nonnegative
  duration milliseconds and a legacy ISO-UTC start;
- malformed, negative, NaN, infinite, reversed, or oversize timing is
  rejected (never silently trusted) and yields ``None``;
- missing wire timing yields ``None`` fields, never an engine-arrival time.
"""

from __future__ import annotations

import datetime
import dataclasses

import coolscanpy._roll as roll_module
import pytest
from coolscanpy.capture.single_pass_workflow import (
    _coerce_nonnegative_u64_ms,
    _finalized_capture_timing,
    _normalize_capture_timing,
)
from coolscanpy.types import (
    ClippingTelemetry,
    ExposureVector,
    FocusDetailTelemetry,
    Receipt,
    TransportSmearAssessment,
)


def _iso(unix_seconds: float) -> str:
    return datetime.datetime.fromtimestamp(
        unix_seconds, tz=datetime.timezone.utc
    ).isoformat()


def _public_receipt() -> Receipt:
    return Receipt(
        version=1,
        slot=1,
        spacing_offset=0,
        dpi=4000,
        depth=16,
        device_id="ls5000-test",
        device_model="Nikon LS-5000 ED",
        reviewed_fingerprint_sha256="a" * 64,
        fresh_fingerprint_sha256="a" * 64,
        manual_approval=None,
        exposure=ExposureVector(0, 1.0, 1.0, 1.0, 1.0),
        split_alignment=None,
        clipping=ClippingTelemetry((0.0, 0.0, 0.0), 0.995, 0.02, False),
        focus_detail=FocusDetailTelemetry("test", "measured", 1.0, 1.0),
        transport_smear=TransportSmearAssessment(
            "clean", None, 0, 0, None, None, None, None, "clean"
        ),
        artifacts={},
        storage_transform="swapaxes01-scanner-native-to-nikon-render-parity-v2",
        started_at="2026-08-02T20:05:00+00:00",
        capture_duration_ms=1900,
    )


def test_new_explicit_fields_are_trusted_exactly() -> None:
    started_at = "2026-08-02T20:05:00+00:00"
    journal = {
        "started_at": started_at,
        "capture_duration_ms": 1900,
        # Legacy fields present but explicitly overridden by the new ones.
        "started_unix": 100.0,
        "finished_unix": 200.0,
    }
    normal_started, duration = _normalize_capture_timing(journal)
    assert normal_started == "2026-08-02T20:05:00+00:00"
    assert duration == 1900


def test_legacy_started_finished_derive_duration() -> None:
    journal = {
        "started_unix": 100.0,
        "finished_unix": 102.5,
    }
    started_at, duration = _normalize_capture_timing(journal)
    assert duration == 2500
    assert started_at == _iso(100.0)


def test_legacy_derives_from_integer_unix_seconds() -> None:
    journal = {"started_unix": 100, "finished_unix": 110}
    started_at, duration = _normalize_capture_timing(journal)
    assert duration == 10000
    assert started_at == _iso(100.0)


def test_missing_timing_yields_none() -> None:
    started_at, duration = _normalize_capture_timing({})
    assert started_at is None
    assert duration is None


def test_legacy_with_only_start_value_keeps_absent_duration() -> None:
    # Only a start exists: no finish, so no duration is derivable; keep the
    # legacy start value and leave duration absent rather than inventing one.
    started_at, duration = _normalize_capture_timing({"started_unix": 100.0})
    assert started_at == _iso(100.0)
    assert duration is None


def test_reversed_times_yield_absent_duration() -> None:
    stared, duration = _normalize_capture_timing(
        {"started_unix": 100.0, "finished_unix": 50.0}
    )
    # Reversed is rejected entirely (no trusted timing at all).
    assert stared is None
    assert duration is None


def test_negative_duration_is_rejected() -> None:
    started_at, duration = _normalize_capture_timing(
        {"started_at": "2026-08-02T20:05:00+00:00", "capture_duration_ms": -5}
    )
    assert started_at is not None
    assert duration is None


def test_boolean_duration_is_rejected() -> None:
    _, duration = _normalize_capture_timing({"capture_duration_ms": True})
    assert duration is None


def test_nan_duration_is_rejected() -> None:
    _, duration = _normalize_capture_timing({"capture_duration_ms": float("nan")})
    assert duration is None


def test_infinite_duration_is_rejected() -> None:
    _, duration = _normalize_capture_timing(
        {"capture_duration_ms": float("inf")}
    )
    assert duration is None


def test_float_duration_is_rejected_instead_of_rounded() -> None:
    _, duration = _normalize_capture_timing({"capture_duration_ms": 1900.0})
    assert duration is None


def test_oversize_duration_beyond_u64_is_rejected() -> None:
    _, duration = _normalize_capture_timing(
        {"capture_duration_ms": (1 << 64)}
    )
    assert duration is None


def test_malformed_started_at_string_is_rejected() -> None:
    started_at, _ = _normalize_capture_timing(
        {"started_at": "not-a-timestamp", "capture_duration_ms": 1}
    )
    assert started_at is None


def test_started_at_without_timezone_is_rejected() -> None:
    started_at, _ = _normalize_capture_timing(
        {"started_at": "2026-08-02T20:05:00", "capture_duration_ms": 1}
    )
    assert started_at is None


def test_legacy_timestamp_outside_datetime_range_is_rejected() -> None:
    started_at, duration = _normalize_capture_timing(
        {"started_unix": 1e300, "finished_unix": 1e300}
    )
    assert started_at is None
    assert duration is None


def test_arbitrarily_large_legacy_integer_is_rejected_without_crashing() -> None:
    started_at, duration = _normalize_capture_timing(
        {"started_unix": 10**1000, "finished_unix": 10**1000}
    )
    assert started_at is None
    assert duration is None


def test_coerce_rejects_bool_negative_and_oversize() -> None:
    assert _coerce_nonnegative_u64_ms(True) is None
    assert _coerce_nonnegative_u64_ms(-1) is None
    assert _coerce_nonnegative_u64_ms((1 << 64) + 1) is None
    assert _coerce_nonnegative_u64_ms(0) == 0
    assert _coerce_nonnegative_u64_ms(1234) == 1234


def test_near_u64_max_duration_is_accepted() -> None:
    u64_max = (1 << 64) - 1
    started_at, duration = _normalize_capture_timing(
        {"started_at": "2026-08-02T20:05:00+00:00", "capture_duration_ms": u64_max}
    )
    assert started_at is not None
    assert duration == u64_max


def test_finalized_explicit_timing_includes_final_quality_checks() -> None:
    timing = _finalized_capture_timing(
        {
            "started_at": "2026-08-02T20:05:00+00:00",
            "capture_duration_ms": 1900,
        },
        100,
    )
    assert timing == (
        "2026-08-02T20:05:00+00:00",
        1900,
        100,
        2000,
    )


def test_finalized_legacy_timing_is_stable_across_replays() -> None:
    timing = _finalized_capture_timing(
        {"started_unix": 100.0, "finished_unix": 102.5},
        100,
    )
    assert timing == (_iso(100.0), 2500, None, 2500)


def test_finalized_explicit_timing_rejects_u64_overflow() -> None:
    u64_max = (1 << 64) - 1
    timing = _finalized_capture_timing(
        {
            "started_at": "2026-08-02T20:05:00+00:00",
            "capture_duration_ms": u64_max,
        },
        1,
    )
    assert timing == (
        "2026-08-02T20:05:00+00:00",
        u64_max,
        None,
        None,
    )


def test_receipt_boundary_keeps_trusted_timing() -> None:
    capture = {
        "started_at": "2026-08-02T20:05:00+00:00",
        "capture_duration_ms": 1900,
    }
    assert roll_module._receipt_started_at(capture) == "2026-08-02T20:05:00+00:00"
    assert roll_module._receipt_duration_ms(capture) == 1900


def test_receipt_boundary_rejects_malformed_timing() -> None:
    assert roll_module._receipt_started_at({"started_at": ""}) is None
    assert roll_module._receipt_started_at({"started_at": "garbage"}) is None
    assert roll_module._receipt_started_at({"started_at": None}) is None
    assert roll_module._receipt_duration_ms({"capture_duration_ms": None}) is None
    assert roll_module._receipt_duration_ms({"capture_duration_ms": -1}) is None
    assert roll_module._receipt_duration_ms({"capture_duration_ms": True}) is None
    assert roll_module._receipt_duration_ms(
        {"capture_duration_ms": "1900"}
    ) is None


def test_receipt_boundary_normalizes_timezone_to_utc() -> None:
    assert roll_module._receipt_started_at(
        {"started_at": "2026-08-02T21:05:00+01:00"}
    ) == "2026-08-02T20:05:00+00:00"


@pytest.mark.parametrize(
    "started_at",
    ["garbage", "2026-08-02T20:05:00", "2026-08-02T21:05:00+01:00"],
)
def test_public_receipt_rejects_non_utc_started_at(started_at: str) -> None:
    with pytest.raises(ValueError, match="ISO-8601 UTC"):
        dataclasses.replace(_public_receipt(), started_at=started_at)


def test_public_receipt_rejects_duration_beyond_u64() -> None:
    with pytest.raises(ValueError, match="unsigned 64-bit"):
        dataclasses.replace(_public_receipt(), capture_duration_ms=(1 << 64))
