"""Fail-closed LS-5000 negative-density evidence and exact evaluator.

Nikon's active 16-bit RGB path computes three density values from three pieces
of acquisition state: three ``READ(0x8c)`` calibration values, a distinct
three-integer exposure record populated through capability ``0x10d`` in bank
``f03``, and a private row-planar RGB buffer at density-child ``+0x44``.

All three producers are now pinned for the archived event.  The density source
is the complete 97-dpi wire READ run at command sequence 564 through 611: 6,104
physical rows of 1,024 bytes.  Nikon keeps the first 576 bytes of each row as
planar 16-bit RGB (96 samples per channel), discards the remaining 448 bytes,
then endian-converts the compact buffer passed to the density routine.  Its raw
wire SHA-256 is
``5069d64defc0df8bdc2769c055b24576d4933b52dcd89a8e8a7b1777875661c4``.

This module has no USB or filesystem access.  It validates acquisition
identities and hashes already-captured bytes, then evaluates the statically
decoded ``LS5000.md3!0x10088810`` row statistic.  A caller cannot accidentally
mix a calibration, source, and exposure record from different sessions,
attempts, or scan identities.

Static Nikon evidence proves the first three producer integers: the
``READ(0x8c)`` color 1/2/3 path decodes each response's big-endian uint32 into
record slots 0..2.  The denominator path is also closed: capability ``0x129``
selects the bank, while per-channel capability ``0x10d`` supplies the exposure.
``0x10077ee0..0x10077f22`` writes that value into the ``f03`` record and the
mode-2 object copies the three channel values into ``+0x34/+0x38/+0x3c``.
The ``SET_WINDOW`` path reads the same dynamic ``0x10d`` value from ``f03`` and
emits it big-endian at absolute window offset 54.

The source mechanics are proven independently.
``LS5000.md3!0x100845c0`` gives the scanner a response-sized row transfer buffer
through ``0x100836a0``; the
completion callback ``0x1007ec60 -> 0x10082720`` invokes ``0x1007eb80``, which
compacts the three RGB planes while preserving row-planar R/G/B order;
``0x10083830`` passes that compact buffer into the mode-2 object;
``0x1008c0a0`` and ``0x10089750`` copy and endian-convert exactly 96 * 3 words
for each of 6,104 rows into ``child+0x44``; and ``0x10089140`` passes that buffer
to ``0x10088810`` with layout 1.

For the archived source, rows 75 through 224 yield selected means
``(33182.166666666664, 29120.114583333332, 22777.90625)``.  Together with the
three calibration numerators and the source-pass ``f03`` triplet
``(70307, 136614, 125470)``, they reproduce Nikon's captured density doubles.
Preserving Nikon's multiply/divide/divide operation order before macOS
``log10`` matches all three binary64 results exactly.

The separate 285-dpi RGBI pass is the analyzer/builder raster, not the density
source.  Its ``f02``/final-fine exposure triplet must remain a distinct field
and is not a valid substitute for the density-source ``f03`` triplet.
"""

from __future__ import annotations

import hashlib
import json
import math
import struct
from dataclasses import dataclass

import numpy as np

from coolscanpy.exceptions import MeterUnusableError


CHANNELS = ("R", "G", "B")
CALIBRATION_COLOR_IDS = (1, 2, 3)
METER_ROWS_FIRST = 75
METER_ROWS_STOP = 225
DENSITY_SOURCE_RESOLUTION_DPI = 97
DENSITY_SOURCE_NATIVE_RESOLUTION_DPI = 4_000
DENSITY_SOURCE_NATIVE_WIDTH = 3_946
DENSITY_SOURCE_SCALE_DIVISOR = 41
DENSITY_SOURCE_FRAME_NATIVE_HEIGHT = 5_959
DENSITY_SOURCE_MINIMUM_STARTUP_RECORDS = 2
DENSITY_SOURCE_MAXIMUM_STARTUP_RECORDS = 40
DENSITY_SOURCE_WIDTH = 96


def density_source_geometry_for_startup_records(
    startup_records: int,
) -> tuple[int, int]:
    """Derive the exact two-row-aligned density geometry for a startup table."""

    if (
        type(startup_records) is not int
        or not DENSITY_SOURCE_MINIMUM_STARTUP_RECORDS
        <= startup_records
        <= DENSITY_SOURCE_MAXIMUM_STARTUP_RECORDS
    ):
        raise ValueError("density source startup record count must be in 2..40")
    native_height = (startup_records + 2) * DENSITY_SOURCE_FRAME_NATIVE_HEIGHT
    height = native_height // DENSITY_SOURCE_SCALE_DIVISOR
    if height % 2:
        height += 1
        native_height = height * DENSITY_SOURCE_SCALE_DIVISOR
    return native_height, height


DENSITY_SOURCE_NATIVE_HEIGHT, DENSITY_SOURCE_HEIGHT = (
    density_source_geometry_for_startup_records(
        DENSITY_SOURCE_MAXIMUM_STARTUP_RECORDS
    )
)
DENSITY_SOURCE_INPUT_CHANNELS = 3
DENSITY_SOURCE_DENSITY_CHANNELS = 3
DENSITY_SOURCE_SAMPLE_BITS = 16
DENSITY_SOURCE_SAMPLE_BYTES = 2
DENSITY_SOURCE_RGB_ROW_BYTES = (
    DENSITY_SOURCE_WIDTH * DENSITY_SOURCE_DENSITY_CHANNELS * DENSITY_SOURCE_SAMPLE_BYTES
)
DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES = 448
DENSITY_SOURCE_ROW_STRIDE_BYTES = (
    DENSITY_SOURCE_RGB_ROW_BYTES + DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES
)
DENSITY_SOURCE_DISCARDED_ROW_BYTES = DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES
DENSITY_SOURCE_WIRE_BYTES = DENSITY_SOURCE_HEIGHT * DENSITY_SOURCE_ROW_STRIDE_BYTES
DENSITY_SOURCE_CHILD_BYTES = DENSITY_SOURCE_HEIGHT * DENSITY_SOURCE_RGB_ROW_BYTES
DENSITY_SOURCE_SUPPORTED_HEIGHTS = frozenset(
    density_source_geometry_for_startup_records(startup_records)
    for startup_records in range(
        DENSITY_SOURCE_MINIMUM_STARTUP_RECORDS,
        DENSITY_SOURCE_MAXIMUM_STARTUP_RECORDS + 1,
    )
)
DENSITY_SOURCE_LAYOUT = "row-planar-rgb-plus-opaque-tail"
DENSITY_SOURCE_BYTE_ORDER = "big"
ARCHIVED_DENSITY_SOURCE_WIRE_SHA256 = (
    "5069d64defc0df8bdc2769c055b24576d4933b52dcd89a8e8a7b1777875661c4"
)
ARCHIVED_DENSITY_SOURCE_COMPACT_BE_SHA256 = (
    "7b6a2de9aba57aeaf07eaadaf3968e8fc9996b8aa99c3a9324c8ca9334fce32f"
)
ARCHIVED_DENSITY_SOURCE_CHILD_LE_SHA256 = (
    "e94378f42c5107d0ef174a0e9ad202f3a613cb1e04c9468c44a38c51a1510598"
)
FULL_SCALE = 65_535.0
SATURATION_LIMIT = 0.9 * FULL_SCALE
ALGORITHM_ID = "ls5000-md3-10088810-layout1-u16-proven-inputs-macos-binary64-exact-v6"
EXPOSURE_BINDING_STATUS = (
    "proven-density-source-capability-0x10d-f03-to-mode2-and-window-offset54"
)
SOURCE_BINDING_STATUS = (
    "proven-97dpi-seq564-611-row-compaction-to-density-child-plus-0x44"
)
ARITHMETIC_BACKEND_STATUS = (
    "runtime-gated-macos-binary64-nikon-order-zero-ulp-reference-triplet"
)
DENSITY_DENOMINATOR_DOMAIN = "density-source-pass-capability-0x10d-bank-f03"

_CALIBRATION_CDB_TEMPLATE = bytes.fromhex("28008c00010300000a80")
_CALIBRATION_PAYLOAD_PREFIX = bytes.fromhex("8c2000000004")
_DENSITY_RANGES = ((0.121, 0.526), (0.459, 0.969), (0.654, 1.137))
_DENSITY_FALLBACKS = (0.316, 0.737, 0.886)
_ARITHMETIC_REFERENCE_NUMERATORS = (57_114, 48_036, 32_683)
_ARITHMETIC_REFERENCE_DENOMINATORS = (70_307, 136_614, 125_470)
_ARITHMETIC_REFERENCE_ROW_MEANS = (
    3_185_488 / 96.0,
    2_795_531 / 96.0,
    2_186_679 / 96.0,
)
_ARITHMETIC_REFERENCE_BINARY64_BE_HEX = (
    "3fd8b159777b9d5f",
    "3fe9cc75f7f6705a",
    "3ff0b0dae0533338",
)


