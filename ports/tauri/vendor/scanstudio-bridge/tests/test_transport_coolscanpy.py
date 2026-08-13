"""Tests for scanstudio_bridge.transport.coolscanpy_transport:
CoolscanPyTransport, the thin real adapter over CoolscanPy's `Device`/`Roll`
API. See BRIDGE.md (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md) for the wire-level contract and the
CoolscanPy-exception-to-error-code rename table this module implements.

Per this task's own instructions, these tests mock the `coolscanpy` module
boundary directly (`coolscanpy.open`/`coolscanpy.get_devices`, plus
lightweight fake `Device`/`Roll` doubles implementing only the methods
`CoolscanPyTransport` calls) -- never coolscanpy's own internal
adapter/workflow injection seams. No hardware is touched by any test here.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import struct
import tempfile
import threading
import time
import uuid
from pathlib import Path

import coolscanpy
import numpy as np
import pytest
import tifffile

from coolscanpy.protocol.ls5000_single_pass import roll_index as _roll_index_module
from coolscanpy.protocol.ls5000_single_pass.density import (
    DensityCalibration,
    build_nikon_density_evidence,
)
from coolscanpy.protocol.ls5000_single_pass.plan import CANONICAL_PLAN_SHA256
from coolscanpy.roll.preview_session import _preview_binding_contract

from scanstudio_bridge import domain, safety, service
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport import FrameRetryExhausted
from scanstudio_bridge.transport import coolscanpy_transport as coolscanpy_transport_module
from scanstudio_bridge.transport.coolscanpy_transport import (
    CoolscanPyTransport,
    _capabilities_from_coolscanpy,
    _trim_out_of_table_slots,
    coolscanpy_provenance,
)

_DEVICE_ID = "coolscan3:usb:001:002"


# -- coolscanpy-shaped test doubles ------------------------------------------------


class _FakeRoll:
    """Duck-types only the `coolscanpy.Roll` methods `CoolscanPyTransport`
    calls. `scan_results[slot]` is a list of scripted outcomes consumed one
    per `scan_many` yield for that slot: either a `coolscanpy.Frame` to
    return, or an exception instance to raise."""

    def __init__(
        self,
        *,
        thumbnails: list["coolscanpy.Thumbnail"] | None = None,
        fingerprint_sha256: str = "f" * 64,
        scan_results: dict[int, list[object]] | None = None,
        material: "coolscanpy.Material" = coolscanpy.Material.COLOR_NEGATIVE,
        install_manual_session_effect: BaseException | None = None,
    ) -> None:
        self._thumbnails = thumbnails or []
        self._fingerprint_sha256 = fingerprint_sha256
        self._scan_results = {slot: list(outcomes) for slot, outcomes in (scan_results or {}).items()}
        self.scan_many_calls: list[tuple[int, ...]] = []
        self.approve_calls: list[int] = []
        self.spacing_offset_calls: list[tuple[int, int]] = []
        self.safe_stop_calls = 0
        self.closed = False
        self._safe_stop_requested = False
        # Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md) / S1 fix
        # (2026-08-08 adversarial review): _session/_session_usb_topology/
        # _approvals/_state_condition mirror real coolscanpy.Roll's own
        # private attribute names, types, and locking shape purely so
        # install_manual_session() below can behave like the real one
        # (coolscanpy's own _roll.py) without duplicating it -- nothing in
        # coolscanpy_transport.py reaches into these directly any more (see
        # manual_frames()'s own comment); this fake's PUBLIC
        # install_manual_session is the only thing that touches them now.
        self.material = material
        self._state_condition = threading.Condition(threading.RLock())
        self._session: object | None = None
        self._session_usb_topology: tuple[int, int] | None = None
        self._approvals: dict[int, object] = {}
        self.install_manual_session_calls: list[object] = []
        # Test-driven failure injection, mirroring _FakeDevice.eject_effect
        # below -- lets a test prove manual_frames() maps
        # coolscanpy.DeviceBusy/RollMismatch from install_manual_session to
        # the right BridgeError, and that a raise here leaves _session/
        # _approvals exactly as they were (install_manual_session's own
        # transactional contract).
        self._install_manual_session_effect = install_manual_session_effect

    def install_manual_session(self, session: object) -> None:
        self.install_manual_session_calls.append(session)
        if self._install_manual_session_effect is not None:
            raise self._install_manual_session_effect
        with self._state_condition:
            self._session = session
            self._session_usb_topology = session.preview.usb_topology
            self._approvals.clear()

    def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
        if slots is None:
            return list(self._thumbnails)
        wanted = set(slots)
        return [t for t in self._thumbnails if t.slot in wanted]

    @property
    def fingerprint(self) -> "coolscanpy.RollFingerprint":
        return coolscanpy.RollFingerprint(
            sha256=self._fingerprint_sha256,
            slot_count=len(self._thumbnails),
            preview_shape=(1, 1, 1),
        )

    @property
    def slot_count(self) -> int:
        return len(self._thumbnails)

    def approve(self, slot: int) -> None:
        self.approve_calls.append(slot)

    def set_spacing_offset(
        self, slot: int, offset_rows: int
    ) -> "coolscanpy.Thumbnail":
        self.spacing_offset_calls.append((slot, offset_rows))
        index = next(
            index
            for index, thumbnail in enumerate(self._thumbnails)
            if thumbnail.slot == slot
        )
        thumbnail = self._thumbnails[index]
        adjusted = dataclasses.replace(
            thumbnail,
            # Native +rows moves the crop window forward, so already-captured
            # content moves toward -X after the bridge swaps native axes.
            image=np.roll(thumbnail.image, -offset_rows, axis=0),
            spacing_offset=offset_rows,
        )
        self._thumbnails[index] = adjusted
        return adjusted

    def scan_many(
        self,
        slots,
        *,
        on_progress=None,
    ):
        ordered = tuple(slots)
        if not ordered:
            raise ValueError("scan_many requires at least one slot")
        if tuple(sorted(set(ordered))) != ordered:
            raise ValueError("batch scanner slots must be unique and strictly increasing")
        self.scan_many_calls.append(ordered)
        for index, slot in enumerate(ordered):
            if self._safe_stop_requested:
                raise coolscanpy.SafeStopRequested(
                    f"safe stop requested; {index} of {len(ordered)} requested frames completed"
                )
            outcomes = self._scan_results.get(slot, [])
            if not outcomes:
                raise AssertionError(
                    f"_FakeRoll.scan_many consumed slot {slot} with no scripted outcome left"
                )
            outcome = outcomes.pop(0)
            if isinstance(outcome, BaseException):
                raise outcome
            if on_progress is not None:
                on_progress(
                    coolscanpy.Progress(
                        stage="fine-scan",
                        slot=slot,
                        index=index,
                        total=len(ordered),
                        fraction=1.0,
                        message=f"slot {slot} complete",
                    )
                )
            yield outcome

    def safe_stop(self) -> None:
        self.safe_stop_calls += 1
        self._safe_stop_requested = True

    def close(self) -> None:
        self.closed = True


class _FakeDevice:
    def __init__(self, roll: _FakeRoll | None = None) -> None:
        self._roll = roll
        self.eject_effect: object = True
        # The vendor-eject confirmation probe (Device.film_present): None
        # (undetermined) mirrors the pre-probe default; vendor-route eject
        # success tests set False (confirmed-out) explicitly, and the
        # accepted-without-progress / unconfirmable shapes set True/None.
        self.film_present_result: object = None
        self.closed = False
        self.capabilities = _fake_capabilities()
        # Plan 10-09 (attempts-root persistence): records exactly what
        # CoolscanPyTransport.preview() passed, so a test can assert on it
        # -- mirrors the real Device.roll()'s own attempts_root kwarg.
        self.roll_calls: list[Path | None] = []

    def roll(
        self, *, material: "coolscanpy.Material", attempts_root: Path | None = None
    ) -> _FakeRoll:
        self.roll_calls.append(attempts_root)
        return self._roll

    def eject(self) -> bool:
        if isinstance(self.eject_effect, BaseException):
            raise self.eject_effect
        return self.eject_effect

    def film_present(self) -> bool | None:
        if isinstance(self.film_present_result, BaseException):
            raise self.film_present_result
        return self.film_present_result

    def close(self) -> None:
        self.closed = True


# -- fixture builders using coolscanpy's own real (plain-data) dataclasses --------


def _fake_capabilities() -> "coolscanpy.Capabilities":
    return coolscanpy.Capabilities(
        ir_channel=True,
        supported_dpi=(4000,),
        supported_depths=(16,),
        multi_sample=True,
        adapter_frame_capacity=40,
        adapter_frame_control=True,
        auto_exposure=True,
        registered_geometry=True,
        can_eject=True,
    )


def _fake_device_info(
    device_id: str = _DEVICE_ID, *, supported: bool = True
) -> "coolscanpy.DeviceInfo":
    return coolscanpy.DeviceInfo(
        id=device_id,
        vendor="Nikon",
        model="SUPER COOLSCAN 5000 ED",
        capabilities=_fake_capabilities(),
        supported=supported,
    )


def _fake_thumbnail(slot: int) -> "coolscanpy.Thumbnail":
    return coolscanpy.Thumbnail(
        slot=slot,
        image=np.zeros((4, 4, 3), dtype=np.uint8),
        boundary_rows=(slot * 100, slot * 100 + 100),
        spacing_offset=0,
        needs_approval=False,
        warnings=(),
    )


def _fake_receipt(slot: int) -> "coolscanpy.Receipt":
    return coolscanpy.Receipt(
        version=1,
        slot=slot,
        spacing_offset=0,
        dpi=4000,
        depth=16,
        device_id="ls5000-usb-0",
        device_model="SUPER COOLSCAN 5000 ED",
        reviewed_fingerprint_sha256="a" * 64,
        fresh_fingerprint_sha256="a" * 64,
        manual_approval=None,
        exposure=coolscanpy.ExposureVector(
            focus_position=800,
            exposure_multiplier=1.0,
            red_exposure_us=1200.0,
            green_exposure_us=950.0,
            blue_exposure_us=1400.0,
        ),
        split_alignment=None,
        clipping=coolscanpy.ClippingTelemetry(
            fractions=(0.0, 0.0, 0.0), clip_level=0.995, warning_fraction=0.02, warning=False
        ),
        focus_detail=coolscanpy.FocusDetailTelemetry(
            method="laplacian-variance", verdict="measured", score=180.0, texture_span=0.7
        ),
        transport_smear=coolscanpy.TransportSmearAssessment(
            verdict="clean",
            start_row=None,
            suffix_rows=0,
            minimum_matches=0,
            tail_median_rms=None,
            tail_min_corr=None,
            pre_tail_median_rms=None,
            texture_span=None,
            reason="no repeated tail rows detected",
        ),
        artifacts={},
        storage_transform="swapaxes01-scanner-native-to-nikon-render-parity-v2",
    )


def _fake_frame(slot: int, *, meter_rgbi: "np.ndarray | None" = None) -> "coolscanpy.Frame":
    return coolscanpy.Frame(
        slot=slot,
        rgb=np.zeros((8, 8, 3), dtype=np.uint16),
        ir=np.zeros((8, 8), dtype=np.uint16),
        ir_validity=np.ones((8, 8), dtype=bool),
        receipt=_fake_receipt(slot),
        meter_rgbi=meter_rgbi,
    )


def _fake_smear() -> "coolscanpy.TransportSmearDetected":
    return coolscanpy.TransportSmearDetected(
        "stopped-transport smear QC refused",
        assessment=coolscanpy.TransportSmearAssessment(
            verdict="smear",
            start_row=10,
            suffix_rows=5,
            minimum_matches=3,
            tail_median_rms=1.0,
            tail_min_corr=0.9,
            pre_tail_median_rms=1.0,
            texture_span=0.5,
            reason="repeated tail rows detected",
        ),
    )


def _opened_transport(
    monkeypatch: pytest.MonkeyPatch, roll: _FakeRoll, device_id: str = _DEVICE_ID
) -> tuple[CoolscanPyTransport, _FakeDevice]:
    info = _fake_device_info(device_id)
    fake_device = _FakeDevice(roll=roll)
    monkeypatch.setattr(coolscanpy, "get_devices", lambda: [info])
    monkeypatch.setattr(coolscanpy, "open", lambda devname: fake_device)
    # CoolscanPyTransport.preview() writes under safety.DEFAULT_BASE_DIR --
    # it has no base_dir plumbing of its own by design (see status()'s own
    # docstring: only service.py owns that wiring). Redirect the module
    # constant here so no test in this file ever touches the real
    # ~/.scanstudio, matching this codebase's established test-isolation
    # convention (see safety.py's own module docstring).
    monkeypatch.setattr(
        safety, "DEFAULT_BASE_DIR", Path(tempfile.mkdtemp(prefix="scanstudio-test-preview-"))
    )
    transport = CoolscanPyTransport()
    transport.open_device(device_id)
    return transport, fake_device


def _output(destination: Path, filename_template: str = "frame-####.tif") -> domain.OutputSpec:
    return domain.OutputSpec(destination=str(destination), filename_template=filename_template)


# -- Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): synthetic on-disk preview ---
# attempt. manual_frames()/preview_strip() read straight from disk
# (attempts_root), bypassing the _FakeRoll double this file otherwise uses
# everywhere else -- see coolscanpy_transport.py's own
# _reconstruct_last_preview_attempt/_validated_preview_from_attempt. The
# helpers below build one REAL, byte-valid preview attempt directory
# (journal.json + capture-preview.bin + capture-008e.bin +
# capture-frame-map.json). Ported byte-for-byte from coolscanpy's own test
# fixture (coolscanpy/tests/roll/test_ls5000_roll_session.py's
# _preview_fixture/_synthetic_index/_encode_index/_transport_table -- the
# owner's already-proven encoding, not re-derived here), landed under a real
# attempts_root with the CaptureMode.PREVIEW "preview-" mkdtemp prefix
# CoolscanPyTransport's own glob expects instead of a bare test directory
# name. The transport-table encoding (code=6*(row%18), selector=row//18) is
# the same 42-native-units-per-row convention coolscanpy's own
# test_manual_frames.py/test_ls5000_roll_session.py fixtures use, comfortably
# inside build_manual_detection's 40..45 ramp-guard gate.

_SYNTHETIC_DENSITY_CALIBRATION_PAYLOADS = tuple(
    bytes.fromhex(value)
    for value in (
        "8c20000000040000df1a",
        "8c20000000040000bba4",
        "8c200000000400007fab",
    )
)
_SYNTHETIC_DENSITY_CALIBRATION_NUMERATORS = (57_114, 48_036, 32_683)


def _synthetic_density_calibration(session_id: str) -> DensityCalibration:
    return DensityCalibration(
        session_id=session_id,
        numerators=_SYNTHETIC_DENSITY_CALIBRATION_NUMERATORS,
        payload_hex=tuple(
            payload.hex() for payload in _SYNTHETIC_DENSITY_CALIBRATION_PAYLOADS
        ),
        payload_sha256=tuple(
            hashlib.sha256(payload).hexdigest()
            for payload in _SYNTHETIC_DENSITY_CALIBRATION_PAYLOADS
        ),
    )


def _encode_synthetic_index(rgb16: np.ndarray) -> bytes:
    """Encode the compact RGB96 index rows the scanner itself would have
    written -- byte-for-byte port of test_ls5000_roll_session.py's own
    _encode_index."""
    blocks = np.zeros(
        (rgb16.shape[0] // 2, _roll_index_module.INDEX_BLOCK_WORDS),
        dtype=np.uint16,
    )
    blocks[:, 0:96] = rgb16[0::2, :, 0]
    blocks[:, 96:192] = rgb16[0::2, :, 1]
    blocks[:, 192:288] = rgb16[0::2, :, 2]
    blocks[:, 512:608] = rgb16[1::2, :, 0]
    blocks[:, 608:704] = rgb16[1::2, :, 1]
    blocks[:, 704:800] = rgb16[1::2, :, 2]
    blocks[:, 800::2] = _roll_index_module.INDEX_TRAILER_MARK
    blocks[:, 801::2] = np.arange(
        _roll_index_module.INDEX_TRAILER_COUNTER0,
        _roll_index_module.INDEX_TRAILER_COUNTER0
        + _roll_index_module.INDEX_TRAILER_WORDS // 2,
        dtype=np.uint16,
    )
    return blocks.astype(">u2", copy=False).tobytes()


def _synthetic_preview_index(
    *, height: int, frame_count: int = 40, content_frames: int = 40, leader: int = 128
) -> np.ndarray:
    """Textured cells separated by physical clear-film gaps, at the pitch=143
    convention coolscanpy's own manual-session fixtures use -- byte-for-byte
    port of test_ls5000_roll_session.py's own _synthetic_index."""
    pitch = 143
    boundaries = [leader + index * pitch for index in range(frame_count + 1)]
    y = np.arange(height, dtype=np.int64)[:, None]
    x = np.arange(90, dtype=np.int64)[None, :]
    texture = (x * 173 + y * 71 + (x * y) % 997) % 7_000
    aperture = np.empty((height, 90, 3), dtype=np.int64)
    for channel, base in enumerate((7_000, 5_500, 4_000)):
        aperture[:, :, channel] = base + texture * (3 - channel) // 2
    clear_base = np.asarray((34_200, 25_500, 17_800), dtype=np.int64)
    clear_noise = ((x * 19 + y * 13) % 301 - 150)[:, :, None]
    aperture[: boundaries[0]] = clear_base + clear_noise[: boundaries[0]]
    aperture[boundaries[-1] :] = clear_base + clear_noise[boundaries[-1] :]
    for boundary in boundaries:
        start = max(0, boundary - 3)
        end = min(height, boundary + 3)
        aperture[start:end] = clear_base + clear_noise[start:end]
    if content_frames < frame_count:
        clear_start = boundaries[content_frames]
        aperture[clear_start:] = clear_base + clear_noise[clear_start:]
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16)


