"""Linux SCSI generic transport for FireWire Coolscan scanners via SG_IO.

The FireWire Coolscan models (LS-4000 ED, LS-8000 ED, SUPER COOLSCAN
9000 ED) carry Nikon's SCSI command set over IEEE 1394 SBP-2. On Linux
the kernel's own ``firewire-sbp2`` driver logs into the scanner's SBP-2
unit and publishes it as a standard SCSI device, which the ``sg`` driver
exposes as a ``/dev/sg*`` character node. This module is coolscanpy's
client for that surface: the v3 ``SG_IO`` ioctl, driven directly through
``ctypes``/``fcntl`` (no compiled extension, so the wheel stays pure
Python). It is the Linux twin of ``coolscanpy.transport.macos_scsi``,
which reaches the same scanners through ASFireWire on macOS.

Contract grounding: every struct field, offset, and constant in this
file is transcribed from the kernel headers at tag v6.6 —
``include/scsi/sg.h`` (``sg_io_hdr``, ``SG_IO``, ``SG_GET_VERSION_NUM``,
``SG_DXFER_*``, ``SG_INFO_*``) and ``include/scsi/scsi_device.h``
(``SCSI_SENSE_BUFFERSIZE``) — not from memory. ``sg_io_hdr`` carries
pointers, so its LP64 layout (88 bytes, pad before ``usr_ptr``) is ABI;
do not reorder fields here without re-reading the header.

Scope: device discovery, identity, and motion-free probing (TEST UNIT
READY / INQUIRY / REQUEST SENSE). Scanning is deliberately NOT wired up:
the single-pass protocol layer is validated against the LS-5000's USB
dialect, and driving the FireWire models further waits on captures from
real hardware (ScanStudio issue #28 is the coordination thread). This
module exists so those captures can happen with coolscanpy itself on
Linux, the platform the FireWire track treats as primary.

Transfer ceiling: ``MAX_TRANSFER_PER_IO`` mirrors the macOS lane's 1 MB
per-task cap. On Linux that number is a policy choice, not a kernel
constant — keeping both lanes on one ceiling lets a future protocol
layer chunk identically on either transport (ASFireWire's 1 MB per-task
limit is the binding constraint of the pair).
"""

from __future__ import annotations

import ctypes
import dataclasses
import errno
import os
import sys
from collections.abc import Callable
from pathlib import Path

from coolscanpy.transport.macos_scsi import _format_inquiry, chunk_transfer_lengths

__all__ = [
    "MAX_TRANSFER_PER_IO",
    "DATA_TRANSFER_NONE",
    "DATA_TRANSFER_FROM_TARGET",
    "DATA_TRANSFER_TO_TARGET",
    "STATUS_GOOD",
    "STATUS_CHECK_CONDITION",
    "SgDeviceInfo",
    "SgTransactionResult",
    "LinuxSgDevice",
    "LinuxSgTransportError",
    "chunk_transfer_lengths",
    "list_sg_devices",
]

# ---------------------------------------------------------------------------
# Constants from include/scsi/sg.h @ v6.6 (values, not names, are the
# contract).
# ---------------------------------------------------------------------------

# "#define SG_IO 0x2285   /* similar effect as write() followed by read() */"
_SG_IO = 0x2285
# "#define SG_GET_VERSION_NUM 0x2282 /* Example: version 2.1.34 yields 20134 */"
_SG_GET_VERSION_NUM = 0x2282
# The v3 sg_io_hdr interface exists from driver version 3.0.
_SG_MIN_VERSION = 30000

# sg.h SG_DXFER_* (dxfer_direction). The names mirror the macOS lane's
# constants; the values are sg's own.
DATA_TRANSFER_NONE = -1  # SG_DXFER_NONE
DATA_TRANSFER_TO_TARGET = -2  # SG_DXFER_TO_DEV
DATA_TRANSFER_FROM_TARGET = -3  # SG_DXFER_FROM_DEV

# sg.h: "#define SG_INFO_OK_MASK 0x1" / "#define SG_INFO_OK 0x0".
_SG_INFO_OK_MASK = 0x1
_SG_INFO_OK = 0x0