def _require_digest(value: object, label: str) -> str:
    if (
        type(value) is not str
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _require_identity(value: object, label: str) -> str:
    if type(value) is not str or not value:
        raise ValueError(f"{label} must be a nonempty string")
    return value


def _require_u32(value: object, label: str) -> int:
    if type(value) is not int or not 1 <= value <= 0xFFFFFFFF:
        raise ValueError(f"{label} must be a nonzero uint32")
    return value


def verify_nikon_density_arithmetic_backend() -> None:
    """Fail closed when this host's binary64/libm result is not Nikon-exact.

    The recovered multiply/divide/divide order alone is insufficient on a
    platform whose ``log10`` rounds the green reference input one ULP away
    from the captured Nikon result.  Replaying all three pinned reference
    inputs at runtime makes that platform dependency explicit before any
    density result can be promoted.
    """

    actual: list[str] = []
    for numerator, denominator, row_mean in zip(
        _ARITHMETIC_REFERENCE_NUMERATORS,
        _ARITHMETIC_REFERENCE_DENOMINATORS,
        _ARITHMETIC_REFERENCE_ROW_MEANS,
        strict=True,
    ):
        product = float(numerator) * row_mean
        quotient = product / float(denominator)
        ratio = FULL_SCALE / quotient
        actual.append(struct.pack(">d", math.log10(ratio)).hex())
    if tuple(actual) != _ARITHMETIC_REFERENCE_BINARY64_BE_HEX:
        raise RuntimeError(
            "host math.log10 is not bit-exact for the Nikon density reference "
            f"triplet: got {tuple(actual)!r}"
        )


def _calibration_cdb(color_id: int) -> bytes:
    expected = bytearray(_CALIBRATION_CDB_TEMPLATE)
    expected[4] = color_id
    return bytes(expected)


@dataclass(frozen=True)
class DensityCalibrationRead:
    """One validated RGB ``READ(0x8c)`` calibration response."""

    color_id: int
    value: int
    cdb_hex: str
    payload_hex: str
    payload_sha256: str

    def __post_init__(self) -> None:
        if type(self.color_id) is not int or self.color_id not in CALIBRATION_COLOR_IDS:
            raise ValueError("calibration color_id must be 1, 2, or 3")
        _require_u32(self.value, "calibration value")
        if type(self.cdb_hex) is not str or len(self.cdb_hex) != 20:
            raise ValueError("calibration CDB must be a 10-byte hex string")
        try:
            cdb = bytes.fromhex(self.cdb_hex)
        except ValueError as error:
            raise ValueError("calibration CDB is not hexadecimal") from error
        if cdb != _calibration_cdb(self.color_id):
            raise ValueError("calibration CDB does not match its RGB channel")
        if type(self.payload_hex) is not str or len(self.payload_hex) != 20:
            raise ValueError("calibration payload must be a 10-byte hex string")
        try:
            payload = bytes.fromhex(self.payload_hex)
        except ValueError as error:
            raise ValueError("calibration payload is not hexadecimal") from error
        if payload[:6] != _CALIBRATION_PAYLOAD_PREFIX:
            raise ValueError("calibration payload header is invalid")
        if int.from_bytes(payload[6:10], "big") != self.value:
            raise ValueError("calibration payload does not contain its decoded value")
        _require_digest(self.payload_sha256, "calibration payload_sha256")
        if hashlib.sha256(payload).hexdigest() != self.payload_sha256:
            raise ValueError("calibration payload SHA-256 does not match its bytes")


def decode_density_calibration_read(
    cdb: bytes | bytearray | memoryview,
    payload: bytes | bytearray | memoryview,
) -> DensityCalibrationRead:
    """Decode one exact 10-byte LS-5000 RGB calibration response.

    The RGB channel is carried in CDB byte four.  Static tracing proves the
    response's final big-endian uint32 is copied into Nikon analyzer record
    slots 0..2.  Every other command and response byte is fixed and checked.
    """

    cdb_bytes = bytes(cdb)
    payload_bytes = bytes(payload)
    if len(cdb_bytes) != len(_CALIBRATION_CDB_TEMPLATE):
        raise ValueError("density calibration CDB must contain exactly 10 bytes")
    color_id = cdb_bytes[4]
    if color_id not in CALIBRATION_COLOR_IDS:
        raise ValueError("density calibration CDB is not an RGB READ(0x8c)")
    if cdb_bytes != _calibration_cdb(color_id):
        raise ValueError("density calibration CDB does not match the pinned form")
    if len(payload_bytes) != 10:
        raise ValueError("density calibration response must contain exactly 10 bytes")
    if payload_bytes[:6] != _CALIBRATION_PAYLOAD_PREFIX:
        raise ValueError("density calibration response header is invalid")
    value = int.from_bytes(payload_bytes[6:10], "big")
    _require_u32(value, f"{CHANNELS[color_id - 1]} calibration value")
    return DensityCalibrationRead(
        color_id=color_id,
        value=value,
        cdb_hex=cdb_bytes.hex(),
        payload_hex=payload_bytes.hex(),
        payload_sha256=hashlib.sha256(payload_bytes).hexdigest(),
    )


@dataclass(frozen=True)
class DensityCalibration:
    """The three calibration numerators bound to one reservation session."""

    session_id: str
    numerators: tuple[int, int, int]
    payload_hex: tuple[str, str, str]
    payload_sha256: tuple[str, str, str]

    def __post_init__(self) -> None:
        _require_identity(self.session_id, "calibration session_id")
        if type(self.numerators) is not tuple or len(self.numerators) != 3:
            raise ValueError("density calibration must contain three numerators")
        for channel, value in zip(CHANNELS, self.numerators, strict=True):
            _require_u32(value, f"{channel} calibration numerator")
        if type(self.payload_hex) is not tuple or len(self.payload_hex) != 3:
            raise ValueError("density calibration must contain three raw payloads")
        if type(self.payload_sha256) is not tuple or len(self.payload_sha256) != 3:
            raise ValueError("density calibration must contain three payload digests")
        for index, (channel, value, payload_hex, digest) in enumerate(
            zip(
                CHANNELS,
                self.numerators,
                self.payload_hex,
                self.payload_sha256,
                strict=True,
            )
        ):
            DensityCalibrationRead(
                color_id=index + 1,
                value=value,
                cdb_hex=_calibration_cdb(index + 1).hex(),
                payload_hex=payload_hex,
                payload_sha256=digest,
            )
            _require_digest(digest, f"{channel} calibration payload digest")

    def to_dict(self) -> dict[str, object]:
        return {
            "session_id": self.session_id,
            "numerators_rgb": list(self.numerators),
            "payload_hex_rgb": list(self.payload_hex),
            "payload_sha256_rgb": list(self.payload_sha256),
        }

    @classmethod
    def from_dict(cls, payload: object) -> "DensityCalibration":
        """Rehydrate the exact JSON-safe worker-journal record."""

        if type(payload) is not dict or set(payload) != {
            "session_id",
            "numerators_rgb",
            "payload_hex_rgb",
            "payload_sha256_rgb",
        }:
            raise ValueError("density calibration journal record is malformed")
        numerators = payload["numerators_rgb"]
        payload_hex = payload["payload_hex_rgb"]
        digests = payload["payload_sha256_rgb"]
        if (
            type(numerators) is not list
            or type(payload_hex) is not list
            or type(digests) is not list
        ):
            raise ValueError("density calibration journal arrays are malformed")
        return cls(
            session_id=payload["session_id"],
            numerators=tuple(numerators),
            payload_hex=tuple(payload_hex),
            payload_sha256=tuple(digests),
        )


def assemble_density_calibration(
    reads: tuple[DensityCalibrationRead, DensityCalibrationRead, DensityCalibrationRead]
    | list[DensityCalibrationRead],
    *,
    session_id: str,
) -> DensityCalibration:
    """Require one ordered, nonduplicated R/G/B calibration group."""

    items = tuple(reads)
    if len(items) != 3 or any(
        not isinstance(item, DensityCalibrationRead) for item in items
    ):
        raise ValueError("density calibration requires exactly three decoded reads")
    if tuple(item.color_id for item in items) != CALIBRATION_COLOR_IDS:
        raise ValueError("density calibration reads must be ordered R, G, B")
    return DensityCalibration(
        session_id=session_id,
        numerators=tuple(item.value for item in items),
        payload_hex=tuple(item.payload_hex for item in items),
        payload_sha256=tuple(item.payload_sha256 for item in items),
    )


@dataclass(frozen=True)
class NikonDensityCalibrationBinding:
    """Bind session calibration evidence to one preview acquisition."""

    calibration: DensityCalibration
    capture_attempt_id: str
    scan_identity: str

    def __post_init__(self) -> None:
        if not isinstance(self.calibration, DensityCalibration):
            raise TypeError("calibration must be a DensityCalibration")
        _require_identity(self.capture_attempt_id, "capture_attempt_id")
        _require_identity(self.scan_identity, "calibration scan_identity")

    @property
    def session_id(self) -> str:
        return self.calibration.session_id

    def to_dict(self) -> dict[str, object]:
        return {
            "calibration": self.calibration.to_dict(),
            "capture_attempt_id": self.capture_attempt_id,
            "scan_identity": self.scan_identity,
        }

    @classmethod
    def from_dict(cls, payload: object) -> "NikonDensityCalibrationBinding":
        if type(payload) is not dict or set(payload) != {
            "calibration",
            "capture_attempt_id",
            "scan_identity",
        }:
            raise ValueError("density calibration binding journal record is malformed")
        return cls(
            calibration=DensityCalibration.from_dict(payload["calibration"]),
            capture_attempt_id=payload["capture_attempt_id"],
            scan_identity=payload["scan_identity"],
        )


@dataclass(frozen=True)
class NikonDensitySourceBinding:
    """Exact identity and byte geometry of Nikon's 97-dpi density source.

    Every geometry field is intentionally carried in the receipt and checked
    against the recovered vendor contract.  This prevents the separate 285-dpi
    RGBI analyzer scan, a differently padded pass, or bytes from another scan
    from being silently treated as Nikon's private ``child+0x44`` source.
    """

    session_id: str
    capture_attempt_id: str
    scan_identity: str
    resolution_dpi: int
    native_resolution_dpi: int
    native_width: int
    native_height: int
    scale_divisor: int
    width: int
    height: int
    input_channels: int
    density_channels: int
    sample_bits: int
    rgb_row_bytes: int
    row_stride_bytes: int
    opaque_row_tail_bytes: int
    discarded_row_bytes: int
    layout: str
    byte_order: str
    wire_sha256: str
    compact_buffer_be_sha256: str
    child_buffer_sha256: str

    def __post_init__(self) -> None:
        _require_identity(self.session_id, "density source session_id")
        _require_identity(self.capture_attempt_id, "capture_attempt_id")
        _require_identity(self.scan_identity, "density source scan_identity")
        exact_fields = (
            ("resolution_dpi", self.resolution_dpi, DENSITY_SOURCE_RESOLUTION_DPI),
            (
                "native_resolution_dpi",
                self.native_resolution_dpi,
                DENSITY_SOURCE_NATIVE_RESOLUTION_DPI,
            ),
            ("native_width", self.native_width, DENSITY_SOURCE_NATIVE_WIDTH),
            (
                "scale_divisor",
                self.scale_divisor,
                DENSITY_SOURCE_SCALE_DIVISOR,
            ),
            ("width", self.width, DENSITY_SOURCE_WIDTH),
            (
                "input_channels",
                self.input_channels,
                DENSITY_SOURCE_INPUT_CHANNELS,
            ),
            (
                "density_channels",
                self.density_channels,
                DENSITY_SOURCE_DENSITY_CHANNELS,
            ),
            ("sample_bits", self.sample_bits, DENSITY_SOURCE_SAMPLE_BITS),
            (
                "rgb_row_bytes",
                self.rgb_row_bytes,
                DENSITY_SOURCE_RGB_ROW_BYTES,
            ),
            (
                "row_stride_bytes",
                self.row_stride_bytes,
                DENSITY_SOURCE_ROW_STRIDE_BYTES,
            ),
            (
                "opaque_row_tail_bytes",
                self.opaque_row_tail_bytes,
                DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES,
            ),
            (
                "discarded_row_bytes",
                self.discarded_row_bytes,
                DENSITY_SOURCE_DISCARDED_ROW_BYTES,
            ),
        )
        for name, value, expected in exact_fields:
            if type(value) is not int or value != expected:
                raise ValueError(f"density source {name} must be exactly {expected}")
        if (
            type(self.native_height) is not int
            or type(self.height) is not int
            or (self.native_height, self.height) not in DENSITY_SOURCE_SUPPORTED_HEIGHTS
        ):
            raise ValueError(
                "density source native_height/height must be a proven preview geometry"
            )
        if self.layout != DENSITY_SOURCE_LAYOUT:
            raise ValueError(f"density source layout must be {DENSITY_SOURCE_LAYOUT}")
        if self.byte_order != DENSITY_SOURCE_BYTE_ORDER:
            raise ValueError(
                f"density source byte_order must be {DENSITY_SOURCE_BYTE_ORDER}"
            )
        if (
            self.rgb_row_bytes + self.opaque_row_tail_bytes != self.row_stride_bytes
            or self.opaque_row_tail_bytes != self.discarded_row_bytes
            or int(self.native_resolution_dpi / self.resolution_dpi)
            != self.scale_divisor
            or int(self.native_width / self.scale_divisor) != self.width
            or int(self.native_height / self.scale_divisor) != self.height
        ):
            raise ValueError("density source geometry/row-stride derivation is invalid")
        _require_digest(self.wire_sha256, "density source wire_sha256")
        _require_digest(
            self.compact_buffer_be_sha256,
            "density source compact_buffer_be_sha256",
        )
        _require_digest(
            self.child_buffer_sha256,
            "density source child_buffer_sha256",
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "session_id": self.session_id,
            "capture_attempt_id": self.capture_attempt_id,
            "scan_identity": self.scan_identity,
            "resolution_dpi": self.resolution_dpi,
            "native_resolution_dpi": self.native_resolution_dpi,
            "native_width": self.native_width,
            "native_height": self.native_height,
            "scale_divisor": self.scale_divisor,
            "width": self.width,
            "height": self.height,
            "input_channels": self.input_channels,
            "density_channels": self.density_channels,
            "sample_bits": self.sample_bits,
            "rgb_row_bytes": self.rgb_row_bytes,
            "row_stride_bytes": self.row_stride_bytes,
            "opaque_row_tail_bytes": self.opaque_row_tail_bytes,
            "discarded_row_bytes": self.discarded_row_bytes,
            "layout": self.layout,
            "byte_order": self.byte_order,
            "wire_sha256": self.wire_sha256,
            "compact_buffer_be_sha256": self.compact_buffer_be_sha256,
            "child_buffer_sha256": self.child_buffer_sha256,
        }

    @classmethod
    def from_dict(cls, payload: object) -> "NikonDensitySourceBinding":
        if type(payload) is not dict or set(payload) != {
            "session_id",
            "capture_attempt_id",
            "scan_identity",
            "resolution_dpi",
            "native_resolution_dpi",
            "native_width",
            "native_height",
            "scale_divisor",
            "width",
            "height",
            "input_channels",
            "density_channels",
            "sample_bits",
            "rgb_row_bytes",
            "row_stride_bytes",
            "opaque_row_tail_bytes",
            "discarded_row_bytes",
            "layout",
            "byte_order",
            "wire_sha256",
            "compact_buffer_be_sha256",
            "child_buffer_sha256",
        }:
            raise ValueError("density source binding journal record is malformed")
        return cls(**payload)


@dataclass(frozen=True)
class NikonDensityExposureBinding:
    """Proven density-source cap-0x10d/f03 RGB exposure record."""

    session_id: str
    capture_attempt_id: str
    scan_identity: str
    density_f03_exposures_raw_10ns: tuple[int, int, int]

    def __post_init__(self) -> None:
        _require_identity(self.session_id, "exposure session_id")
        _require_identity(self.capture_attempt_id, "capture_attempt_id")
        _require_identity(self.scan_identity, "exposure scan_identity")
        exposures = self.density_f03_exposures_raw_10ns
        if type(exposures) is not tuple or len(exposures) != 3:
            raise ValueError("density f03 exposure binding must contain R, G, B")
        for channel, value in zip(CHANNELS, exposures, strict=True):
            _require_u32(value, f"{channel} density f03 exposure")

    def to_dict(self) -> dict[str, object]:
        return {
            "session_id": self.session_id,
            "capture_attempt_id": self.capture_attempt_id,
            "scan_identity": self.scan_identity,
            "density_f03_exposures_raw_10ns_rgb": list(
                self.density_f03_exposures_raw_10ns
            ),
        }

    @classmethod
    def from_dict(cls, payload: object) -> "NikonDensityExposureBinding":
        if type(payload) is not dict or set(payload) != {
            "session_id",
            "capture_attempt_id",
            "scan_identity",
            "density_f03_exposures_raw_10ns_rgb",
        }:
            raise ValueError("density exposure binding journal record is malformed")
        exposures = payload["density_f03_exposures_raw_10ns_rgb"]
        if type(exposures) is not list:
            raise ValueError("density exposure journal exposures are malformed")
        return cls(
            session_id=payload["session_id"],
            capture_attempt_id=payload["capture_attempt_id"],
            scan_identity=payload["scan_identity"],
            density_f03_exposures_raw_10ns=tuple(exposures),
        )


@dataclass(frozen=True)
class NikonDensityResult:
    """Promotable receipt with proven input bindings and binary64 outputs."""

    algorithm_id: str
    session_id: str
    capture_attempt_id: str
    scan_identity: str
    source_wire_sha256: str
    source_compact_buffer_be_sha256: str
    source_child_buffer_sha256: str
    source_native_height: int
    source_height: int
    calibration_payload_sha256: tuple[str, str, str]
    numerators: tuple[int, int, int]
    density_f03_denominators: tuple[int, int, int]
    selected_rows: tuple[int, int, int]
    selected_row_means: tuple[float, float, float]
    raw_densities: tuple[float, float, float]
    densities: tuple[float, float, float]
    fallback_applied: tuple[bool, bool, bool]

    @property
    def promotable(self) -> bool:
        """All source, exposure, calibration, and arithmetic gates are closed."""

        return True

    @property
    def exposure_binding_status(self) -> str:
        return EXPOSURE_BINDING_STATUS

    @property
    def source_binding_status(self) -> str:
        return SOURCE_BINDING_STATUS

    @property
    def arithmetic_backend_status(self) -> str:
        return ARITHMETIC_BACKEND_STATUS

    @property
    def density_denominator_domain(self) -> str:
        return DENSITY_DENOMINATOR_DOMAIN

    def to_dict(self) -> dict[str, object]:
        return {
            "algorithm_id": self.algorithm_id,
            "promotable": self.promotable,
            "exposure_binding_status": self.exposure_binding_status,
            "source_binding_status": self.source_binding_status,
            "arithmetic_backend_status": self.arithmetic_backend_status,
            "density_denominator_domain": self.density_denominator_domain,
            "session_id": self.session_id,
            "capture_attempt_id": self.capture_attempt_id,
            "scan_identity": self.scan_identity,
            "source_wire_sha256": self.source_wire_sha256,
            "source_compact_buffer_be_sha256": (self.source_compact_buffer_be_sha256),
            "source_child_buffer_sha256": self.source_child_buffer_sha256,
            "calibration_payload_sha256_rgb": list(self.calibration_payload_sha256),
            "source_resolution_dpi": DENSITY_SOURCE_RESOLUTION_DPI,
            "source_native_height": self.source_native_height,
            "source_geometry": [
                self.source_height,
                DENSITY_SOURCE_WIDTH,
                DENSITY_SOURCE_INPUT_CHANNELS,
            ],
            "source_rgb_row_bytes": DENSITY_SOURCE_RGB_ROW_BYTES,
            "source_row_stride_bytes": DENSITY_SOURCE_ROW_STRIDE_BYTES,
            "source_opaque_row_tail_bytes": DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES,
            "source_discarded_row_bytes": DENSITY_SOURCE_DISCARDED_ROW_BYTES,
            "source_layout": DENSITY_SOURCE_LAYOUT,
            "numerators_rgb": list(self.numerators),
            "density_f03_denominators_raw_10ns_rgb": list(
                self.density_f03_denominators
            ),
            "selected_rows_rgb": list(self.selected_rows),
            "selected_row_means_rgb": list(self.selected_row_means),
            "raw_densities_rgb": list(self.raw_densities),
            "densities_rgb": list(self.densities),
            "density_binary64_be_hex_rgb": [
                struct.pack(">d", density).hex() for density in self.densities
            ],
            "fallback_applied_rgb": list(self.fallback_applied),
        }


DENSITY_EVIDENCE_SCHEMA_VERSION = 1
DENSITY_EVIDENCE_SCOPE = "reservation-preview"
PER_FRAME_BINDING_STATUS = "requires-explicit-frame-ownership-receipt"
DENSITY_FRAME_OWNERSHIP_SCHEMA_VERSION = 1
DENSITY_FRAME_OWNERSHIP_SCOPE = "reservation-preview-frame"
DENSITY_FRAME_OWNERSHIP_STATUS = (
    "proven-exact-reservation-preview-registration-and-transport"
)
NIKON_ANALYZER_RESOLUTION_DPI = 285
NIKON_ANALYZER_SHAPE = (425, 281, 3)
NIKON_ANALYZER_RECTANGLE = (50, 36, 375, 245)


def _canonical_json_sha256(payload: dict[str, object]) -> str:
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True)
class NikonDensityEvidence:
    """Immutable reservation-preview evidence, including its raw source.

    This object is reusable only inside the exact uninterrupted reservation
    and preview identified by ``preview_identity_sha256``.  It deliberately
    does not claim ownership of any fine-scan frame by itself; that edge is
    closed by :class:`NikonDensityFrameOwnershipReceipt`.
    """

    source_payload: bytes
    calibration_binding: NikonDensityCalibrationBinding
    source_binding: NikonDensitySourceBinding
    exposure_binding: NikonDensityExposureBinding
    result: NikonDensityResult

    @property
    def scope(self) -> str:
        return DENSITY_EVIDENCE_SCOPE

    @property
    def per_frame_binding_status(self) -> str:
        return PER_FRAME_BINDING_STATUS

    @property
    def preview_identity_sha256(self) -> str:
        """Canonical identity of every producer feeding the Nikon result."""

        return _canonical_json_sha256(self._preview_identity_material())

    def _preview_identity_material(self) -> dict[str, object]:
        return {
            "schema_version": DENSITY_EVIDENCE_SCHEMA_VERSION,
            "scope": self.scope,
            "source_payload_bytes": len(self.source_payload),
            "calibration_binding": self.calibration_binding.to_dict(),
            "source_binding": self.source_binding.to_dict(),
            "exposure_binding": self.exposure_binding.to_dict(),
            "result": self.result.to_dict(),
        }

    def __post_init__(self) -> None:
        if type(self.source_payload) is not bytes:
            raise TypeError("density evidence source_payload must be immutable bytes")
        if not isinstance(self.calibration_binding, NikonDensityCalibrationBinding):
            raise TypeError("density evidence calibration_binding has the wrong type")
        if not isinstance(self.source_binding, NikonDensitySourceBinding):
            raise TypeError("density evidence source_binding has the wrong type")
        if not isinstance(self.exposure_binding, NikonDensityExposureBinding):
            raise TypeError("density evidence exposure_binding has the wrong type")
        if not isinstance(self.result, NikonDensityResult):
            raise TypeError("density evidence result has the wrong type")
        replay = evaluate_nikon_density(
            self.source_payload,
            calibration_binding=self.calibration_binding,
            source_binding=self.source_binding,
            exposure_binding=self.exposure_binding,
        )
        if replay != self.result:
            raise ValueError("density evidence result does not replay from its inputs")

    def to_dict(self) -> dict[str, object]:
        """Return the JSON-safe receipt; raw bytes remain on the object only."""

        return {
            "schema_version": DENSITY_EVIDENCE_SCHEMA_VERSION,
            "scope": self.scope,
            "per_frame_binding_status": self.per_frame_binding_status,
            "preview_identity_sha256": self.preview_identity_sha256,
            "source_payload_bytes": len(self.source_payload),
            "calibration_binding": self.calibration_binding.to_dict(),
            "source_binding": self.source_binding.to_dict(),
            "exposure_binding": self.exposure_binding.to_dict(),
            "result": self.result.to_dict(),
        }


