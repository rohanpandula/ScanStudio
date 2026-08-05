"""Tests for the acquisition slice of the LS-5000 dual-RGBI ICE bundle.

Split from NegPy's tests/scanners/test_ls5000_ice.py: this package owns only
acquire_ice_bundle/build_ice_receipt/IceRollError (the acquire-and-hand-off
half). process_ice_bundle/publish_ice_frame and every hybrid-repair test
stayed behind in NegPy, which still owns the engine-invocation and
publish-to-disk half (see coolscanpy.receipts.ice_bundle docstring).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace

import pytest

from coolscanpy.receipts import ice_bundle
from coolscanpy.receipts.ice_bundle import (
    ICE_FRAME_RECEIPT_KIND,
    ICE_FRAME_RECEIPT_VERSION,
    build_ice_receipt,
)
from coolscanpy.transport.libsane_dual_source import DiceDualSourcePlan


class _FakeDevice:
    def __init__(self, log: list[str]) -> None:
        self._log = log

    def close(self) -> None:
        self._log.append("device.close")


class _FakeLibsane:
    instances: list["_FakeLibsane"] = []

    def __init__(self) -> None:
        self.log: list[str] = []
        _FakeLibsane.instances.append(self)

    def require_ls5000(self, device_id: str):
        self.log.append(f"require:{device_id}")
        return SimpleNamespace(device_id=device_id)

    def open(self, device_id: str, *, identity=None):
        self.log.append(f"open:{device_id}")
        return _FakeDevice(self.log)

    def close(self) -> None:
        self.log.append("sane.close")


def test_acquire_closes_every_handle_before_the_bundle_is_written(monkeypatch, tmp_path) -> None:
    _FakeLibsane.instances = []
    plan = DiceDualSourcePlan.for_transport("roll", frame=3, subframe_mm=1.25)
    capture = SimpleNamespace(scanner_identity=SimpleNamespace(device_id="coolscan3:usb:test"))
    order: list[str] = []

    def fake_acquire(device, acquired_plan, *, progress=None):
        assert acquired_plan is plan
        _FakeLibsane.instances[0].log.append("acquire")
        return capture

    def fake_write(bundle_root, *, device_id, plan, capture, run_id):
        order.extend(_FakeLibsane.instances[0].log)
        order.append("write_bundle")
        return Path(bundle_root) / run_id

    monkeypatch.setattr(ice_bundle, "Libsane", _FakeLibsane)
    monkeypatch.setattr(ice_bundle, "acquire_dual_sources", fake_acquire)
    monkeypatch.setattr(ice_bundle, "write_capture_bundle", fake_write)

    bundle = ice_bundle.acquire_ice_bundle(
        device_id="coolscan3:usb:test",
        plan=plan,
        bundle_root=tmp_path,
        run_id="slot03-test",
    )

    assert bundle == tmp_path / "slot03-test"
    assert order == [
        "require:coolscan3:usb:test",
        "open:coolscan3:usb:test",
        "acquire",
        "device.close",
        "sane.close",
        "write_bundle",
    ]


def test_acquire_closes_handles_even_when_acquisition_fails(monkeypatch, tmp_path) -> None:
    _FakeLibsane.instances = []

    def failing_acquire(device, plan, *, progress=None):
        raise RuntimeError("transport jammed")

    monkeypatch.setattr(ice_bundle, "Libsane", _FakeLibsane)
    monkeypatch.setattr(ice_bundle, "acquire_dual_sources", failing_acquire)

    with pytest.raises(RuntimeError, match="transport jammed"):
        ice_bundle.acquire_ice_bundle(
            device_id="coolscan3:usb:test",
            plan=DiceDualSourcePlan.for_transport("roll", frame=1),
            bundle_root=tmp_path,
            run_id="slot01-fail",
        )

    assert _FakeLibsane.instances[0].log[-2:] == ["device.close", "sane.close"]


@dataclass
class _StubEngineReceipt:
    """Duck-typed stand-in for the (NegPy-owned) engine receipt dataclass.

    build_ice_receipt's ``processed`` parameter is typed ``Any`` precisely so
    this package does not need to depend on NegPy's ``ProcessedIceFrame`` (a
    dataclass carrying ``PortableDigitalIceResult``, an ICE-engine type that
    lives outside this package) to exercise its own receipt-assembly logic.
    This still has to be an actual dataclass, since build_ice_receipt itself
    calls the real ``dataclasses.asdict()`` on ``processed.ice.receipt`` —
    only the *outer* shape (processed/ice) is freeform duck-typing.
    """

    same_frame_id: str


class _StubIceResult:
    def __init__(self, *, requested: str, used: str, reason: str, receipt: _StubEngineReceipt) -> None:
        self.requested_backend = SimpleNamespace(value=requested)
        self.used_backend = SimpleNamespace(value=used)
        self.selection_reason = reason
        self.receipt = receipt


class _StubProcessed:
    def __init__(self, *, plan, bundle_manifest_sha256: str, ice: _StubIceResult) -> None:
        self.plan = plan
        self.bundle_manifest_sha256 = bundle_manifest_sha256
        self.ice = ice


def test_build_ice_receipt_assembles_a_duck_typed_processed_frame() -> None:
    plan = DiceDualSourcePlan.for_transport("roll", frame=5)
    processed = _StubProcessed(
        plan=plan,
        bundle_manifest_sha256="e" * 64,
        ice=_StubIceResult(
            requested="cpu-fast",
            used="cpu-fast",
            reason="explicit CPU-FAST request",
            receipt=_StubEngineReceipt(same_frame_id="roll-slot-05"),
        ),
    )

    receipt = build_ice_receipt(processed, roll_slot=5, boundary_offset_rows=-7)

    assert receipt["kind"] == ICE_FRAME_RECEIPT_KIND
    assert receipt["version"] == ICE_FRAME_RECEIPT_VERSION
    assert receipt["roll_slot"] == 5
    assert receipt["boundary_offset_rows"] == -7
    assert receipt["plan"] == plan.semantic_dict()
    assert receipt["bundle_manifest_sha256"] == "e" * 64
    assert receipt["backend"] == {
        "requested": "cpu-fast",
        "used": "cpu-fast",
        "selection_reason": "explicit CPU-FAST request",
    }
    assert receipt["engine_receipt"] == {"same_frame_id": "roll-slot-05"}