# sg_io_hdr.interface_id: "[i] 'S' for SCSI generic (required)".
_INTERFACE_ID = ord("S")

# SAM status bytes, as in the macOS lane and the USB lane.
STATUS_GOOD = 0x00
STATUS_CHECK_CONDITION = 0x02

# include/scsi/scsi_device.h @ v6.6: "#define SCSI_SENSE_BUFFERSIZE 96" —
# the most sense bytes the kernel will ever hold for one command, so the
# most mx_sb_len can usefully request.
_SENSE_BUFFER_SIZE = 96

# Fixed-format sense payload requested by the explicit REQUEST SENSE probe,
# matching the macOS lane's _SENSE_DATA_LENGTH.
_REQUEST_SENSE_LENGTH = 18

# Historical DRIVER_SENSE bit in driver_status: set alongside valid sense
# data. Any other driver_status bit is treated as a transport fault.
_DRIVER_SENSE = 0x08

# Same per-transaction ceiling as macos_scsi.MAX_TRANSFER_PER_TASK; see the
# module docstring for why the Linux lane adopts it as policy.
MAX_TRANSFER_PER_IO = 1 << 20

# Same accepted CDB sizes as the macOS lane's guard.
_VALID_CDB_SIZES = (6, 10, 12, 16)

_SYSFS_SCSI_GENERIC = "/sys/class/scsi_generic"
_DEV_ROOT = "/dev"


class LinuxSgTransportError(RuntimeError):
    """An sg call failed; the message carries errno or the fault fields."""


# ---------------------------------------------------------------------------
# ctypes transcription of sg_io_hdr (include/scsi/sg.h @ v6.6). Field order
# and types are ABI; the offline tests pin the LP64 offsets independently.
# ---------------------------------------------------------------------------


class _SgIoHdr(ctypes.Structure):
    _fields_ = [
        ("interface_id", ctypes.c_int),
        ("dxfer_direction", ctypes.c_int),
        ("cmd_len", ctypes.c_ubyte),
        ("mx_sb_len", ctypes.c_ubyte),
        ("iovec_count", ctypes.c_ushort),
        ("dxfer_len", ctypes.c_uint),
        ("dxferp", ctypes.c_void_p),
        ("cmdp", ctypes.c_void_p),
        ("sbp", ctypes.c_void_p),
        ("timeout", ctypes.c_uint),
        ("flags", ctypes.c_uint),
        ("pack_id", ctypes.c_int),
        ("usr_ptr", ctypes.c_void_p),
        ("status", ctypes.c_ubyte),
        ("masked_status", ctypes.c_ubyte),
        ("msg_status", ctypes.c_ubyte),
        ("sb_len_wr", ctypes.c_ubyte),
        ("host_status", ctypes.c_ushort),
        ("driver_status", ctypes.c_ushort),
        ("resid", ctypes.c_int),
        ("duration", ctypes.c_uint),
        ("info", ctypes.c_uint),
    ]


# ---------------------------------------------------------------------------
# Syscall seams. Tests replace these three names to build a scripted kernel;
# production code never calls os.open/fcntl.ioctl through any other path.
# ---------------------------------------------------------------------------


def _open_node(path: str) -> int:
    # O_EXCL on an sg node is the claim: it fails EBUSY while any other
    # descriptor is open, and blocks later opens while ours is. O_NONBLOCK
    # makes contention surface immediately instead of hanging.
    return os.open(path, os.O_RDWR | os.O_EXCL | os.O_NONBLOCK)


def _close_fd(fd: int) -> None:
    os.close(fd)


def _ioctl(fd: int, request: int, buffer: object) -> int:
    # Imported here, not at module top: fcntl does not exist on Windows,
    # and this module must stay importable everywhere (tests fake this
    # seam; only real hardware calls reach it).
    import fcntl

    return fcntl.ioctl(fd, request, buffer)