@dataclass(frozen=True)
class NikonDensityFrameOwnershipReceipt:
    """Fail-closed ownership of one preview density result by one frame.

    A receipt is valid only while the same scanner reservation, 97-dpi
    preview, transport table, reviewed/fresh registration pair, and batch
    identity remain explicit.  A new reservation, preview, registration, film
    move, eject/refeed, or any absent identity therefore cannot inherit the
    prior density result.
    """

    reservation_id: str
    batch_session_id: str
    preview_sha256: str
    preview_identity_sha256: str
    transport_table_sha256: str
    reviewed_fingerprint_sha256: str
    fresh_fingerprint_sha256: str
    frame_capture_attempt_id: str
    frame_index: int
    frame_total: int
    selected_slots: tuple[int, ...]
    selected_slot: int

    @property
    def schema_version(self) -> int:
        return DENSITY_FRAME_OWNERSHIP_SCHEMA_VERSION

    @property
    def scope(self) -> str:
        return DENSITY_FRAME_OWNERSHIP_SCOPE

    @property
    def binding_status(self) -> str:
        return DENSITY_FRAME_OWNERSHIP_STATUS

    @property
    def session_reservation_retained(self) -> bool:
        return True

    @property
    def transport_identity_sha256(self) -> str:
        return _canonical_json_sha256(
            {
                "reservation_id": self.reservation_id,
                "batch_session_id": self.batch_session_id,
                "preview_sha256": self.preview_sha256,
                "preview_identity_sha256": self.preview_identity_sha256,
                "transport_table_sha256": self.transport_table_sha256,
                "reviewed_fingerprint_sha256": self.reviewed_fingerprint_sha256,
                "fresh_fingerprint_sha256": self.fresh_fingerprint_sha256,
                "selected_slots": list(self.selected_slots),
            }
        )

    def __post_init__(self) -> None:
        _require_identity(self.reservation_id, "density reservation_id")
        _require_identity(self.batch_session_id, "density batch_session_id")
        if self.reservation_id != self.batch_session_id:
            raise ValueError(
                "density reservation and batch session identities disagree"
            )
        for label, value in (
            ("preview_sha256", self.preview_sha256),
            ("preview_identity_sha256", self.preview_identity_sha256),
            ("transport_table_sha256", self.transport_table_sha256),
            ("reviewed_fingerprint_sha256", self.reviewed_fingerprint_sha256),
            ("fresh_fingerprint_sha256", self.fresh_fingerprint_sha256),
        ):
            _require_digest(value, f"density ownership {label}")
        _require_identity(
            self.frame_capture_attempt_id,
            "density frame_capture_attempt_id",
        )
        if type(self.frame_total) is not int or self.frame_total < 1:
            raise ValueError("density ownership frame_total must be positive")
        if (
            type(self.frame_index) is not int
            or not 1 <= self.frame_index <= self.frame_total
        ):
            raise ValueError("density ownership frame_index is outside the batch")
        if (
            type(self.selected_slots) is not tuple
            or len(self.selected_slots) != self.frame_total
            or not self.selected_slots
            or any(type(slot) is not int or slot < 1 for slot in self.selected_slots)
            or len(set(self.selected_slots)) != len(self.selected_slots)
        ):
            raise ValueError("density ownership selected_slots is malformed")
        if type(self.selected_slot) is not int or self.selected_slot < 1:
            raise ValueError("density ownership selected_slot must be positive")
        if self.selected_slots[self.frame_index - 1] != self.selected_slot:
            raise ValueError(
                "density ownership selected_slot does not match its batch index"
            )

    def validate_evidence(self, evidence: NikonDensityEvidence) -> None:
        """Raise if this frame cannot own exactly ``evidence``."""

        if not isinstance(evidence, NikonDensityEvidence):
            raise TypeError("density ownership requires NikonDensityEvidence")
        sessions = {
            evidence.calibration_binding.session_id,
            evidence.source_binding.session_id,
            evidence.exposure_binding.session_id,
            evidence.result.session_id,
        }
        if sessions != {self.reservation_id}:
            raise ValueError("density ownership reservation does not match evidence")
        if evidence.source_binding.wire_sha256 != self.preview_sha256:
            raise ValueError("density ownership preview does not match evidence")
        if evidence.preview_identity_sha256 != self.preview_identity_sha256:
            raise ValueError(
                "density ownership preview identity does not match evidence"
            )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "scope": self.scope,
            "binding_status": self.binding_status,
            "session_reservation_retained": self.session_reservation_retained,
            "reservation_id": self.reservation_id,
            "batch_session_id": self.batch_session_id,
            "preview_sha256": self.preview_sha256,
            "preview_identity_sha256": self.preview_identity_sha256,
            "transport_table_sha256": self.transport_table_sha256,
            "transport_identity_sha256": self.transport_identity_sha256,
            "reviewed_fingerprint_sha256": self.reviewed_fingerprint_sha256,
            "fresh_fingerprint_sha256": self.fresh_fingerprint_sha256,
            "frame_capture_attempt_id": self.frame_capture_attempt_id,
            "frame_index": self.frame_index,
            "frame_total": self.frame_total,
            "selected_slots": list(self.selected_slots),
            "selected_slot": self.selected_slot,
        }

    @classmethod
    def from_dict(cls, payload: object) -> "NikonDensityFrameOwnershipReceipt":
        expected_keys = {
            "schema_version",
            "scope",
            "binding_status",
            "session_reservation_retained",
            "reservation_id",
            "batch_session_id",
            "preview_sha256",
            "preview_identity_sha256",
            "transport_table_sha256",
            "transport_identity_sha256",
            "reviewed_fingerprint_sha256",
            "fresh_fingerprint_sha256",
            "frame_capture_attempt_id",
            "frame_index",
            "frame_total",
            "selected_slots",
            "selected_slot",
        }
        if type(payload) is not dict or set(payload) != expected_keys:
            raise ValueError("density frame ownership receipt is malformed")
        if (
            payload["schema_version"] != DENSITY_FRAME_OWNERSHIP_SCHEMA_VERSION
            or payload["scope"] != DENSITY_FRAME_OWNERSHIP_SCOPE
            or payload["binding_status"] != DENSITY_FRAME_OWNERSHIP_STATUS
            or payload["session_reservation_retained"] is not True
            or type(payload["selected_slots"]) is not list
        ):
            raise ValueError("density frame ownership contract is invalid")
        receipt = cls(
            reservation_id=payload["reservation_id"],
            batch_session_id=payload["batch_session_id"],
            preview_sha256=payload["preview_sha256"],
            preview_identity_sha256=payload["preview_identity_sha256"],
            transport_table_sha256=payload["transport_table_sha256"],
            reviewed_fingerprint_sha256=payload["reviewed_fingerprint_sha256"],
            fresh_fingerprint_sha256=payload["fresh_fingerprint_sha256"],
            frame_capture_attempt_id=payload["frame_capture_attempt_id"],
            frame_index=payload["frame_index"],
            frame_total=payload["frame_total"],
            selected_slots=tuple(payload["selected_slots"]),
            selected_slot=payload["selected_slot"],
        )
        if payload["transport_identity_sha256"] != receipt.transport_identity_sha256:
            raise ValueError("density frame transport identity digest is invalid")
        return receipt


