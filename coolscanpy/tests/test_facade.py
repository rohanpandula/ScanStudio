"""Hardware-free contracts for the public facade (``coolscanpy.__init__``).

Follows this suite's own convention (see tests/conftest.py): every test
fakes the boundary just below the module under test with small classes
local to this file. The doubles below are adapted from the concrete tests
they mirror -- ``tests/session/test_service.py``'s ``FakeBackend``,
``tests/roll/test_ls5000_roll_session.py``'s synthetic preview raster, and
``tests/protocol/ls5000_single_pass/test_capture_process.py``'s
``FakeRunner``/``FakeBatchProcess`` -- so the facade is exercised against the
same replay-fixture shapes the concrete modules are already tested with, not
a parallel invented double.
"""

from __future__ import annotations

import gc
import hashlib
import functools
import json
import struct
import subprocess
import sys
import threading
import time
import weakref
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Sequence

import numpy as np
import pytest

import coolscanpy
import coolscanpy._device as device_module
import coolscanpy._roll as roll_module
import coolscanpy.transport.adapter_status as adapter_status_module
from coolscanpy._roll import Roll
from coolscanpy.capture.single_pass_workflow import (
    LS5000SinglePassWorkflow,
    PackedCaptureContract,
)
from coolscanpy.protocol.ls5000_single_pass import roll_index
from coolscanpy.protocol.ls5000_single_pass.bundle import CAPTURE_BUNDLE_SHA256
from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    AttemptPaths,
    CANONICAL_FINE_READ_BYTES,
    CANONICAL_FINE_READ_COUNT,
    CaptureAttemptResult,
    CaptureOutcome,
    CaptureProcessAdapter,
    CaptureRequest,
    ManualFrameApproval,
)
from coolscanpy.protocol.ls5000_single_pass.continuation_plan import (
    CANONICAL_CONTINUATION_PLAN_SHA256,
)
from coolscanpy.protocol.ls5000_single_pass.density import (
    DensityCalibration,
    assemble_density_calibration,
    build_nikon_density_evidence,
    build_nikon_density_frame_ownership,
    decode_density_calibration_read,
)
from coolscanpy.protocol.ls5000_single_pass.plan import CANONICAL_PLAN_SHA256
from coolscanpy.receipts.quality import StoppedTransportSmearAssessment
from coolscanpy.session.backend import ScanMode, ScannerCapabilities, ScannerDevice
from coolscanpy.session.params import ScanParams
from coolscanpy.session.result import ScanResult
from coolscanpy.session.service import ScannerService


# ---------------------------------------------------------------------------
# Plain-scan (Device) doubles -- mirrors tests/session/test_service.py's
# FakeBackend.
# ---------------------------------------------------------------------------


class _FakeBackend:
    def __init__(self, devices: list[ScannerDevice] | None = None) -> None:
        self._devices = devices or []
        self.eject_calls: list[str] = []
        self.eject_result: bool = True
        self.eject_error: Exception | None = None
        self.scan_calls: list[ScanParams] = []

    def list_devices(self) -> list[ScannerDevice]:
        return self._devices

    def scan(
        self, device_id: str, params: ScanParams, progress, cancel: threading.Event
    ) -> ScanResult:
        self.scan_calls.append(params)
        if progress:
            progress(0.0)
        if cancel.is_set():
            raise RuntimeError("scan cancelled")
        rgb = np.full((8, 6, 3), 12_000, dtype=np.uint16)
        if progress:
            progress(1.0)
        return ScanResult(rgb=rgb, ir=None, dpi=params.dpi, device_model="Fake LS-5000")

    def eject(self, device_id: str) -> bool:
        device = next((d for d in self._devices if d.id == device_id), None)
        if device is None or not device.capabilities.can_eject:
            return False
        self.eject_calls.append(device_id)
        if self.eject_error is not None:
            raise self.eject_error
        return self.eject_result


_COOLSCAN_ID = "net:scanner:coolscan3:usb:001:002"
_LOCAL_COOLSCAN_ID = "coolscan3:usb:libusb:001:002"


def _caps(**overrides: object) -> ScannerCapabilities:
    values: dict[str, object] = dict(
        ir_channel=True,
        supported_dpi=(1_000, 2_000, 4_000),
        supported_depths=(8, 16),
        sources=(ScanMode.NEGATIVE,),
        multi_sample=True,
        adapter_frame_capacity=40,
        adapter_frame_control=True,
        auto_exposure=True,
        registered_geometry=False,
        can_eject=True,
    )
    values.update(overrides)
    return ScannerCapabilities(**values)


def _coolscan_device(
    *,
    device_id: str = _COOLSCAN_ID,
    **cap_overrides: object,
) -> ScannerDevice:
    return ScannerDevice(
        id=device_id,
        vendor="Nikon",
        model="LS-5000 ED",
        capabilities=_caps(**cap_overrides),
    )


@pytest.fixture(autouse=True)
def _reset_open_device_registry() -> None:
    """The in-process open-device registry is module-level state; keep it
    from leaking between tests."""

    device_module._open_devices.clear()
    yield
    device_module._open_devices.clear()


@pytest.fixture
def fake_service_factory(
    monkeypatch: pytest.MonkeyPatch,
) -> Callable[[list[ScannerDevice]], _FakeBackend]:
    """Monkeypatch coolscanpy's device factory to hand out a ScannerService
    wrapping a fake backend, exactly like ScannerService's own tests do
    (``service._backend = FakeBackend(...)``) -- avoids ever importing
    python-sane or touching hardware."""

    created: dict[str, _FakeBackend] = {}

    def install(devices: list[ScannerDevice]) -> _FakeBackend:
        backend = _FakeBackend(devices)
        created["backend"] = backend

        def factory() -> ScannerService:
            service = ScannerService()
            service._backend = backend
            return service

        monkeypatch.setattr(device_module, "_service_factory", factory)
        monkeypatch.setattr("usb.core.find", lambda **_kwargs: [])
        monkeypatch.setattr(
            "coolscanpy.protocol.ls5000_single_pass.usb_backend.get_libusb_backend",
            lambda: object(),
        )
        return backend

    return install


# ---------------------------------------------------------------------------
# Roll-engine doubles -- mirrors tests/roll/test_ls5000_roll_session.py's
# synthetic index/table encoders and
# tests/protocol/ls5000_single_pass/test_capture_process.py's FakeRunner /
# FakeBatchProcess.
# ---------------------------------------------------------------------------


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _density_calibration_provenance(session_id: str) -> dict[str, object]:
    reads = [
        decode_density_calibration_read(
            bytes.fromhex(cdb),
            bytes.fromhex(payload),
        )
        for cdb, payload in zip(
            (
                "28008c00010300000a80",
                "28008c00020300000a80",
                "28008c00030300000a80",
            ),
            (
                "8c20000000040000df1a",
                "8c20000000040000bba4",
                "8c200000000400007fab",
            ),
            strict=True,
        )
    ]
    calibration = assemble_density_calibration(reads, session_id=session_id)
    return {
        "density_calibration_session_id": session_id,
        "nikon_density_calibration": calibration.to_dict(),
    }


@functools.lru_cache(maxsize=1)
def _density_source_fixture() -> bytes:
    samples = np.concatenate(
        (
            np.full(96, 45_000, dtype=np.uint16),
            np.full(96, 40_000, dtype=np.uint16),
            np.full(96, 32_000, dtype=np.uint16),
        )
    ).astype(">u2")
    row = samples.tobytes() + bytes(448)
    return bytes(100 * 1_024) + row + bytes((6_104 - 101) * 1_024)


@functools.lru_cache(maxsize=40)
def _meter_sidecar_fixture(slot: int) -> bytes:
    """Three exact wire-layout meter passes with frame-specific texture."""

    rows = np.arange(425, dtype=np.uint32)[:, None]
    columns = np.arange(281, dtype=np.uint32)[None, :]
    image = np.empty((425, 281, 4), dtype=np.uint16)
    for channel in range(4):
        image[:, :, channel] = (
            2_000
            + channel * 3_000
            + slot * 101
            + (rows * (31 + channel * 2) + columns * (17 + channel * 4)) % 42_000
        ).astype(np.uint16)
    wire_rows = np.zeros((425, 1_280), dtype=">u2")
    wire_rows[:, : 281 * 4] = image.transpose(0, 2, 1).reshape(425, 281 * 4)
    one_pass = wire_rows.tobytes(order="C")
    assert len(one_pass) == 1_088_000
    return one_pass * 3


def _density_batch_frame_provenance(
    job_path: Path,
    *,
    output: Path,
    frame_index: int,
    selected_slot: int,
) -> tuple[dict[str, object], str, str]:
    job = json.loads(job_path.read_text(encoding="utf-8"))
    session_id = job["session_id"]
    selected_slots = tuple(frame["slot"] for frame in job["frames"])
    first_output = job_path.parent / job["frames"][0]["output"]
    calibration = assemble_density_calibration(
        [
            decode_density_calibration_read(
                bytes.fromhex(f"28008c000{color}0300000a80"),
                bytes.fromhex(payload),
            )
            for color, payload in enumerate(
                (
                    "8c20000000040000df1a",
                    "8c20000000040000bba4",
                    "8c200000000400007fab",
                ),
                start=1,
            )
        ],
        session_id=session_id,
    )
    source = _density_source_fixture()
    evidence = build_nikon_density_evidence(
        source,
        calibration=calibration,
        density_f03_exposures_raw_10ns=(70_307, 136_614, 125_470),
        session_id=session_id,
        capture_attempt_id=first_output.parent.name,
        scan_identity=f"{session_id}:density-97dpi:{_sha256(source)}",
    )
    if frame_index == 1:
        first_output.with_name(f"{first_output.stem}-preview.bin").write_bytes(source)
    table_sha = "2" * 64
    ownership = build_nikon_density_frame_ownership(
        evidence,
        reservation_id=session_id,
        batch_session_id=session_id,
        transport_table_sha256=table_sha,
        reviewed_fingerprint_sha256=job["reviewed_roll_fingerprint"]["binding_sha256"],
        fresh_fingerprint_sha256=job["reviewed_roll_fingerprint"]["binding_sha256"],
        frame_capture_attempt_id=output.parent.name,
        frame_index=frame_index,
        frame_total=len(selected_slots),
        selected_slots=selected_slots,
        selected_slot=selected_slot,
    )
    provenance: dict[str, object] = {
        "nikon_density_frame_ownership": ownership.to_dict()
    }
    if frame_index == 1:
        provenance["nikon_density_evidence"] = evidence.to_dict()
    return provenance, evidence.source_binding.wire_sha256, table_sha


def _encode_index(rgb16: np.ndarray) -> bytes:
    blocks = np.zeros(
        (rgb16.shape[0] // 2, roll_index.INDEX_BLOCK_WORDS), dtype=np.uint16
    )
    blocks[:, 0:96] = rgb16[0::2, :, 0]
    blocks[:, 96:192] = rgb16[0::2, :, 1]
    blocks[:, 192:288] = rgb16[0::2, :, 2]
    blocks[:, 512:608] = rgb16[1::2, :, 0]
    blocks[:, 608:704] = rgb16[1::2, :, 1]
    blocks[:, 704:800] = rgb16[1::2, :, 2]
    blocks[:, 800::2] = roll_index.INDEX_TRAILER_MARK
    blocks[:, 801::2] = np.arange(
        roll_index.INDEX_TRAILER_COUNTER0,
        roll_index.INDEX_TRAILER_COUNTER0 + roll_index.INDEX_TRAILER_WORDS // 2,
        dtype=np.uint16,
    )
    return blocks.astype(">u2", copy=False).tobytes()


def _synthetic_index(*, height: int = 6_104) -> np.ndarray:
    """40 textured cells separated by clear-film gaps (adapted from
    tests/roll/test_ls5000_roll_session.py's ``_synthetic_index``)."""

    pitch = 143
    leader = 128
    boundaries = [leader + index * pitch for index in range(41)]
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
        aperture[boundary - 3 : boundary + 3] = (
            clear_base + clear_noise[boundary - 3 : boundary + 3]
        )
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16)