# ---------------------------------------------------------------------------
# Discovery through sysfs: /sys/class/scsi_generic/sg*/device/{vendor,model,
# rev,type} are fixed-width INQUIRY echoes published by the SCSI midlayer.
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class SgDeviceInfo:
    """One sg-exposed SCSI device seen in sysfs."""

    node: str
    vendor: str | None
    product: str | None
    revision: str | None
    scsi_type: int | None

    @property
    def looks_like_nikon_coolscan(self) -> bool:
        vendor = (self.vendor or "").strip().upper()
        return vendor == "NIKON"


def _read_sysfs_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="ascii", errors="replace").strip() or None
    except OSError:
        return None


def list_sg_devices(
    *,
    sysfs_root: str | None = None,
    dev_root: str | None = None,
) -> list[SgDeviceInfo]:
    """Enumerate /dev/sg* nodes with their sysfs identity, sg-number order.

    The roots resolve at call time (not at def time) so tests and callers
    can point the module constants at a fake tree.
    """

    if sysfs_root is None:
        sysfs_root = _SYSFS_SCSI_GENERIC
    if dev_root is None:
        dev_root = _DEV_ROOT
    root = Path(sysfs_root)
    try:
        entries = [p for p in root.iterdir() if p.name.startswith("sg")]
    except OSError:
        return []

    def sg_number(p: Path) -> int:
        suffix = p.name[2:]
        return int(suffix) if suffix.isdigit() else 1 << 31

    devices: list[SgDeviceInfo] = []
    for entry in sorted(entries, key=sg_number):
        device_dir = entry / "device"
        type_text = _read_sysfs_text(device_dir / "type")
        devices.append(
            SgDeviceInfo(
                node=str(Path(dev_root) / entry.name),
                vendor=_read_sysfs_text(device_dir / "vendor"),
                product=_read_sysfs_text(device_dir / "model"),
                revision=_read_sysfs_text(device_dir / "rev"),
                scsi_type=int(type_text) if type_text and type_text.isdigit() else None,
            )
        )
    return devices


# ---------------------------------------------------------------------------
# The device handle.
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class SgTransactionResult:
    """Outcome of one synchronous SG_IO transaction, USB-lane result shape."""

    status: int
    host_status: int
    driver_status: int
    transferred: int
    payload: bytes
    sense: bytes

    @property
    def good(self) -> bool:
        return (
            self.status == STATUS_GOOD
            and self.host_status == 0
            and self.driver_status == 0
        )

    @property
    def check_condition(self) -> bool:
        return self.status == STATUS_CHECK_CONDITION