def _synthetic_transport_table(rows: int) -> bytes:
    """42-native-units-per-row same-traversal table -- byte-for-byte port of
    test_ls5000_roll_session.py's own _transport_table."""
    records = bytearray()
    for row in range(rows):
        records.extend(struct.pack(">HH", 6 * (row % 18), row // 18))
    total = 8 + len(records)
    return b"\x00\x8e\x00\x00" + total.to_bytes(2, "big") + b"\x00\x00" + bytes(records)


def _write_synthetic_preview_attempt(
    attempts_root: Path, *, slot_capacity_hint: int = 40
) -> Path:
    """Write one complete, byte-valid preview attempt directory under
    ``attempts_root`` with CoolscanPyTransport's own "preview-" mkdtemp
    prefix -- everything manual_frames()/preview_strip()'s
    _reconstruct_last_preview_attempt/_validated_preview_from_attempt need to
    find and validate it, exactly as if a real roll.preview attempt had just
    completed (this journal shape is "preview-only"/"complete"/released --
    see preview_session.py's _validate_preview_result: both that shape and
    the "preview-and-hold" shape a real Roll.preview() always uses today
    validate identically). Returns the attempt directory."""
    contract = _preview_binding_contract(slot_capacity_hint)
    native_height = contract["native_height"]
    decoded_height = contract["decoded_height"]
    startup_status = contract["startup_status"]
    preview_binding = {
        key: value for key, value in contract.items() if key != "startup_status"
    }

    attempt = attempts_root / f"preview-{uuid.uuid4().hex}"
    attempt.mkdir(parents=True)
    output = attempt / "capture.bin"
    output.write_bytes(b"")
    preview_path = attempt / "capture-preview.bin"
    table_path = attempt / "capture-008e.bin"
    mapping_path = attempt / "capture-frame-map.json"

    rgb = _synthetic_preview_index(height=decoded_height)
    usable_rows = len(rgb)
    preview = _encode_synthetic_index(rgb)
    table = _synthetic_transport_table(usable_rows)
    preview_path.write_bytes(preview)
    table_path.write_bytes(table)

    density_session_id = "single-reservation-roll-preview"
    density_exposures = (71_373, 137_524, 126_126)
    preview_sha256 = hashlib.sha256(preview).hexdigest()
    density_evidence = build_nikon_density_evidence(
        preview,
        calibration=_synthetic_density_calibration(density_session_id),
        density_f03_exposures_raw_10ns=density_exposures,
        session_id=density_session_id,
        capture_attempt_id=attempt.name,
        scan_identity=f"{density_session_id}:density-97dpi:{preview_sha256}",
        source_native_height=native_height,
        source_height=decoded_height,
    )
    receipt = {
        "status": "preview-only-complete",
        "slot_capacity_hint": slot_capacity_hint,
        "slot_capacity_semantics": (
            "scanner-addressable preview slots; not an exposure count"
        ),
        "preview_bytes": len(preview),
        "preview_sha256": preview_sha256,
        "table_bytes": len(table),
        "table_sha256": hashlib.sha256(table).hexdigest(),
        "frame_detection": "deferred-offline",
        "startup_table": {
            "count": slot_capacity_hint,
            "sha256": "a" * 64,
            "status": startup_status,
        },
        "preview_binding": preview_binding,
    }
    mapping_path.write_text(json.dumps(receipt), encoding="utf-8")
    journal = {
        "status": "complete",
        "capture_mode": "preview-only",
        "requested_frame": None,
        "requested_boundary_offset_rows": 0,
        "expected_frame_count": None,
        "expected_reads": 0,
        "completed_reads": 0,
        "expected_bytes": 0,
        "completed_bytes": 0,
        "disk_bytes": 0,
        "unit_released": True,
        "output": str(output.resolve()),
        "output_sha256": hashlib.sha256(b"").hexdigest(),
        "plan_sha256": CANONICAL_PLAN_SHA256,
        "capture_engine_sha256": "b" * 64,
        "scanner_identity": "Nikon LS-5000 ED 1.03",
        "expected_usb_bus": 1,
        "expected_usb_address": 2,
        "actual_usb_bus": 1,
        "actual_usb_address": 2,
        "preview_geometry_validated_before_reads": True,
        "preview_windows": [
            {
                "color_id": color,
                "resolution": [97, 97],
                "origin": [0, 0],
                "size": [3_946, native_height],
                "bit_depth": 16,
                "density_f03_exposure_raw_10ns": exposure,
            }
            for color, exposure in zip((1, 2, 3), density_exposures, strict=True)
        ],
        "density_calibration_session_id": density_session_id,
        "nikon_density_evidence": density_evidence.to_dict(),
        "live_startup_0x8f": {"count": slot_capacity_hint, "sha256": "a" * 64},
        "live_startup_0x8f_status": startup_status,
        "live_preview_binding": preview_binding,
        "live_index_artifacts": {
            "mapping": str(mapping_path.resolve()),
            "preview": str(preview_path.resolve()),
            "table": str(table_path.resolve()),
        },
        "live_index_evidence": {
            "status": "persisted-before-frame-detection",
            "preview_bytes": len(preview),
            "preview_sha256": preview_sha256,
            "table_bytes": len(table),
            "table_sha256": hashlib.sha256(table).hexdigest(),
        },
        "preview_only_receipt": receipt,
    }
    (attempt / "journal.json").write_text(json.dumps(journal), encoding="utf-8")
    return attempt


# -- list_devices / open_device ----------------------------------------------------


def test_list_devices_maps_coolscanpy_device_info(monkeypatch: pytest.MonkeyPatch) -> None:
    info = _fake_device_info()
    monkeypatch.setattr(coolscanpy, "get_devices", lambda: [info])

    devices = CoolscanPyTransport().list_devices()

    assert len(devices) == 1
    assert devices[0].device_id == _DEVICE_ID
    assert devices[0].vendor == "Nikon"
    assert devices[0].capabilities.ir_channel is True
    assert devices[0].capabilities.supported_dpi == (4000,)


def test_list_devices_passes_through_supported_from_coolscanpy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Lane D (#14): a recognized-but-unsupported model must reach the wire
    # with supported=False so the app never offers a connect affordance.
    info = _fake_device_info(supported=False)
    monkeypatch.setattr(coolscanpy, "get_devices", lambda: [info])

    devices = CoolscanPyTransport().list_devices()

    assert len(devices) == 1
    assert devices[0].supported is False


def test_capabilities_from_coolscanpy_reports_fixed_supported_multisample_passes() -> None:
    assert _capabilities_from_coolscanpy(_fake_capabilities()).supported_multisample_passes == (4,)


def test_status_reports_film_present_none_when_device_has_no_film_present_attribute(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Preserve compatibility with older CoolScanPy builds: a missing method
    # remains an honest unknown rather than an absence claim.
    transport, _device = _opened_transport(monkeypatch, _FakeRoll())
    assert transport.status().film_present is None


@pytest.mark.parametrize("verdict", (True, False, None))
def test_status_forwards_coolscanpy_film_present_tristate(
    monkeypatch: pytest.MonkeyPatch,
    verdict: bool | None,
) -> None:
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.film_present = lambda: verdict  # type: ignore[attr-defined]

    assert transport.status().film_present is verdict


def test_status_degrades_a_film_present_probe_failure_to_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, device = _opened_transport(monkeypatch, _FakeRoll())

    def fail() -> bool:
        raise RuntimeError("USB claim conflict")

    device.film_present = fail  # type: ignore[attr-defined]

    assert transport.status().film_present is None


def test_status_invalidates_preview_when_fresh_probe_reports_no_film(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A completed preview is registration evidence, not live media truth.

    The scanner's verified MEDIUM NOT PRESENT verdict must retire that stale
    registration so a subsequent capture cannot reuse its coordinates.
    """
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, device = _opened_transport(monkeypatch, roll)
    device.film_present = lambda: True  # type: ignore[attr-defined]
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.status().preview_established is True

    device.film_present = lambda: False  # type: ignore[attr-defined]
    status = transport.status()

    assert status.film_present is False
    assert status.preview_established is False
    assert status.slot_count is None


def test_open_device_raises_device_not_found(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(coolscanpy, "get_devices", lambda: [])

    def _raise_not_found(devname: str) -> None:
        raise coolscanpy.DeviceNotFound(f"no device {devname!r}")

    monkeypatch.setattr(coolscanpy, "open", _raise_not_found)

    with pytest.raises(BridgeError) as excinfo:
        CoolscanPyTransport().open_device("nonexistent")
    assert excinfo.value.code == ErrorCode.DEVICE_NOT_FOUND


def test_open_device_raises_device_busy(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raise_busy(devname: str) -> None:
        raise coolscanpy.DeviceBusy(f"device {devname!r} already open")

    monkeypatch.setattr(coolscanpy, "open", _raise_busy)

    with pytest.raises(BridgeError) as excinfo:
        CoolscanPyTransport().open_device(_DEVICE_ID)
    assert excinfo.value.code == ErrorCode.DEVICE_BUSY


def test_open_device_rejects_second_open_with_already_connected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, _device = _opened_transport(monkeypatch, _FakeRoll())
    with pytest.raises(BridgeError) as excinfo:
        transport.open_device(_DEVICE_ID)
    assert excinfo.value.code == ErrorCode.ALREADY_CONNECTED


# -- preview -----------------------------------------------------------------------


def test_preview_calls_on_thumbnail_exactly_twice_in_order(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    thumbnails = [_fake_thumbnail(1), _fake_thumbnail(2)]
    roll = _FakeRoll(thumbnails=thumbnails)
    transport, _device = _opened_transport(monkeypatch, roll)

    received: list[domain.Thumbnail] = []
    result = transport.preview(domain.Material.COLOR_NEGATIVE, None, received.append)

    assert [t.slot for t in received] == [1, 2]
    assert result.count == 2
    for thumbnail in received:
        assert thumbnail.image_path
        tile_path = Path(thumbnail.image_path)
        assert tile_path.exists()
        decoded = tifffile.imread(tile_path)
        assert decoded.shape == (4, 4, 3)
        assert decoded.dtype == np.uint8


def test_preview_transposes_scanner_native_tile_without_flipping(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ramp = np.arange(6, dtype=np.uint16).reshape(2, 3)
    scanner_native = np.repeat(ramp[..., np.newaxis], 3, axis=2)
    thumbnail = dataclasses.replace(_fake_thumbnail(1), image=scanner_native)
    transport, _device = _opened_transport(
        monkeypatch, _FakeRoll(thumbnails=[thumbnail])
    )
    received: list[domain.Thumbnail] = []

    transport.preview(domain.Material.COLOR_NEGATIVE, None, received.append)

    decoded = tifffile.imread(received[0].image_path)
    assert decoded.shape == (3, 2, 3)
    assert np.array_equal(
        np.argsort(decoded[..., 0], axis=None),
        np.array([0, 2, 4, 1, 3, 5]),
    )


def test_set_spacing_offset_returns_all_fresh_thumbnail_metadata_at_unique_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    thumbnail = dataclasses.replace(
        _fake_thumbnail(2),
        needs_approval=True,
        warnings=("ambiguous-content-tail-boundary",),
    )
    roll = _FakeRoll(thumbnails=[thumbnail])
    transport, _device = _opened_transport(monkeypatch, roll)
    initial: list[domain.Thumbnail] = []
    transport.preview(domain.Material.COLOR_NEGATIVE, None, initial.append)

    adjusted = transport.set_spacing_offset(2, -7)
    adjusted_again = transport.set_spacing_offset(2, 3)

    assert roll.spacing_offset_calls == [(2, -7), (2, 3)]
    assert adjusted.slot == 2
    assert adjusted.boundary_rows == (200, 300)
    assert adjusted.spacing_offset == -7
    assert adjusted.needs_approval is True
    assert adjusted.warnings == ("ambiguous-content-tail-boundary",)
    paths = {
        initial[0].image_path,
        adjusted.image_path,
        adjusted_again.image_path,
    }
    assert len(paths) == 3
    assert all(Path(path).is_file() for path in paths)


def test_set_spacing_offset_without_real_device_is_not_connected() -> None:
    transport = CoolscanPyTransport()

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 0)

    assert excinfo.value.code is ErrorCode.NOT_CONNECTED


def test_set_spacing_offset_without_real_preview_is_no_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, _device = _opened_transport(
        monkeypatch,
        _FakeRoll(thumbnails=[_fake_thumbnail(1)]),
    )

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 0)

    assert excinfo.value.code is ErrorCode.NO_PREVIEW


def test_adjusted_real_tile_keeps_landscape_orientation_and_moves_content_left(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    scanner_native_plane = np.array(
        [
            [0, 1],
            [10, 11],
            [20, 21],
            [30, 31],
        ],
        dtype=np.uint16,
    )
    scanner_native = np.repeat(
        scanner_native_plane[..., np.newaxis],
        3,
        axis=2,
    )
    roll = _FakeRoll(
        thumbnails=[
            dataclasses.replace(_fake_thumbnail(2), image=scanner_native)
        ]
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    initial_thumbnails: list[domain.Thumbnail] = []
    transport.preview(
        domain.Material.COLOR_NEGATIVE,
        None,
        initial_thumbnails.append,
    )

    adjusted = transport.set_spacing_offset(2, 1)
    initial_pixels = tifffile.imread(initial_thumbnails[0].image_path)
    adjusted_pixels = tifffile.imread(adjusted.image_path)

    assert initial_pixels.shape == adjusted_pixels.shape == (2, 4, 3)
    assert np.array_equal(adjusted_pixels[:, :-1], initial_pixels[:, 1:])
    assert np.all(adjusted_pixels[0, :, 0] < adjusted_pixels[1, :, 0])


def test_set_spacing_offset_rejects_while_real_scan_is_active(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    scan_entered = threading.Event()
    release_scan = threading.Event()
    scan_errors: list[BaseException] = []

    def run_scan() -> None:
        try:
            transport.start_scan(
                slots=[1],
                recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
                output=_output(tmp_path / "output"),
                on_progress=lambda _p: (
                    scan_entered.set(),
                    release_scan.wait(timeout=2),
                ),
                on_retry=lambda *_a: None,
                on_frame=lambda *_a: None,
            )
        except BaseException as exc:
            scan_errors.append(exc)

    worker = threading.Thread(target=run_scan)
    worker.start()
    assert scan_entered.wait(timeout=2)
    try:
        with pytest.raises(BridgeError) as excinfo:
            transport.set_spacing_offset(1, 1)
        assert excinfo.value.code is ErrorCode.HARDWARE_LANE_BUSY
        assert roll.spacing_offset_calls == []
    finally:
        release_scan.set()
        worker.join(timeout=2)

    assert not worker.is_alive()
    assert scan_errors == []


def test_set_spacing_offset_maps_value_error_to_invalid_params(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class _InvalidOffsetRoll(_FakeRoll):
        def set_spacing_offset(
            self, slot: int, offset_rows: int
        ) -> "coolscanpy.Thumbnail":
            raise ValueError("offsetRows for slot 1 must be between 0 and 144")

    transport, _device = _opened_transport(
        monkeypatch,
        _InvalidOffsetRoll(thumbnails=[_fake_thumbnail(1)]),
    )
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, -1)

    assert excinfo.value.code is ErrorCode.INVALID_PARAMS
    assert "between 0 and 144" in str(excinfo.value)


def test_set_spacing_offset_maps_device_busy_to_hardware_lane_busy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class _BusyOffsetRoll(_FakeRoll):
        def set_spacing_offset(
            self, slot: int, offset_rows: int
        ) -> "coolscanpy.Thumbnail":
            raise coolscanpy.DeviceBusy("scanner is finishing another operation")

    transport, _device = _opened_transport(
        monkeypatch,
        _BusyOffsetRoll(thumbnails=[_fake_thumbnail(1)]),
    )
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 1)

    assert excinfo.value.code is ErrorCode.HARDWARE_LANE_BUSY
    assert "finishing another operation" in str(excinfo.value)


def test_set_spacing_offset_maps_lost_preview_session_to_no_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from coolscanpy.roll.preview_session import RollSessionError

    class _LostSessionRoll(_FakeRoll):
        def set_spacing_offset(
            self, slot: int, offset_rows: int
        ) -> "coolscanpy.Thumbnail":
            raise RollSessionError("preview session no longer has slot geometry")

    transport, _device = _opened_transport(
        monkeypatch,
        _LostSessionRoll(thumbnails=[_fake_thumbnail(1)]),
    )
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 1)

    assert excinfo.value.code is ErrorCode.NO_PREVIEW
    assert "fresh preview" in str(excinfo.value)
    assert "no longer has slot geometry" in str(excinfo.value)
    assert transport.status().preview_established is False


def test_set_spacing_offset_preserves_session_integrity_error_for_internal_boundary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from coolscanpy.roll.preview_session import RollSessionIntegrityError

    class _CorruptSessionRoll(_FakeRoll):
        def set_spacing_offset(
            self, slot: int, offset_rows: int
        ) -> "coolscanpy.Thumbnail":
            raise RollSessionIntegrityError(
                "persisted preview journal differs from validated geometry"
            )

    transport, _device = _opened_transport(
        monkeypatch,
        _CorruptSessionRoll(thumbnails=[_fake_thumbnail(1)]),
    )
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(RollSessionIntegrityError):
        transport.set_spacing_offset(1, 1)

    assert transport.status().preview_established is False


def test_set_spacing_offset_tile_write_failure_invalidates_preview_and_blocks_scan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    def fail_adjusted_tile_write(*_args: object, **_kwargs: object) -> None:
        raise OSError("preview volume became read-only")

    monkeypatch.setattr(
        coolscanpy_transport_module.tifffile,
        "imwrite",
        fail_adjusted_tile_write,
    )

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 1)

    assert excinfo.value.code is ErrorCode.INTERNAL
    assert "alignment was applied" in str(excinfo.value)
    assert "preview volume became read-only" in str(excinfo.value)
    assert transport.status().preview_established is False
    assert roll.spacing_offset_calls == [(1, 1)]

    with pytest.raises(BridgeError) as scan_excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path / "output"),
            on_progress=lambda _p: None,
            on_retry=lambda *_a: None,
            on_frame=lambda *_a: None,
        )
    assert scan_excinfo.value.code is ErrorCode.NO_PREVIEW


def test_set_spacing_offset_tile_directory_failure_invalidates_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    def fail_preview_directory(*_args: object, **_kwargs: object) -> None:
        raise OSError("preview directory cannot be created")

    monkeypatch.setattr(Path, "mkdir", fail_preview_directory)

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 1)

    assert excinfo.value.code is ErrorCode.INTERNAL
    assert "preview directory cannot be created" in str(excinfo.value)
    assert transport.status().preview_established is False
    assert roll.spacing_offset_calls == [(1, 1)]


def test_preview_raises_feeder_parked(monkeypatch: pytest.MonkeyPatch) -> None:
    class _FeederParkedRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.FeederParked("power cycle required")

    transport, _device = _opened_transport(monkeypatch, _FeederParkedRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.FEEDER_PARKED


def test_preview_worker_bootstrap_failure_is_not_mislabeled_as_feeder_parked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A typed pre-dispatch worker failure is not a feeder condition."""

    class _BrokenWorkerRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.CaptureWorkerBootstrapFailed(
                "CAPTURE_WORKER_BOOTSTRAP_FAILED: bundled capture worker "
                "failed before scanner dispatch (ModuleNotFoundError): "
                "No module named 'coolscanpy'"
            )

    transport, _device = _opened_transport(monkeypatch, _BrokenWorkerRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    assert excinfo.value.code == ErrorCode.INTERNAL
    assert "CAPTURE_WORKER_BOOTSTRAP_FAILED" in str(excinfo.value)
    assert "before scanner dispatch" in str(excinfo.value)
    assert "ModuleNotFoundError" in str(excinfo.value)
    assert "No module named 'coolscanpy'" in str(excinfo.value)


def test_preview_maps_refeed_required(monkeypatch: pytest.MonkeyPatch) -> None:
    """`coolscanpy.RefeedRequired` is already part of `Roll.preview()`'s
    mapped public taxonomy on the `start_scan` side (this module's
    start_scan, lines ~647-648) -- `preview()` must translate it identically
    rather than let it fall through to a bare INTERNAL."""

    class _RefeedRequiredRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.RefeedRequired("strip must be re-fed")

    transport, _device = _opened_transport(monkeypatch, _RefeedRequiredRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED
    assert "re-fed" in str(excinfo.value)


def test_preview_maps_device_busy(monkeypatch: pytest.MonkeyPatch) -> None:
    """`coolscanpy.DeviceBusy` is already mapped on `open_device` (this
    module's open_device) -- `preview()` must map it the same way instead of
    letting it fall through to a bare INTERNAL."""

    class _DeviceBusyRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.DeviceBusy("scanner is busy with another operation")

    transport, _device = _opened_transport(monkeypatch, _DeviceBusyRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.DEVICE_BUSY


def test_preview_maps_meter_unusable(monkeypatch: pytest.MonkeyPatch) -> None:
    """Lane B (#17): density metering runs as part of ``Roll.preview()``
    itself (not just ``scan_many``), so a channel with no usable meter mean
    can raise ``coolscanpy.MeterUnusableError`` from the PREVIEW path, not
    only from ``start_scan`` (see ``test_start_scan_maps_meter_unusable``
    above). Before this fix, ``preview()``'s except chain had no handler for
    it, so it fell through to service.py's generic ``except Exception``
    branch and flattened to a bare INTERNAL code. Must map to the typed
    ``METER_UNUSABLE`` wire code instead, guidance text preserved."""

    class _MeterUnusableRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.MeterUnusableError("G")

    transport, _device = _opened_transport(monkeypatch, _MeterUnusableRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.METER_UNUSABLE
    assert "could not find usable image data" in str(excinfo.value)
    assert "channel G" in str(excinfo.value)


def test_preview_maps_leaked_index_decode_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """Live incident, 2026-07-25: `Roll.preview()` let a coolscanpy-internal
    `IndexDecodeError` (coolscanpy.protocol.ls5000_single_pass.roll_index --
    not part of coolscanpy's public taxonomy) escape uncaught. Before this
    fix, the preview path of this transport only mapped FeederParked, so the
    exception reached service.py's generic `except Exception` branch and was
    flattened to a bare INTERNAL code with the original message ("transport
    anchor residual is inconsistent with one affine preview traversal (MAE
    4.447 rows, max 11.241 rows)") dropped entirely from telemetry. It must
    now surface as REFEED_REQUIRED with an operator-actionable eject/refeed
    instruction, and the original diagnostic text must survive inside the
    message."""
    from coolscanpy.protocol.ls5000_single_pass.roll_index import IndexDecodeError

    class _IndexDecodeErrorRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise IndexDecodeError(
                "transport anchor residual is inconsistent with one affine "
                "preview traversal (MAE 4.447 rows, max 11.241 rows)"
            )

    transport, _device = _opened_transport(monkeypatch, _IndexDecodeErrorRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED
    message = str(excinfo.value)
    assert "refeed" in message or "eject" in message
    assert "MAE 4.447" in message


def test_preview_preserves_leading_frame_clipped_refeed_guidance(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from coolscanpy.protocol.ls5000_single_pass.roll_index import (
        LeadingFrameClippedError,
    )

    class _LeadingFrameClippedRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise LeadingFrameClippedError(
                fitted_start_row=-17,
                coverage_fraction=126 / 143,
                content_fraction=41 / 42,
                clear_film_fraction=1 / 42,
            )

    transport, _device = _opened_transport(monkeypatch, _LeadingFrameClippedRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED
    message = str(excinfo.value)
    assert "first frame begins 17 preview rows" in message
    assert "refeed the film slightly deeper" in message
    assert "uniform traversal" not in message


def test_preview_maps_leaked_roll_session_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """`coolscanpy.roll.preview_session.RollSessionError` is another
    coolscanpy-internal type outside the public taxonomy that `Roll.preview()`
    can leak (e.g. "roll preview produced no scanner-addressable slots",
    raised by coolscanpy's own `build_roll_preview_session`). Must translate
    to REFEED_REQUIRED with the original text preserved, not fall through to
    a bare INTERNAL."""
    from coolscanpy.roll.preview_session import RollSessionError

    class _RollSessionErrorRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise RollSessionError("roll preview produced no scanner-addressable slots")

    transport, _device = _opened_transport(monkeypatch, _RollSessionErrorRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED
    assert "roll preview produced no scanner-addressable slots" in str(excinfo.value)


def test_preview_lets_integrity_errors_propagate(monkeypatch: pytest.MonkeyPatch) -> None:
    """`RollSessionIntegrityError` (a `RollSessionError` subclass) signals a
    driver-side artifact/journal integrity defect, not an operator-actionable
    condition -- CoolscanPyTransport must NOT translate it to a BridgeError;
    it propagates untouched so service.py's boundary reports it as INTERNAL
    with the exception class preserved in the message."""
    from coolscanpy.roll.preview_session import RollSessionIntegrityError

    class _RollSessionIntegrityErrorRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise RollSessionIntegrityError(
                "persisted preview journal differs from the validated attempt result"
            )

    transport, _device = _opened_transport(monkeypatch, _RollSessionIntegrityErrorRoll())

    with pytest.raises(RollSessionIntegrityError):
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)


def test_preview_maps_base_roll_mismatch(monkeypatch: pytest.MonkeyPatch) -> None:
    """CoolscanPy raises the bare `RollMismatch` base for e.g. a completed
    preview whose evidence belongs to a different USB topology -- previously
    unmapped, so it fell through to a bare INTERNAL. Must surface as the
    typed ROLL_MISMATCH with the message preserved."""

    class _RollMismatchRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.RollMismatch(
                "completed preview evidence belongs to a different USB topology than this Roll"
            )

    transport, _device = _opened_transport(monkeypatch, _RollMismatchRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.ROLL_MISMATCH
    assert "different USB topology" in str(excinfo.value)


def test_preview_probable_cause_survives_into_refeed_required_message(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Rung 3 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): detect_roll_frames's
    failure paths attach a best-effort plain-English
    diagnostics["probable_cause"] sentence to the IndexDecodeError they raise
    (roll_index.py). IndexDecodeError.__str__ already embeds its full
    diagnostics dict (json.dumps) in the message, and preview()'s own
    existing except IndexDecodeError branch already interpolates str(exc)
    into its REFEED_REQUIRED message -- so the sentence should ride through
    automatically, with no bridge change needed. This test pins that so a
    future refactor of either side can't silently drop it."""
    from coolscanpy.protocol.ls5000_single_pass.roll_index import IndexDecodeError

    sentence = (
        "this looks like half-frame film (frames about every 19 mm); this "
        "driver expects standard 35 mm spacing"
    )

    class _ProbableCauseRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise IndexDecodeError(
                "transport anchor residual is inconsistent with one affine "
                "preview traversal (MAE 4.447 rows, max 11.241 rows)",
                error_id="gap-lattice-anchor",
                diagnostics={"probable_cause": sentence},
            )

    transport, _device = _opened_transport(monkeypatch, _ProbableCauseRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED
    message = str(excinfo.value)
    assert sentence in message
    assert "MAE 4.447" in message


# -- roll.manualFrames / roll.previewStrip (Rung 4) --------------------------------


def test_manual_frames_without_any_preview_attempt_is_no_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """manual_frames() is usable only after at least one roll.preview
    attempt (successful or refused) exists on disk -- before that, self._roll
    and self.attempts_root are both still None."""
    transport, _device = _opened_transport(monkeypatch, _FakeRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([128, 271, 414])
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def test_preview_strip_without_any_preview_attempt_is_no_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, _device = _opened_transport(monkeypatch, _FakeRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview_strip()
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def _transport_with_synthetic_preview_attempt(
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[CoolscanPyTransport, _FakeRoll, Path]:
    """An opened transport whose attempts_root already holds one real,
    byte-valid preview attempt on disk -- the "completed-but-refused (or
    completed) preview attempt" manual_frames()/preview_strip() require.
    Runs one (successful, contents-irrelevant) fake preview() first purely
    to let CoolscanPyTransport.preview()'s own existing code create
    self._roll/self.attempts_root exactly as it would in production; the
    attempt this test actually reads back is a separately-written synthetic
    one, matching how a real refused preview would leave its own evidence
    on disk without ever producing a _FakeRoll-shaped in-memory session.

    S5 fix (2026-08-08 adversarial review): manual_frames()/preview_strip()
    now read ONLY `transport._recorded_preview_attempt_journal`, never a
    fresh glob of attempts_root -- production sets that from what
    preview()'s own before/after snapshot actually saw appear on disk
    (see coolscanpy_transport.py's own comment), which is necessarily empty
    here since `_FakeRoll.preview()` writes nothing at all. This fixture's
    whole point is a synthetic attempt written OUT OF BAND from any real
    preview() call, so it sets the recorded identity directly too --
    exactly the side effect a real preview() call would have performed had
    this synthetic attempt actually been the product of one."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.attempts_root is not None
    attempt_dir = _write_synthetic_preview_attempt(transport.attempts_root)
    transport._recorded_preview_attempt_journal = (
        attempt_dir / "journal.json"
    ).resolve(strict=True)
    return transport, roll, attempt_dir


def test_manual_frames_happy_path_arms_session_for_approve_and_scan(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, roll, _attempt_dir = _transport_with_synthetic_preview_attempt(
        monkeypatch
    )

    result, thumbnails, snaps, material = transport.manual_frames([128, 271, 414])

    assert material is domain.Material.COLOR_NEGATIVE
    assert result.count == 2
    assert len(thumbnails) == 2
    assert [t.slot for t in thumbnails] == [1, 2]
    assert thumbnails[0].boundary_rows == (128, 271)
    assert thumbnails[1].boundary_rows == (271, 414)
    assert thumbnails[0].needs_approval is True
    assert "user-picked" in thumbnails[0].warnings
    assert Path(thumbnails[0].image_path).is_file()
    # Picked rows land exactly on the synthetic raster's own clear-film gap
    # centers -- snap assist finds a zero-distance match at every boundary,
    # so nothing moves and no snap note is produced.
    assert snaps == ()

    # The transport's own bookkeeping is re-armed exactly like a successful
    # preview() leaves it.
    assert transport._material is domain.Material.COLOR_NEGATIVE
    assert transport._preview_established is True

    # The real proof of "armed exactly like a successful preview": the SAME
    # coolscanpy.Roll instance's session/approvals state now reflects the
    # manual session, and the EXISTING, unmodified approve()/
    # set_spacing_offset() methods keep working against it unchanged.
    assert roll._session is not None
    assert len(roll._session.slots) == 2
    assert roll._approvals == {}
    transport.approve(1)
    assert roll.approve_calls == [1]
    # _FakeRoll.set_spacing_offset resolves against its OWN _thumbnails list
    # (slot 1, from the fixture's setup preview() call above) -- unrelated to
    # the manual session's own slot numbering, but exactly enough to prove
    # set_spacing_offset() itself still runs unmodified, end to end, after
    # manual_frames() armed the roll.
    adjusted = transport.set_spacing_offset(1, 0)
    assert adjusted.slot == 1
    assert roll.spacing_offset_calls == [(1, 0)]


def test_manual_frames_validation_failure_maps_to_invalid_params(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """manual_frames.py's own plain-English physical-frame-height gate (15-75
    mm) refuses a too-short pick -- surfaced as INVALID_PARAMS (the operator's
    rows, not a hardware fault), with the exact sentence preserved."""
    transport, _roll, _attempt_dir = _transport_with_synthetic_preview_attempt(
        monkeypatch
    )

    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([128, 140])

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    message = str(excinfo.value)
    assert "15 mm floor" in message
    assert "manual placement" in message


def test_manual_frames_structural_failure_maps_to_invalid_params(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A single boundary row (0 frames) fails manual_frames.py's own
    structural gate before any physical check runs -- also INVALID_PARAMS."""
    transport, _roll, _attempt_dir = _transport_with_synthetic_preview_attempt(
        monkeypatch
    )

    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([128])

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "at least 2 boundary rows" in str(excinfo.value)


def test_preview_strip_happy_path_renders_whole_raster(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, _roll, _attempt_dir = _transport_with_synthetic_preview_attempt(
        monkeypatch
    )

    strip = transport.preview_strip()

    assert strip.row_count == 6_104  # the 40-record contract's decoded_height
    assert strip.pixels_per_row == 1
    assert Path(strip.image_path).is_file()
    with tifffile.TiffFile(strip.image_path) as handle:
        image = handle.asarray()
    # _normalize_preview_tile's swapaxes(0,1): the raster's row axis (what
    # roll.manualFrames's rows address) becomes the image's WIDTH axis.
    assert image.shape == (96, 6_104, 3)


def test_preview_strip_refuses_when_current_attempt_has_no_recorded_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """S5, previewStrip's own half of the same fix: no recorded current
    attempt means refuse, never a filesystem scan for something older."""
    transport, _roll, _attempt_dir = _transport_with_synthetic_preview_attempt(
        monkeypatch
    )
    transport._recorded_preview_attempt_journal = None

    with pytest.raises(BridgeError) as excinfo:
        transport.preview_strip()

    assert excinfo.value.code == ErrorCode.NO_PREVIEW
    assert "left no usable evidence" in str(excinfo.value)
    assert "acquire a fresh preview" in str(excinfo.value)


# -- 2026-08-08 adversarial review, S1 (manual placement replacement safety) --
# and S5 (stale-attempt evidence selection) -------------------------------------


def test_manual_frames_thumbnail_write_failure_leaves_roll_state_and_preview_established_unchanged(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """S1, part 1: rendering B's thumbnails happens BEFORE any Roll state
    mutation. A completed placement A is already installed and approved;
    a replacement placement B passes validation but its thumbnail disk
    write fails. Roll's session/approvals (A's) must be completely
    untouched -- install_manual_session must never even be called -- and
    self._preview_established must stay at its PREVIOUS value (True, from
    A) rather than being left False or flipped mid-mutation. A subsequent
    approve() must therefore still cleanly reach A's own (unchanged)
    session, exactly as if B had never been attempted."""
    transport, roll, _attempt_dir = _transport_with_synthetic_preview_attempt(
        monkeypatch
    )

    # Placement A: completes cleanly, arms roll._session/approvals and
    # self._preview_established -- exactly today's already-tested happy
    # path (test_manual_frames_happy_path_arms_session_for_approve_and_scan).
    transport.manual_frames([128, 271, 414])
    assert transport._preview_established is True
    session_a = roll._session
    assert session_a is not None
    # A sentinel approval "on file" for operation A -- proves it survives
    # byte-for-byte (not just "still non-None") through the failed B
    # attempt below.
    roll._approvals[1] = "operation-a-approval-sentinel"
    approvals_a = dict(roll._approvals)
    # install_manual_session_calls already holds A's own (legitimate) call
    # from the successful placement above -- capture that count so the
    # assertion below proves B added NONE, not that the list is empty.
    install_calls_after_a = len(roll.install_manual_session_calls)

    def _failing_imwrite(*_args: object, **_kwargs: object) -> None:
        raise OSError("simulated disk write failure")

    monkeypatch.setattr(tifffile, "imwrite", _failing_imwrite)

    # Placement B: same evidence, same valid rows -- passes every gate
    # build_manual_roll_preview_session checks -- but its thumbnail render
    # fails partway through persisting to disk.
    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([128, 271, 414])
    assert excinfo.value.code == ErrorCode.INTERNAL
    assert "left unchanged" in str(excinfo.value)

    # Roll state: completely untouched -- the exact same session object,
    # the exact same approvals, and install_manual_session was never
    # called again for B (the write failure is caught before any Roll
    # mutation is attempted at all).
    assert roll._session is session_a
    assert roll._approvals == approvals_a
    assert len(roll.install_manual_session_calls) == install_calls_after_a

    # self._preview_established stayed at its PREVIOUS value (True, from
    # A's own successful placement) -- never touched by B's failure.
    assert transport._preview_established is True

    # A subsequent approve() against the operation the UI still shows (A)
    # must still cleanly reach A's own, unchanged session -- never
    # NO_PREVIEW, and never silently landing on some half-installed B.
    transport.approve(1)
    assert roll.approve_calls == [1]


def test_manual_frames_maps_install_failure_without_reporting_partial_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """S1, part 2/3: install_manual_session's own failure modes (locked
    state / USB-topology mismatch, modeled here as DeviceBusy/RollMismatch)
    must map to typed BridgeErrors, and self._preview_established must be
    left False (not re-armed) since install is where the fail-closed marker
    is set immediately before this call."""
    roll = _FakeRoll(
        install_manual_session_effect=coolscanpy.DeviceBusy("another roll batch is active")
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.attempts_root is not None
    attempt_dir = _write_synthetic_preview_attempt(transport.attempts_root)
    transport._recorded_preview_attempt_journal = (
        attempt_dir / "journal.json"
    ).resolve(strict=True)

    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([128, 271, 414])
    assert excinfo.value.code == ErrorCode.DEVICE_BUSY
    assert transport._preview_established is False
    assert len(roll.install_manual_session_calls) == 1


def test_approve_refuses_on_fingerprint_mismatch(monkeypatch: pytest.MonkeyPatch) -> None:
    """S1, part 4: an approval computed against an earlier session
    (identified by its expected fingerprint) must be refused before ever
    reaching coolscanpy's own Roll.approve() -- a stale click must never
    silently approve whatever slot number happens to exist in the roll's
    CURRENT session."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], fingerprint_sha256="c" * 64)
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.approve(1, fingerprint="d" * 64)

    assert excinfo.value.code == ErrorCode.FINGERPRINT_REFUSED
    assert roll.approve_calls == []


def test_approve_succeeds_when_fingerprint_matches(monkeypatch: pytest.MonkeyPatch) -> None:
    """The additive fingerprint check is a comparison, not a blanket
    refusal: a caller-supplied value equal to the roll's current
    fingerprint approves normally."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], fingerprint_sha256="c" * 64)
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    transport.approve(1, fingerprint="c" * 64)

    assert roll.approve_calls == [1]


def test_approve_with_no_fingerprint_keeps_pre_existing_behavior(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Every existing caller (no `fingerprint` argument at all) must be
    completely unaffected: `None` is the default and skips the comparison
    entirely, exactly as before this parameter existed."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], fingerprint_sha256="c" * 64)
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    transport.approve(1)

    assert roll.approve_calls == [1]


def test_manual_frames_refuses_when_current_attempt_has_no_recorded_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """S5: attempt A completed and is still on disk; a NEWER attempt B's
    directory also exists (a retried preview's transport read started) but
    B failed before it ever wrote a journal.json of its own. The most
    recent attempt (B) left no usable evidence, so manual placement must
    refuse outright -- it must NEVER silently fall back to A's older,
    physically-superseded evidence, even though A is still present and
    perfectly well-formed on disk."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.attempts_root is not None
    _write_synthetic_preview_attempt(transport.attempts_root)  # attempt A: complete
    stale_dir = transport.attempts_root / f"preview-{uuid.uuid4().hex}"
    stale_dir.mkdir(parents=True)  # attempt B: started, no journal.json ever written
    # What a real preview() call for B would itself have recorded: its own
    # before/after snapshot diff finds no new journal at all (B wrote
    # none), so the previously-invalidated candidate stays None -- see
    # preview()'s own S5 comment. Never falls back to A.
    transport._recorded_preview_attempt_journal = None

    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([128, 271, 414])

    assert excinfo.value.code == ErrorCode.NO_PREVIEW
    message = str(excinfo.value)
    assert "left no usable evidence" in message
    assert "acquire a fresh preview" in message
    assert roll.install_manual_session_calls == []


def test_sole_new_attempt_journal_ignores_mtime_and_identifies_the_new_candidate(
    tmp_path: Path,
) -> None:
    """S5's core selection primitive: identifying the attempt a preview()
    call itself just produced is pure set membership against a snapshot
    taken immediately beforehand -- NEVER a modification-time comparison.
    Here the OLDER attempt's journal is touched (its mtime pushed into the
    future, past the newer attempt's own) after the newer one is written --
    exactly the "A's journal is touched later" S5 scenario -- and the
    correct (new) candidate must still be the one identified."""
    attempts_root = tmp_path
    old_dir = attempts_root / "preview-old"
    old_dir.mkdir()
    old_journal = old_dir / "journal.json"
    old_journal.write_text("{}", encoding="utf-8")
    before = frozenset(
        attempts_root.glob(coolscanpy_transport_module._PREVIEW_ATTEMPT_GLOB)
    )

    new_dir = attempts_root / "preview-new"
    new_dir.mkdir()
    new_journal = new_dir / "journal.json"
    new_journal.write_text("{}", encoding="utf-8")
    # Touch the OLDER journal so it carries a strictly newer mtime than the
    # attempt that actually just happened -- an mtime-sorting selection
    # would incorrectly pick this one.
    future = time.time() + 10_000
    os.utime(old_journal, (future, future))
    assert old_journal.stat().st_mtime > new_journal.stat().st_mtime

    resolved = coolscanpy_transport_module._sole_new_attempt_journal(
        attempts_root, before
    )

    assert resolved == new_journal.resolve()


def test_sole_new_attempt_journal_is_none_when_nothing_new_appeared(
    tmp_path: Path,
) -> None:
    """A hard failure that writes no journal at all (e.g. a bootstrap
    failure before the transport read even starts) must resolve to `None`,
    never to whatever older attempt happens to already be on disk."""
    attempts_root = tmp_path
    old_dir = attempts_root / "preview-old"
    old_dir.mkdir()
    (old_dir / "journal.json").write_text("{}", encoding="utf-8")
    before = frozenset(
        attempts_root.glob(coolscanpy_transport_module._PREVIEW_ATTEMPT_GLOB)
    )

    # Nothing new is written under attempts_root this time.

    resolved = coolscanpy_transport_module._sole_new_attempt_journal(
        attempts_root, before
    )

    assert resolved is None


def test_start_scan_maps_base_roll_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Live 2026-07-25: a post-power-cycle unit attention surfaced mid-scan
    as `RollMismatch: SynchronizedProtocolError: ready group 170-170:
    untraced sense 063f03` and reached the app as INTERNAL, because the scan
    path mapped every RollMismatch SUBCLASS but not the base. Typed
    ROLL_MISMATCH now, message preserved."""
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={
            1: [
                coolscanpy.RollMismatch(
                    "SynchronizedProtocolError: ready group 170-170: "
                    "untraced sense 063f03; terminal 000000"
                )
            ]
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.ROLL_MISMATCH
    assert "untraced sense 063f03" in str(excinfo.value)


def test_start_scan_maps_meter_unusable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Lane B (#17): a frame whose metering found no usable image data for a
    channel raises ``coolscanpy.MeterUnusableError``. The scan path must map it
    to the typed ``METER_UNUSABLE`` wire code (guidance preserved), never
    flatten it to a bare INTERNAL."""
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [coolscanpy.MeterUnusableError("G")]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.METER_UNUSABLE
    assert "could not find usable image data" in str(excinfo.value)
    assert "channel G" in str(excinfo.value)


@pytest.mark.parametrize(
    "diagnostic",
    (
        "SynchronizedProtocolError: ready group 233-496: untraced sense 023a00; terminal 000000",
        "SynchronizedProtocolError: ready group 233-496: untraced sense 02/3A/00; terminal 00/00/00",
    ),
)
def test_start_scan_maps_medium_not_present_roll_mismatch_to_film_feed_interrupted(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    diagnostic: str,
) -> None:
    """Live 2026-08-02: positioning frame 4 returned SCSI 02/3A/00.

    That is a verified medium-not-present transport interruption, not an
    unclassified ROLL_MISMATCH and never an INTERNAL application fault.
    """
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [coolscanpy.RollMismatch(diagnostic)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )

    assert excinfo.value.code == ErrorCode.FILM_FEED_INTERRUPTED
    assert "023a00" in str(excinfo.value).lower().replace("/", "")


def test_film_feed_interrupted_immediately_invalidates_preview_before_another_scan(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The terminal error itself retires registration; no status poll is
    required before a second scan.start is rejected without transport I/O.
    """
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={
            1: [
                coolscanpy.RollMismatch(
                    "SynchronizedProtocolError: ready group 233-496: "
                    "untraced sense 023a00; terminal 000000"
                )
            ]
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as interrupted:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path / "first"),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )
    assert interrupted.value.code == ErrorCode.FILM_FEED_INTERRUPTED
    assert roll.scan_many_calls == [(1,)]

    with pytest.raises(BridgeError) as no_preview:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path / "second"),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )
    assert no_preview.value.code == ErrorCode.NO_PREVIEW
    assert roll.scan_many_calls == [(1,)]


def test_trim_out_of_table_slots_drops_slots_above_the_parsed_bound() -> None:
    """Pure-function unit coverage for the regex/partition logic
    start_scan's RollMismatch handler relies on -- no structured attribute
    exists anywhere on this exception for the table bound (confirmed by
    reading coolscanpy's own exceptions.py/_roll.py), so this is recovered
    from the message text, the only place it exists."""
    result = _trim_out_of_table_slots(
        [35, 36, 37, 38, 39],
        "requested frame 38 is outside the scanner-addressable table 1..37",
    )
    assert result == ([35, 36, 37], [38, 39])


def test_trim_out_of_table_slots_returns_none_for_an_unrelated_roll_mismatch() -> None:
    """A different RollMismatch message shape (e.g. the live 2026-07-25
    SynchronizedProtocolError case) must not be misparsed -- falls back to
    the caller's unconditional raise."""
    assert (
        _trim_out_of_table_slots(
            [1, 2, 3],
            "SynchronizedProtocolError: ready group 170-170: untraced sense 063f03",
        )
        is None
    )


def test_trim_out_of_table_slots_returns_none_when_nothing_would_be_dropped() -> None:
    """Every remaining slot already fits under the parsed bound, so
    trimming would not shrink the batch at all -- the caller must fall
    back to the unconditional raise rather than retry a no-op."""
    assert (
        _trim_out_of_table_slots(
            [1, 2, 3],
            "requested frame 38 is outside the scanner-addressable table 1..37",
        )
        is None
    )


# -- start_scan: batch clamp-and-retry on a fresh-reread table shrink (2026-07-25) --


def test_start_scan_trims_out_of_table_slots_and_retries_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Live 2026-07-25: requesting slot 39 after a fresh re-read inside
    scan_many found only 37 addressable slots failed the ENTIRE batch up
    front with ROLL_MISMATCH ("requested frame 38 is outside the
    scanner-addressable table 1..37") -- nothing scanned, even though
    slots 35..37 (this test's analog of 1..37) were still perfectly
    scannable. CoolscanPyTransport must now catch this shape, drop 38/39
    into failure_reasons, and retry scan_many once with the surviving
    subset."""
    slots = [35, 36, 37, 38, 39]
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(s) for s in slots],
        scan_results={
            # The first scripted outcome for the batch's first slot is the
            # out-of-table exception -- scan_many raises it before
            # yielding anything (matching the live incident: nothing
            # scanned). The SECOND scripted outcome (a real frame) is only
            # reached on the trimmed retry.
            35: [
                coolscanpy.RollMismatch(
                    "requested frame 38 is outside the scanner-addressable table 1..37"
                ),
                _fake_frame(35),
            ],
            36: [_fake_frame(36)],
            37: [_fake_frame(37)],
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    summary = transport.start_scan(
        slots=slots,
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda *_a: None,
    )

    assert summary.completed == (35, 36, 37)
    assert summary.failed == (38, 39)
    assert summary.failure_reasons[38]["code"] == "ROLL_MISMATCH"
    assert summary.failure_reasons[39]["code"] == "ROLL_MISMATCH"
    assert "scanner-addressable table 1..37" in summary.failure_reasons[38]["reason_message"]
    # Exactly two scan_many calls -- the original 5-slot batch, then the
    # trimmed 3-slot retry -- proves "retry once", not a loop.
    assert roll.scan_many_calls == [(35, 36, 37, 38, 39), (35, 36, 37)]


def test_start_scan_does_not_retry_a_second_out_of_table_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One-shot guard: if the trimmed retry batch ALSO hits an out-of-table
    RollMismatch (e.g. the table shrank again mid-retry), the second
    failure must raise normally -- never a second trim-and-retry."""
    slots = [10, 11, 12]
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(s) for s in slots],
        scan_results={
            10: [
                coolscanpy.RollMismatch(
                    "requested frame 12 is outside the scanner-addressable table 1..11"
                ),
                coolscanpy.RollMismatch(
                    "requested frame 11 is outside the scanner-addressable table 1..10"
                ),
            ],
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=slots,
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.ROLL_MISMATCH
    assert "table 1..10" in str(excinfo.value)
    # Two calls total -- the original batch, then exactly one retry -- not
    # a third attempt after the retry's own out-of-table failure.
    assert roll.scan_many_calls == [(10, 11, 12), (10, 11)]


# -- FIX 1 regression (2026-07-25): a real CoolscanPyTransport driven through
# BridgeService must not misattribute a pre-frame batch failure to the
# batch's LAST slot ------------------------------------------------------


def _wait_for(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pytest.fail("condition not met within timeout")


class _ThreadSafeEmit:
    """Minimal thread-safe emit() collector -- BridgeService's scan.start
    worker runs on a background thread, unlike every other test in this
    file, which drives CoolscanPyTransport synchronously on the test
    thread alone."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._events: list[tuple[str, dict]] = []

    def __call__(self, event: str, payload: dict) -> None:
        with self._lock:
            self._events.append((event, payload))

    def names(self) -> list[str]:
        with self._lock:
            return [e for e, _p in self._events]

    def has(self, event: str) -> bool:
        return event in self.names()

    def payload_of(self, event: str) -> dict:
        with self._lock:
            return next(p for e, p in self._events if e == event)


def test_service_scan_start_pre_frame_roll_mismatch_names_the_first_slot_not_the_last(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """End-to-end reproduction of the live 2026-07-25 incident: a 33-slot
    batch ([4..36]) failed with a pre-frame RollMismatch (a
    SynchronizedProtocolError wrapped as RollMismatch, raised from
    scan_many before any frame yielded) and scan.frameFailed reported slot
    36 -- the LAST requested slot -- instead of slot 4, the first pending
    (and the honest answer once no frame in the batch has resolved at
    all).

    Drives a REAL CoolscanPyTransport (not service.py's own hand-written
    _StubTransport double used by test_scan_frame_failed.py) through
    BridgeService, using this file's own _FakeRoll scripted to raise on
    the very first slot it consumes -- proving both halves of the fix
    together: CoolscanPyTransport's upfront, whole-batch on_progress
    emission (unchanged by this fix -- see start_scan's own comment) and
    service.py's first_pending_slot() replacement for the old,
    on_progress-based current_fail_slot() that broke on exactly this
    shape."""
    slots = list(range(4, 37))  # 33 slots, matching the live incident
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(s) for s in slots],
        scan_results={
            4: [
                coolscanpy.RollMismatch(
                    "SynchronizedProtocolError: ready group 170-170: "
                    "untraced sense 063f03; terminal 000000"
                )
            ]
        },
    )
    info = _fake_device_info()
    fake_device = _FakeDevice(roll=roll)
    monkeypatch.setattr(coolscanpy, "get_devices", lambda: [info])
    monkeypatch.setattr(coolscanpy, "open", lambda devname: fake_device)
    monkeypatch.setattr(
        safety, "DEFAULT_BASE_DIR", Path(tempfile.mkdtemp(prefix="scanstudio-test-preview-"))
    )

    base_dir = tmp_path / ".scanstudio"
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    base_dir.mkdir(parents=True, exist_ok=True)
    (base_dir / "hw-motion-armed").write_text("junk-roll")

    telemetry = safety.TelemetryLog(base_dir)
    svc = service.BridgeService(CoolscanPyTransport(), telemetry, base_dir=base_dir)
    emit = _ThreadSafeEmit()

    svc.dispatch(
        {"id": 1, "method": "bridge.hello", "params": {"clientName": "t", "protocolVersion": 1}},
        emit,
    )
    svc.dispatch({"id": 2, "method": "device.open", "params": {"deviceId": _DEVICE_ID}}, emit)
    svc.dispatch({"id": 3, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit)
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for(lambda: not svc._lane_held)
    _wait_for(lambda: not svc._motion_op_active)

    svc.dispatch(
        {
            "id": 4,
            "method": "scan.start",
            "params": {
                "slots": slots,
                "recipe": {
                    "resolutionDpi": 4000,
                    "bitDepth": 16,
                    "multisamplePasses": 4,
                    "channels": "rgbi",
                    "autofocus": True,
                    "autoExposure": True,
                },
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed["slot"] == 4
    assert frame_failed["slot"] != 36
    assert frame_failed["attribution"] == "batch-pre-frame"

    completed_summary = emit.payload_of("scan.completed")["summary"]
    assert completed_summary["completed"] == []
    assert completed_summary["failed"] == slots


def test_preview_material_change_closes_the_old_roll_and_creates_a_fresh_one(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Adversarial review, 2026-07-25: `_material` was overwritten up front
    and an existing Roll reused regardless, so previewing material A then
    requesting material B relabeled the bridge's state as B while the Roll
    (and any still-valid session) remained A's. A material CHANGE must close
    the old Roll and create a new one; a same-material re-preview keeps
    reusing the existing Roll."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, device = _opened_transport(monkeypatch, roll)

    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert len(device.roll_calls) == 1

    # Same material: the Roll is reused, no new Device.roll() call.
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert len(device.roll_calls) == 1
    assert roll.closed is False

    # Material change: old Roll closed, a fresh one requested.
    transport.preview(domain.Material.BLACK_AND_WHITE_NEGATIVE, None, lambda _t: None)
    assert len(device.roll_calls) == 2
    assert roll.closed is True


def test_failed_preview_clears_preview_established(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CoolscanPy's `Roll.preview()` re-reads the transport and replaces the
    prior session the moment it runs -- so once a NEW preview attempt
    starts, the old established state is gone whether or not the attempt
    completes. A successful preview followed by a failed one must leave
    `preview_established` False (and scans blocked on NO_PREVIEW), not
    truthfully-stale True."""
    fail_next = {"value": False}

    class _FlakyRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            if fail_next["value"]:
                raise coolscanpy.FeederParked("power cycle required")
            return super().preview(slots)

    roll = _FlakyRoll(thumbnails=[_fake_thumbnail(1)])
    transport, _device = _opened_transport(monkeypatch, roll)

    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.status().preview_established is True

    fail_next["value"] = True
    with pytest.raises(BridgeError):
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.status().preview_established is False


# -- preview: attempts-root persistence (Plan 10-09, coordinator scope addition) ----


def test_preview_passes_a_caller_owned_attempts_root_to_device_roll(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without a caller-owned attempts_root, coolscanpy's own Roll.close()
    shutil.rmtree()s its default tempfile.mkdtemp() directory -- wiping any
    per-attempt journal/manifest before an operator can ever look at it.
    CoolscanPyTransport must pass one in, and remember it for service.py to
    surface in telemetry (see coolscanpy_transport.py's preview())."""
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, device = _opened_transport(monkeypatch, roll)

    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    assert len(device.roll_calls) == 1
    passed_root = device.roll_calls[0]
    assert passed_root is not None
    assert transport.attempts_root == passed_root
    assert passed_root.is_dir()
    assert passed_root.parent.name == "coolscanpy-attempts"


def test_preview_attempts_root_is_created_once_per_roll_not_per_preview_call(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, device = _opened_transport(monkeypatch, roll)

    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    first_root = transport.attempts_root
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    # Same Roll instance (transport._roll is only created once, when None)
    # -- attempts_root must not silently rotate underneath it.
    assert len(device.roll_calls) == 1
    assert transport.attempts_root == first_root


# -- start_scan: recipe rejection without touching Roll.scan -----------------------


def test_start_scan_rejects_bad_recipe_without_calling_roll_scan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [_fake_frame(1)]})
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    bad_recipe = dataclasses.replace(domain.FIXED_COLOR_NEGATIVE_RECIPE, channels=domain.Channels.RGB)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=bad_recipe,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert roll.scan_many_calls == []


# -- start_scan: scan_many batch behavior ------------------------------------------


def test_start_scan_calls_scan_many_once_for_multiple_slots(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1), _fake_thumbnail(2)],
        scan_results={1: [_fake_frame(1)], 2: [_fake_frame(2)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    frames: list[int] = []
    summary = transport.start_scan(
        slots=[1, 2],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda slot, _receipt: frames.append(slot),
    )

    assert roll.scan_many_calls == [(1, 2)]
    assert summary.completed == (1, 2)
    assert summary.failed == ()
    assert frames == [1, 2]
    assert (tmp_path / "frame-0001.tif").exists()
    assert (tmp_path / "frame-0002.tif").exists()


def test_start_scan_maps_transport_smear_to_frame_retry_exhausted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """scan_many does not expose per-frame retry hooks, so the bridge
    surfaces a smear fault as FrameRetryExhausted instead of retrying."""
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_smear()]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(FrameRetryExhausted) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )

    assert excinfo.value.slot == 1
    assert isinstance(excinfo.value.last_error, coolscanpy.TransportSmearDetected)
    assert roll.scan_many_calls == [(1,)]


# -- start_scan: meter_rgbi sidecar -----------------------------------------------


def test_start_scan_writes_meter_rgbi_sidecar_when_coolscanpy_supplies_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    meter = np.zeros((8, 8, 4), dtype=np.uint16)
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1, meter_rgbi=meter)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    meter_path = tmp_path / "frame-0001_METER.tif"
    assert frames[0].meter_rgbi_path == str(meter_path)
    assert meter_path.exists()
    assert tifffile.imread(meter_path).shape == (8, 8, 4)


def test_start_scan_receipt_forwards_the_exact_current_roll_attempts_root(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1)]},
    )
    transport, device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    caller_owned_root = device.roll_calls[0]
    assert caller_owned_root is not None
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    assert frames[0].attempts_root == str(caller_owned_root)


def test_scan_receipt_forwards_captured_timing_from_coolscanpy_receipt(
    tmp_path: Path,
) -> None:
    receipt = dataclasses.replace(
        _fake_receipt(1),
        started_at="2026-08-02T20:05:00+00:00",
        capture_duration_ms=1900,
    )
    with tempfile.TemporaryDirectory() as attempts:
        mapped = coolscanpy_transport_module._scan_receipt_from_coolscanpy(
            receipt,
            rgb_path="/tmp/frame-0001.tif",
            ir_path=None,
            meter_rgbi_path=None,
            attempts_root=Path(attempts),
        )
    assert mapped.started_at == "2026-08-02T20:05:00+00:00"
    assert mapped.capture_duration_ms == 1900
    assert mapped.started_at == receipt.started_at


def test_start_scan_receipt_forwards_best_effort_exposure_authority(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    authority = domain.ExposureAuthority(
        rgb_source="nikon-parity-guarded-v2",
        ir_source="active-controller",
        commanded_channels_raw_10ns={"R": 1, "G": 2, "B": 3, "IR": 4},
        active_controller_channels_raw_10ns={"R": 5, "G": 6, "B": 7, "IR": 4},
        device_bound_clamped_channels_raw_10ns={},
        device_exposure_bounds_raw_10ns=(50_000, 400_000),
    )
    seen: list[tuple[Path | None, int]] = []

    def fake_build(*, attempts_root: Path | None, slot: int):
        seen.append((attempts_root, slot))
        return authority

    monkeypatch.setattr(coolscanpy_transport_module, "build_exposure_authority", fake_build)
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [_fake_frame(1)]})
    transport, device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    assert seen == [(device.roll_calls[0], 1)]
    assert frames[0].exposure_authority == authority


def test_start_scan_leaves_meter_rgbi_path_none_when_coolscanpy_omits_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1)]},  # meter_rgbi defaults to None
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    assert frames[0].meter_rgbi_path is None
    assert not (tmp_path / "frame-0001_METER.tif").exists()


def test_start_scan_writes_meter_sidecar_for_rgb_when_coolscanpy_supplies_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    meter = np.zeros((8, 8, 4), dtype=np.uint16)
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1, meter_rgbi=meter)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    # The production route is fixed RGBI; bypass only that recipe gate so
    # this transport-level test can cover CoolscanPy's independent meter
    # sidecar behavior for an RGB request.
    monkeypatch.setattr(domain, "validate_capture_recipe", lambda *_a: None)
    rgb_recipe = dataclasses.replace(domain.FIXED_COLOR_NEGATIVE_RECIPE, channels=domain.Channels.RGB)
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=rgb_recipe,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    meter_path = tmp_path / "frame-0001_METER.tif"
    assert frames[0].ir_path is None
    assert frames[0].meter_rgbi_path == str(meter_path)
    assert tifffile.imread(meter_path).shape == (8, 8, 4)


# -- start_scan: path traversal, validated before Roll.scan is called --------------


def test_start_scan_rejects_path_traversal_before_roll_scan_called(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [_fake_frame(1)]})
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    destination = tmp_path / "out"

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(destination, "../escape-####.tif"),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert roll.scan_many_calls == []
    assert not (tmp_path / "escape-0001.tif").exists()


@pytest.mark.parametrize("sidecar_suffix", ["", "_IR", "_METER"])
def test_start_scan_refuses_existing_output_group_before_scan_many(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, sidecar_suffix: str
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [_fake_frame(1)]})
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    output_root = tmp_path / "out"
    target = output_root / f"frame-0001{sidecar_suffix}.tif"
    target.parent.mkdir()
    original = b"do-not-replace-existing-artifact"
    target.write_bytes(original)
    progress: list[domain.ScanProgress] = []

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(output_root),
            on_progress=progress.append,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert target.read_bytes() == original
    assert roll.scan_many_calls == []
    assert progress == []
    assert list(output_root.iterdir()) == [target]


def test_start_scan_failure_after_scan_starts_cleans_unwritten_reservations(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [coolscanpy.BatchIntegrityError("decoder failed before a frame")]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    output_root = tmp_path / "out"

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(output_root),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )

    assert excinfo.value.code == ErrorCode.BATCH_INTEGRITY_ERROR
    assert roll.scan_many_calls == [(1,)]
    assert list(output_root.iterdir()) == []


def test_start_scan_write_failure_keeps_rgb_and_releases_unwritten_sidecars(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [_fake_frame(1)]})
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    output_root = tmp_path / "out"
    actual_write_tiff = coolscanpy_transport_module.write_tiff

    def fail_ir_write(reservations, path, data, **kwargs):
        if path.name.endswith("_IR.tif"):
            raise RuntimeError("injected IR writer failure")
        return actual_write_tiff(reservations, path, data, **kwargs)

    monkeypatch.setattr(coolscanpy_transport_module, "write_tiff", fail_ir_write)

    with pytest.raises(RuntimeError, match="injected IR writer failure"):
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(output_root),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )

    rgb_path = output_root / "frame-0001.tif"
    assert rgb_path.exists()
    assert tifffile.imread(rgb_path).shape == (8, 8, 3)
    assert not (output_root / "frame-0001_IR.tif").exists()
    assert not (output_root / "frame-0001_METER.tif").exists()


def test_start_scan_real_adapter_writes_requested_raw_before_completing_frame(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    rgb = np.arange(8 * 8 * 3, dtype=np.uint16).reshape(8, 8, 3)
    infrared = (np.arange(8 * 8, dtype=np.uint16).reshape(8, 8) + 30000)
    frame = dataclasses.replace(_fake_frame(1), rgb=rgb, ir=infrared)
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [frame]})
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    receipts: list[domain.ScanReceipt] = []
    output = domain.OutputSpec(
        destination=str(tmp_path / "capture"),
        filename_template="frame-####.tif",
        raw_export=domain.RawExportSpec(
            destination=str(tmp_path / "raw"),
            filename_template="negative-####",
            file_format=domain.RawExportFormat.LINEAR_DNG,
        ),
    )

    transport.start_scan(
        [1],
        domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output,
        lambda _p: None,
        lambda *_a: None,
        lambda _slot, receipt: receipts.append(receipt),
    )

    raw_path = tmp_path / "raw" / "negative-0001.dng"
    assert receipts[0].raw_export_path == str(raw_path)
    with tifffile.TiffFile(raw_path) as tiff:
        np.testing.assert_array_equal(tiff.pages[0].asarray(), rgb)
        np.testing.assert_array_equal(tiff.pages[0].pages[0].asarray(), infrared)


def test_start_scan_real_adapter_receipts_complete_raw_sidecar_pair(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    rgb = np.arange(8 * 8 * 3, dtype=np.uint16).reshape(8, 8, 3)
    infrared = (np.arange(8 * 8, dtype=np.uint16).reshape(8, 8) + 30000)
    frame = dataclasses.replace(_fake_frame(1), rgb=rgb, ir=infrared)
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)], scan_results={1: [frame]})
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    receipts: list[domain.ScanReceipt] = []
    output = domain.OutputSpec(
        destination=str(tmp_path / "capture"),
        filename_template="frame-####.tif",
        raw_export=domain.RawExportSpec(
            destination=str(tmp_path / "raw"),
            filename_template="negative-####",
            file_format=domain.RawExportFormat.LINEAR_TIFF,
            tiff_infrared=domain.RawTiffInfrared.SIDECAR,
        ),
    )

    transport.start_scan(
        [1],
        domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output,
        lambda _p: None,
        lambda *_a: None,
        lambda _slot, receipt: receipts.append(receipt),
    )

    raw_path = tmp_path / "raw" / "negative-0001.tif"
    raw_ir_path = tmp_path / "raw" / "negative-0001-ir.tif"
    assert receipts[0].raw_export_path == str(raw_path)
    assert receipts[0].raw_export_ir_path == str(raw_ir_path)
    np.testing.assert_array_equal(tifffile.imread(raw_path), rgb)
    np.testing.assert_array_equal(tifffile.imread(raw_ir_path), infrared)


# -- start_scan: other coolscanpy exception mappings --------------------------------


def test_start_scan_maps_batch_integrity_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [coolscanpy.BatchIntegrityError("manifest self-check failed")]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )
    assert excinfo.value.code == ErrorCode.BATCH_INTEGRITY_ERROR


def test_start_scan_maps_typed_worker_bootstrap_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={
            1: [
                coolscanpy.CaptureWorkerBootstrapFailed(
                    "CAPTURE_WORKER_BOOTSTRAP_FAILED: bundled capture worker "
                    "failed before scanner dispatch (ModuleNotFoundError): "
                    "No module named 'coolscanpy'"
                )
            ]
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )

    assert excinfo.value.code == ErrorCode.INTERNAL
    assert "ModuleNotFoundError" in str(excinfo.value)
    assert "No module named 'coolscanpy'" in str(excinfo.value)


def test_start_scan_maps_refeed_required(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`CoolscanPyTransport`'s `coolscanpy.RefeedRequired -> BridgeError(REFEED_REQUIRED)`
    mapping, kept correct and covered independent of which coolscanpy pin is
    installed (Plan 10-05 added this test; Plan 10-07 reconciles its framing
    against the newer pinned source -- see below).

    History, for anyone tracing why this test exists: Plan 10-05 root-caused
    the live 0.55s `roll.scan:slot1` fast-fail (LIVE-VERIFICATION-20260723.md
    attempt #2, 2026-07-23 ~18:00 PDT -- `roll.preview` finished a whole-roll
    traversal, `scan.start` on slot 1 followed ~1ms later, `roll.scan`
    returned in 0.55s) to `coolscanpy.RefeedRequired` via elimination and
    coolscanpy's own docstring/changelog, since the live defect at the time
    (service.py's worker silently swallowing this exact BridgeError, see
    tests/test_service_dispatch.py's
    test_scan_start_bridge_error_from_transport_emits_scan_error_then_completed_with_slot_failed)
    meant no traceback was ever captured. Live attempt #3
    (`~/.scanstudio/hw-telemetry/9d29b1a82d094599a78891bd3189d8d9.jsonl`,
    2026-07-24T02:10:39Z / 2026-07-23 19:10:39 PDT, job
    6806732c40d04ff9a24fc2efc988062f) then confirmed the hypothesis directly
    on the wire -- an identical preview-then-immediate-scan sequence (37
    slots, ~0.59s `roll.scan:slot1` call) closed with
    `{"method":"scan.start","outcome":"error","code":"REFEED_REQUIRED"}`,
    proving 10-05's diagnosis correct against the *then-installed* coolscanpy
    0.1.3 build (the pre-586f575 snapshot 10-05 already flagged as possibly
    over-classifying, per its own Confidence caveat).

    Plan 10-07 bumped the pin (editable install, same nominal "0.1.3" version
    string, newer content) to the coolscanpy source that already contains
    commit 586f575's fix. Under that source, `RefeedRequired`'s own docstring
    narrowed to "Compatibility exception for a confirmed physical refeed
    condition. Generic command-status text is not sufficient to emit this
    exception." -- i.e. attempt #3's exact scenario (a generic post-preview
    command-64 status read, not a separately confirmed refeed) is no longer
    expected to raise this exception at all under the new pin (see
    coolscanpy's own `tests/test_facade.py::TestRollBatchRefusal::
    test_command_64_nonzero_status_is_not_misreported_as_refeed_required`,
    and this file's own
    `test_start_scan_succeeds_immediately_after_preview_when_transport_reports_a_generic_status`
    below, which mirrors that same call sequence and asserts success).

    This test itself still documents live, needed behavior: `RefeedRequired`
    remains exported and can still fire for a genuinely confirmed refeed
    condition (per its narrowed docstring), and `CoolscanPyTransport` must
    still map that correctly to `BridgeError(REFEED_REQUIRED)` when it does.
    Only the *framing* of when coolscanpy is expected to raise it changed;
    the mapping code and its correctness did not, and this plan made no
    change to `coolscanpy_transport.py`.
    """
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={
            1: [
                coolscanpy.RefeedRequired(
                    "a separately confirmed physical refeed condition was detected; "
                    "pull the strip fully out, reinsert it until the feeder grips, "
                    "then retry the batch"
                )
            ]
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )
    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED
    assert roll.scan_many_calls == [(1,)]


def test_start_scan_succeeds_immediately_after_preview_when_transport_reports_a_generic_status(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Plan 10-07: proves the bridge-side wiring for the scenario that made
    roll scanning structurally impossible on the stale pinned coolscanpy
    0.1.3 build -- a `roll.scan(slot)` call issued immediately after a
    whole-roll `preview()`, the exact shape of live attempts #2 and #3 (see
    `test_start_scan_maps_refeed_required`'s docstring above for the full
    evidence trail, including attempt #3's confirmed
    `code":"REFEED_REQUIRED"` wire event under the pre-fix pin).

    Every autoload feed ends a whole-roll preview parked at the end of
    transport travel -- per `Roll.preview`'s own docstring, that is what a
    whole-roll traversal always does -- so this exact call sequence
    (`preview()` then `scan()` on the just-previewed roll, no intervening
    calls) is not a rare edge case: it is the ordinary shape of *every* roll
    scan this bridge issues. Under coolscanpy's newer pinned source, this
    generic post-preview condition alone no longer raises `RefeedRequired`
    (see `test_start_scan_maps_refeed_required`'s docstring for exactly which
    coolscanpy source/commit/test asserts that, byte-for-byte, at the
    protocol level -- this file deliberately does not re-derive that
    byte-level claim; verifying coolscanpy's own internal USB status
    classification is coolscanpy's job and already has coolscanpy's own
    regression test, not this bridge's).

    What *this* test actually proves, at the `CoolscanPyTransport` boundary
    this file owns: `CoolscanPyTransport` has no classifier of its own and
    imposes no assumption that a post-preview scan must fail -- it fully
    defers to whatever `Roll.scan()` actually returns or raises. Scripting
    the fake `Roll.scan(1)` to succeed (mirroring what the newer pin's fixed
    classifier now does for this exact scenario, instead of raising as the
    stale pre-586f575 build did) must therefore produce a normal completed
    scan on the bridge's own wire contract -- not an error of any kind, and
    specifically not a `REFEED_REQUIRED` the bridge invented on its own.
    """
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    summary = transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda *a: None,
    )

    assert summary.completed == (1,)
    assert summary.failed == ()
    assert summary.stopped is False
    assert roll.scan_many_calls == [(1,)]


def test_start_scan_manual_review_required_marks_slot_failed_and_continues(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1), _fake_thumbnail(2)],
        scan_results={
            1: [coolscanpy.ManualReviewRequired("needs approval", slot=1)],
            2: [_fake_frame(2)],
        },
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    frames: list[int] = []

    summary = transport.start_scan(
        slots=[1, 2],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda slot, _receipt: frames.append(slot),
    )

    assert summary.failed == (1,)
    assert summary.completed == (2,)
    assert frames == [2]
    # Plan 10-09 (coordinator scope addition): the exception's class and
    # exact message must survive -- previously discarded by a bare
    # `except coolscanpy.ManualReviewRequired:` with no `as exc` binding.
    assert summary.failure_reasons == {
        1: {
            "reason_class": "ManualReviewRequired",
            "reason_message": "needs approval",
            "code": "MANUAL_REVIEW_REQUIRED",
        }
    }


def test_start_scan_safe_stop_requested_stops_and_reports_summary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1), _fake_thumbnail(2)],
        scan_results={1: [_fake_frame(1)], 2: [coolscanpy.SafeStopRequested("safe stop requested")]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    summary = transport.start_scan(
        slots=[1, 2],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda *a: None,
    )

    assert summary.completed == (1,)
    assert summary.stopped is True


# -- start_scan: scan.phase-boundary telemetry (Plan 10-09) ------------------------


class _RecordingOnCall:
    """Records every on_call invocation with its full argument set --
    positional AND the raise-aware/phase-kind keyword arguments Plan 10-09
    added to `timed_call`'s contract."""

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

    def pairs(self, kind: str) -> set[tuple[str, str]]:
        return {(e["name"], e["phase"]) for e in self.entries if e["kind"] == kind}


def test_start_scan_emits_scan_phase_boundary_for_batch_and_each_file_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """With scan_many the bridge observes one ``fine_scan:batch`` phase
    around the whole batch consumption, while file writes remain individual
    ``phased_call`` boundaries under ``file_write.*:slot{N}``."""
    meter = np.zeros((8, 8, 4), dtype=np.uint16)
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_frame(1, meter_rgbi=meter)]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    on_call = _RecordingOnCall()

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda *a: None,
        on_call=on_call,
    )

    phase_pairs = on_call.pairs("phase")
    for expected_name in (
        "fine_scan:batch",
        "file_write.rgb:slot1",
        "file_write.ir:slot1",
        "file_write.meter:slot1",
    ):
        assert (expected_name, "enter") in phase_pairs, phase_pairs
        assert (expected_name, "exit") in phase_pairs, phase_pairs

    # scan.call granularity (Plan 10-04) is untouched for file writes;
    # there is no per-slot roll.scan call in the scan_many path.
    call_pairs = on_call.pairs("call")
    assert ("roll.scan:slot1", "enter") not in call_pairs
    assert ("file_write.rgb:slot1", "enter") in call_pairs, (
        "phased_call must ALSO keep the original scan.call entry, not replace it"
    )

    # Ordering: file writes stream INSIDE the open batch bracket -- each
    # frame is written as it arrives from the scan_many iterator, so the
    # batch phase enters before the first write and exits only after the
    # last write of the last streamed frame.
    names_in_order = [e["name"] for e in on_call.entries if e["kind"] == "phase"]
    assert names_in_order.index("fine_scan:batch") < names_in_order.index(
        "file_write.rgb:slot1"
    )
    fine_scan_exit_index = next(
        i
        for i, e in enumerate(on_call.entries)
        if e["kind"] == "phase" and e["name"] == "fine_scan:batch" and e["phase"] == "exit"
    )
    meter_write_exit_index = next(
        i
        for i, e in enumerate(on_call.entries)
        if e["kind"] == "phase"
        and e["name"] == "file_write.meter:slot1"
        and e["phase"] == "exit"
    )
    assert meter_write_exit_index < fine_scan_exit_index


def test_start_scan_frame_retry_exhausted_records_raise_outcome_on_batch_phase(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Plan 10-09 (raise-aware call telemetry): the single
    ``fine_scan:batch`` scan.phase boundary exits via a raise with
    ``exception_class=FrameRetryExhausted`` when scan_many raises
    TransportSmearDetected."""
    roll = _FakeRoll(
        thumbnails=[_fake_thumbnail(1)],
        scan_results={1: [_fake_smear()]},
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    on_call = _RecordingOnCall()

    with pytest.raises(FrameRetryExhausted):
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
            on_call=on_call,
        )

    phase_exits = [
        e
        for e in on_call.entries
        if e["kind"] == "phase" and e["name"] == "fine_scan:batch" and e["phase"] == "exit"
    ]
    assert len(phase_exits) == 1
    assert phase_exits[0]["call_outcome"] == "raise"
    assert phase_exits[0]["exception_class"] == "FrameRetryExhausted"


# -- request_stop / eject -----------------------------------------------------------


def test_request_stop_calls_roll_safe_stop(monkeypatch: pytest.MonkeyPatch) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    transport.request_stop()

    assert roll.safe_stop_calls == 1


def test_eject_raises_eject_failed_on_import_error(monkeypatch: pytest.MonkeyPatch) -> None:
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.eject_effect = ImportError("python-sane is not installed")

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.EJECT_FAILED


def test_eject_raises_eject_failed_on_coolscanpy_eject_failed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.eject_effect = coolscanpy.EjectFailed("vendor eject command failed")

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.EJECT_FAILED


def test_eject_returns_true_on_success(monkeypatch: pytest.MonkeyPatch) -> None:
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.eject_effect = True
    device.film_present_result = False
    assert transport.eject() is True


def test_eject_false_raises_eject_failed_not_silent_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A capability-gated no-op (Device.eject() -> False) means the film is
    still inside the feeder -- INCIDENT-20260719-eject-from-park forbids
    reporting that as success in any form."""
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.eject_effect = False

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.EJECT_FAILED
    assert "not ejected" in str(excinfo.value)


class _EjectRecordingRoll(_FakeRoll):
    """_FakeRoll plus the Roll.eject() the pinned coolscanpy exposes."""

    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.eject_calls = 0
        self.eject_effect: object = True

    def eject(self) -> bool:
        self.eject_calls += 1
        if isinstance(self.eject_effect, BaseException):
            raise self.eject_effect
        return bool(self.eject_effect)


def test_eject_routes_through_open_roll_and_clears_preview_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With a Roll open, eject goes through Roll.eject() (where the
    vendor-traced held-session eject lands when the pin advances), and a
    confirmed eject invalidates the preview: the film is out, so the
    session must read as previewEstablished=false / slotCount=null and the
    Roll must be closed."""
    roll = _EjectRecordingRoll(thumbnails=[_fake_thumbnail(1), _fake_thumbnail(2)])
    transport, device = _opened_transport(monkeypatch, roll)
    # Any device-route eject would be a routing bug -- make it fail loudly.
    device.eject_effect = AssertionError("device.eject must not be called when a roll is open")
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert transport.status().preview_established is True

    assert transport.eject() is True

    assert roll.eject_calls == 1
    assert roll.closed is True
    status = transport.status()
    assert status.connected is True
    assert status.preview_established is False
    assert status.slot_count is None


def test_eject_falls_back_to_device_when_roll_lacks_eject(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    roll = _FakeRoll(thumbnails=[_fake_thumbnail(1)])
    transport, device = _opened_transport(monkeypatch, roll)
    device.eject_effect = True
    device.film_present_result = False
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    assert transport.eject() is True

    assert roll.closed is True
    assert transport.status().preview_established is False


def test_eject_maps_feeder_parked_stall_and_preserves_session_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """FeederParked from the driver's eject is the typed
    accepted-without-progress outcome (the 2026-07-24 STALLED case): the
    film did NOT come out, so the roll session must stay exactly as it was
    -- no close, no preview invalidation, and no retry from this layer."""
    roll = _EjectRecordingRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = coolscanpy.FeederParked(
        "eject accepted without confirmed clear; power cycle required"
    )
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.FEEDER_PARKED
    assert roll.eject_calls == 1
    assert roll.closed is False
    assert transport.status().preview_established is True


def test_eject_not_available_falls_back_to_device_eject(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Roll.eject() with no held reservation (the state every failed
    preview's fail-closed teardown leaves behind) raises the REAL exported
    coolscanpy.EjectNotAvailable without sending any command -- so the
    transport must try the capability-gated vendor eject on Device instead
    of refusing outright (#16 #68 #76: the refusal used to strand the film
    until a power cycle). Uses the real exception class on purpose: the
    old fake-substitute version of this test could not catch a
    class-identity regression."""
    roll = _EjectRecordingRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = coolscanpy.EjectNotAvailable(
        "no held reservation to eject: call preview() first"
    )
    transport, device = _opened_transport(monkeypatch, roll)
    device.eject_effect = True
    device.film_present_result = False
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    assert transport.eject() is True

    assert roll.eject_calls == 1
    assert roll.closed is True
    assert transport.status().preview_established is False


def test_eject_fallback_failure_stays_typed_and_preserves_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When the Device fallback also fails, the error stays the typed
    EJECT_FAILED of the direct device route -- and the roll session is
    preserved exactly as the FeederParked case preserves it, because the
    film did not come out."""
    roll = _EjectRecordingRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = coolscanpy.EjectNotAvailable("no held reservation to eject")
    transport, device = _opened_transport(monkeypatch, roll)
    device.eject_effect = coolscanpy.EjectFailed("vendor eject command failed")
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.EJECT_FAILED
    assert "vendor eject command failed" in str(excinfo.value)
    assert roll.closed is False
    assert transport.status().preview_established is True


def test_eject_fallback_feeder_parked_maps_typed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A parked transport reported by the fallback vendor eject keeps the
    FEEDER_PARKED taxonomy (never a silent success, never a retry)."""
    roll = _EjectRecordingRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = coolscanpy.EjectNotAvailable("no held reservation to eject")
    transport, device = _opened_transport(monkeypatch, roll)
    device.eject_effect = coolscanpy.FeederParked(
        "eject accepted without confirmed clear; power cycle required"
    )
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.FEEDER_PARKED
    assert roll.closed is False


def test_eject_fallback_device_busy_maps_typed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """DeviceBusy from the fallback vendor eject is a retry-later state,
    not an eject failure -- it must keep its own taxonomy instead of
    collapsing into EJECT_FAILED."""
    roll = _EjectRecordingRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = coolscanpy.EjectNotAvailable("no held reservation to eject")
    transport, device = _opened_transport(monkeypatch, roll)
    device.eject_effect = coolscanpy.DeviceBusy("io lock is held")
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.DEVICE_BUSY
    assert roll.closed is False


def test_vendor_eject_still_present_after_accept_is_feeder_parked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The vendor eject reports acceptance, not actuation
    (INCIDENT-20260719-eject-from-park): a clean scanimage exit with film
    still present is the accepted-without-progress wedge and must surface
    as FEEDER_PARKED, never as success."""
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.eject_effect = True
    device.film_present_result = True

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.FEEDER_PARKED
    assert "still present" in str(excinfo.value)


def test_vendor_eject_unconfirmable_presence_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """film_present() -> None means undetermined -- per its contract it
    must never be read as film-absent, so an unconfirmable vendor eject
    fails closed as EJECT_FAILED."""
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.eject_effect = True
    device.film_present_result = None

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.EJECT_FAILED
    assert "could not be confirmed" in str(excinfo.value)


def test_eject_roll_close_failure_reports_film_out_not_eject_failed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A post-eject Roll.close() failure happens AFTER the film is
    physically out: it must surface as INTERNAL with a message saying so,
    never as an eject failure -- and `_roll` stays set so device.close can
    still run the Roll-then-Device teardown order."""

    class _CloseFailingRoll(_EjectRecordingRoll):
        def close(self) -> None:
            raise RuntimeError("batch worker still reporting")

    roll = _CloseFailingRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = True
    transport, _device = _opened_transport(monkeypatch, roll)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    with pytest.raises(BridgeError) as excinfo:
        transport.eject()

    assert excinfo.value.code == ErrorCode.INTERNAL
    assert "the film was ejected" in str(excinfo.value)
    assert roll.closed is False


def test_eject_after_failed_preview_ejects_via_device_fallback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """End-to-end regression for the #16/#68/#76 shape: preview fails, the
    operator clicks Eject, and the film must come out through the Device
    fallback instead of the guaranteed EjectNotAvailable refusal."""

    class _RefusedPreviewRoll(_EjectRecordingRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.RefeedRequired(
                "preview could not establish a usable roll session"
            )

    roll = _RefusedPreviewRoll(thumbnails=[_fake_thumbnail(1)])
    roll.eject_effect = coolscanpy.EjectNotAvailable(
        "no held reservation to eject: call preview() first"
    )
    transport, device = _opened_transport(monkeypatch, roll)
    device.eject_effect = True
    device.film_present_result = False

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.REFEED_REQUIRED

    assert transport.eject() is True
    assert roll.eject_calls == 1
    assert roll.closed is True


# -- coolscanpy_provenance (Plan 10-09) ---------------------------------------------


def test_coolscanpy_provenance_reports_real_file_and_version() -> None:
    info = coolscanpy_provenance()
    assert info["file"] == coolscanpy.__file__
    assert info["version"] == coolscanpy.__version__
    assert info["head_sha"] is None or isinstance(info["head_sha"], str)


def test_coolscanpy_provenance_reflects_a_monkeypatched_version_string(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(coolscanpy, "__version__", "9.9.9-test-pin")
    assert coolscanpy_provenance()["version"] == "9.9.9-test-pin"


def test_coolscanpy_provenance_head_sha_none_when_git_is_not_installed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _raise_not_found(*args: object, **kwargs: object) -> None:
        raise FileNotFoundError("git not found")

    monkeypatch.setattr(coolscanpy_transport_module.subprocess, "run", _raise_not_found)
    assert coolscanpy_provenance()["head_sha"] is None


def test_coolscanpy_provenance_head_sha_none_when_not_a_git_checkout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class _FakeFailedProcess:
        returncode = 128
        stdout = ""

    monkeypatch.setattr(
        coolscanpy_transport_module.subprocess, "run", lambda *a, **k: _FakeFailedProcess()
    )
    assert coolscanpy_provenance()["head_sha"] is None


def test_coolscanpy_git_head_never_borrows_an_ancestor_checkout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    package_dir = tmp_path / "outer-repo" / "copied-source" / "coolscanpy" / "src" / "coolscanpy"
    package_dir.mkdir(parents=True)
    # Only the unrelated ancestor has a git marker. The component root
    # (<copied-source>/coolscanpy) intentionally does not.
    (tmp_path / "outer-repo" / ".git").mkdir()

    def _must_not_run(*args: object, **kwargs: object) -> object:
        raise AssertionError("git must not inspect an ancestor checkout")

    monkeypatch.setattr(coolscanpy_transport_module.subprocess, "run", _must_not_run)
    assert coolscanpy_transport_module._coolscanpy_git_head_sha(package_dir) is None


def test_coolscanpy_provenance_head_sha_none_when_git_subprocess_times_out(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import subprocess as real_subprocess

    def _raise_timeout(*args: object, **kwargs: object) -> None:
        raise real_subprocess.TimeoutExpired(cmd="git", timeout=5.0)

    monkeypatch.setattr(coolscanpy_transport_module.subprocess, "run", _raise_timeout)
    assert coolscanpy_provenance()["head_sha"] is None


def test_coolscanpy_git_head_sha_present_when_component_git_succeeds(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    package_dir = tmp_path / "coolscanpy" / "src" / "coolscanpy"
    package_dir.mkdir(parents=True)
    (tmp_path / "coolscanpy" / ".git").mkdir()

    class _FakeOkProcess:
        returncode = 0
        stdout = "0123456789abcdef0123456789abcdef01234567\n"

    monkeypatch.setattr(
        coolscanpy_transport_module.subprocess, "run", lambda *a, **k: _FakeOkProcess()
    )
    assert (
        coolscanpy_transport_module._coolscanpy_git_head_sha(package_dir)
        == "0123456789abcdef0123456789abcdef01234567"
    )


# ---------------------------------------------------------------------------
# Adapter identity (#70): status surfaces the page-01h string; a positively
# identified non-strip adapter refuses preview as ADAPTER_UNSUPPORTED.
# ---------------------------------------------------------------------------


def test_preview_raises_adapter_unsupported(monkeypatch: pytest.MonkeyPatch) -> None:
    class _MountAdapterRoll(_FakeRoll):
        def preview(self, slots: list[int] | None = None) -> list["coolscanpy.Thumbnail"]:
            raise coolscanpy.AdapterUnsupported(
                "the inserted MA-21 mount adapter cannot run the strip "
                "preview/scan workflow",
                adapter="Mount",
                supported=("6Strip", "36Strip"),
            )

    transport, _device = _opened_transport(monkeypatch, _MountAdapterRoll())

    with pytest.raises(BridgeError) as excinfo:
        transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    assert excinfo.value.code == ErrorCode.ADAPTER_UNSUPPORTED
    assert "MA-21" in excinfo.value.message


def test_status_reports_adapter_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Identity:
        adapter_ascii = "Mount"

    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    device.adapter_identity = lambda: _Identity()
    assert transport.status().adapter == "Mount"


def test_status_adapter_is_none_when_probe_is_absent_or_failing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # _FakeDevice has no adapter_identity attribute at all: older coolscanpy.
    transport, device = _opened_transport(monkeypatch, _FakeRoll())
    assert transport.status().adapter is None

    # A probe that raises must degrade to None, never propagate from status().
    def _boom() -> object:
        raise RuntimeError("interface is owned by an active capture")

    device.adapter_identity = _boom
    assert transport.status().adapter is None

    # A probe returning None (unreadable identity) also reports None.
    device.adapter_identity = lambda: None
    assert transport.status().adapter is None

    # A non-callable attribute (a broken/mocked dependency) is not a probe;
    # the defensive callable() check keeps the identity honestly unknown.
    device.adapter_identity = "Mount"
    assert transport.status().adapter is None