def build_nikon_density_frame_ownership(
    evidence: NikonDensityEvidence,
    *,
    reservation_id: str,
    batch_session_id: str,
    transport_table_sha256: str,
    reviewed_fingerprint_sha256: str,
    fresh_fingerprint_sha256: str,
    frame_capture_attempt_id: str,
    frame_index: int,
    frame_total: int,
    selected_slots: tuple[int, ...],
    selected_slot: int,
) -> NikonDensityFrameOwnershipReceipt:
    """Bind one exact reservation preview to one frame, or fail closed."""

    if not isinstance(evidence, NikonDensityEvidence):
        raise TypeError("evidence must be NikonDensityEvidence")
    receipt = NikonDensityFrameOwnershipReceipt(
        reservation_id=reservation_id,
        batch_session_id=batch_session_id,
        preview_sha256=evidence.source_binding.wire_sha256,
        preview_identity_sha256=evidence.preview_identity_sha256,
        transport_table_sha256=transport_table_sha256,
        reviewed_fingerprint_sha256=reviewed_fingerprint_sha256,
        fresh_fingerprint_sha256=fresh_fingerprint_sha256,
        frame_capture_attempt_id=frame_capture_attempt_id,
        frame_index=frame_index,
        frame_total=frame_total,
        selected_slots=selected_slots,
        selected_slot=selected_slot,
    )
    receipt.validate_evidence(evidence)
    return receipt