class LinuxSgDevice:
    """One exclusively-claimed /dev/sg node speaking the v3 SG_IO interface.

    ``open()`` is the claim (O_EXCL), so unlike the macOS lane there is no
    separate obtain-exclusive-access step; a node another client holds
    raises the named contention error instead of returning a handle.
    """

    def __init__(self) -> None:
        self._node: str = ""
        self._fd: int | None = None

    @classmethod
    def open(cls, node: str) -> "LinuxSgDevice":
        device = cls()
        device._node = node
        try:
            fd = _open_node(node)
        except OSError as error:
            if error.errno == errno.EBUSY:
                raise LinuxSgTransportError(
                    f"{node} is held by another client (EBUSY). Close the "
                    "other program using the scanner and retry."
                ) from error
            raise LinuxSgTransportError(
                f"opening {node} failed: {error.strerror} "
                f"(errno {error.errno})"
            ) from error
        device._fd = fd
        try:
            version = ctypes.c_int(0)
            _ioctl(fd, _SG_GET_VERSION_NUM, version)
            if version.value < _SG_MIN_VERSION:
                raise LinuxSgTransportError(
                    f"{node} answered sg driver version {version.value}, "
                    f"below the v3 SG_IO minimum {_SG_MIN_VERSION}"
                )
        except OSError as error:
            device.close(raise_on_error=False)
            raise LinuxSgTransportError(
                f"{node} did not answer SG_GET_VERSION_NUM: not an sg node? "
                f"({error.strerror}, errno {error.errno})"
            ) from error
        except LinuxSgTransportError:
            device.close(raise_on_error=False)
            raise
        return device

    def close(self, *, raise_on_error: bool = True) -> None:
        fd, self._fd = self._fd, None
        if fd is None:
            return
        try:
            _close_fd(fd)
        except OSError as error:
            if raise_on_error:
                raise LinuxSgTransportError(
                    f"closing {self._node} failed: {error.strerror} "
                    f"(errno {error.errno})"
                ) from error

    def __enter__(self) -> "LinuxSgDevice":
        return self

    def __exit__(self, exc_type: object, *exc_info: object) -> None:
        self.close(raise_on_error=exc_type is None)

    def _require_fd(self) -> int:
        if self._fd is None:
            raise LinuxSgTransportError("device is not open")
        return self._fd

    def perform_transaction(
        self,
        cdb: bytes,
        *,
        direction: int = DATA_TRANSFER_NONE,
        data_out: bytes | None = None,
        data_in_length: int = 0,
        timeout_ms: int = 10_000,
    ) -> SgTransactionResult:
        """Execute one synchronous SG_IO transaction and return its outcome.

        Fail-closed, matching the macOS lane: syscall failures and
        transport-level faults (nonzero host_status, driver_status bits
        other than the sense marker) raise; a CHECK CONDITION is not an
        exception — the caller gets status + sense to interpret.
        """

        if len(cdb) not in _VALID_CDB_SIZES:
            raise LinuxSgTransportError(
                f"CDB length {len(cdb)} invalid; this lane accepts "
                f"{_VALID_CDB_SIZES}"
            )
        if direction == DATA_TRANSFER_TO_TARGET and data_out is None:
            raise LinuxSgTransportError("outbound transfer requires data_out")
        if direction == DATA_TRANSFER_FROM_TARGET and data_in_length <= 0:
            raise LinuxSgTransportError("inbound transfer requires data_in_length")
        if timeout_ms <= 0:
            raise LinuxSgTransportError("timeout_ms must be positive")
        transfer_length = (
            len(data_out) if direction == DATA_TRANSFER_TO_TARGET
            else data_in_length if direction == DATA_TRANSFER_FROM_TARGET
            else 0
        )
        if transfer_length > MAX_TRANSFER_PER_IO:
            raise LinuxSgTransportError(
                f"transfer of {transfer_length} bytes exceeds the "
                f"{MAX_TRANSFER_PER_IO}-byte per-transaction ceiling; split "
                "it with chunk_transfer_lengths()"
            )

        fd = self._require_fd()
        cdb_buf = ctypes.create_string_buffer(cdb, len(cdb))
        sense_buf = ctypes.create_string_buffer(_SENSE_BUFFER_SIZE)
        data_buf: ctypes.Array[ctypes.c_char] | None = None
        if transfer_length:
            if direction == DATA_TRANSFER_TO_TARGET:
                assert data_out is not None
                data_buf = ctypes.create_string_buffer(data_out, transfer_length)
            else:
                data_buf = ctypes.create_string_buffer(transfer_length)

        hdr = _SgIoHdr()
        hdr.interface_id = _INTERFACE_ID
        hdr.dxfer_direction = direction
        hdr.cmd_len = len(cdb)
        hdr.mx_sb_len = _SENSE_BUFFER_SIZE
        hdr.iovec_count = 0
        hdr.dxfer_len = transfer_length
        hdr.dxferp = ctypes.cast(data_buf, ctypes.c_void_p) if data_buf else None
        hdr.cmdp = ctypes.cast(cdb_buf, ctypes.c_void_p)
        hdr.sbp = ctypes.cast(sense_buf, ctypes.c_void_p)
        hdr.timeout = timeout_ms
        hdr.flags = 0
        hdr.pack_id = 0
        hdr.usr_ptr = None

        while True:
            try:
                _ioctl(fd, _SG_IO, hdr)
                break
            except InterruptedError:
                # sg.h documents EINTR handling for SG_IO as the caller's
                # choice; retrying preserves the synchronous contract.
                continue
            except OSError as error:
                raise LinuxSgTransportError(
                    f"SG_IO failed on {self._node}: {error.strerror} "
                    f"(errno {error.errno})"
                ) from error

        if hdr.host_status != 0:
            raise LinuxSgTransportError(
                f"host adapter fault on {self._node}: "
                f"host_status=0x{hdr.host_status:04x} (see sg.h DID codes)"
            )
        if hdr.driver_status & ~_DRIVER_SENSE:
            raise LinuxSgTransportError(
                f"sg driver fault on {self._node}: "
                f"driver_status=0x{hdr.driver_status:04x}"
            )

        transferred = max(0, transfer_length - hdr.resid)
        payload = b""
        if direction == DATA_TRANSFER_FROM_TARGET and data_buf is not None:
            payload = data_buf.raw[:transferred]
        return SgTransactionResult(
            status=hdr.status,
            host_status=hdr.host_status,
            driver_status=hdr.driver_status,
            transferred=transferred,
            payload=payload,
            sense=sense_buf.raw[: hdr.sb_len_wr],
        )

    # -- motion-free probes ------------------------------------------------

    def test_unit_ready(self, *, timeout_ms: int = 5_000) -> SgTransactionResult:
        return self.perform_transaction(bytes(6), timeout_ms=timeout_ms)

    def inquiry(
        self, *, allocation: int = 96, timeout_ms: int = 5_000
    ) -> SgTransactionResult:
        if not 5 <= allocation <= 255:
            raise LinuxSgTransportError("INQUIRY allocation must be 5..255")
        cdb = bytes([0x12, 0x00, 0x00, 0x00, allocation, 0x00])
        return self.perform_transaction(
            cdb,
            direction=DATA_TRANSFER_FROM_TARGET,
            data_in_length=allocation,
            timeout_ms=timeout_ms,
        )

    def request_sense(self, *, timeout_ms: int = 5_000) -> SgTransactionResult:
        cdb = bytes([0x03, 0x00, 0x00, 0x00, _REQUEST_SENSE_LENGTH, 0x00])
        return self.perform_transaction(
            cdb,
            direction=DATA_TRANSFER_FROM_TARGET,
            data_in_length=_REQUEST_SENSE_LENGTH,
            timeout_ms=timeout_ms,
        )


