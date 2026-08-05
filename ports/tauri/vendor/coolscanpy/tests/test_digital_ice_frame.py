from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pytest

from coolscanpy.types import Frame, build_digital_ice_acquisition_evidence


@dataclass(frozen=True)
class _Ownership:
    reservation_id: str
    frame_capture_attempt_id: str
    selected_slot: int

    def validate_evidence(self, _evidence: object) -> None:
        return None


@dataclass(frozen=True)
class _Receipt:
    slot: int
    nikon_density_ownership: _Ownership


def test_frame_prepares_scanner_native_dice_acquisition_and_freezes_sources() -> None:
    native_main = np.arange(4 * 3 * 4, dtype=np.uint16).reshape(4, 3, 4)
    upright = np.ascontiguousarray(np.swapaxes(native_main, 0, 1))
    storage_rgb = upright[..., :3]
    storage_ir = upright[..., 3]
    storage_validity = np.ones(storage_ir.shape, dtype=np.bool_)
    storage_validity[0, -1] = False
    meter_rgbi = np.arange(2 * 3 * 4, dtype=np.uint16).reshape(2, 3, 4)
    ownership = _Ownership(
        reservation_id="reservation-001",
        frame_capture_attempt_id="fine-slot-7-attempt-001",
        selected_slot=7,
    )
    evidence = build_digital_ice_acquisition_evidence(
        slot=7,
        reservation_id=ownership.reservation_id,
        capture_attempt_id=ownership.frame_capture_attempt_id,
        storage_rgb=storage_rgb,
        storage_ir=storage_ir,
        storage_ir_validity=storage_validity,
        meter_rgbi=meter_rgbi,
    )

    frame = Frame(
        slot=7,
        rgb=storage_rgb,
        ir=storage_ir,
        ir_validity=storage_validity,
        receipt=_Receipt(slot=7, nikon_density_ownership=ownership),
        meter_rgbi=meter_rgbi,
        nikon_density_evidence=object(),
        digital_ice_evidence=evidence,
    )
    acquisition = frame.prepare_digital_ice()

    np.testing.assert_array_equal(acquisition.main_rgbi, native_main)
    np.testing.assert_array_equal(
        acquisition.ir_validity,
        np.swapaxes(storage_validity, 0, 1),
    )
    np.testing.assert_array_equal(acquisition.meter_rgbi, meter_rgbi)
    assert acquisition.acquisition_id == evidence.acquisition_id
    assert acquisition.slot == 7
    assert acquisition.reservation_id == ownership.reservation_id
    assert acquisition.storage_transform == "swapaxes01-scanner-native-to-nikon-render-parity-v2"
    assert acquisition.evidence_sha256 == evidence.sha256
    for array in (
        frame.rgb,
        frame.ir,
        frame.ir_validity,
        frame.meter_rgbi,
        acquisition.main_rgbi,
        acquisition.ir_validity,
        acquisition.meter_rgbi,
    ):
        assert array is not None
        assert array.flags.c_contiguous
        assert not array.flags.writeable


def test_prepare_digital_ice_rejects_post_capture_ir_meter_mutation() -> None:
    native_main = np.arange(4 * 3 * 4, dtype=np.uint16).reshape(4, 3, 4)
    upright = np.ascontiguousarray(np.swapaxes(native_main, 0, 1))
    validity = np.ones(upright.shape[:2], dtype=np.bool_)
    meter = np.arange(2 * 3 * 4, dtype=np.uint16).reshape(2, 3, 4)
    ownership = _Ownership("reservation-001", "fine-slot-7-attempt-001", 7)
    evidence = build_digital_ice_acquisition_evidence(
        slot=7,
        reservation_id=ownership.reservation_id,
        capture_attempt_id=ownership.frame_capture_attempt_id,
        storage_rgb=upright[..., :3],
        storage_ir=upright[..., 3],
        storage_ir_validity=validity,
        meter_rgbi=meter,
    )
    frame = Frame(
        slot=7,
        rgb=upright[..., :3],
        ir=upright[..., 3],
        ir_validity=validity,
        receipt=_Receipt(slot=7, nikon_density_ownership=ownership),
        meter_rgbi=meter,
        nikon_density_evidence=object(),
        digital_ice_evidence=evidence,
    )
    frame.meter_rgbi.setflags(write=True)
    frame.meter_rgbi[0, 0, 3] ^= np.uint16(1)

    with pytest.raises(ValueError, match="changed after capture"):
        frame.prepare_digital_ice()


def test_frame_rejects_meter_or_reservation_swapped_across_acquisitions() -> None:
    native_main = np.arange(4 * 3 * 4, dtype=np.uint16).reshape(4, 3, 4)
    upright = np.ascontiguousarray(np.swapaxes(native_main, 0, 1))
    validity = np.ones(upright.shape[:2], dtype=np.bool_)
    meter_a = np.arange(2 * 3 * 4, dtype=np.uint16).reshape(2, 3, 4)
    meter_b = np.ascontiguousarray(meter_a + 100)
    owner_a = _Ownership("reservation-a", "fine-slot-7-attempt-a", 7)
    owner_b = _Ownership("reservation-b", "fine-slot-7-attempt-b", 7)
    evidence_a = build_digital_ice_acquisition_evidence(
        slot=7,
        reservation_id=owner_a.reservation_id,
        capture_attempt_id=owner_a.frame_capture_attempt_id,
        storage_rgb=upright[..., :3],
        storage_ir=upright[..., 3],
        storage_ir_validity=validity,
        meter_rgbi=meter_a,
    )

    with pytest.raises(ValueError, match="arrays do not match"):
        Frame(
            slot=7,
            rgb=upright[..., :3],
            ir=upright[..., 3],
            ir_validity=validity,
            receipt=_Receipt(slot=7, nikon_density_ownership=owner_a),
            meter_rgbi=meter_b,
            nikon_density_evidence=object(),
            digital_ice_evidence=evidence_a,
        )
    with pytest.raises(ValueError, match="another reservation or capture"):
        Frame(
            slot=7,
            rgb=upright[..., :3],
            ir=upright[..., 3],
            ir_validity=validity,
            receipt=_Receipt(slot=7, nikon_density_ownership=owner_b),
            meter_rgbi=meter_a,
            nikon_density_evidence=object(),
            digital_ice_evidence=evidence_a,
        )