def _canonical_receipt_bytes(payload: dict[str, object]) -> bytes:
    return json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


@dataclass(frozen=True)
class NikonExactBuilderEvidence:
    """Complete neutral producer contract for NegPy's native Stage-1 builder.

    Coolscanpy owns acquisition and therefore snapshots the settled 285-dpi
    analyzer plus final RGB SET_WINDOW exposures here.  The object contains
    no NegPy imports; NegPy converts this exact producer type to its own
    ``NativeBuilderEvidence`` at the application boundary.
    """

    session_id: str
    capture_attempt_id: str
    scan_identity: str
    slot: int
    density_source_wire_sha256: str
    density_source_child_sha256: str
    calibration_numerators: tuple[int, int, int]
    density_f03_denominators: tuple[int, int, int]
    densities: tuple[float, float, float]
    density_arithmetic: str
    frame_ownership_status: str
    frame_ownership_receipt: bytes
    frame_ownership_receipt_sha256: str
    density_evidence_receipt: bytes
    density_evidence_receipt_sha256: str
    reservation_id: str
    batch_session_id: str
    preview_sha256: str
    preview_identity_sha256: str
    transport_table_sha256: str
    transport_identity_sha256: str
    reviewed_fingerprint_sha256: str
    fresh_fingerprint_sha256: str
    frame_index: int
    frame_total: int
    selected_slots: tuple[int, ...]
    analyzer_rgb: np.ndarray
    analyzer_rgb_sha256: str
    analyzer_resolution_dpi: int
    analyzer_rectangle: tuple[int, int, int, int]
    final_f02_denominators: tuple[int, int, int]

    def __post_init__(self) -> None:
        for label, value in (
            ("session_id", self.session_id),
            ("capture_attempt_id", self.capture_attempt_id),
            ("scan_identity", self.scan_identity),
            ("reservation_id", self.reservation_id),
            ("batch_session_id", self.batch_session_id),
        ):
            _require_identity(value, f"exact builder {label}")
        if not (self.session_id == self.reservation_id == self.batch_session_id):
            raise ValueError("exact builder reservation identities disagree")
        if type(self.slot) is not int or not 1 <= self.slot <= 40:
            raise ValueError("exact builder slot must be in 1..40")
        for label, digest in (
            ("density source wire", self.density_source_wire_sha256),
            ("density source child", self.density_source_child_sha256),
            ("frame ownership receipt", self.frame_ownership_receipt_sha256),
            ("density evidence receipt", self.density_evidence_receipt_sha256),
            ("preview", self.preview_sha256),
            ("preview identity", self.preview_identity_sha256),
            ("transport table", self.transport_table_sha256),
            ("transport identity", self.transport_identity_sha256),
            ("reviewed fingerprint", self.reviewed_fingerprint_sha256),
            ("fresh fingerprint", self.fresh_fingerprint_sha256),
            ("analyzer RGB", self.analyzer_rgb_sha256),
        ):
            _require_digest(digest, f"exact builder {label} SHA-256")
        if self.density_arithmetic != ALGORITHM_ID:
            raise ValueError("exact builder density arithmetic is not certified")
        if self.frame_ownership_status != DENSITY_FRAME_OWNERSHIP_STATUS:
            raise ValueError("exact builder frame ownership is not proven")
        for label, values in (
            ("calibration numerators", self.calibration_numerators),
            ("density f03 denominators", self.density_f03_denominators),
            ("final f02 denominators", self.final_f02_denominators),
        ):
            if type(values) is not tuple or len(values) != 3:
                raise ValueError(f"exact builder {label} must contain RGB")
            for channel, value in zip(CHANNELS, values, strict=True):
                _require_u32(value, f"exact builder {label} {channel}")
        if self.density_f03_denominators == self.final_f02_denominators:
            raise ValueError("exact builder f03 and final f02 exposures were conflated")
        if (
            type(self.densities) is not tuple
            or len(self.densities) != 3
            or any(
                type(value) is not float or not math.isfinite(value)
                for value in self.densities
            )
        ):
            raise ValueError("exact builder densities must be three finite doubles")
        if (
            type(self.frame_index) is not int
            or type(self.frame_total) is not int
            or not 1 <= self.frame_index <= self.frame_total
            or type(self.selected_slots) is not tuple
            or len(self.selected_slots) != self.frame_total
            or any(
                type(slot) is not int or not 1 <= slot <= 40
                for slot in self.selected_slots
            )
            or len(set(self.selected_slots)) != len(self.selected_slots)
            or self.selected_slots[self.frame_index - 1] != self.slot
        ):
            raise ValueError("exact builder batch/frame identity is malformed")
        if type(self.frame_ownership_receipt) is not bytes:
            raise TypeError("exact builder frame ownership receipt must be bytes")
        if type(self.density_evidence_receipt) is not bytes:
            raise TypeError("exact builder density evidence receipt must be bytes")
        for label, payload, digest in (
            (
                "frame ownership",
                self.frame_ownership_receipt,
                self.frame_ownership_receipt_sha256,
            ),
            (
                "density evidence",
                self.density_evidence_receipt,
                self.density_evidence_receipt_sha256,
            ),
        ):
            try:
                decoded = json.loads(payload)
            except (UnicodeDecodeError, ValueError, RecursionError) as error:
                raise ValueError(f"exact builder {label} receipt is invalid") from error
            if (
                type(decoded) is not dict
                or _canonical_receipt_bytes(decoded) != payload
            ):
                raise ValueError(f"exact builder {label} receipt is not canonical")
            if hashlib.sha256(payload).hexdigest() != digest:
                raise ValueError(f"exact builder {label} receipt SHA-256 changed")
        if self.analyzer_resolution_dpi != NIKON_ANALYZER_RESOLUTION_DPI:
            raise ValueError("exact builder analyzer must be the 285-dpi pass")
        if self.analyzer_rectangle != NIKON_ANALYZER_RECTANGLE:
            raise ValueError("exact builder analyzer rectangle is not Nikon's window")
        analyzer = np.asarray(self.analyzer_rgb)
        if analyzer.dtype != np.uint16 or analyzer.shape != NIKON_ANALYZER_SHAPE:
            raise ValueError(
                f"exact builder analyzer must be uint16 {NIKON_ANALYZER_SHAPE}"
            )
        snapshot = np.array(analyzer, dtype="<u2", order="C", copy=True)
        if (
            hashlib.sha256(snapshot.tobytes(order="C")).hexdigest()
            != self.analyzer_rgb_sha256
        ):
            raise ValueError("exact builder analyzer snapshot SHA-256 changed")
        snapshot.setflags(write=False)
        object.__setattr__(self, "analyzer_rgb", snapshot)

    def validate_bindings(
        self,
        density_evidence: NikonDensityEvidence,
        ownership: NikonDensityFrameOwnershipReceipt,
    ) -> None:
        ownership.validate_evidence(density_evidence)
        ownership_payload = _canonical_receipt_bytes(ownership.to_dict())
        density_payload = _canonical_receipt_bytes(density_evidence.to_dict())
        if ownership_payload != self.frame_ownership_receipt:
            raise ValueError("exact builder ownership receipt changed")
        if density_payload != self.density_evidence_receipt:
            raise ValueError("exact builder density receipt changed")
        expected = (
            ownership.frame_capture_attempt_id,
            density_evidence.source_binding.scan_identity,
            ownership.selected_slot,
            density_evidence.source_binding.wire_sha256,
            density_evidence.source_binding.child_buffer_sha256,
            density_evidence.calibration_binding.calibration.numerators,
            density_evidence.exposure_binding.density_f03_exposures_raw_10ns,
            density_evidence.result.densities,
            ownership.reservation_id,
            ownership.batch_session_id,
            ownership.preview_sha256,
            ownership.preview_identity_sha256,
            ownership.transport_table_sha256,
            ownership.transport_identity_sha256,
            ownership.reviewed_fingerprint_sha256,
            ownership.fresh_fingerprint_sha256,
            ownership.frame_index,
            ownership.frame_total,
            ownership.selected_slots,
        )
        actual = (
            self.capture_attempt_id,
            self.scan_identity,
            self.slot,
            self.density_source_wire_sha256,
            self.density_source_child_sha256,
            self.calibration_numerators,
            self.density_f03_denominators,
            self.densities,
            self.reservation_id,
            self.batch_session_id,
            self.preview_sha256,
            self.preview_identity_sha256,
            self.transport_table_sha256,
            self.transport_identity_sha256,
            self.reviewed_fingerprint_sha256,
            self.fresh_fingerprint_sha256,
            self.frame_index,
            self.frame_total,
            self.selected_slots,
        )
        if actual != expected or self.session_id != ownership.reservation_id:
            raise ValueError("exact builder belongs to another acquisition")