# ---------------------------------------------------------------------------
# Probe CLI: the artifact a FireWire tester runs on Linux and pastes back.
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None, *, out: Callable[[str], None] = print) -> int:
    """List sg devices; with ``--probe /dev/sgN``, run the motion-free probe."""

    usage = "usage: python -m coolscanpy.transport.linux_sg [--probe /dev/sgN]"
    args = list(sys.argv[1:] if argv is None else argv)
    probe_node: str | None = None
    if args and args[0] == "--probe":
        if len(args) != 2:
            out(usage)
            return 2
        probe_node = args[1]
        if not probe_node.startswith("/dev/sg"):
            out(f"--probe expects an sg node like /dev/sg1, got {probe_node!r}")
            out(usage)
            return 2
    elif args:
        out(usage)
        return 2

    devices = list_sg_devices()
    if not devices:
        out(
            "no sg devices found. If a FireWire Coolscan is connected and "
            "powered on, check that firewire-sbp2 and sg are loaded "
            "(lsmod) and that the FireWire link shows the scanner "
            "(dmesg | grep -i firewire)."
        )
        return 1
    for device in devices:
        marker = "  <- Nikon" if device.looks_like_nikon_coolscan else ""
        out(
            f"{device.node}: vendor={device.vendor!r} "
            f"product={device.product!r} revision={device.revision!r} "
            f"scsi_type={device.scsi_type}{marker}"
        )
    if probe_node is None:
        return 0

    with LinuxSgDevice.open(probe_node) as device:
        ready = device.test_unit_ready()
        out(
            f"TEST UNIT READY: status=0x{ready.status:02x}"
            + (f" sense={ready.sense.hex()}" if ready.check_condition else "")
        )
        if ready.check_condition:
            sense = device.request_sense()
            out(f"REQUEST SENSE: {sense.payload.hex()}")
        identity = device.inquiry()
        if not identity.good:
            out(
                f"INQUIRY did not complete cleanly: "
                f"status=0x{identity.status:02x} "
                f"host=0x{identity.host_status:04x} "
                f"driver=0x{identity.driver_status:04x} "
                f"sense={identity.sense.hex()}"
            )
            return 1
        out("INQUIRY: " + _format_inquiry(identity.payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