def _transport_table(rows: int) -> bytes:
    records = bytearray()
    for row in range(rows):
        records.extend(struct.pack(">HH", 6 * (row % 18), row // 18))
    total = 8 + len(records)
    return b"\x00\x8e\x00\x00" + total.to_bytes(2, "big") + b"\x00\x00" + bytes(records)


def _arg(argv: Sequence[str], name: str) -> str:
    return argv[argv.index(name) + 1]


@dataclass
class _PreviewAndBatchWorker:
    """Combined ProcessRunner (preview attempts) + BatchProcessSpawner (fine
    scans) double. Writes real journals/streams the way the real worker
    subprocess would, so ``CaptureProcessAdapter``/``build_roll_preview_session``
    exercise their real validation logic."""

    worker_sha256: str
    events: list[str] = field(default_factory=list)
    preview_argv: list[tuple[str, ...]] = field(default_factory=list)
    preview_started: threading.Event | None = None
    preview_release: threading.Event | None = None

    # -- ProcessRunner (preview) --------------------------------------

    def __call__(
        self, argv: Sequence[str], *, cwd: Path
    ) -> subprocess.CompletedProcess[str]:
        assert "--preview-only" in argv, "this double only fakes preview attempts"
        self.preview_argv.append(tuple(argv))
        if self.preview_started is not None:
            self.preview_started.set()
        if self.preview_release is not None:
            self.preview_release.wait(timeout=5)
        output = Path(_arg(argv, "--output"))
        journal_path = Path(_arg(argv, "--journal"))
        rgb = _synthetic_index()
        preview = _encode_index(rgb)
        table = _transport_table(len(rgb))
        preview_path = cwd / "capture-preview.bin"
        table_path = cwd / "capture-008e.bin"
        mapping_path = cwd / "capture-frame-map.json"
        preview_path.write_bytes(preview)
        table_path.write_bytes(table)
        output.write_bytes(b"")
        preview_binding = {
            "mode": "canonical-40-record",
            "startup_records": 40,
            "native_height": 250_278,
            "decoded_height": 6_104,
            "expected_stream_bytes": 6_250_496,
            "read_count": 48,
            "active_read_sequence_range": [118, 165],
            "skipped_read_sequence_range": None,
        }
        mapping = {
            "status": "preview-only-complete",
            "slot_capacity_hint": 40,
            "slot_capacity_semantics": "scanner-addressable preview slots; not an exposure count",
            "preview_bytes": len(preview),
            "preview_sha256": _sha256(preview),
            "table_bytes": len(table),
            "table_sha256": _sha256(table),
            "frame_detection": "deferred-offline",
            "startup_table": {
                "count": 40,
                "sha256": "a" * 64,
                "status": "0000000000000000",
            },
            "preview_binding": preview_binding,
        }
        mapping_path.write_text(json.dumps(mapping), encoding="utf-8")
        density_session_id = "single-reservation-facade-preview"
        density_exposures = (71_373, 137_524, 126_126)
        density_provenance = _density_calibration_provenance(density_session_id)
        density_evidence = build_nikon_density_evidence(
            preview,
            calibration=DensityCalibration.from_dict(
                density_provenance["nikon_density_calibration"]
            ),
            density_f03_exposures_raw_10ns=density_exposures,
            session_id=density_session_id,
            capture_attempt_id=cwd.name,
            scan_identity=(
                f"{density_session_id}:density-97dpi:{_sha256(preview)}"
            ),
        )
        journal = {
            **density_provenance,
            "status": "complete",
            "capture_mode": "preview-only",
            "requested_frame": None,
            "requested_boundary_offset_rows": 0,
            "expected_frame_count": None,
            "expected_usb_bus": (
                int(_arg(argv, "--expected-usb-bus"))
                if "--expected-usb-bus" in argv
                else None
            ),
            "expected_usb_address": (
                int(_arg(argv, "--expected-usb-address"))
                if "--expected-usb-address" in argv
                else None
            ),
            "actual_usb_bus": (
                int(_arg(argv, "--expected-usb-bus"))
                if "--expected-usb-bus" in argv
                else None
            ),
            "actual_usb_address": (
                int(_arg(argv, "--expected-usb-address"))
                if "--expected-usb-address" in argv
                else None
            ),
            "expected_reads": 0,
            "completed_reads": 0,
            "expected_bytes": 0,
            "completed_bytes": 0,
            "disk_bytes": 0,
            "unit_released": True,
            "recovery_required": None,
            "output": str(output.resolve()),
            "output_sha256": _sha256(b""),
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "capture_engine_sha256": self.worker_sha256,
            "scanner_identity": "Nikon LS-5000 ED 1.03",
            "preview_geometry_validated_before_reads": True,
            "preview_windows": [
                {
                    "color_id": color,
                    "resolution": [97, 97],
                    "origin": [0, 0],
                    "size": [3_946, 250_278],
                    "bit_depth": 16,
                    "density_f03_exposure_raw_10ns": exposure,
                }
                for color, exposure in zip(
                    (1, 2, 3),
                    density_exposures,
                    strict=True,
                )
            ],
            "nikon_density_evidence": density_evidence.to_dict(),
            "live_startup_0x8f": {"count": 40, "sha256": "a" * 64},
            "live_startup_0x8f_status": "0000000000000000",
            "live_preview_binding": preview_binding,
            "live_index_artifacts": {
                "mapping": str(mapping_path.resolve()),
                "preview": str(preview_path.resolve()),
                "table": str(table_path.resolve()),
            },
            "live_index_evidence": {
                "status": "persisted-before-frame-detection",
                "preview_bytes": len(preview),
                "preview_sha256": _sha256(preview),
                "table_bytes": len(table),
                "table_sha256": _sha256(table),
            },
            "preview_only_receipt": mapping,
        }
        journal_path.write_text(json.dumps(journal), encoding="utf-8")
        self.events.append("preview")
        return subprocess.CompletedProcess(list(argv), 0, "", "")


def _roll_identity_payload(reviewed_sha: str, *, slot: int) -> dict[str, Any]:
    return {
        "reviewed_fingerprint_sha256": reviewed_sha,
        "fresh_fingerprint_sha256": reviewed_sha,
        "comparison": {
            "matches": True,
            "reason": "matched",
            "compared_frames": 40,
            "preview_height_delta_rows": 0,
            "visual_median_hamming": 0.0,
            "visual_p90_hamming": 0,
            "frame_start_median_delta_rows": 0.0,
            "frame_start_max_delta_rows": 0,
            "native_origin_median_delta": 0.0,
            "native_origin_max_delta": 0,
            "discriminative_frames": 40,
            "minimum_discriminative_frames": 3,
            "minimum_visual_log_span": 0.5,
        },
        "selected_slot_comparison": {
            "matches": True,
            "reason": "matched",
            "slot": slot,
            "visual_hamming": 0,
            "maximum_visual_hamming": 48,
            "reviewed_visual_log_span": 2.0,
            "fresh_visual_log_span": 2.0,
            "minimum_visual_log_span": 0.5,
        },
    }


@functools.lru_cache(maxsize=1)
def _zero_stream_sha256(size: int) -> str:
    """sha256 of ``size`` NUL bytes, computed in memory (no disk read).

    A packed-stream file created via ``open(path, "xb"); f.truncate(size)``
    without writing anything is a sparse hole that reads back as all zero
    bytes (standard POSIX truncate semantics) -- this equals what the real
    ``stable_hasher`` would compute for that file, without needing to read
    hundreds of megabytes back from disk.
    """

    digest = hashlib.sha256()
    chunk = b"\x00" * (8 * 1024 * 1024)
    remaining = size
    while remaining > 0:
        take = min(remaining, len(chunk))
        digest.update(chunk[:take])
        remaining -= take
    return digest.hexdigest()


_FULL_STREAM_BYTES = CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES


def _fake_decoded_frame() -> np.ndarray:
    """One full-size (height, width, 4) uint16 array the fake decoder always
    returns, regardless of the (sparse, content-irrelevant) stream bytes on
    disk. Cached so every frame in a test reuses the same allocation."""

    cached = getattr(_fake_decoded_frame, "_cache", None)
    if cached is None:
        rng = np.random.default_rng(20260716)
        cached = rng.integers(4_000, 55_000, size=(5_959, 3_946, 4), dtype=np.uint16)
        _fake_decoded_frame._cache = cached
    return cached


def _make_workflow() -> LS5000SinglePassWorkflow:
    """Real contract (so the packed-stream byte count matches the adapter's
    own canonical check), fake decoder + smear assessor + hasher (so no test
    needs a byte-perfect packed stream or a slow full-file hash)."""

    return LS5000SinglePassWorkflow(
        contract=PackedCaptureContract(),
        decoder=lambda _path: (
            _fake_decoded_frame(),
            {
                "padding_validated_records": CANONICAL_FINE_READ_COUNT,
                "rgb_samples_decoded": 4,
                "ir_planes_transferred": 1,
            },
        ),
        smear_assessor=lambda _rgb, *, dpi: StoppedTransportSmearAssessment(
            verdict="clean",
            start_row=None,
            suffix_rows=0,
            minimum_matches=64,
            tail_median_rms=None,
            tail_min_corr=None,
            pre_tail_median_rms=None,
            texture_span=1_234.0,
            reason="unit-test clean",
        ),
        # NOT overriding stable_hasher: the real hasher's output must agree
        # with write_full_negative_tiff's own (also real) reported TIFF
        # hashes, which _verify_outputs cross-checks. The packed stream is a
        # sparse file (see _FULL_STREAM_BYTES truncate() below), so hashing
        # it is memory-bandwidth-bound, not disk-bound, and stays fast.
    )


@dataclass
class _FakeBatchProcess:
    """RunningBatchProcess double: emits one frame at a time, waiting for the
    parent's ack file before advancing -- mirrors
    tests/protocol/ls5000_single_pass/test_capture_process.py's
    FakeBatchProcess."""

    job_path: Path
    session_journal_path: Path
    events: list[str]
    stop_after_index: int | None = None

    def __post_init__(self) -> None:
        self.job = json.loads(self.job_path.read_text(encoding="utf-8"))
        self.index = 0
        self.returncode: int | None = None
        self._emit_frame()

    def _emit_frame(self) -> None:
        frame = self.job["frames"][self.index]
        directory = self.job_path.parent
        output = directory / frame["output"]
        journal_path = directory / frame["journal"]
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("xb") as stream:
            stream.truncate(_FULL_STREAM_BYTES)
        meter_path = output.with_name(f"{output.stem}-meter.bin")
        meter_payload = _meter_sidecar_fixture(frame["slot"])
        meter_path.write_bytes(meter_payload)
        output_sha256 = _zero_stream_sha256(_FULL_STREAM_BYTES)
        reviewed_sha = self.job["reviewed_roll_fingerprint"]["binding_sha256"]
        density, density_preview_sha, density_table_sha = (
            _density_batch_frame_provenance(
                self.job_path,
                output=output,
                frame_index=self.index + 1,
                selected_slot=frame["slot"],
            )
        )
        if self.index == 0:
            self.density_evidence_receipt = density["nikon_density_evidence"]
        journal = {
            **_density_calibration_provenance(self.job["session_id"]),
            **density,
            "ack_nonce": f"nonce-{frame['slot']}",
            "batch_session": {
                "frame_index": self.index + 1,
                "frame_total": len(self.job["frames"]),
                "selected_slots": [item["slot"] for item in self.job["frames"]],
                "session_id": self.job["session_id"],
            },
            "capture_engine_sha256": _sha256(_FAKE_WORKER_SOURCE),
            "capture_mode": "full",
            "expected_usb_bus": self.job["expected_usb_bus"],
            "expected_usb_address": self.job["expected_usb_address"],
            "actual_usb_bus": self.job["expected_usb_bus"],
            "actual_usb_address": self.job["expected_usb_address"],
            "completed_bytes": _FULL_STREAM_BYTES,
            "completed_reads": CANONICAL_FINE_READ_COUNT,
            "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
            "disk_bytes": _FULL_STREAM_BYTES,
            "expected_bytes": _FULL_STREAM_BYTES,
            "expected_reads": CANONICAL_FINE_READ_COUNT,
            "frame_complete": True,
            "status": "frame-complete",
            "unit_released": False,
            "recovery_required": None,
            "output": str(output.resolve()),
            "output_sha256": output_sha256,
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "requested_frame": frame["slot"],
            "requested_boundary_offset_rows": frame["boundary_offset_rows"],
            "applied_boundary_offset_rows": frame["boundary_offset_rows"],
            "resolved_lookup_row": 2_400 + frame["boundary_offset_rows"],
            "resolved_native_origin": 100_000 + frame["slot"],
            "scanner_identity": "Nikon LS-5000 ED 1.03",
            "preview_geometry_validated_before_reads": True,
            "session_reservation_retained": True,
            "reviewed_roll_fingerprint_sha256": reviewed_sha,
            "manual_review_approval": frame["manual_review_approval"],
            "live_frame_selection": {
                "frame": frame["slot"],
                "preview_sha256": density_preview_sha,
                "table_sha256": density_table_sha,
                "detection": {"confidence": "automatic", "frame_count": 40},
                "transport_mapping": {"status": "resolved"},
                "roll_identity": _roll_identity_payload(
                    reviewed_sha, slot=frame["slot"]
                ),
                "selected": {
                    "automatic": frame["manual_review_approval"] is None,
                    "manual_review": frame["manual_review_approval"] is not None,
                    "frame": frame["slot"],
                    "native_origin": 100_000 + frame["slot"],
                    "method": "explicit-addressable-slot",
                    "selector": 1,
                    "code": 1,
                    "lookup_row": 2_400 + frame["boundary_offset_rows"],
                },
            },
            "fine_set_windows_preflight": [
                {
                    "color_id": color,
                    "resolution": [4_000, 4_000],
                    "origin": [0, 100_000 + frame["slot"]],
                    "size": [3_946, 5_959],
                    "samples": 4,
                    "exposure_raw_10ns": 100_000 + color,
                }
                for color in (1, 2, 3, 9)
            ],
            "fine_windows": [
                {
                    "color_id": color,
                    "resolution": [4_000, 4_000],
                    "origin": [0, 100_000 + frame["slot"]],
                    "size": [3_946, 5_959],
                    "samples": 4,
                    "exposure_raw_10ns": 100_000 + color,
                    "interleave": 64,
                }
                for color in (1, 2, 3, 9)
            ],
            "meter_controller_final_result": {
                "accepted": True,
                "final_exposures_raw_10ns": {
                    "R": 100_001,
                    "G": 100_002,
                    "B": 100_003,
                    "IR": 100_009,
                },
                "steps": [
                    {
                        "observation": {
                            "exposures_raw_10ns": {
                                "R": 100_001,
                                "G": 100_002,
                                "B": 100_003,
                                "IR": 100_009,
                            }
                        }
                    }
                ],
            },
            "meter_layout": {
                "passes": 3,
                "rows_per_pass": 425,
                "columns": 281,
                "decoded_raster_channel_order": ["R", "G", "B", "IR"],
                "wire_window_color_order": [9, 1, 2, 3],
                "wire_color_to_controller_channel": {
                    "9": "IR",
                    "1": "R",
                    "2": "G",
                    "3": "B",
                },
                "sample_byte_order": "big-endian-u16",
                "row_core_bytes": 2_248,
                "row_stride_bytes": 2_560,
                "row_tail_bytes": 312,
            },
            "meter_completed_reads": 15,
            "meter_completed_bytes": len(meter_payload),
            "meter_group_bytes": [1_088_000, 1_088_000, 1_088_000],
            "meter_group_offsets": [0, 1_088_000, 2_176_000],
            "meter_evidence": {
                "path": str(meter_path.resolve()),
                "bytes": len(meter_payload),
                "sha256": _sha256(meter_payload),
                "complete": True,
                "durable_completed_passes": 3,
            },
            "meter_evidence_persisted_before_fine_arm": True,
            "meter_observed_exposures_raw_10ns": [
                {"1": 100_001, "2": 100_002, "3": 100_003, "9": 100_009}
                for _ in range(3)
            ],
            "meter_pass_exposures_raw_10ns": [
                {"1": 100_001, "2": 100_002, "3": 100_003, "9": 100_009}
                for _ in range(3)
            ],
            "meter_pass_commanded_exposures": [
                {
                    "pass": meter_pass,
                    "controller_channels_raw_10ns": {
                        "R": 100_001,
                        "G": 100_002,
                        "B": 100_003,
                        "IR": 100_009,
                    },
                    "wire_colors_raw_10ns": {
                        "1": 100_001,
                        "2": 100_002,
                        "3": 100_003,
                        "9": 100_009,
                    },
                }
                for meter_pass in range(1, 4)
            ],
            "meter_final_exposures": {
                "controller_channels_raw_10ns": {
                    "R": 100_001,
                    "G": 100_002,
                    "B": 100_003,
                    "IR": 100_009,
                },
                "wire_colors_raw_10ns": {
                    "1": 100_001,
                    "2": 100_002,
                    "3": 100_003,
                    "9": 100_009,
                },
            },
            # The guarded nikon-parity solve is the RGB command authority;
            # this fixture's parity solve happens to equal the active solve,
            # which is a legal (unclamped, unguarded) state.
            "active_exposure_authority": {
                "rgb_source": "nikon-parity-guarded-v2",
                "ir_source": "active-controller",
                "commanded_channels_raw_10ns": {
                    "R": 100_001,
                    "G": 100_002,
                    "B": 100_003,
                    "IR": 100_009,
                },
                "active_controller_channels_raw_10ns": {
                    "R": 100_001,
                    "G": 100_002,
                    "B": 100_003,
                    "IR": 100_009,
                },
                "device_bound_clamped_channels_raw_10ns": {},
                "device_exposure_bounds_raw_10ns": [50_000, 400_000],
            },
        }
        journal_path.write_text(json.dumps(journal), encoding="utf-8")
        self.events.append(f"ready-{frame['slot']}")

    def poll(self) -> int | None:
        if self.returncode is not None:
            return self.returncode
        frame = self.job["frames"][self.index]
        ack_path = self.job_path.parent / frame["ack"]
        if not ack_path.exists():
            return None
        ack = json.loads(ack_path.read_text(encoding="utf-8"))
        self.events.append(f"ack-{frame['slot']}-{ack['action']}")
        forced_stop = (
            self.stop_after_index is not None and self.index >= self.stop_after_index
        )
        if (
            ack["action"] == "continue"
            and not forced_stop
            and self.index + 1 < len(self.job["frames"])
        ):
            self.index += 1
            self._emit_frame()
            return None
        completed = [item["slot"] for item in self.job["frames"][: self.index + 1]]
        self.session_journal_path.write_text(
            json.dumps(
                {
                    **_density_calibration_provenance(self.job["session_id"]),
                    "nikon_density_evidence": self.density_evidence_receipt,
                    "batch_job_sha256": _sha256(self.job_path.read_bytes()),
                    "capture_bundle_sha256": CAPTURE_BUNDLE_SHA256,
                    "capture_engine_sha256": _sha256(_FAKE_WORKER_SOURCE),
                    "expected_usb_bus": self.job["expected_usb_bus"],
                    "expected_usb_address": self.job["expected_usb_address"],
                    "actual_usb_bus": self.job["expected_usb_bus"],
                    "actual_usb_address": self.job["expected_usb_address"],
                    "manual_review_approval_sha256_by_slot": {
                        str(item["slot"]): (
                            None
                            if item["manual_review_approval"] is None
                            else item["manual_review_approval"]["binding_sha256"]
                        )
                        for item in self.job["frames"]
                    },
                    "reviewed_roll_fingerprint_sha256": self.job[
                        "reviewed_roll_fingerprint"
                    ]["binding_sha256"],
                    "completed_slots": completed,
                    "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
                    "plan_sha256": CANONICAL_PLAN_SHA256,
                    "recovery_required": "none",
                    "reservation_acquired": True,
                    "selected_slots": [item["slot"] for item in self.job["frames"]],
                    "session_id": self.job["session_id"],
                    "status": "stopped"
                    if ack["action"] == "stop" or forced_stop
                    else "complete",
                    "unit_release_attempts": 1,
                    "unit_released": True,
                }
            ),
            encoding="utf-8",
        )
        self.returncode = 0
        return 0

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        while self.poll() is None:
            time.sleep(0.001)
        return int(self.returncode)


@dataclass
class _GatedBatchProcess(_FakeBatchProcess):
    """``_FakeBatchProcess`` that withholds every frame after the first
    until released, so streaming-vs-buffering is observable by event order
    rather than by a wall-clock race."""

    release_after_first: threading.Event = field(default_factory=threading.Event)

    def _emit_frame(self) -> None:
        if self.index >= 1:
            self.release_after_first.wait(timeout=5)
        super()._emit_frame()


@dataclass
class _RefusalBatchProcess:
    """RunningBatchProcess double that refuses before any frame is
    captured -- mirrors
    test_terminal_batch_receipt_wakes_parent_before_repeated_process_polling."""

    job_path: Path
    session_journal_path: Path
    message: str

    def __post_init__(self) -> None:
        job = json.loads(self.job_path.read_text(encoding="utf-8"))
        self.session_journal_path.write_text(
            json.dumps(
                {
                    **_density_calibration_provenance(job["session_id"]),
                    "batch_job_sha256": _sha256(self.job_path.read_bytes()),
                    "capture_bundle_sha256": CAPTURE_BUNDLE_SHA256,
                    "capture_engine_sha256": _sha256(_FAKE_WORKER_SOURCE),
                    "expected_usb_bus": job["expected_usb_bus"],
                    "expected_usb_address": job["expected_usb_address"],
                    "actual_usb_bus": job["expected_usb_bus"],
                    "actual_usb_address": job["expected_usb_address"],
                    "manual_review_approval_sha256_by_slot": {
                        str(item["slot"]): (
                            None
                            if item["manual_review_approval"] is None
                            else item["manual_review_approval"]["binding_sha256"]
                        )
                        for item in job["frames"]
                    },
                    "reviewed_roll_fingerprint_sha256": job[
                        "reviewed_roll_fingerprint"
                    ]["binding_sha256"],
                    "completed_slots": [],
                    "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
                    "plan_sha256": CANONICAL_PLAN_SHA256,
                    "recovery_required": "none",
                    "reservation_acquired": True,
                    "selected_slots": [item["slot"] for item in job["frames"]],
                    "session_id": job["session_id"],
                    "status": "failed",
                    "error": self.message,
                    "finished_unix": 0.0,
                    "unit_release_attempts": 1,
                    "unit_released": True,
                }
            ),
            encoding="utf-8",
        )
        self.returncode = 1

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        return self.returncode


_FAKE_WORKER_SOURCE = b"# fake external capture worker\n"


def _adapter(
    tmp_path: Path, worker: _PreviewAndBatchWorker, *, batch_spawner
) -> CaptureProcessAdapter:
    worker_path = tmp_path / "worker.py"
    worker_path.write_bytes(_FAKE_WORKER_SOURCE)
    # expected_worker_sha256 is checked against the real bytes on disk, so it
    # must be derived from them, not chosen independently.
    worker.worker_sha256 = _sha256(_FAKE_WORKER_SOURCE)
    manifest_path = tmp_path / "replay-first-rgbi4-manifest.json"
    manifest_path.write_text(
        json.dumps({"plan_sha256": CANONICAL_PLAN_SHA256}), encoding="utf-8"
    )
    return CaptureProcessAdapter(
        worker_path=worker_path,
        expected_worker_sha256=worker.worker_sha256,
        manifest_path=manifest_path,
        attempts_root=tmp_path / "attempts",
        python_executable=sys.executable,
        runner=worker,
        batch_spawner=batch_spawner,
    )


def _make_roll(
    tmp_path: Path,
    device: "coolscanpy.Device",
    *,
    material: "coolscanpy.Material" = coolscanpy.Material.COLOR_NEGATIVE,
    batch_spawner,
    preview_started: threading.Event | None = None,
    preview_release: threading.Event | None = None,
) -> tuple[Roll, _PreviewAndBatchWorker]:
    worker = _PreviewAndBatchWorker(
        worker_sha256="",
        preview_started=preview_started,
        preview_release=preview_release,
    )
    adapter = _adapter(tmp_path, worker, batch_spawner=batch_spawner)
    roll = Roll(
        device,
        material,
        adapter=adapter,
        workflow=_make_workflow(),
        attempts_root=tmp_path / "attempts",
    )
    return roll, worker


def _success_spawner(events: list[str], *, stop_after_index: int | None = None):
    def spawn(
        argv: Sequence[str], *, cwd: Path, stdout: object, stderr: object
    ) -> _FakeBatchProcess:
        del cwd, stdout, stderr
        job_path = Path(_arg(argv, "--batch-job"))
        session_journal_path = Path(_arg(argv, "--session-journal"))
        return _FakeBatchProcess(
            job_path, session_journal_path, events, stop_after_index=stop_after_index
        )

    return spawn


def _tampered_meter_spawner(events: list[str], *, tamper: str):
    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> _FakeBatchProcess:
        del cwd, stdout, stderr
        job_path = Path(_arg(argv, "--batch-job"))
        session_journal_path = Path(_arg(argv, "--session-journal"))
        process = _FakeBatchProcess(job_path, session_journal_path, events)
        frame = process.job["frames"][0]
        output = job_path.parent / frame["output"]
        meter_path = output.with_name(f"{output.stem}-meter.bin")
        journal_path = job_path.parent / frame["journal"]
        if tamper == "missing":
            meter_path.unlink()
        elif tamper == "digest":
            payload = bytearray(meter_path.read_bytes())
            payload[-1] ^= 1
            meter_path.write_bytes(payload)
        elif tamper == "final-exposure":
            journal = json.loads(journal_path.read_text(encoding="utf-8"))
            journal["meter_final_exposures"]["wire_colors_raw_10ns"]["1"] += 1
            journal_path.write_text(json.dumps(journal), encoding="utf-8")
        else:  # pragma: no cover - test helper guard
            raise AssertionError(f"unknown meter tamper {tamper}")
        return process

    return spawn


def _refusal_spawner(message: str):
    def spawn(
        argv: Sequence[str], *, cwd: Path, stdout: object, stderr: object
    ) -> _RefusalBatchProcess:
        del cwd, stdout, stderr
        job_path = Path(_arg(argv, "--batch-job"))
        session_journal_path = Path(_arg(argv, "--session-journal"))
        return _RefusalBatchProcess(job_path, session_journal_path, message)

    return spawn


def _gated_spawner(events: list[str], gate: threading.Event):
    def spawn(
        argv: Sequence[str], *, cwd: Path, stdout: object, stderr: object
    ) -> _GatedBatchProcess:
        del cwd, stdout, stderr
        job_path = Path(_arg(argv, "--batch-job"))
        session_journal_path = Path(_arg(argv, "--session-journal"))
        return _GatedBatchProcess(
            job_path, session_journal_path, events, release_after_first=gate
        )

    return spawn


def _open_device(fake_service_factory, **cap_overrides: object) -> "coolscanpy.Device":
    fake_service_factory(
        [_coolscan_device(device_id=_LOCAL_COOLSCAN_ID, **cap_overrides)]
    )
    return coolscanpy.open("ls5000")


# ===========================================================================
# get_devices() / open() errors
# ===========================================================================


class TestOpenErrors:
    def test_get_devices_filters_to_coolscan_only(self, fake_service_factory) -> None:
        other = ScannerDevice(
            id="pieusb:usb:001",
            vendor="Reflecta",
            model="Flatbed",
            capabilities=_caps(),
        )
        fake_service_factory([_coolscan_device(), other])

        devices = coolscanpy.get_devices()

        assert [d.id for d in devices] == [_COOLSCAN_ID]

    def test_open_ls5000_alias_with_no_devices_raises_device_not_found(
        self, fake_service_factory, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        fake_service_factory([])
        # Device discovery deliberately falls back from SANE to direct USB.
        # Keep this unit test hermetic even when a real LS-5000 is attached to
        # the host running the suite.
        monkeypatch.setattr(device_module, "_usb_fallback_device_infos", list)

        with pytest.raises(coolscanpy.DeviceNotFound):
            coolscanpy.open("ls5000")

    def test_open_ls5000_alias_ambiguous_with_two_devices_raises_device_not_found(
        self, fake_service_factory
    ) -> None:
        second = ScannerDevice(
            id="net:scanner:coolscan3:usb:2",
            vendor="Nikon",
            model="LS-5000 ED",
            capabilities=_caps(),
        )
        fake_service_factory([_coolscan_device(), second])

        with pytest.raises(coolscanpy.DeviceNotFound):
            coolscanpy.open("ls5000")

    def test_open_exact_id_not_found_raises_device_not_found(
        self, fake_service_factory
    ) -> None:
        fake_service_factory([_coolscan_device()])

        with pytest.raises(coolscanpy.DeviceNotFound):
            coolscanpy.open("no-such-device")

    def test_open_same_device_twice_raises_device_busy(
        self, fake_service_factory
    ) -> None:
        fake_service_factory([_coolscan_device()])

        first = coolscanpy.open("ls5000")
        try:
            with pytest.raises(coolscanpy.DeviceBusy):
                coolscanpy.open("ls5000")
        finally:
            first.close()

    def test_close_then_reopen_succeeds(self, fake_service_factory) -> None:
        fake_service_factory([_coolscan_device()])

        first = coolscanpy.open("ls5000")
        first.close()
        second = coolscanpy.open("ls5000")
        second.close()

    def test_device_context_manager_releases_on_exit(
        self, fake_service_factory
    ) -> None:
        fake_service_factory([_coolscan_device()])

        with coolscanpy.open("ls5000"):
            pass

        # released: opening again does not raise DeviceBusy
        again = coolscanpy.open("ls5000")
        again.close()

    def test_device_close_is_idempotent(self, fake_service_factory) -> None:
        fake_service_factory([_coolscan_device()])

        dev = coolscanpy.open("ls5000")
        dev.close()
        dev.close()  # must not raise


# ===========================================================================
# Device methods refuse to run after close()
# ===========================================================================


class TestDeviceClosedRaises:
    def test_scan_after_close_raises_runtime_error(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory)
        dev.close()

        with pytest.raises(RuntimeError, match="has been closed"):
            dev.scan()

    def test_roll_after_close_raises_runtime_error(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory)
        dev.close()

        with pytest.raises(RuntimeError, match="has been closed"):
            dev.roll()

    def test_eject_after_close_raises_runtime_error(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory, can_eject=True)
        dev.close()

        with pytest.raises(RuntimeError, match="has been closed"):
            dev.eject()

    def test_film_present_after_close_raises_runtime_error(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory)
        dev.close()

        with pytest.raises(RuntimeError, match="has been closed"):
            dev.film_present()


# ===========================================================================
# Device option introspection / get / set
# ===========================================================================


class TestDeviceOptions:
    def test_option_names_is_fixed_sane_shaped_list(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory)
        try:
            assert dev.option_names == [
                "resolution",
                "depth",
                "samples",
                "autofocus",
                "auto_exposure",
            ]
        finally:
            dev.close()

    def test_getitem_resolution_describes_constraint_from_capabilities(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            option = dev["resolution"]
            assert option.name == "resolution"
            assert option.type == coolscanpy.OptionType.INT
            assert option.unit == coolscanpy.OptionUnit.DPI
            assert option.constraint == (1_000, 2_000, 4_000)
            assert option.active is True
            assert option.settable is True
        finally:
            dev.close()

    def test_getitem_unknown_option_raises_key_error(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            with pytest.raises(KeyError):
                dev["not-a-real-option"]
        finally:
            dev.close()

    def test_getitem_auto_exposure_reflects_capability_gating(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory, auto_exposure=False)
        try:
            option = dev["auto_exposure"]
            assert option.active is False
            assert option.settable is False
        finally:
            dev.close()

    def test_set_valid_resolution_succeeds(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory)
        try:
            dev.resolution = 2_000
            assert dev.resolution == 2_000
        finally:
            dev.close()

    def test_set_invalid_resolution_raises_value_error(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            with pytest.raises(ValueError):
                dev.resolution = 12_345
        finally:
            dev.close()

    def test_set_samples_without_multi_sample_capability_raises(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory, multi_sample=False)
        try:
            with pytest.raises(ValueError):
                dev.samples = 4
        finally:
            dev.close()

    def test_set_auto_exposure_without_capability_raises(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory, auto_exposure=False)
        try:
            with pytest.raises(ValueError):
                dev.auto_exposure = True
        finally:
            dev.close()

    def test_set_autofocus_wrong_type_raises_type_error(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            with pytest.raises(TypeError):
                dev.autofocus = "yes"
        finally:
            dev.close()


# ===========================================================================
# Device.scan() / cancel() / eject()
# ===========================================================================


class TestDeviceScanAndEject:
    def test_scan_returns_uint16_hxwx3_array(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory)
        try:
            rgb = dev.scan()
            assert rgb.dtype == np.uint16
            assert rgb.ndim == 3 and rgb.shape[2] == 3
        finally:
            dev.close()

    def test_concurrent_scan_raises_device_busy(self, fake_service_factory) -> None:
        backend = fake_service_factory([_coolscan_device()])
        backend.scan_calls  # noqa: B018 - just confirm attribute exists
        dev = coolscanpy.open("ls5000")
        try:
            release = threading.Event()
            started = threading.Event()
            original_scan = dev._service.run_scan

            def blocking_scan(*args, **kwargs):
                started.set()
                release.wait(timeout=2)
                return original_scan(*args, **kwargs)

            dev._service.run_scan = blocking_scan
            worker = threading.Thread(target=dev.scan)
            worker.start()
            started.wait(timeout=2)
            try:
                with pytest.raises(coolscanpy.DeviceBusy):
                    dev.scan()
            finally:
                release.set()
                worker.join(timeout=2)
        finally:
            dev.close()

    def test_eject_returns_false_when_capability_absent(
        self, fake_service_factory
    ) -> None:
        backend = fake_service_factory([_coolscan_device(can_eject=False)])
        dev = coolscanpy.open("ls5000")
        try:
            assert dev.eject() is False
            assert backend.eject_calls == []
        finally:
            dev.close()

    def test_eject_delegates_to_backend_when_capable(
        self, fake_service_factory
    ) -> None:
        backend = fake_service_factory([_coolscan_device(can_eject=True)])
        dev = coolscanpy.open("ls5000")
        try:
            assert dev.eject() is True
            assert backend.eject_calls == [_COOLSCAN_ID]
        finally:
            dev.close()

    def test_eject_failure_raises_eject_failed(self, fake_service_factory) -> None:
        backend = fake_service_factory([_coolscan_device(can_eject=True)])
        backend.eject_error = RuntimeError("transport hiccup")
        dev = coolscanpy.open("ls5000")
        try:
            with pytest.raises(coolscanpy.EjectFailed):
                dev.eject()
        finally:
            dev.close()


class TestDeviceFilmPresent:
    @pytest.mark.parametrize(
        ("probe_value", "expected"),
        ((True, True), (False, False), (None, None)),
    )
    def test_film_presence_passes_exact_device_id_and_tristate(
        self,
        fake_service_factory,
        monkeypatch: pytest.MonkeyPatch,
        probe_value: bool | None,
        expected: bool | None,
    ) -> None:
        dev = _open_device(fake_service_factory)
        device_ids: list[str] = []

        def probe(*, device_id: str):
            device_ids.append(device_id)
            return adapter_status_module.AdapterStatus(
                film_present=probe_value,
                frame_capacity=40 if probe_value is True else None,
                raw_status=(
                    "000000"
                    if probe_value is True
                    else "023a00"
                    if probe_value is False
                    else None
                ),
            )

        monkeypatch.setattr(adapter_status_module, "probe_adapter_status", probe)
        try:
            assert dev.film_present() is expected
            assert device_ids == [_LOCAL_COOLSCAN_ID]
        finally:
            dev.close()

    def test_film_presence_cannot_race_an_in_process_capture(
        self,
        fake_service_factory,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        dev = _open_device(fake_service_factory)
        probed = False

        def forbidden_probe(**_kwargs: object):
            nonlocal probed
            probed = True
            raise AssertionError("a busy Device must not open raw USB")

        monkeypatch.setattr(
            adapter_status_module,
            "probe_adapter_status",
            forbidden_probe,
        )
        assert dev._lock.acquire(blocking=False)
        try:
            with pytest.raises(coolscanpy.DeviceBusy, match="film status"):
                dev.film_present()
            assert probed is False
        finally:
            dev._lock.release()
            dev.close()

    def test_second_roll_while_first_open_raises_device_busy(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            first = dev.roll()
            try:
                with pytest.raises(coolscanpy.DeviceBusy):
                    dev.roll()
            finally:
                first.close()
        finally:
            dev.close()

    def test_roll_context_manager_releases_reservation_exactly_once(
        self, fake_service_factory
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            with dev.roll() as roll:
                assert isinstance(roll, Roll)
            # released: a second roll() succeeds immediately after
            second = dev.roll()
            second.close()
        finally:
            dev.close()

    def test_roll_close_is_idempotent(self, fake_service_factory) -> None:
        dev = _open_device(fake_service_factory)
        try:
            roll = dev.roll()
            roll.close()
            roll.close()  # must not raise
            # and the reservation really was released
            again = dev.roll()
            again.close()
        finally:
            dev.close()

    def test_caller_owned_attempts_root_survives_roll_close(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        evidence = tmp_path / "retained-attempts"
        evidence.mkdir()
        marker = evidence / "marker.txt"
        marker.write_text("retain", encoding="utf-8")
        dev = _open_device(fake_service_factory)
        try:
            roll = dev.roll(attempts_root=evidence)
            assert roll._attempts_root == evidence
            roll.close()
            assert marker.read_text(encoding="utf-8") == "retain"
        finally:
            dev.close()

    def test_default_attempts_root_is_removed_on_roll_close(
        self,
        fake_service_factory,
    ) -> None:
        dev = _open_device(fake_service_factory)
        try:
            roll = dev.roll()
            attempts = roll._attempts_root
            assert attempts.is_dir()
            roll.close()
            assert not attempts.exists()
        finally:
            dev.close()

    def test_device_close_refuses_while_a_roll_is_open(
        self,
        fake_service_factory,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll = dev.roll()
        try:
            with pytest.raises(coolscanpy.DeviceBusy, match="close the Roll"):
                dev.close()
            assert dev._closed is False
        finally:
            roll.close()
            dev.close()


# ===========================================================================
# Roll.preview() / spacing offset / approval / fingerprint
# ===========================================================================


class TestRollPreview:
    def test_preview_surfaces_typed_pre_dispatch_bootstrap_failure(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempt_dir = tmp_path / "attempts" / "bootstrap-failure"
        attempt_dir.mkdir(parents=True)
        paths = AttemptPaths(
            directory=attempt_dir,
            output=attempt_dir / "capture.bin",
            journal=attempt_dir / "journal.json",
            plan=attempt_dir / "replay-first-rgbi4-plan.jsonl",
            manifest=attempt_dir / "replay-first-rgbi4-manifest.json",
            bootstrap_status=attempt_dir / "worker-bootstrap.json",
            stdout=attempt_dir / "stdout.txt",
            stderr=attempt_dir / "stderr.txt",
        )

        def bootstrap_failed(request: CaptureRequest) -> CaptureAttemptResult:
            return CaptureAttemptResult(
                outcome=CaptureOutcome.BOOTSTRAP_FAILED,
                request=request,
                paths=paths,
                argv=(),
                returncode=1,
                stdout="",
                stderr="",
                journal=None,
                journal_error=(
                    "CAPTURE_WORKER_BOOTSTRAP_FAILED: bundled capture worker "
                    "failed before scanner dispatch (ModuleNotFoundError): "
                    "No module named 'coolscanpy'"
                ),
            )

        assert roll._adapter is not None
        roll._adapter.run_attempt = bootstrap_failed  # type: ignore[method-assign]
        try:
            with pytest.raises(coolscanpy.CaptureWorkerBootstrapFailed) as excinfo:
                roll.preview()
        finally:
            roll.close()
            dev.close()

        assert "CAPTURE_WORKER_BOOTSTRAP_FAILED" in str(excinfo.value)
        assert "ModuleNotFoundError" in str(excinfo.value)
        assert "No module named 'coolscanpy'" in str(excinfo.value)

    def test_caller_owned_attempts_root_retains_generated_preview_evidence(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
        )
        try:
            roll.preview()
        finally:
            roll.close()
            dev.close()

        evidence = tmp_path / "attempts"
        assert list(evidence.rglob("capture-preview.bin"))
        assert list(evidence.rglob("capture-008e.bin"))
        assert list(evidence.rglob("journal.json"))

    def test_roll_close_has_a_bounded_wait_for_an_unresponsive_preview(
        self, fake_service_factory, tmp_path: Path, monkeypatch
    ) -> None:
        monkeypatch.setattr(roll_module, "_SCAN_WORKER_JOIN_TIMEOUT_SECONDS", 0.05)
        preview_started = threading.Event()
        preview_release = threading.Event()
        dev = _open_device(fake_service_factory)
        assert dev._roll_lock.acquire(blocking=False)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
            preview_started=preview_started,
            preview_release=preview_release,
        )
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-on-unresponsive-preview"
        sentinel.write_text("retain", encoding="utf-8")
        preview_errors: list[BaseException] = []
        close_errors: list[BaseException] = []

        def run_preview() -> None:
            try:
                roll.preview()
            except BaseException as error:
                preview_errors.append(error)

        def close_roll() -> None:
            try:
                roll.close()
            except BaseException as error:
                close_errors.append(error)

        preview_thread = threading.Thread(target=run_preview)
        closer = threading.Thread(target=close_roll)
        try:
            preview_thread.start()
            assert preview_started.wait(timeout=10)
            closer.start()
            closer.join(timeout=5)

            assert not closer.is_alive(), "Roll.close() exceeded its preview deadline"
            assert len(close_errors) == 1
            assert isinstance(close_errors[0], coolscanpy.DeviceBusy)
            assert preview_errors == []
            assert sentinel.exists()
            assert roll._closed is False
            assert roll._preview_active is True
            with pytest.raises(coolscanpy.DeviceBusy, match="close the Roll"):
                dev.close()
        finally:
            preview_release.set()
            preview_thread.join(timeout=10)
            closer.join(timeout=10)
            roll.close()
            dev.close()

    def test_preview_blocks_a_concurrent_plain_scan(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        preview_started = threading.Event()
        preview_release = threading.Event()
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
            preview_started=preview_started,
            preview_release=preview_release,
        )
        failure: list[BaseException] = []

        def run_preview() -> None:
            try:
                roll.preview()
            except BaseException as error:  # pragma: no cover - test relay
                failure.append(error)

        preview_thread = threading.Thread(target=run_preview)
        preview_thread.start()
        assert preview_started.wait(timeout=2)
        try:
            with pytest.raises(coolscanpy.DeviceBusy):
                dev.scan()
        finally:
            preview_release.set()
            preview_thread.join(timeout=5)
            roll.close()
            dev.close()
        assert not preview_thread.is_alive()
        assert failure == []

    def test_preview_blocks_a_concurrent_eject(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        preview_started = threading.Event()
        preview_release = threading.Event()
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
            preview_started=preview_started,
            preview_release=preview_release,
        )
        preview_thread = threading.Thread(target=roll.preview)
        preview_thread.start()
        assert preview_started.wait(timeout=2)
        try:
            with pytest.raises(coolscanpy.DeviceBusy):
                dev.eject()
        finally:
            preview_release.set()
            preview_thread.join(timeout=5)
            roll.close()
            dev.close()
        assert not preview_thread.is_alive()

    def test_preview_returns_forty_thumbnails(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            thumbnails = roll.preview()
            assert len(thumbnails) == 40
            assert [t.slot for t in thumbnails] == list(range(1, 41))
            assert all(t.image.dtype == np.uint16 for t in thumbnails)
            assert all(t.image.shape[1:] == (96, 3) for t in thumbnails)
        finally:
            roll.close()
            dev.close()

    def test_preview_filters_returned_thumbnails_by_requested_slots(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            thumbnails = roll.preview([3, 7, 19])
            assert [t.slot for t in thumbnails] == [3, 7, 19]
        finally:
            roll.close()
            dev.close()

    def test_restore_preview_session_revalidates_without_hardware_io(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            payload = roll._require_session().to_json()
            roll._approvals[1] = object()

            restored = roll.restore_preview_session(payload, slots=[2, 5])

            assert [thumbnail.slot for thumbnail in restored] == [2, 5]
            assert worker.events == ["preview"]
            assert roll._approvals == {}
            assert roll._session_usb_topology == (1, 2)
            assert roll._require_session().preview.usb_topology == (1, 2)
        finally:
            roll.close()
            dev.close()

    def test_restore_preview_session_refuses_another_usb_topology_without_mutation(
        self, fake_service_factory, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            original_session = roll._require_session()
            original_approval = object()
            roll._approvals[1] = original_approval
            payload = original_session.to_json()
            monkeypatch.setattr(roll, "_preview_topology_locked", lambda: (1, 3))

            with pytest.raises(coolscanpy.RollMismatch, match="USB topology"):
                roll.restore_preview_session(payload)

            assert roll._session is original_session
            assert roll._approvals == {1: original_approval}
        finally:
            roll.close()
            dev.close()

    def test_restore_preview_session_refuses_while_a_batch_is_reserved(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        iterator = None
        try:
            roll.preview()
            payload = roll._require_session().to_json()
            slot = next(
                (item for item in range(1, 41) if not roll.needs_approval(item)),
                1,
            )
            if roll.needs_approval(slot):
                roll.approve(slot)
            iterator = roll.scan_many([slot])

            with pytest.raises(coolscanpy.DeviceBusy, match="active roll batch"):
                roll.restore_preview_session(payload)
        finally:
            if iterator is not None:
                iterator.close()
            roll.close()
            dev.close()

    def test_fingerprint_before_preview_raises_runtime_error(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            with pytest.raises(RuntimeError):
                roll.fingerprint  # noqa: B018
        finally:
            roll.close()
            dev.close()

    def test_fingerprint_after_preview_has_slot_count_and_sha256(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            fp = roll.fingerprint
            assert fp.slot_count == 40
            assert len(fp.sha256) == 64
            assert fp.preview_shape[2] == 3
        finally:
            roll.close()
            dev.close()

    def test_spacing_offset_defaults_to_zero_and_can_be_set(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            assert roll.spacing_offset(10) == 0
            roll.set_spacing_offset(10, 5)
            assert roll.spacing_offset(10) == 5
        finally:
            roll.close()
            dev.close()

    def test_set_spacing_offset_before_preview_raises_runtime_error(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            with pytest.raises(RuntimeError, match=r"preview\(\) has not been called"):
                roll.set_spacing_offset(1, 0)
        finally:
            roll.close()
            dev.close()

    def test_set_spacing_offset_returns_the_fresh_recropped_thumbnail(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            before = next(thumbnail for thumbnail in roll.preview() if thumbnail.slot == 10)

            adjusted = roll.set_spacing_offset(10, 5)

            assert isinstance(adjusted, coolscanpy.Thumbnail)
            assert adjusted.slot == before.slot
            assert adjusted.boundary_rows == before.boundary_rows
            assert adjusted.spacing_offset == 5
            assert adjusted.needs_approval == before.needs_approval
            assert adjusted.warnings == before.warnings
            assert adjusted.image.shape == before.image.shape
            assert not np.array_equal(adjusted.image, before.image)
        finally:
            roll.close()
            dev.close()

    def test_set_spacing_offset_is_absolute_when_the_same_value_is_set_twice(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()

            first = roll.set_spacing_offset(10, 5)
            second = roll.set_spacing_offset(10, 5)

            assert first.spacing_offset == second.spacing_offset == 5
            np.testing.assert_array_equal(second.image, first.image)
        finally:
            roll.close()
            dev.close()

    def test_spacing_offset_out_of_range_raises_value_error(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            with pytest.raises(ValueError):
                # slot 1's range is [0, 144] (never negative); every other
                # slot allows [-144, 144].
                roll.set_spacing_offset(1, -5)
        finally:
            roll.close()
            dev.close()

    @pytest.mark.parametrize(
        ("slot", "offset_rows"),
        ((1, 0), (1, 144), (10, -144), (10, 144)),
    )
    def test_set_spacing_offset_accepts_each_inclusive_policy_boundary(
        self,
        fake_service_factory,
        tmp_path: Path,
        slot: int,
        offset_rows: int,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()

            adjusted = roll.set_spacing_offset(slot, offset_rows)

            assert adjusted.spacing_offset == offset_rows
            assert roll.spacing_offset(slot) == offset_rows
        finally:
            roll.close()
            dev.close()

    def test_unknown_slot_raises_value_error(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            with pytest.raises(ValueError):
                roll.spacing_offset(999)
        finally:
            roll.close()
            dev.close()

    def test_set_spacing_offset_rejects_an_unknown_slot(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            with pytest.raises(ValueError, match="unknown roll slot"):
                roll.set_spacing_offset(999, 0)
        finally:
            roll.close()
            dev.close()

    def test_set_spacing_offset_is_refused_while_a_batch_owns_the_roll(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        iterator = None
        try:
            roll.preview()
            if roll.needs_approval(3):
                roll.approve(3)
            iterator = roll.scan_many([3])

            with pytest.raises(coolscanpy.DeviceBusy, match="active roll batch"):
                roll.set_spacing_offset(3, 1)
        finally:
            if iterator is not None:
                iterator.close()
            roll.close()
            dev.close()

    def test_setting_even_the_same_spacing_offset_requires_public_reapproval(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            thumbnails = roll.preview()
            flagged = next(
                (thumbnail for thumbnail in thumbnails if thumbnail.needs_approval),
                None,
            )
            if flagged is None:
                pytest.skip(
                    "synthetic preview produced no manual-review slot to test invalidation against"
                )
            roll.approve(flagged.slot)

            adjusted = roll.set_spacing_offset(
                flagged.slot,
                flagged.spacing_offset,
            )

            assert adjusted.spacing_offset == flagged.spacing_offset
            with pytest.raises(coolscanpy.ManualReviewRequired) as excinfo:
                next(iter(roll.scan_many([flagged.slot])))
            assert excinfo.value.slot == flagged.slot
        finally:
            roll.close()
            dev.close()

    def test_approve_returns_the_exact_content_bound_receipt_retained_for_batch(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            thumbnails = roll.preview()
            slot = next(
                thumbnail.slot for thumbnail in thumbnails if thumbnail.needs_approval
            )

            approval = roll.approve(slot)

            assert isinstance(approval, ManualFrameApproval)
            assert approval is roll._approvals[slot]
            assert approval.slot == slot
            assert approval.reviewed_fingerprint_sha256 == roll.fingerprint.sha256
            assert approval.binding_sha256 == approval.to_payload()["binding_sha256"]
        finally:
            roll.close()
            dev.close()

    def test_approve_on_slot_that_does_not_need_approval_raises_value_error(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            clean_slot = next(
                (s for s in range(1, 41) if not roll.needs_approval(s)), None
            )
            if clean_slot is None:
                pytest.skip("synthetic preview flagged every slot for manual review")
            with pytest.raises(ValueError):
                roll.approve(clean_slot)
        finally:
            roll.close()
            dev.close()

    # ===========================================================================
    # Roll.scan_many() / scan()
    # ===========================================================================

    def test_scan_many_yields_frames_in_requested_order(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        events: list[str] = []
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_success_spawner(events)
        )
        try:
            roll.preview()
            # CaptureBatchRequest requires unique, strictly increasing slots
            # (one continuous forward transport reservation) -- "ordering"
            # here means the yielded Frames replay that same sequence, not
            # that arbitrary reordering is supported.
            for slot in (2, 5, 9):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            frames = list(roll.scan_many([2, 5, 9]))

            assert [frame.slot for frame in frames] == [2, 5, 9]
            for frame in frames:
                assert frame.rgb.dtype == np.uint16
                assert frame.ir.dtype == np.uint16
                assert frame.ir_validity.dtype == np.bool_
                assert frame.receipt.slot == frame.slot
                assert frame.receipt.dpi == 4_000
                assert frame.receipt.depth == 16
                assert frame.receipt.device_id == _LOCAL_COOLSCAN_ID
                assert (
                    frame.receipt.reviewed_fingerprint_sha256 == roll.fingerprint.sha256
                )
                assert frame.receipt.fresh_fingerprint_sha256 == roll.fingerprint.sha256
                assert frame.receipt.transport_smear.verdict == "clean"
                assert frame.receipt.exposure.red_exposure_us == pytest.approx(1_000.01)
                assert frame.receipt.split_alignment is None
                assert (
                    "rgb" in frame.receipt.artifacts and "ir" in frame.receipt.artifacts
                )
                assert frame.nikon_density_evidence is not None
                assert frame.nikon_density_ownership is not None
                assert (
                    frame.receipt.nikon_density_ownership
                    is frame.nikon_density_ownership
                )
                frame.nikon_density_ownership.validate_evidence(
                    frame.nikon_density_evidence
                )
                builder = frame.nikon_exact_builder_evidence
                assert builder is not None
                assert builder.slot == frame.slot
                assert (
                    builder.capture_attempt_id
                    == frame.nikon_density_ownership.frame_capture_attempt_id
                )
                assert builder.final_f02_denominators == (
                    100_001,
                    100_002,
                    100_003,
                )
                assert builder.analyzer_rgb.shape == (425, 281, 3)
                assert builder.analyzer_rgb.flags.writeable is False
                builder.validate_bindings(
                    frame.nikon_density_evidence,
                    frame.nikon_density_ownership,
                )
                acquisition = frame.prepare_digital_ice()
                assert frame.digital_ice_evidence is not None
                assert acquisition.slot == frame.slot
                assert (
                    acquisition.reservation_id
                    == frame.nikon_density_ownership.reservation_id
                )
                assert acquisition.main_rgbi.shape == (5_959, 3_946, 4)
                assert acquisition.meter_rgbi.shape == (425, 281, 4)
                assert acquisition.ir_validity.shape == (5_959, 3_946)
                upright = np.ascontiguousarray(
                    np.swapaxes(acquisition.main_rgbi, 0, 1)
                )
                np.testing.assert_array_equal(upright[..., :3], frame.rgb)
                np.testing.assert_array_equal(upright[..., 3], frame.ir)
            assert len(
                {
                    frame.nikon_exact_builder_evidence.analyzer_rgb_sha256
                    for frame in frames
                }
            ) == len(frames)
        finally:
            roll.close()
            dev.close()

    def test_scan_is_sugar_for_scan_many_of_one(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            if roll.needs_approval(11):
                roll.approve(11)

            frame = roll.scan(11)

            assert frame.slot == 11
        finally:
            roll.close()
            dev.close()

    def test_scan_many_binds_the_adjusted_offset_and_reapproval_to_the_worker(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        events: list[str] = []
        observed_jobs: list[dict[str, Any]] = []

        def spawn(
            argv: Sequence[str],
            *,
            cwd: Path,
            stdout: object,
            stderr: object,
        ) -> _FakeBatchProcess:
            del cwd, stdout, stderr
            job_path = Path(_arg(argv, "--batch-job"))
            session_journal_path = Path(_arg(argv, "--session-journal"))
            observed_jobs.append(json.loads(job_path.read_text(encoding="utf-8")))
            return _FakeBatchProcess(job_path, session_journal_path, events)

        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=spawn)
        try:
            thumbnails = roll.preview()
            flagged = next(
                (
                    thumbnail
                    for thumbnail in thumbnails
                    if thumbnail.needs_approval and thumbnail.slot != 1
                ),
                None,
            )
            if flagged is None:
                pytest.skip("synthetic preview has no offsettable manual-review slot")
            adjusted = roll.set_spacing_offset(flagged.slot, -7)
            approval = roll.approve(flagged.slot)

            frame = next(iter(roll.scan_many([flagged.slot])))

            assert adjusted.spacing_offset == -7
            assert approval.boundary_offset_rows == -7
            assert len(observed_jobs) == 1
            worker_frame = observed_jobs[0]["frames"][0]
            assert worker_frame["boundary_offset_rows"] == -7
            assert worker_frame["manual_review_approval"] == approval.to_payload()
            assert frame.receipt.spacing_offset == -7
            assert frame.receipt.manual_approval is not None
            assert frame.receipt.manual_approval.spacing_offset == -7
        finally:
            roll.close()
            dev.close()

    def test_color_batch_job_is_bound_to_the_reviewed_local_usb_topology(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        events: list[str] = []
        observed_jobs: list[dict[str, object]] = []

        def spawn(
            argv: Sequence[str],
            *,
            cwd: Path,
            stdout: object,
            stderr: object,
        ) -> _FakeBatchProcess:
            del cwd, stdout, stderr
            job_path = Path(_arg(argv, "--batch-job"))
            session_journal_path = Path(_arg(argv, "--session-journal"))
            observed_jobs.append(json.loads(job_path.read_text(encoding="utf-8")))
            return _FakeBatchProcess(job_path, session_journal_path, events)

        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=spawn)
        try:
            roll.preview()
            if roll.needs_approval(2):
                roll.approve(2)

            frame = roll.scan(2)

            assert frame.slot == 2
            assert len(observed_jobs) == 1
            assert observed_jobs[0]["schema_version"] == 3
            assert observed_jobs[0]["expected_usb_bus"] == 1
            assert observed_jobs[0]["expected_usb_address"] == 2
        finally:
            roll.close()
            dev.close()

    @pytest.mark.parametrize(
        ("tamper", "message"),
        [
            ("missing", "meter sidecar cannot be opened safely"),
            ("digest", "meter sidecar does not match its capture digest"),
            ("final-exposure", "fine exposure echo does not match"),
        ],
    )
    def test_scan_refuses_missing_or_changed_exact_builder_sources(
        self,
        fake_service_factory,
        tmp_path: Path,
        tamper: str,
        message: str,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_tampered_meter_spawner([], tamper=tamper),
        )
        try:
            roll.preview()
            if roll.needs_approval(11):
                roll.approve(11)

            with pytest.raises(coolscanpy.PyCoolscanError, match=message):
                roll.scan(11)
        finally:
            roll.close()
            dev.close()

    def test_scan_refuses_an_unstable_exact_builder_source(
        self,
        fake_service_factory,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        real_identity = roll_module._stable_file_identity
        calls = 0

        def changing_identity(value: object) -> tuple[int, ...]:
            nonlocal calls
            calls += 1
            identity = real_identity(value)
            return (*identity[:-1], identity[-1] + calls)

        monkeypatch.setattr(
            roll_module,
            "_stable_file_identity",
            changing_identity,
        )
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
        )
        try:
            roll.preview()
            if roll.needs_approval(11):
                roll.approve(11)

            with pytest.raises(
                coolscanpy.BatchIntegrityError,
                match="capture journal changed while it was read",
            ):
                roll.scan(11)
        finally:
            roll.close()
            dev.close()

    def test_scan_many_raises_manual_review_required_when_unapproved(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            thumbnails = roll.preview()
            flagged = next((t.slot for t in thumbnails if t.needs_approval), None)
            if flagged is None:
                pytest.skip("synthetic preview produced no manual-review slot")

            with pytest.raises(coolscanpy.ManualReviewRequired) as excinfo:
                next(iter(roll.scan_many([flagged])))

            assert excinfo.value.slot == flagged
        finally:
            roll.close()
            dev.close()

    def test_approve_accepts_boundary_review_with_automatic_transport_origin(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            roll.preview()
            session = roll._session
            assert session is not None
            slot = session.slots[39]
            assert slot.manual_review is True
            assert slot.base_origin.automatic is True
            assert slot.base_origin.manual_review is False

            roll.approve(40)

            assert session.validate_manual_approval(
                roll._approvals[40],
                slot_id=40,
                boundary_offset_rows=0,
            )
        finally:
            roll.close()
            dev.close()

    def test_roll_close_stops_and_cleans_an_active_batch(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        fake_service_factory(
            [
                _coolscan_device(
                    device_id=_LOCAL_COOLSCAN_ID,
                    registered_geometry=True,
                )
            ]
        )
        dev = coolscanpy.open(_LOCAL_COOLSCAN_ID)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            material=coolscanpy.Material.COLOR_NEGATIVE,
            batch_spawner=_success_spawner([]),
        )
        iterator = None
        try:
            roll.preview()
            for slot in (3, 4):
                if roll.needs_approval(slot):
                    roll.approve(slot)
            iterator = roll.scan_many([3, 4])
            assert next(iterator).slot == 3

            roll.close()

            assert roll._stop_event.is_set()
            assert roll._closed is True
            assert list(iterator) == []
        finally:
            if iterator is not None:
                iterator.close()
            roll.close()
            dev.close()

    def test_lazy_color_batch_is_owned_before_return_and_cannot_start_after_close(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
        )
        try:
            roll.preview()
            if roll.needs_approval(3):
                roll.approve(3)
            iterator = roll.scan_many([3])

            with pytest.raises(coolscanpy.DeviceBusy):
                dev.scan()
            with pytest.raises(coolscanpy.DeviceBusy):
                dev.eject()
            roll.close()

            assert list(iterator) == []
            assert worker.events == ["preview"]
        finally:
            roll.close()
            dev.close()

    def test_exhausted_iterator_close_cannot_stop_a_later_batch(
        self,
        fake_service_factory,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
        )
        try:
            roll.preview()
            for slot in (3, 4):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            monkeypatch.setattr(
                roll,
                "_scan_many",
                lambda _request, slots, _progress: iter(slots),
            )
            first = roll.scan_many([3])
            assert list(first) == [3]
            second = roll.scan_many([4])

            first.close()

            assert list(second) == [4]
        finally:
            roll.close()
            dev.close()

    def test_temporary_for_break_releases_batch_and_allows_the_next_one(
        self,
        fake_service_factory,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_success_spawner([]),
        )
        try:
            roll.preview()
            for slot in (3, 4):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            monkeypatch.setattr(
                roll,
                "_scan_many",
                lambda _request, slots, _progress: iter(slots),
            )
            for value in roll.scan_many([3]):
                assert value == 3
                break

            assert roll._stop_event.is_set()
            assert list(roll.scan_many([4])) == [4]
        finally:
            roll.close()
            dev.close()

    @pytest.mark.parametrize(
        "material",
        (coolscanpy.Material.COLOR_NEGATIVE,),
    )
    def test_roll_close_from_progress_callback_is_refused_without_releasing(
        self,
        fake_service_factory,
        tmp_path: Path,
        material: coolscanpy.Material,
    ) -> None:
        fake_service_factory(
            [
                _coolscan_device(
                    device_id=_LOCAL_COOLSCAN_ID,
                    registered_geometry=True,
                )
            ]
        )
        dev = coolscanpy.open(_LOCAL_COOLSCAN_ID)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            material=material,
            batch_spawner=_success_spawner([]),
        )
        refused: list[coolscanpy.DeviceBusy] = []
        try:
            roll.preview()
            if roll.needs_approval(3):
                roll.approve(3)

            def close_from_callback(_progress: coolscanpy.Progress) -> None:
                try:
                    roll.close()
                except coolscanpy.DeviceBusy as error:
                    refused.append(error)

            frames = list(roll.scan_many([3], on_progress=close_from_callback))

            assert [frame.slot for frame in frames] == [3]
            assert refused
            assert roll._closed is False
        finally:
            roll.close()
            dev.close()

    def test_progress_callback_close_is_refused_before_waiting_on_concurrent_close(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        fake_service_factory(
            [
                _coolscan_device(
                    device_id=_LOCAL_COOLSCAN_ID,
                    registered_geometry=True,
                )
            ]
        )
        dev = coolscanpy.open(_LOCAL_COOLSCAN_ID)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            material=coolscanpy.Material.COLOR_NEGATIVE,
            batch_spawner=_success_spawner([]),
        )
        callback_entered = threading.Event()
        callback_may_reenter_close = threading.Event()
        callback_returned = threading.Event()
        refused: list[coolscanpy.DeviceBusy] = []
        frames: list[coolscanpy.Frame] = []
        consumer_errors: list[BaseException] = []
        closer_errors: list[BaseException] = []
        consumer: threading.Thread | None = None
        closer: threading.Thread | None = None

        def close_from_callback(_progress: coolscanpy.Progress) -> None:
            callback_entered.set()
            if not callback_may_reenter_close.wait(timeout=10):
                raise AssertionError("concurrent close never acquired Roll ownership")
            try:
                roll.close()
            except coolscanpy.DeviceBusy as error:
                refused.append(error)
            finally:
                callback_returned.set()

        try:
            roll.preview()
            if roll.needs_approval(3):
                roll.approve(3)
            iterator = roll.scan_many([3], on_progress=close_from_callback)

            def consume() -> None:
                try:
                    frames.append(next(iterator))
                except BaseException as error:
                    consumer_errors.append(error)

            consumer = threading.Thread(target=consume, daemon=True)
            consumer.start()
            assert callback_entered.wait(timeout=10)

            def close_from_other_thread() -> None:
                try:
                    roll.close()
                except BaseException as error:
                    closer_errors.append(error)

            closer = threading.Thread(target=close_from_other_thread, daemon=True)
            closer.start()
            with roll._state_condition:
                assert roll._state_condition.wait_for(
                    lambda: roll._closing,
                    timeout=10,
                )
            callback_may_reenter_close.set()

            returned_without_rescue = callback_returned.wait(timeout=3)
            if not returned_without_rescue:
                # Let an old wait-before-callback-check implementation unwind
                # so the regression fails cleanly instead of hanging pytest.
                with roll._state_condition:
                    roll._closing = False
                    roll._state_condition.notify_all()

            consumer.join(timeout=20)
            closer.join(timeout=20)

            assert returned_without_rescue, (
                "progress callback deadlocked behind the concurrent Roll.close()"
            )
            assert not consumer.is_alive()
            assert not closer.is_alive()
            assert len(refused) == 1
            assert "active progress callback" in str(refused[0])
            assert consumer_errors == []
            assert closer_errors == []
            assert [frame.slot for frame in frames] == [3]
        finally:
            callback_may_reenter_close.set()
            if consumer is None or not consumer.is_alive():
                if closer is None or not closer.is_alive():
                    roll.close()
                    dev.close()

    @pytest.mark.parametrize(
        "material",
        (coolscanpy.Material.COLOR_NEGATIVE,),
    )
    def test_roll_preview_refuses_remote_sane_id_before_direct_usb(
        self,
        fake_service_factory,
        tmp_path: Path,
        material: coolscanpy.Material,
    ) -> None:
        fake_service_factory(
            [_coolscan_device(device_id=_COOLSCAN_ID, registered_geometry=True)]
        )
        dev = coolscanpy.open(_COOLSCAN_ID)
        roll, worker = _make_roll(
            tmp_path,
            dev,
            material=material,
            batch_spawner=_success_spawner([]),
        )
        try:
            with pytest.raises(
                coolscanpy.BatchIntegrityError, match="exact local coolscan3"
            ):
                roll.preview()

            assert worker.events == []
        finally:
            roll.close()
            dev.close()

    def test_safe_stop_mid_batch_yields_completed_frames_then_raises(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        events: list[str] = []
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_success_spawner(events)
        )
        try:
            roll.preview()
            for slot in (1, 2, 3):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            seen: list[int] = []

            def on_progress(progress: coolscanpy.Progress) -> None:
                seen.append(progress.slot)
                if len(seen) == 1:
                    roll.safe_stop()

            iterator = roll.scan_many([1, 2, 3], on_progress=on_progress)
            produced = []
            with pytest.raises(coolscanpy.SafeStopRequested):
                for frame in iterator:
                    produced.append(frame)

            assert [frame.slot for frame in produced] == [1]
        finally:
            roll.close()
            dev.close()

    def test_scan_many_yields_first_frame_before_batch_completes(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        events: list[str] = []
        gate = threading.Event()
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_gated_spawner(events, gate)
        )
        try:
            roll.preview()
            for slot in (2, 5, 9):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            iterator = roll.scan_many([2, 5, 9])
            first = next(iterator)

            assert first.slot == 2
            # The second requested frame's journal is gated until we release
            # it below. Seeing it absent here -- deterministically, not by
            # timing -- proves the first frame reached the caller without
            # the rest of the batch having run yet, i.e. streaming rather
            # than buffer-then-yield.
            assert not any(event.startswith("ready-5") for event in events)

            gate.set()
            rest = list(iterator)

            assert [frame.slot for frame in rest] == [5, 9]
        finally:
            roll.close()
            dev.close()

    def test_color_roll_batch_blocks_a_concurrent_plain_scan(
        self,
        fake_service_factory,
        tmp_path: Path,
    ) -> None:
        events: list[str] = []
        gate = threading.Event()
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path,
            dev,
            batch_spawner=_gated_spawner(events, gate),
        )
        try:
            roll.preview()
            for slot in (2, 5):
                if roll.needs_approval(slot):
                    roll.approve(slot)
            iterator = roll.scan_many([2, 5])
            first = next(iterator)
            assert first.slot == 2

            with pytest.raises(coolscanpy.DeviceBusy):
                dev.scan()

            gate.set()
            assert [frame.slot for frame in iterator] == [5]
        finally:
            gate.set()
            roll.close()
            dev.close()

    def test_scan_many_early_close_requests_safe_stop_without_deadlock(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        events: list[str] = []
        dev = _open_device(fake_service_factory)
        # Two slots, not three: safe_stop() never aborts a frame already in
        # flight (only the *next* one is refused), so abandoning after the
        # first slot still lets one more full frame -- with this fixture's
        # real per-frame hashing/TIFF I/O -- finish before the batch winds
        # down. Keeping the batch short bounds that unavoidable tail cost.
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_success_spawner(events)
        )
        try:
            roll.preview()
            for slot in (2, 5):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            iterator = roll.scan_many([2, 5])
            first = next(iterator)
            assert first.slot == 2

            # Abandon mid-batch on a watchdog thread: if the worker were left
            # blocked writing a completed frame to a now-unread, full queue,
            # close() would hang and this join would time out. The bound is
            # generous (not tight) because it must comfortably outlast the
            # in-flight frame's real processing, not just prove promptness.
            closer = threading.Thread(target=iterator.close)
            closer.start()
            closer.join(timeout=90.0)

            assert not closer.is_alive(), (
                "generator.close() deadlocked instead of returning"
            )
            assert roll._stop_event.is_set()
        finally:
            roll.close()
            dev.close()

    def test_hung_worker_close_retains_roll_and_attempt_state(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-on-hung-worker"
        sentinel.write_text("retain", encoding="utf-8")

        def hung_worker():
            try:
                yield object()
            finally:
                raise roll_module._BatchWorkerStillActive("simulated hung worker")

        iterator = roll._reserve_batch_locked(hung_worker())
        assert next(iterator) is not None
        try:
            with pytest.raises(coolscanpy.DeviceBusy, match="hung worker"):
                roll.close()

            assert sentinel.exists()
            assert roll._active_batch_id == id(iterator)
            with pytest.raises(coolscanpy.DeviceBusy):
                dev.scan()
        finally:
            # The production path deliberately retains ownership after this
            # fail-closed condition. Release the fake reservation explicitly
            # so this isolated test can clean up its in-memory device.
            iterator._ownership_uncertain = False
            iterator._closed = True
            iterator._release_roll_once()
            roll.close()
            dev.close()

    def test_concurrent_roll_close_retains_ownership_when_next_reports_hung_worker(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-on-concurrent-hung-worker"
        sentinel.write_text("retain", encoding="utf-8")
        started = threading.Event()
        release = threading.Event()
        consume_errors: list[BaseException] = []
        close_errors: list[BaseException] = []

        def active_then_uncertain():
            started.set()
            assert release.wait(timeout=10)
            raise roll_module._BatchWorkerStillActive("simulated concurrent hang")
            yield object()

        iterator = roll._reserve_batch_locked(active_then_uncertain())

        def consume() -> None:
            try:
                next(iterator)
            except BaseException as error:
                consume_errors.append(error)

        def close_roll() -> None:
            try:
                roll.close()
            except BaseException as error:
                close_errors.append(error)

        consumer = threading.Thread(target=consume)
        closer = threading.Thread(target=close_roll)
        try:
            consumer.start()
            assert started.wait(timeout=10)
            closer.start()
            assert roll._stop_event.wait(timeout=10)

            release.set()
            consumer.join(timeout=10)
            closer.join(timeout=10)

            assert not consumer.is_alive()
            assert not closer.is_alive()
            assert len(consume_errors) == 1
            assert isinstance(consume_errors[0], coolscanpy.DeviceBusy)
            assert len(close_errors) == 1
            assert isinstance(close_errors[0], coolscanpy.DeviceBusy)
            assert sentinel.exists()
            assert roll._closed is False
            assert roll._active_batch_id == id(iterator)
        finally:
            release.set()
            consumer.join(timeout=10)
            closer.join(timeout=10)
            # Release the deliberately retained fake reservation so this test
            # can close its in-memory device after exercising fail-closed state.
            iterator._ownership_uncertain = False
            iterator._closed = True
            iterator._release_roll_once()
            roll.close()
            dev.close()

    def test_roll_close_has_a_bounded_wait_for_an_unresponsive_next(
        self, fake_service_factory, tmp_path: Path, monkeypatch
    ) -> None:
        monkeypatch.setattr(roll_module, "_SCAN_WORKER_JOIN_TIMEOUT_SECONDS", 0.05)
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-on-unresponsive-next"
        sentinel.write_text("retain", encoding="utf-8")
        started = threading.Event()
        release = threading.Event()
        close_errors: list[BaseException] = []

        def unresponsive_next():
            started.set()
            assert release.wait(timeout=10)
            return
            yield object()

        iterator = roll._reserve_batch_locked(unresponsive_next())

        def consume() -> None:
            try:
                next(iterator)
            except StopIteration:
                pass

        def close_roll() -> None:
            try:
                roll.close()
            except BaseException as error:
                close_errors.append(error)

        consumer = threading.Thread(target=consume)
        closer = threading.Thread(target=close_roll)
        try:
            consumer.start()
            assert started.wait(timeout=10)
            closer.start()
            assert roll._stop_event.wait(timeout=10)
            closer.join(timeout=5)

            assert not closer.is_alive(), "Roll.close() exceeded its worker deadline"
            assert len(close_errors) == 1
            assert isinstance(close_errors[0], coolscanpy.DeviceBusy)
            assert sentinel.exists()
            assert roll._closed is False
            assert roll._active_batch_id == id(iterator)
        finally:
            release.set()
            consumer.join(timeout=10)
            closer.join(timeout=10)
            roll.close()
            dev.close()

    def test_roll_close_does_not_cross_an_in_progress_iterator_close(
        self, fake_service_factory, tmp_path: Path, monkeypatch
    ) -> None:
        monkeypatch.setattr(roll_module, "_SCAN_WORKER_JOIN_TIMEOUT_SECONDS", 0.05)
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-during-in-progress-close"
        sentinel.write_text("retain", encoding="utf-8")
        close_started = threading.Event()
        release_close = threading.Event()
        iterator_close_errors: list[BaseException] = []
        roll_close_errors: list[BaseException] = []

        def slow_close():
            try:
                yield object()
            finally:
                close_started.set()
                assert release_close.wait(timeout=10)

        iterator = roll._reserve_batch_locked(slow_close())
        assert next(iterator) is not None

        def close_iterator() -> None:
            try:
                iterator.close()
            except BaseException as error:
                iterator_close_errors.append(error)

        def close_roll() -> None:
            try:
                roll.close()
            except BaseException as error:
                roll_close_errors.append(error)

        iterator_closer = threading.Thread(target=close_iterator)
        roll_closer = threading.Thread(target=close_roll)
        try:
            iterator_closer.start()
            assert close_started.wait(timeout=10)
            roll_closer.start()
            roll_closer.join(timeout=5)

            assert not roll_closer.is_alive()
            assert len(roll_close_errors) == 1
            assert isinstance(roll_close_errors[0], coolscanpy.DeviceBusy)
            assert iterator_close_errors == []
            assert sentinel.exists()
            assert roll._closed is False
            assert roll._active_batch_id == id(iterator)
        finally:
            release_close.set()
            iterator_closer.join(timeout=10)
            roll_closer.join(timeout=10)
            roll.close()
            dev.close()

    def test_roll_close_does_not_cross_an_in_progress_batch_release(
        self, fake_service_factory, tmp_path: Path, monkeypatch
    ) -> None:
        monkeypatch.setattr(roll_module, "_SCAN_WORKER_JOIN_TIMEOUT_SECONDS", 0.05)
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-during-batch-release"
        sentinel.write_text("retain", encoding="utf-8")
        release_started = threading.Event()
        allow_release = threading.Event()
        iterator_close_errors: list[BaseException] = []
        roll_close_errors: list[BaseException] = []

        def one_frame():
            yield object()

        iterator = roll._reserve_batch_locked(one_frame())
        assert next(iterator) is not None
        original_batch_finished = roll._batch_finished

        def gated_batch_finished(batch) -> None:
            release_started.set()
            assert allow_release.wait(timeout=10)
            original_batch_finished(batch)

        monkeypatch.setattr(roll, "_batch_finished", gated_batch_finished)

        def close_iterator() -> None:
            try:
                iterator.close()
            except BaseException as error:
                iterator_close_errors.append(error)

        def close_roll() -> None:
            try:
                roll.close()
            except BaseException as error:
                roll_close_errors.append(error)

        iterator_closer = threading.Thread(target=close_iterator)
        roll_closer = threading.Thread(target=close_roll)
        try:
            iterator_closer.start()
            assert release_started.wait(timeout=10)
            roll_closer.start()
            roll_closer.join(timeout=5)

            assert not roll_closer.is_alive()
            assert len(roll_close_errors) == 1
            assert isinstance(roll_close_errors[0], coolscanpy.DeviceBusy)
            assert iterator_close_errors == []
            assert sentinel.exists()
            assert roll._closed is False
            assert roll._active_batch_id == id(iterator)
        finally:
            allow_release.set()
            iterator_closer.join(timeout=10)
            roll_closer.join(timeout=10)
            roll.close()
            dev.close()

    def test_uncertain_batch_is_retained_after_the_caller_drops_its_iterator(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        attempts = roll._attempts_root
        attempts.mkdir(parents=True, exist_ok=True)
        sentinel = attempts / "preserve-after-iterator-drop"
        sentinel.write_text("retain", encoding="utf-8")

        def uncertain_worker():
            raise roll_module._BatchWorkerStillActive("simulated uncertain owner")
            yield object()

        iterator = roll._reserve_batch_locked(uncertain_worker())
        with pytest.raises(coolscanpy.DeviceBusy, match="uncertain owner"):
            next(iterator)
        iterator_reference = weakref.ref(iterator)
        del iterator
        gc.collect()

        try:
            retained = iterator_reference()
            assert retained is not None
            with pytest.raises(coolscanpy.DeviceBusy):
                roll.close()
            assert sentinel.exists()
            with pytest.raises(coolscanpy.DeviceBusy):
                dev.scan()
        finally:
            retained = iterator_reference()
            if retained is not None:
                retained._ownership_uncertain = False
                retained._closed = True
                retained._release_roll_once()
            else:
                # This is only the cleanup path for the intentionally RED
                # pre-fix behavior, where the weak-reference tombstone has
                # already destroyed the iterator that owned these locks.
                with roll._state_condition:
                    roll._active_batch = None
                    roll._active_batch_id = None
                    roll._batch_lock.release()
                    dev._release_io_lock()
                    roll._state_condition.notify_all()
            roll.close()
            dev.close()

    def test_scan_many_worker_exception_surfaces_with_original_type_after_earlier_frames(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        events: list[str] = []
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_success_spawner(events)
        )

        calls = 0

        def flaky_smear_assessor(rgb, *, dpi):
            nonlocal calls
            calls += 1
            if calls == 2:
                return StoppedTransportSmearAssessment(
                    verdict="smear",
                    start_row=10,
                    suffix_rows=5,
                    minimum_matches=64,
                    tail_median_rms=1.0,
                    tail_min_corr=0.1,
                    pre_tail_median_rms=1.0,
                    texture_span=1.0,
                    reason="synthetic smear for test",
                )
            return StoppedTransportSmearAssessment(
                verdict="clean",
                start_row=None,
                suffix_rows=0,
                minimum_matches=64,
                tail_median_rms=None,
                tail_min_corr=None,
                pre_tail_median_rms=None,
                texture_span=1_234.0,
                reason="unit-test clean",
            )

        # Swap in a workflow whose smear QC refuses the SECOND finalized
        # frame, so the worker thread raises mid-batch -- the first frame
        # must already be in the caller's hands with the right type
        # (TransportSmearDetected) surfacing for the second.
        roll._workflow = LS5000SinglePassWorkflow(
            contract=PackedCaptureContract(),
            decoder=lambda _path: (
                _fake_decoded_frame(),
                {
                    "padding_validated_records": CANONICAL_FINE_READ_COUNT,
                    "rgb_samples_decoded": 4,
                    "ir_planes_transferred": 1,
                },
            ),
            smear_assessor=flaky_smear_assessor,
        )
        try:
            roll.preview()
            for slot in (2, 5):
                if roll.needs_approval(slot):
                    roll.approve(slot)

            produced = []
            with pytest.raises(coolscanpy.TransportSmearDetected):
                for frame in roll.scan_many([2, 5]):
                    produced.append(frame)

            assert [frame.slot for frame in produced] == [2]
        finally:
            roll.close()
            dev.close()


# ===========================================================================
# Roll batch refusal -> typed exceptions
# ===========================================================================


class TestRollBatchRefusal:
    def test_fingerprint_mismatch_message_raises_fingerprint_refused(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        message = (
            "SynchronizedProtocolError: fresh live index does not match the "
            "reviewed roll fingerprint: visual-content-mismatch"
        )
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_refusal_spawner(message)
        )
        try:
            roll.preview()
            if roll.needs_approval(1):
                roll.approve(1)
            with pytest.raises(coolscanpy.FingerprintRefused) as excinfo:
                next(iter(roll.scan_many([1])))
            assert excinfo.value.comparison.matches is False
        finally:
            roll.close()
            dev.close()

    def test_manual_review_message_raises_manual_review_required(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        message = "SynchronizedProtocolError: frame 4 transport origin requires manual review; approve its current thumbnail"
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_refusal_spawner(message)
        )
        try:
            roll.preview()
            if roll.needs_approval(4):
                roll.approve(4)
            with pytest.raises(coolscanpy.ManualReviewRequired) as excinfo:
                next(iter(roll.scan_many([4])))
            assert excinfo.value.slot == 4
        finally:
            roll.close()
            dev.close()

    def test_other_refusal_message_raises_generic_roll_mismatch(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        dev = _open_device(fake_service_factory)
        message = "SynchronizedProtocolError: metering refused"
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_refusal_spawner(message)
        )
        try:
            roll.preview()
            if roll.needs_approval(1):
                roll.approve(1)
            with pytest.raises(coolscanpy.RollMismatch) as excinfo:
                next(iter(roll.scan_many([1])))
            assert not isinstance(
                excinfo.value,
                (coolscanpy.FingerprintRefused, coolscanpy.ManualReviewRequired),
            )
        finally:
            roll.close()
            dev.close()

    def test_command_64_nonzero_status_is_not_misreported_as_refeed_required(
        self, fake_service_factory, tmp_path: Path
    ) -> None:
        message = (
            "SynchronizedProtocolError: command 64 status 022b4b0000000000 "
            "!= 0000000000000000"
        )
        dev = _open_device(fake_service_factory)
        roll, _worker = _make_roll(
            tmp_path, dev, batch_spawner=_refusal_spawner(message)
        )
        try:
            roll.preview()
            if roll.needs_approval(1):
                roll.approve(1)
            with pytest.raises(coolscanpy.RollMismatch) as excinfo:
                next(iter(roll.scan_many([1])))
            assert not isinstance(excinfo.value, coolscanpy.RefeedRequired)
            assert str(excinfo.value) == message
        finally:
            roll.close()
            dev.close()


# ===========================================================================
# SANE-free fallback: get_devices()/open()/scan()/eject()/roll() when
# python-sane is not importable (see coolscanpy._device's module docstring)
# ===========================================================================


@dataclass
class _FakeUsbDevice:
    """Just enough of a ``usb.core.Device`` for ``_usb_fallback_device_infos``
    to read: the attributes it actually uses. Defaults to the LS-5000 product
    id so pre-existing fixture uses stay valid."""

    bus: int
    address: int
    idProduct: int = 0x4002


_LS50_PRODUCT_ID = 0x4001
_LS40_PRODUCT_ID = 0x4000


@pytest.fixture
def python_sane_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    """Simulates python-sane genuinely not being installed, as opposed to
    installed-but-misbehaving (which tests/session/test_service.py already
    covers with a fake module object standing in for ``sane``). Setting the
    ``sys.modules`` entry to ``None`` makes any ``import sane`` -- anywhere,
    including inside ``SaneBackend.__init__`` -- raise ``ImportError``,
    exactly like an environment that never had python-sane installed. This
    exercises the real ``ScannerService``/``SaneBackend`` classes, not a
    hand-rolled stand-in for them."""

    monkeypatch.setitem(sys.modules, "sane", None)


def _mock_usb_find(
    monkeypatch: pytest.MonkeyPatch, devices: list[_FakeUsbDevice]
) -> None:
    """Stands in for ``usb.core.find`` so the fallback enumeration path never
    touches a real USB bus."""

    monkeypatch.setattr("usb.core.find", lambda find_all=False, **kwargs: list(devices))
    monkeypatch.setattr(
        "coolscanpy.protocol.ls5000_single_pass.usb_backend.get_libusb_backend",
        lambda: object(),
    )


class TestSaneFreeFallback:
    def test_get_devices_falls_back_to_direct_usb_when_device_present(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=1, address=7)])

        devices = coolscanpy.get_devices()

        assert len(devices) == 1
        info = devices[0]
        assert info.id == "usb:1:7"
        assert info.vendor == "Nikon"
        assert info.model == "LS-5000 ED"
        assert info.supported is True
        assert info.capabilities.adapter_frame_control is True

    def test_get_devices_lists_ls50_as_recognized_but_unsupported(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # #14: an LS-50 (04b0:4001) on the bus must be named, not silently
        # missing, and must never be connectable.
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=5, address=3, idProduct=_LS50_PRODUCT_ID)])

        devices = coolscanpy.get_devices()

        assert len(devices) == 1
        info = devices[0]
        assert info.model == "LS-50 ED"
        assert info.supported is False

        with pytest.raises(coolscanpy.DeviceNotFound, match="not supported"):
            coolscanpy.open("ls5000")

    def test_get_devices_lists_ls40_as_recognized_but_unsupported(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=6, address=2, idProduct=_LS40_PRODUCT_ID)])

        devices = coolscanpy.get_devices()

        assert len(devices) == 1
        assert devices[0].model == "LS-40 ED"
        assert devices[0].supported is False

    def test_get_devices_skips_unknown_nikon_product_ids(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # A foreign product id on the Nikon vendor is not guessed.
        _mock_usb_find(
            monkeypatch,
            [_FakeUsbDevice(bus=7, address=1, idProduct=0x9999)],
        )

        assert coolscanpy.get_devices() == []

    def test_get_devices_marks_ls5000_supported_alongside_an_ls50(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(
            monkeypatch,
            [
                _FakeUsbDevice(bus=1, address=1, idProduct=_LS50_PRODUCT_ID),
                _FakeUsbDevice(bus=2, address=1, idProduct=0x4002),
            ],
        )

        by_model = {d.model: d.supported for d in coolscanpy.get_devices()}
        assert by_model == {"LS-5000 ED": True, "LS-50 ED": False}

    def test_get_devices_falls_back_to_empty_list_when_no_usb_device(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(monkeypatch, [])

        assert coolscanpy.get_devices() == []

    def test_get_devices_falls_back_when_sane_finds_no_coolscan(
        self,
        fake_service_factory,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        fake_service_factory([])
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=2, address=9)])

        assert [item.id for item in coolscanpy.get_devices()] == ["usb:2:9"]

    def test_get_devices_falls_back_when_sane_enumeration_fails(
        self,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        class FailingService:
            def list_devices(self):
                raise OSError("SANE backend unavailable")

        monkeypatch.setattr(device_module, "_service_factory", FailingService)
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=3, address=4)])

        assert [item.id for item in coolscanpy.get_devices()] == ["usb:3:4"]

    def test_open_succeeds_without_python_sane(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=1, address=7)])

        dev = coolscanpy.open("ls5000")
        try:
            assert dev.capabilities.adapter_frame_control is True
        finally:
            dev.close()

    def test_plain_scan_without_python_sane_raises_import_error_with_install_hint(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=1, address=7)])
        dev = coolscanpy.open("ls5000")
        try:
            with pytest.raises(
                ImportError, match=r'pip install "coolscanpy\[scanner\]"'
            ):
                dev.scan()
        finally:
            dev.close()

    def test_eject_without_python_sane_raises_import_error(
        self, python_sane_unavailable: None, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=1, address=7)])
        dev = coolscanpy.open("ls5000")
        try:
            with pytest.raises(ImportError, match="python-sane not importable"):
                dev.eject()
        finally:
            dev.close()

    def test_roll_is_reachable_without_python_sane(
        self,
        python_sane_unavailable: None,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        """The roll-feeder extension never uses SANE (see the module
        docstrings across coolscanpy._roll/roll/protocol/capture): a Device
        opened through the pyusb fallback must be able to preview and
        fine-scan a roll exactly like a SANE-backed one, using the same
        injectable adapter/workflow doubles as every other roll test above
        -- still no real hardware, and now no python-sane either."""

        _mock_usb_find(monkeypatch, [_FakeUsbDevice(bus=1, address=7)])
        dev = coolscanpy.open("ls5000")
        roll, _worker = _make_roll(tmp_path, dev, batch_spawner=_success_spawner([]))
        try:
            thumbnails = roll.preview()
            assert len(thumbnails) == 40

            slot = 5
            if roll.needs_approval(slot):
                roll.approve(slot)
            frame = roll.scan(slot)

            assert frame.slot == slot
            assert frame.receipt.device_id == dev._info.id
        finally:
            roll.close()
            dev.close()

    def test_fingerprint_refused_and_manual_review_required_are_roll_mismatch(
        self,
    ) -> None:
        assert issubclass(coolscanpy.FingerprintRefused, coolscanpy.RollMismatch)
        assert issubclass(coolscanpy.ManualReviewRequired, coolscanpy.RollMismatch)
        assert issubclass(coolscanpy.RefeedRequired, coolscanpy.RollMismatch)

    def test_fingerprint_refused_carries_comparison(self) -> None:
        comparison = coolscanpy.FingerprintComparison(
            matches=False,
            reason="test",
            compared_frames=1,
            visual_median_hamming=None,
            visual_p90_hamming=None,
            frame_start_median_delta_rows=None,
            frame_start_max_delta_rows=None,
        )
        error = coolscanpy.FingerprintRefused("nope", comparison=comparison)
        assert error.comparison is comparison

    def test_manual_review_required_carries_slot(self) -> None:
        error = coolscanpy.ManualReviewRequired("nope", slot=7)
        assert error.slot == 7