def build_nikon_exact_builder_evidence(
    density_evidence: NikonDensityEvidence,
    ownership: NikonDensityFrameOwnershipReceipt,
    *,
    analyzer_rgb: np.ndarray,
    final_f02_denominators: tuple[int, int, int],
) -> NikonExactBuilderEvidence:
    """Bind the settled 285-dpi analyzer and final SET_WINDOW RGB exposure."""

    if not isinstance(density_evidence, NikonDensityEvidence):
        raise TypeError("density_evidence must be NikonDensityEvidence")
    if not isinstance(ownership, NikonDensityFrameOwnershipReceipt):
        raise TypeError("ownership must be NikonDensityFrameOwnershipReceipt")
    ownership.validate_evidence(density_evidence)
    analyzer = np.asarray(analyzer_rgb)
    if analyzer.dtype != np.uint16 or analyzer.shape != NIKON_ANALYZER_SHAPE:
        raise ValueError(f"analyzer_rgb must be uint16 {NIKON_ANALYZER_SHAPE}")
    analyzer_snapshot = np.array(analyzer, dtype="<u2", order="C", copy=True)
    ownership_payload = _canonical_receipt_bytes(ownership.to_dict())
    density_payload = _canonical_receipt_bytes(density_evidence.to_dict())
    result = NikonExactBuilderEvidence(
        session_id=ownership.reservation_id,
        capture_attempt_id=ownership.frame_capture_attempt_id,
        scan_identity=density_evidence.source_binding.scan_identity,
        slot=ownership.selected_slot,
        density_source_wire_sha256=density_evidence.source_binding.wire_sha256,
        density_source_child_sha256=density_evidence.source_binding.child_buffer_sha256,
        calibration_numerators=(
            density_evidence.calibration_binding.calibration.numerators
        ),
        density_f03_denominators=(
            density_evidence.exposure_binding.density_f03_exposures_raw_10ns
        ),
        densities=density_evidence.result.densities,
        density_arithmetic=density_evidence.result.algorithm_id,
        frame_ownership_status=ownership.binding_status,
        frame_ownership_receipt=ownership_payload,
        frame_ownership_receipt_sha256=hashlib.sha256(ownership_payload).hexdigest(),
        density_evidence_receipt=density_payload,
        density_evidence_receipt_sha256=hashlib.sha256(density_payload).hexdigest(),
        reservation_id=ownership.reservation_id,
        batch_session_id=ownership.batch_session_id,
        preview_sha256=ownership.preview_sha256,
        preview_identity_sha256=ownership.preview_identity_sha256,
        transport_table_sha256=ownership.transport_table_sha256,
        transport_identity_sha256=ownership.transport_identity_sha256,
        reviewed_fingerprint_sha256=ownership.reviewed_fingerprint_sha256,
        fresh_fingerprint_sha256=ownership.fresh_fingerprint_sha256,
        frame_index=ownership.frame_index,
        frame_total=ownership.frame_total,
        selected_slots=ownership.selected_slots,
        analyzer_rgb=analyzer_snapshot,
        analyzer_rgb_sha256=hashlib.sha256(
            analyzer_snapshot.tobytes(order="C")
        ).hexdigest(),
        analyzer_resolution_dpi=NIKON_ANALYZER_RESOLUTION_DPI,
        analyzer_rectangle=NIKON_ANALYZER_RECTANGLE,
        final_f02_denominators=final_f02_denominators,
    )
    result.validate_bindings(density_evidence, ownership)
    return result


