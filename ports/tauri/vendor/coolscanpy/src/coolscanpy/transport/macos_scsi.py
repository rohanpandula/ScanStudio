"""macOS SCSI transport for FireWire Coolscan scanners via SCSITaskLib.

The FireWire Coolscan models (LS-4000 ED, LS-8000 ED, SUPER COOLSCAN
9000 ED) carry Nikon's SCSI command set over IEEE 1394 SBP-2 instead of
USB bulk pipes. On modern macOS the ASFireWire DriverKit stack
(https://github.com/mrmidi/ASFireWire) logs into the scanner's SBP-2
unit and publishes it as a standard SCSI peripheral through Apple's
IOSCSIParallelFamily -- the same surface VueScan uses to scan through
it. This module is coolscanpy's client for that surface: Apple's
SCSITaskLib, driven directly through ctypes (no compiled extension, so
the wheel stays pure Python).

Contract grounding: every UUID, vtable layout, struct, and constant in
this file is transcribed from the macOS SDK headers
``IOKit/scsi/SCSITaskLib.h``, ``IOKit/scsi/SCSITask.h``,
``IOKit/scsi/SCSICmds_REQUEST_SENSE_Defs.h``, ``IOKit/IOCFPlugIn.h``,
and ``CoreFoundation/CFPlugInCOM.h`` -- not from memory. The COM-style
plug-in interfaces are C vtables whose slot order is ABI; do not reorder
fields here without re-reading the header.

Scope: device discovery, identity, and motion-free probing (TEST UNIT
READY / INQUIRY / REQUEST SENSE). Scanning is deliberately NOT wired up:
the single-pass protocol layer is validated against the LS-5000's USB
dialect, and whether the FireWire models' command vocabulary matches is
an open question that only captures from real hardware can settle
(ScanStudio issue #28 is the coordination thread). This module exists so
those captures can happen with coolscanpy itself.

Known ASFireWire-side limits that shape this client: one target, one
LUN, and a 1 MB ceiling per SCSI task (``kMaxTransferPerTask`` in its
SCSI controller), hence ``MAX_TRANSFER_PER_TASK`` and the chunking
helper below.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import dataclasses
import sys
from collections.abc import Callable, Iterator

__all__ = [
    "MAX_TRANSFER_PER_TASK",
    "DATA_TRANSFER_NONE",
    "DATA_TRANSFER_FROM_TARGET",
    "DATA_TRANSFER_TO_TARGET",
    "TASK_STATUS_GOOD",
    "TASK_STATUS_CHECK_CONDITION",
    "ScsiTaskDeviceInfo",
    "ScsiTransactionResult",
    "MacScsiTaskDevice",
    "MacScsiTransportError",
    "chunk_transfer_lengths",
    "list_scsi_task_devices",
]

# ---------------------------------------------------------------------------
# Constants from the SDK headers (values, not names, are the contract).
# ---------------------------------------------------------------------------

# SCSITask.h: kSCSIDataTransfer_* (SetScatterGatherEntries direction).
DATA_TRANSFER_NONE = 0x00
DATA_TRANSFER_TO_TARGET = 0x01  # kSCSIDataTransfer_FromInitiatorToTarget
DATA_TRANSFER_FROM_TARGET = 0x02  # kSCSIDataTransfer_FromTargetToInitiator

# SCSITask.h: SCSITaskStatus values this client interprets.
TASK_STATUS_GOOD = 0x00
TASK_STATUS_CHECK_CONDITION = 0x02
TASK_STATUS_BUSY = 0x08

# SCSITask.h: SCSIServiceResponse.
SERVICE_RESPONSE_TASK_COMPLETE = 2

# ASFireWire ASFWSCSIController.cpp kMaxTransferPerTask. Anything larger
# must be split into multiple SCSI tasks by the caller.
MAX_TRANSFER_PER_TASK = 1 << 20

# SCSITaskLib.h: valid CDB sizes.
_VALID_CDB_SIZES = (6, 10, 12, 16)

# SCSICmds_REQUEST_SENSE_Defs.h: SCSI_Sense_Data is 18 packed bytes.
_SENSE_DATA_LENGTH = 18

# SCSITaskLib.h kIOPropertySCSITaskDeviceCategory /
# kIOPropertySCSITaskUserClientDevice: the IORegistry rendezvous for
# devices with no in-kernel logical-unit driver (our scanner case).
_DEVICE_CATEGORY_KEY = "SCSITaskDeviceCategory"
_DEVICE_CATEGORY_VALUE = "SCSITaskUserClientDevice"
_INSTANCE_GUID_KEY = "SCSITaskUserClient GUID"

# CFUUID byte tuples from SCSITaskLib.h (comments show the canonical
# string form printed in the header).
# 7D66678E-08A2-11D5-A1B8-0030657D052A
_UUID_SCSITASK_DEVICE_USER_CLIENT = (
    0x7D, 0x66, 0x67, 0x8E, 0x08, 0xA2, 0x11, 0xD5,
    0xA1, 0xB8, 0x00, 0x30, 0x65, 0x7D, 0x05, 0x2A,
)
# 1BBC4132-08A5-11D5-90ED-0030657D052A
_UUID_SCSITASK_DEVICE_INTERFACE = (
    0x1B, 0xBC, 0x41, 0x32, 0x08, 0xA5, 0x11, 0xD5,
    0x90, 0xED, 0x00, 0x30, 0x65, 0x7D, 0x05, 0x2A,
)
# IOCFPlugIn.h: kIOCFPlugInInterfaceID C244E858-109C-11D4-91D4-0050E4C6426F
_UUID_IOCFPLUGIN_INTERFACE = (
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F,
)


class MacScsiTransportError(RuntimeError):
    """A SCSITaskLib call failed; the message carries the IOReturn code."""


# ---------------------------------------------------------------------------
# ctypes transcriptions of the COM vtables. Slot order is ABI.
# ---------------------------------------------------------------------------

_HRESULT = ctypes.c_int32
_ULONG = ctypes.c_uint32
_IOReturn = ctypes.c_int
_Boolean = ctypes.c_ubyte


class _CFUUIDBytes(ctypes.Structure):
    _fields_ = [("byte" + str(i), ctypes.c_uint8) for i in range(16)]


def _uuid_bytes(values: tuple[int, ...]) -> _CFUUIDBytes:
    out = _CFUUIDBytes()
    for i, value in enumerate(values):
        setattr(out, "byte" + str(i), value)
    return out


class _SGElement(ctypes.Structure):
    # SCSITaskLib.h: SCSITaskSGElement = IOAddressRange on LP64 --
    # {UInt64 address, UInt64 length}.
    _fields_ = [("address", ctypes.c_uint64), ("length", ctypes.c_uint64)]


# CFPlugInCOM.h IUNKNOWN_C_GUTS: _reserved, QueryInterface(this,
# REFIID-by-value, void**), AddRef, Release. REFIID = CFUUIDBytes.
def _iunknown_fields() -> list[tuple[str, object]]:
    return [
        ("_reserved", ctypes.c_void_p),
        (
            "QueryInterface",
            ctypes.CFUNCTYPE(
                _HRESULT, ctypes.c_void_p, _CFUUIDBytes,
                ctypes.POINTER(ctypes.c_void_p),
            ),
        ),
        ("AddRef", ctypes.CFUNCTYPE(_ULONG, ctypes.c_void_p)),
        ("Release", ctypes.CFUNCTYPE(_ULONG, ctypes.c_void_p)),
    ]


class _IOCFPlugInVtbl(ctypes.Structure):
    # IOCFPlugIn.h: IUNKNOWN_C_GUTS; IOCFPLUGINBASE (version, revision,
    # Probe, Start, Stop).
    _fields_ = _iunknown_fields() + [
        ("version", ctypes.c_uint16),
        ("revision", ctypes.c_uint16),
        (
            "Probe",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p, ctypes.c_void_p,
                ctypes.c_uint32, ctypes.POINTER(ctypes.c_int32),
            ),
        ),
        (
            "Start",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32
            ),
        ),
        ("Stop", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p)),
    ]


class _DeviceVtbl(ctypes.Structure):
    # SCSITaskLib.h SCSITaskDeviceInterface, exact slot order.
    _fields_ = _iunknown_fields() + [
        ("version", ctypes.c_uint16),
        ("revision", ctypes.c_uint16),
        ("IsExclusiveAccessAvailable", ctypes.CFUNCTYPE(_Boolean, ctypes.c_void_p)),
        (
            "AddCallbackDispatcherToRunLoop",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.c_void_p),
        ),
        (
            "RemoveCallbackDispatcherFromRunLoop",
            ctypes.CFUNCTYPE(None, ctypes.c_void_p),
        ),
        ("ObtainExclusiveAccess", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p)),
        ("ReleaseExclusiveAccess", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p)),
        # Header type is SCSITaskInterface** -- carried as an opaque
        # address so the vtable stays usable from ctypes callbacks in
        # the offline tests (ctypes callbacks cannot return POINTER
        # types), which is a pure declaration choice with identical ABI.
        ("CreateSCSITask", ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)),
    ]


class _TaskVtbl(ctypes.Structure):
    # SCSITaskLib.h SCSITaskInterface, exact slot order.
    _fields_ = _iunknown_fields() + [
        ("version", ctypes.c_uint16),
        ("revision", ctypes.c_uint16),
        ("IsTaskActive", ctypes.CFUNCTYPE(_Boolean, ctypes.c_void_p)),
        ("SetTaskAttribute", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.c_uint32)),
        (
            "GetTaskAttribute",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)),
        ),
        (
            "SetCommandDescriptorBlock",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint8,
            ),
        ),
        ("GetCommandDescriptorBlockSize", ctypes.CFUNCTYPE(ctypes.c_uint8, ctypes.c_void_p)),
        (
            "GetCommandDescriptorBlock",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)),
        ),
        (
            "SetScatterGatherEntries",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p, ctypes.POINTER(_SGElement),
                ctypes.c_uint8, ctypes.c_uint64, ctypes.c_uint8,
            ),
        ),
        ("SetTimeoutDuration", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.c_uint32)),
        ("GetTimeoutDuration", ctypes.CFUNCTYPE(ctypes.c_uint32, ctypes.c_void_p)),
        (
            "SetTaskCompletionCallback",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
            ),
        ),
        ("ExecuteTaskAsync", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p)),
        (
            "ExecuteTaskSync",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p, ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint64),
            ),
        ),
        ("AbortTask", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p)),
        (
            "GetSCSIServiceResponse",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)),
        ),
        (
            "GetTaskState",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)),
        ),
        (
            "GetTaskStatus",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)),
        ),
        ("GetRealizedDataTransferCount", ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_void_p)),
        (
            "GetAutoSenseData",
            ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p, ctypes.c_void_p),
        ),
        (
            "SetAutoSenseDataBuffer",
            ctypes.CFUNCTYPE(
                _IOReturn, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint8
            ),
        ),
        ("ResetForNewTask", ctypes.CFUNCTYPE(_IOReturn, ctypes.c_void_p)),
    ]


# A COM interface handle is a pointer to a pointer to its vtable.
def _vtbl(handle: ctypes.c_void_p, vtbl_type: type[ctypes.Structure]):
    inner = ctypes.cast(handle, ctypes.POINTER(ctypes.c_void_p)).contents
    return ctypes.cast(inner, ctypes.POINTER(vtbl_type)).contents


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class ScsiTaskDeviceInfo:
    """One SCSITask-capable device seen in the IORegistry."""

    registry_entry_id: int
    instance_guid: str | None
    vendor: str | None
    product: str | None
    revision: str | None

    @property
    def looks_like_nikon_coolscan(self) -> bool:
        vendor = (self.vendor or "").strip().upper()
        return vendor == "NIKON"


@dataclasses.dataclass(frozen=True)
class ScsiTransactionResult:
    """Outcome of one synchronous SCSI task, USB-lane result shape."""

    service_response: int
    task_status: int
    transferred: int
    payload: bytes
    sense: bytes

    @property
    def good(self) -> bool:
        return (
            self.service_response == SERVICE_RESPONSE_TASK_COMPLETE
            and self.task_status == TASK_STATUS_GOOD
        )

    @property
    def check_condition(self) -> bool:
        return self.task_status == TASK_STATUS_CHECK_CONDITION


def chunk_transfer_lengths(total: int, cap: int = MAX_TRANSFER_PER_TASK) -> list[int]:
    """Split a transfer into per-task lengths within the HBA's cap.

    ASFireWire's SCSI controller refuses tasks above 1 MB, so a frame
    read must be issued as multiple SCSI tasks. Pure arithmetic so the
    policy is testable off-hardware.
    """

    if total < 0:
        raise ValueError("transfer length cannot be negative")
    if cap <= 0:
        raise ValueError("transfer cap must be positive")
    if total == 0:
        return []
    full, tail = divmod(total, cap)
    return [cap] * full + ([tail] if tail else [])


# ---------------------------------------------------------------------------
# IOKit / CoreFoundation bindings (lazy; only this section is darwin-only)
# ---------------------------------------------------------------------------


class _Frameworks:
    """dlopen handles + prototypes, created on first hardware call."""

    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise MacScsiTransportError(
                "the macOS SCSI transport only exists on macOS; on Linux the "
                "same scanners are reachable through the kernel's firewire-sbp2"
            )
        iokit_path = ctypes.util.find_library("IOKit")
        cf_path = ctypes.util.find_library("CoreFoundation")
        if not iokit_path or not cf_path:
            raise MacScsiTransportError("IOKit/CoreFoundation could not be located")
        self.iokit = ctypes.CDLL(iokit_path)
        self.cf = ctypes.CDLL(cf_path)

        self.iokit.IOServiceMatching.restype = ctypes.c_void_p
        self.iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
        self.iokit.IOServiceGetMatchingServices.restype = ctypes.c_int
        self.iokit.IOServiceGetMatchingServices.argtypes = [
            ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32),
        ]
        self.iokit.IOIteratorNext.restype = ctypes.c_uint32
        self.iokit.IOIteratorNext.argtypes = [ctypes.c_uint32]
        self.iokit.IOObjectRelease.restype = ctypes.c_int
        self.iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]
        self.iokit.IORegistryEntryGetRegistryEntryID.restype = ctypes.c_int
        self.iokit.IORegistryEntryGetRegistryEntryID.argtypes = [
            ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64),
        ]
        self.iokit.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
        self.iokit.IORegistryEntryCreateCFProperty.argtypes = [
            ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
        ]
        self.iokit.IOServiceGetMatchingService.restype = ctypes.c_uint32
        self.iokit.IOServiceGetMatchingService.argtypes = [
            ctypes.c_uint32, ctypes.c_void_p,
        ]
        self.iokit.IORegistryEntryIDMatching.restype = ctypes.c_void_p
        self.iokit.IORegistryEntryIDMatching.argtypes = [ctypes.c_uint64]
        self.iokit.IOCreatePlugInInterfaceForService.restype = ctypes.c_int
        self.iokit.IOCreatePlugInInterfaceForService.argtypes = [
            ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int32),
        ]
        self.iokit.IODestroyPlugInInterface.restype = ctypes.c_int
        self.iokit.IODestroyPlugInInterface.argtypes = [ctypes.c_void_p]

        self.cf.CFUUIDGetConstantUUIDWithBytes.restype = ctypes.c_void_p
        self.cf.CFUUIDGetConstantUUIDWithBytes.argtypes = [ctypes.c_void_p] + [
            ctypes.c_uint8
        ] * 16
        self.cf.CFUUIDGetUUIDBytes.restype = _CFUUIDBytes
        self.cf.CFUUIDGetUUIDBytes.argtypes = [ctypes.c_void_p]
        self.cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        self.cf.CFStringCreateWithCString.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32,
        ]
        self.cf.CFStringGetCString.restype = ctypes.c_ubyte
        self.cf.CFStringGetCString.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32,
        ]
        self.cf.CFRelease.restype = None
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
        self.cf.CFStringGetTypeID.restype = ctypes.c_ulong
        self.cf.CFStringGetTypeID.argtypes = []

        self._utf8 = 0x08000100  # kCFStringEncodingUTF8

    def cfstr(self, value: str) -> ctypes.c_void_p:
        ref = self.cf.CFStringCreateWithCString(None, value.encode(), self._utf8)
        if not ref:
            # CF Create functions may return NULL; passing that onward and
            # CFRelease-ing it later traps.
            raise MacScsiTransportError(f"CFStringCreateWithCString({value!r}) failed")
        return ctypes.c_void_p(ref)

    def cf_to_str(self, ref: int | None) -> str | None:
        if not ref:
            return None
        try:
            if self.cf.CFGetTypeID(ref) != self.cf.CFStringGetTypeID():
                return None
            buf = ctypes.create_string_buffer(256)
            if not self.cf.CFStringGetCString(ref, buf, len(buf), self._utf8):
                return None
            return buf.value.decode(errors="replace")
        finally:
            self.cf.CFRelease(ref)

    def uuid_ref(self, values: tuple[int, ...]) -> ctypes.c_void_p:
        return ctypes.c_void_p(
            self.cf.CFUUIDGetConstantUUIDWithBytes(None, *values)
        )


_frameworks: _Frameworks | None = None


def _get_frameworks() -> _Frameworks:
    global _frameworks
    if _frameworks is None:
        _frameworks = _Frameworks()
    return _frameworks


def _service_string_property(fw: _Frameworks, service: int, key: str) -> str | None:
    cf_key = fw.cfstr(key)
    try:
        ref = fw.iokit.IORegistryEntryCreateCFProperty(service, cf_key, None, 0)
    finally:
        fw.cf.CFRelease(cf_key)
    return fw.cf_to_str(ref)


def _iter_scsi_task_services(fw: _Frameworks) -> Iterator[int]:
    # Match every IOService and filter on the SCSITaskLib category
    # property; matching on the property dict directly would also work
    # but IOServiceMatching on a class name plus a property read keeps
    # the matching dictionary trivial and the filtering logic in Python
    # where it is testable.
    matching = fw.iokit.IOServiceMatching(b"IOService")
    iterator = ctypes.c_uint32(0)
    status = fw.iokit.IOServiceGetMatchingServices(
        0, matching, ctypes.byref(iterator)
    )
    if status != 0:
        raise MacScsiTransportError(
            f"IOServiceGetMatchingServices failed: 0x{status & 0xFFFFFFFF:08x}"
        )
    try:
        while True:
            service = fw.iokit.IOIteratorNext(iterator.value)
            if not service:
                break
            try:
                category = _service_string_property(fw, service, _DEVICE_CATEGORY_KEY)
                if category == _DEVICE_CATEGORY_VALUE:
                    yield service
                    continue
            except MacScsiTransportError:
                pass
            fw.iokit.IOObjectRelease(service)
    finally:
        # IOServiceGetMatchingServices may succeed with a NULL iterator
        # when nothing matched; releasing MACH_PORT_NULL is invalid.
        if iterator.value:
            fw.iokit.IOObjectRelease(iterator.value)


def list_scsi_task_devices() -> list[ScsiTaskDeviceInfo]:
    """Enumerate SCSITask-capable peripherals (no exclusive access taken).

    Identity strings come from the INQUIRY data the kernel already
    collected and published in the IORegistry, so discovery never
    touches the device.
    """

    fw = _get_frameworks()
    devices: list[ScsiTaskDeviceInfo] = []
    for service in _iter_scsi_task_services(fw):
        try:
            entry_id = ctypes.c_uint64(0)
            fw.iokit.IORegistryEntryGetRegistryEntryID(
                service, ctypes.byref(entry_id)
            )
            devices.append(
                ScsiTaskDeviceInfo(
                    registry_entry_id=entry_id.value,
                    instance_guid=_service_string_property(
                        fw, service, _INSTANCE_GUID_KEY
                    ),
                    vendor=_service_string_property(
                        fw, service, "Vendor Identification"
                    ),
                    product=_service_string_property(
                        fw, service, "Product Identification"
                    ),
                    revision=_service_string_property(
                        fw, service, "Product Revision Level"
                    ),
                )
            )
        finally:
            fw.iokit.IOObjectRelease(service)
    return devices


# ---------------------------------------------------------------------------
# The device handle
# ---------------------------------------------------------------------------


class MacScsiTaskDevice:
    """Exclusive SCSITaskLib session with one device.

    Lifecycle: ``open(registry_entry_id)`` -> ``perform_transaction(...)``
    calls -> ``close()``. The context-manager form guarantees exclusive
    access and the plug-in are released even when a transaction raises,
    mirroring the USB lane's teardown discipline.
    """

    def __init__(self) -> None:
        self._fw: _Frameworks | None = None
        self._plugin = ctypes.c_void_p(None)
        self._device = ctypes.c_void_p(None)
        self._exclusive = False

    # -- lifecycle ---------------------------------------------------------

    @classmethod
    def open(cls, registry_entry_id: int) -> "MacScsiTaskDevice":
        self = cls()
        fw = _get_frameworks()
        self._fw = fw

        matching = fw.iokit.IORegistryEntryIDMatching(registry_entry_id)
        service = fw.iokit.IOServiceGetMatchingService(0, matching)
        if not service:
            raise MacScsiTransportError(
                f"no IORegistry entry with id {registry_entry_id}; the device "
                "may have been unplugged or the FireWire bus reset"
            )
        try:
            score = ctypes.c_int32(0)
            status = fw.iokit.IOCreatePlugInInterfaceForService(
                service,
                fw.uuid_ref(_UUID_SCSITASK_DEVICE_USER_CLIENT),
                fw.uuid_ref(_UUID_IOCFPLUGIN_INTERFACE),
                ctypes.byref(self._plugin),
                ctypes.byref(score),
            )
            if status != 0 or not self._plugin:
                raise MacScsiTransportError(
                    "IOCreatePlugInInterfaceForService failed: "
                    f"0x{status & 0xFFFFFFFF:08x} (is another client -- "
                    "VueScan, a stale probe -- holding the device?)"
                )
        finally:
            fw.iokit.IOObjectRelease(service)

        plugin_vtbl = _vtbl(self._plugin, _IOCFPlugInVtbl)
        out = ctypes.c_void_p(None)
        hresult = plugin_vtbl.QueryInterface(
            self._plugin,
            fw.cf.CFUUIDGetUUIDBytes(
                fw.uuid_ref(_UUID_SCSITASK_DEVICE_INTERFACE)
            ),
            ctypes.byref(out),
        )
        if hresult != 0 or not out:
            extra = self._destroy_plugin()
            raise MacScsiTransportError(
                f"QueryInterface(SCSITaskDeviceInterface) failed: {hresult}"
                + ("; " + "; ".join(extra) if extra else "")
            )
        self._device = out
        return self

    def obtain_exclusive_access(self) -> None:
        device_vtbl = _vtbl(self._require_device(), _DeviceVtbl)
        status = device_vtbl.ObtainExclusiveAccess(self._device)
        if status != 0:
            raise MacScsiTransportError(
                f"ObtainExclusiveAccess failed: 0x{status & 0xFFFFFFFF:08x} "
                "(kIOReturnExclusiveAccess means another client owns the "
                "device; kIOReturnBusy means media is mounted)"
            )
        self._exclusive = True

    def close(self, *, raise_on_error: bool = True) -> None:
        """Release exclusive access, the device interface, and the plug-in.

        All teardown steps always run (a failed exclusive release must not
        leak the plug-in), their failures are collected, and by default a
        failure raises AFTER cleanup completes -- silently losing a failed
        ReleaseExclusiveAccess would leave the in-kernel logical-unit
        drivers quiesced with nothing telling the user why. A second
        close() is a no-op.
        """

        failures: list[str] = []
        if self._device:
            device_vtbl = _vtbl(self._device, _DeviceVtbl)
            if self._exclusive:
                status = device_vtbl.ReleaseExclusiveAccess(self._device)
                if status != 0:
                    failures.append(
                        "ReleaseExclusiveAccess failed: "
                        f"0x{status & 0xFFFFFFFF:08x} (the device may stay "
                        "quiesced until this process exits or the bus resets)"
                    )
                self._exclusive = False
            device_vtbl.Release(self._device)
            self._device = ctypes.c_void_p(None)
        failures.extend(self._destroy_plugin())
        if failures and raise_on_error:
            raise MacScsiTransportError("; ".join(failures))

    def __enter__(self) -> "MacScsiTaskDevice":
        return self

    def __exit__(self, exc_type: object, *exc_info: object) -> None:
        # During exception unwind, a teardown failure must not mask the
        # original error; on the clean path it must be heard.
        self.close(raise_on_error=exc_type is None)

    def _destroy_plugin(self) -> list[str]:
        failures: list[str] = []
        if self._plugin and self._fw is not None:
            status = self._fw.iokit.IODestroyPlugInInterface(self._plugin)
            if status != 0:
                failures.append(
                    f"IODestroyPlugInInterface failed: 0x{status & 0xFFFFFFFF:08x}"
                )
            self._plugin = ctypes.c_void_p(None)
        return failures

    def _require_device(self) -> ctypes.c_void_p:
        if not self._device:
            raise MacScsiTransportError("device is not open")
        return self._device

    # -- transactions ------------------------------------------------------

    def perform_transaction(
        self,
        cdb: bytes,
        *,
        direction: int = DATA_TRANSFER_NONE,
        data_out: bytes | None = None,
        data_in_length: int = 0,
        timeout_ms: int = 10_000,
    ) -> ScsiTransactionResult:
        """Execute one synchronous SCSI task and return its full outcome.

        Fail-closed: any SCSITaskLib call that does not return success
        raises; a CHECK CONDITION is not an exception (the caller gets
        status + sense to interpret, matching the USB lane's
        TransactionResult semantics).
        """

        if len(cdb) not in _VALID_CDB_SIZES:
            raise MacScsiTransportError(
                f"CDB length {len(cdb)} invalid; SCSITaskLib accepts "
                f"{_VALID_CDB_SIZES}"
            )
        if direction == DATA_TRANSFER_TO_TARGET and data_out is None:
            raise MacScsiTransportError("outbound transfer requires data_out")
        if direction == DATA_TRANSFER_FROM_TARGET and data_in_length <= 0:
            raise MacScsiTransportError("inbound transfer requires data_in_length")
        transfer_length = (
            len(data_out) if direction == DATA_TRANSFER_TO_TARGET
            else data_in_length if direction == DATA_TRANSFER_FROM_TARGET
            else 0
        )
        if transfer_length > MAX_TRANSFER_PER_TASK:
            raise MacScsiTransportError(
                f"transfer of {transfer_length} bytes exceeds the "
                f"{MAX_TRANSFER_PER_TASK}-byte per-task ceiling; split it "
                "with chunk_transfer_lengths()"
            )

        device = self._require_device()
        if not self._exclusive:
            raise MacScsiTransportError(
                "obtain_exclusive_access() must succeed before transactions"
            )
        device_vtbl = _vtbl(device, _DeviceVtbl)
        task = device_vtbl.CreateSCSITask(device)
        if not task:
            raise MacScsiTransportError("CreateSCSITask returned NULL")
        task_handle = ctypes.c_void_p(task)
        task_vtbl = _vtbl(task_handle, _TaskVtbl)
        try:
            cdb_buf = (ctypes.c_uint8 * len(cdb)).from_buffer_copy(cdb)
            status = task_vtbl.SetCommandDescriptorBlock(
                task_handle, cdb_buf, len(cdb)
            )
            if status != 0:
                raise MacScsiTransportError(
                    f"SetCommandDescriptorBlock failed: 0x{status & 0xFFFFFFFF:08x}"
                )

            data_buf: ctypes.Array[ctypes.c_char] | None = None
            if transfer_length:
                if direction == DATA_TRANSFER_TO_TARGET:
                    assert data_out is not None
                    data_buf = ctypes.create_string_buffer(
                        data_out, transfer_length
                    )
                else:
                    data_buf = ctypes.create_string_buffer(transfer_length)
                element = _SGElement(
                    address=ctypes.cast(data_buf, ctypes.c_void_p).value or 0,
                    length=transfer_length,
                )
                status = task_vtbl.SetScatterGatherEntries(
                    task_handle, ctypes.byref(element), 1,
                    transfer_length, direction,
                )
                if status != 0:
                    raise MacScsiTransportError(
                        f"SetScatterGatherEntries failed: 0x{status & 0xFFFFFFFF:08x}"
                    )

            status = task_vtbl.SetTimeoutDuration(task_handle, timeout_ms)
            if status != 0:
                raise MacScsiTransportError(
                    f"SetTimeoutDuration failed: 0x{status & 0xFFFFFFFF:08x}"
                )

            sense_buf = ctypes.create_string_buffer(_SENSE_DATA_LENGTH)
            task_status = ctypes.c_uint32(0xFF)
            transferred = ctypes.c_uint64(0)
            status = task_vtbl.ExecuteTaskSync(
                task_handle, sense_buf,
                ctypes.byref(task_status), ctypes.byref(transferred),
            )
            if status != 0:
                raise MacScsiTransportError(
                    f"ExecuteTaskSync failed: 0x{status & 0xFFFFFFFF:08x}"
                )
            service_response = ctypes.c_uint32(0)
            status = task_vtbl.GetSCSIServiceResponse(
                task_handle, ctypes.byref(service_response)
            )
            if status != 0:
                raise MacScsiTransportError(
                    f"GetSCSIServiceResponse failed: 0x{status & 0xFFFFFFFF:08x}"
                )

            payload = b""
            if direction == DATA_TRANSFER_FROM_TARGET and data_buf is not None:
                payload = data_buf.raw[: transferred.value]
            return ScsiTransactionResult(
                service_response=service_response.value,
                task_status=task_status.value,
                transferred=transferred.value,
                payload=payload,
                sense=bytes(sense_buf.raw),
            )
        finally:
            task_vtbl.Release(task_handle)

    # -- motion-free probes ------------------------------------------------

    def test_unit_ready(self, *, timeout_ms: int = 5_000) -> ScsiTransactionResult:
        return self.perform_transaction(bytes(6), timeout_ms=timeout_ms)

    def inquiry(
        self, *, allocation: int = 96, timeout_ms: int = 5_000
    ) -> ScsiTransactionResult:
        if not 5 <= allocation <= 255:
            raise MacScsiTransportError("INQUIRY allocation must be 5..255")
        cdb = bytes([0x12, 0x00, 0x00, 0x00, allocation, 0x00])
        return self.perform_transaction(
            cdb,
            direction=DATA_TRANSFER_FROM_TARGET,
            data_in_length=allocation,
            timeout_ms=timeout_ms,
        )

    def request_sense(self, *, timeout_ms: int = 5_000) -> ScsiTransactionResult:
        cdb = bytes([0x03, 0x00, 0x00, 0x00, _SENSE_DATA_LENGTH, 0x00])
        return self.perform_transaction(
            cdb,
            direction=DATA_TRANSFER_FROM_TARGET,
            data_in_length=_SENSE_DATA_LENGTH,
            timeout_ms=timeout_ms,
        )


# ---------------------------------------------------------------------------
# Probe CLI: the artifact a FireWire tester runs and pastes back.
# ---------------------------------------------------------------------------


def _format_inquiry(payload: bytes) -> str:
    if len(payload) < 36:
        return f"short INQUIRY payload ({len(payload)} bytes): {payload.hex()}"
    peripheral = payload[0] & 0x1F
    vendor = payload[8:16].decode("ascii", errors="replace").strip()
    product = payload[16:32].decode("ascii", errors="replace").strip()
    revision = payload[32:36].decode("ascii", errors="replace").strip()
    return (
        f"peripheral device type 0x{peripheral:02x}, vendor {vendor!r}, "
        f"product {product!r}, revision {revision!r}\n"
        f"raw: {payload.hex()}"
    )


def main(argv: list[str] | None = None, *, out: Callable[[str], None] = print) -> int:
    """List SCSITask devices; with ``--probe <id>``, run the motion-free probe."""

    usage = "usage: python -m coolscanpy.transport.macos_scsi [--probe <registry-id>]"
    args = list(sys.argv[1:] if argv is None else argv)
    probe_id: int | None = None
    if args and args[0] == "--probe":
        if len(args) != 2:
            out(usage)
            return 2
        try:
            probe_id = int(args[1], 0)
        except ValueError:
            out(f"--probe expects a registry id (decimal or 0x-hex), got {args[1]!r}")
            out(usage)
            return 2
        if not 0 < probe_id < 1 << 64:
            out(f"--probe registry id out of range: {args[1]!r}")
            out(usage)
            return 2
    elif args:
        out(usage)
        return 2

    devices = list_scsi_task_devices()
    if not devices:
        out(
            "no SCSITask-capable devices found. If a FireWire Coolscan is "
            "connected through ASFireWire, check that the driver extension "
            "is running and logged into the scanner (see its README)."
        )
        return 1
    for device in devices:
        marker = "  <- Nikon" if device.looks_like_nikon_coolscan else ""
        out(
            f"registry id {device.registry_entry_id}: "
            f"vendor={device.vendor!r} product={device.product!r} "
            f"revision={device.revision!r} guid={device.instance_guid!r}{marker}"
        )
    if probe_id is None:
        return 0

    with MacScsiTaskDevice.open(probe_id) as device:
        device.obtain_exclusive_access()
        ready = device.test_unit_ready()
        out(
            f"TEST UNIT READY: service_response={ready.service_response} "
            f"task_status=0x{ready.task_status:02x}"
            + (f" sense={ready.sense.hex()}" if ready.check_condition else "")
        )
        if ready.check_condition:
            sense = device.request_sense()
            out(f"REQUEST SENSE: {sense.payload.hex()}")
        identity = device.inquiry()
        if not identity.good:
            out(
                f"INQUIRY did not complete cleanly: "
                f"service_response={identity.service_response} "
                f"task_status=0x{identity.task_status:02x} "
                f"sense={identity.sense.hex()}"
            )
            return 1
        out("INQUIRY: " + _format_inquiry(identity.payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