def _density_source_buffers(
    payload: bytes,
    *,
    height: int,
) -> tuple[np.ndarray, bytes, bytes]:
    expected_wire_bytes = height * DENSITY_SOURCE_ROW_STRIDE_BYTES
    if len(payload) != expected_wire_bytes:
        raise ValueError(
            "density source meter payload must contain exactly "
            f"{expected_wire_bytes} bytes"
        )
    padded_rows = np.frombuffer(payload, dtype=np.uint8).reshape(
        height,
        DENSITY_SOURCE_ROW_STRIDE_BYTES,
    )
    compact_big_endian = np.ascontiguousarray(
        padded_rows[:, :DENSITY_SOURCE_RGB_ROW_BYTES]
    )
    compact_buffer_be = compact_big_endian.tobytes(order="C")
    row_planar = compact_big_endian.view(">u2").reshape(
        height,
        DENSITY_SOURCE_DENSITY_CHANNELS,
        DENSITY_SOURCE_WIDTH,
    )
    native_row_planar = row_planar.astype(np.uint16)
    child_buffer = native_row_planar.astype("<u2", copy=False).tobytes(order="C")
    if len(child_buffer) != height * DENSITY_SOURCE_RGB_ROW_BYTES:
        raise AssertionError("internal density source child-buffer size mismatch")
    return native_row_planar, compact_buffer_be, child_buffer


def bind_nikon_density_source(
    meter_payload: bytes | bytearray | memoryview,
    *,
    session_id: str,
    capture_attempt_id: str,
    scan_identity: str,
    native_height: int = DENSITY_SOURCE_NATIVE_HEIGHT,
    height: int = DENSITY_SOURCE_HEIGHT,
) -> NikonDensitySourceBinding:
    """Create immutable evidence for one in-memory 97-dpi density source.

    The capture path calls this before releasing its bounded 97-dpi source
    buffer, then journals the binding without retaining a private file.
    """

    if not isinstance(meter_payload, (bytes, bytearray, memoryview)):
        raise TypeError("density source meter_payload must be bytes-like")
    payload = bytes(meter_payload)
    if (
        type(native_height) is not int
        or type(height) is not int
        or (native_height, height) not in DENSITY_SOURCE_SUPPORTED_HEIGHTS
    ):
        raise ValueError(
            "density source native_height/height must be a proven preview geometry"
        )
    _, compact_buffer_be, child_buffer = _density_source_buffers(
        payload,
        height=height,
    )
    return NikonDensitySourceBinding(
        session_id=session_id,
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
        resolution_dpi=DENSITY_SOURCE_RESOLUTION_DPI,
        native_resolution_dpi=DENSITY_SOURCE_NATIVE_RESOLUTION_DPI,
        native_width=DENSITY_SOURCE_NATIVE_WIDTH,
        native_height=native_height,
        scale_divisor=DENSITY_SOURCE_SCALE_DIVISOR,
        width=DENSITY_SOURCE_WIDTH,
        height=height,
        input_channels=DENSITY_SOURCE_INPUT_CHANNELS,
        density_channels=DENSITY_SOURCE_DENSITY_CHANNELS,
        sample_bits=DENSITY_SOURCE_SAMPLE_BITS,
        rgb_row_bytes=DENSITY_SOURCE_RGB_ROW_BYTES,
        row_stride_bytes=DENSITY_SOURCE_ROW_STRIDE_BYTES,
        opaque_row_tail_bytes=DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES,
        discarded_row_bytes=DENSITY_SOURCE_DISCARDED_ROW_BYTES,
        layout=DENSITY_SOURCE_LAYOUT,
        byte_order=DENSITY_SOURCE_BYTE_ORDER,
        wire_sha256=hashlib.sha256(payload).hexdigest(),
        compact_buffer_be_sha256=hashlib.sha256(compact_buffer_be).hexdigest(),
        child_buffer_sha256=hashlib.sha256(child_buffer).hexdigest(),
    )


def decode_nikon_density_source(
    meter_payload: bytes | bytearray | memoryview,
    *,
    binding: NikonDensitySourceBinding,
) -> np.ndarray:
    """Extract Nikon's density RGB planes from the raw 97-dpi source pass.

    The returned convenience view is ``(height, 96, 3)`` native-endian uint16,
    where height is the proven startup-bound preview height carried by
    ``binding``. The validated child-buffer digest is calculated over Nikon's
    actual little-endian row-planar order: R[96], G[96], B[96] for each row.
    Each raw 1,024-byte row has a 448-byte physical tail that is discarded.
    """

    if not isinstance(binding, NikonDensitySourceBinding):
        raise TypeError("binding must be a NikonDensitySourceBinding")
    if not isinstance(meter_payload, (bytes, bytearray, memoryview)):
        raise TypeError("density source meter_payload must be bytes-like")
    payload = bytes(meter_payload)
    expected_wire_bytes = binding.height * binding.row_stride_bytes
    if len(payload) != expected_wire_bytes:
        raise ValueError(
            "density source meter payload must contain exactly "
            f"{expected_wire_bytes} bytes"
        )
    wire_sha256 = hashlib.sha256(payload).hexdigest()
    if wire_sha256 != binding.wire_sha256:
        raise ValueError(
            "density source meter payload does not match its SHA-256 evidence"
        )

    native_row_planar, compact_buffer_be, child_buffer = _density_source_buffers(
        payload,
        height=binding.height,
    )
    compact_be_sha256 = hashlib.sha256(compact_buffer_be).hexdigest()
    if compact_be_sha256 != binding.compact_buffer_be_sha256:
        raise ValueError(
            "density source compact big-endian buffer does not match its SHA-256 evidence"
        )
    child_sha256 = hashlib.sha256(child_buffer).hexdigest()
    if child_sha256 != binding.child_buffer_sha256:
        raise ValueError(
            "density source compact child buffer does not match its SHA-256 evidence"
        )

    return np.transpose(native_row_planar, (0, 2, 1))


def _select_usable_mean(
    image: np.ndarray,
    channel_index: int,
    *,
    row_first: int,
    row_stop: int,
) -> tuple[int, float] | None:
    """Best full-row mean in ``[row_first, row_stop)`` below saturation.

    Returns ``(row_index, mean)`` for the greatest full-row mean strictly
    below ``SATURATION_LIMIT`` within the window, or ``None`` when no row in
    the window has a nonzero, unsaturated mean. ``row_stop`` is clamped to the
    decoded source height so the widened full-frame retry cannot run past the
    image.
    """
    row_stop = min(row_stop, int(image.shape[0]))
    selected_row = -1
    selected_mean = 0.0
    for row_index in range(max(0, row_first), row_stop):
        total = int(np.sum(image[row_index, :, channel_index], dtype=np.uint32))
        mean = float(total) / float(DENSITY_SOURCE_WIDTH)
        if selected_mean < mean < SATURATION_LIMIT:
            selected_row = row_index
            selected_mean = mean
    if selected_row < 0 or selected_mean == 0.0:
        return None
    return selected_row, selected_mean


# Lane B widened-window retry: how much wider than the primary meter band
# the retry window is allowed to grow. Bounding this to a multiple of the
# primary band's own height (rather than the whole frame) is a fail-closed
# erosion fix -- the retry used to span [0, height) unconditionally, so a
# usable row anywhere in the frame, arbitrarily far from the primary band,
# could silently become the selected exposure reference.
_METER_RETRY_WIDENING_FACTOR = 3


def _widened_meter_window(
    row_first: int, row_stop: int, frame_height: int
) -> tuple[int, int]:
    """Bound the Lane B retry window to the primary band widened
    symmetrically to ``_METER_RETRY_WIDENING_FACTOR`` times its own height,
    centered on the primary band and clamped to the frame. See
    :func:`_selected_row`.
    """
    band_height = row_stop - row_first
    center = (row_first + row_stop) / 2.0
    half_widened = (band_height * _METER_RETRY_WIDENING_FACTOR) / 2.0
    widened_first = int(math.floor(center - half_widened))
    widened_stop = int(math.ceil(center + half_widened))
    return max(0, widened_first), min(frame_height, widened_stop)


def _selected_row(
    image: np.ndarray,
    channel_index: int,
    *,
    row_first: int = METER_ROWS_FIRST,
    row_stop: int = METER_ROWS_STOP,
) -> tuple[int, float]:
    """Select a usable meter row for a channel (Lane B widened-window retry).

    The primary meter window is ``[METER_ROWS_FIRST, METER_ROWS_STOP)``. If it
    yields no usable mean, the selection retries once over the primary band
    widened symmetrically to 3x its own height and clamped to the frame (the
    ``#17`` fix, now bounded rather than spanning the whole frame -- see
    :func:`_widened_meter_window`) before giving up. Only if both windows are
    unusable does it raise the typed :class:`MeterUnusableError` (bridge code
    ``METER_UNUSABLE``) instead of a bare ``ValueError``, so a B&W strip /
    modified SA-21 / dense negative surfaces as a friendly card rather than
    ``INTERNAL``.
    """
    widened = _widened_meter_window(row_first, row_stop, int(image.shape[0]))
    windows = [(row_first, row_stop), widened]
    for start, stop in windows:
        selected = _select_usable_mean(
            image, channel_index, row_first=start, row_stop=stop
        )
        if selected is not None:
            return selected
    raise MeterUnusableError(CHANNELS[channel_index])


def evaluate_nikon_density(
    source_meter_payload: bytes | bytearray | memoryview,
    *,
    calibration_binding: NikonDensityCalibrationBinding,
    source_binding: NikonDensitySourceBinding,
    exposure_binding: NikonDensityExposureBinding,
) -> NikonDensityResult:
    """Evaluate Nikon arithmetic over the proven 97-dpi density source.

    Rows 75 through 224 are considered.  For each RGB channel, Nikon selects
    the first occurrence of the greatest full-row mean strictly below 90% of
    16-bit full scale, then computes::

        log10(65535 / ((numerator * row_mean) / denominator))

    Values outside Nikon's channel-specific inclusive ranges are replaced by
    the vendor fallbacks.
    """

    if not isinstance(calibration_binding, NikonDensityCalibrationBinding):
        raise TypeError("calibration_binding must be a NikonDensityCalibrationBinding")
    if not isinstance(source_binding, NikonDensitySourceBinding):
        raise TypeError("source_binding must be a NikonDensitySourceBinding")
    if not isinstance(exposure_binding, NikonDensityExposureBinding):
        raise TypeError("exposure_binding must be a NikonDensityExposureBinding")
    verify_nikon_density_arithmetic_backend()
    identities = (
        (
            "session",
            calibration_binding.session_id,
            source_binding.session_id,
            exposure_binding.session_id,
        ),
        (
            "capture attempt",
            calibration_binding.capture_attempt_id,
            source_binding.capture_attempt_id,
            exposure_binding.capture_attempt_id,
        ),
        (
            "scan",
            calibration_binding.scan_identity,
            source_binding.scan_identity,
            exposure_binding.scan_identity,
        ),
    )
    for label, *values in identities:
        if len(set(values)) != 1:
            raise ValueError(f"density inputs have different {label} identities")

    source = decode_nikon_density_source(
        source_meter_payload,
        binding=source_binding,
    )
    denominators = exposure_binding.density_f03_exposures_raw_10ns
    selected = tuple(_selected_row(source, index) for index in range(3))
    selected_rows = tuple(item[0] for item in selected)
    selected_means = tuple(item[1] for item in selected)

    raw_densities: list[float] = []
    densities: list[float] = []
    fallbacks: list[bool] = []
    for index, (numerator, denominator, row_mean) in enumerate(
        zip(
            calibration_binding.calibration.numerators,
            denominators,
            selected_means,
            strict=True,
        )
    ):
        # Preserve Nikon's instruction/store order.  Reassociating this as
        # FULL_SCALE * denominator / (numerator * row_mean) changes the green
        # result by one ULP for the archived closure event.
        product = float(numerator) * row_mean
        quotient = product / float(denominator)
        ratio = FULL_SCALE / quotient
        if not math.isfinite(ratio) or ratio <= 0.0:
            raise ValueError(
                f"{CHANNELS[index]} density ratio is not positive and finite"
            )
        raw = math.log10(ratio)
        if not math.isfinite(raw):
            raise ValueError(f"{CHANNELS[index]} density is not finite")
        lower, upper = _DENSITY_RANGES[index]
        use_fallback = not lower <= raw <= upper
        raw_densities.append(raw)
        densities.append(_DENSITY_FALLBACKS[index] if use_fallback else raw)
        fallbacks.append(use_fallback)

    return NikonDensityResult(
        algorithm_id=ALGORITHM_ID,
        session_id=source_binding.session_id,
        capture_attempt_id=source_binding.capture_attempt_id,
        scan_identity=source_binding.scan_identity,
        source_wire_sha256=source_binding.wire_sha256,
        source_compact_buffer_be_sha256=(source_binding.compact_buffer_be_sha256),
        source_child_buffer_sha256=source_binding.child_buffer_sha256,
        source_native_height=source_binding.native_height,
        source_height=source_binding.height,
        calibration_payload_sha256=calibration_binding.calibration.payload_sha256,
        numerators=calibration_binding.calibration.numerators,
        density_f03_denominators=denominators,
        selected_rows=selected_rows,
        selected_row_means=selected_means,
        raw_densities=tuple(raw_densities),
        densities=tuple(densities),
        fallback_applied=tuple(fallbacks),
    )


def build_nikon_density_evidence(
    source_payload: bytes | bytearray | memoryview,
    *,
    calibration: DensityCalibration,
    density_f03_exposures_raw_10ns: tuple[int, int, int],
    session_id: str,
    capture_attempt_id: str,
    scan_identity: str,
    source_native_height: int = DENSITY_SOURCE_NATIVE_HEIGHT,
    source_height: int = DENSITY_SOURCE_HEIGHT,
) -> NikonDensityEvidence:
    """Build and replay-check one immutable session-level evidence bundle."""

    if not isinstance(calibration, DensityCalibration):
        raise TypeError("calibration must be a DensityCalibration")
    if calibration.session_id != session_id:
        raise ValueError("density calibration belongs to another session")
    payload = bytes(source_payload)
    calibration_binding = NikonDensityCalibrationBinding(
        calibration=calibration,
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
    )
    source_binding = bind_nikon_density_source(
        payload,
        session_id=session_id,
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
        native_height=source_native_height,
        height=source_height,
    )
    exposure_binding = NikonDensityExposureBinding(
        session_id=session_id,
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
        density_f03_exposures_raw_10ns=density_f03_exposures_raw_10ns,
    )
    result = evaluate_nikon_density(
        payload,
        calibration_binding=calibration_binding,
        source_binding=source_binding,
        exposure_binding=exposure_binding,
    )
    return NikonDensityEvidence(
        source_payload=payload,
        calibration_binding=calibration_binding,
        source_binding=source_binding,
        exposure_binding=exposure_binding,
        result=result,
    )
