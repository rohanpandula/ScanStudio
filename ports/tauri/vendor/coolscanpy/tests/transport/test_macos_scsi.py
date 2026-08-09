"""Offline tests for the macOS SCSITaskLib transport.

The COM vtables are plain C structs of function pointers, so a complete
fake device can be built from ctypes callbacks on any platform -- no
IOKit, no hardware. These tests pin the parts that must not drift: the
transaction call sequence, buffer plumbing in both directions, sense
propagation, the fail-closed guards, and the 1 MB chunking policy that
mirrors ASFireWire's per-task ceiling.
"""

from __future__ import annotations

import ctypes

import pytest

from coolscanpy.transport import macos_scsi
from coolscanpy.transport.macos_scsi import (
    DATA_TRANSFER_FROM_TARGET,
    DATA_TRANSFER_TO_TARGET,
    MAX_TRANSFER_PER_TASK,
    MacScsiTaskDevice,
    MacScsiTransportError,
    chunk_transfer_lengths,
)


class FakeScsiTarget:
    """A scripted SCSI target behind real C vtables.

    ``responses`` maps a CDB opcode byte to a dict with optional keys
    ``payload`` (bytes returned target->initiator), ``task_status``,
    ``service_response``, and ``sense`` (18 bytes). Unknown opcodes
    complete GOOD with no data.
    """

    def __init__(
        self,
        responses: dict[int, dict] | None = None,
        *,
        fail_step: str | None = None,
    ) -> None:
        self.responses = responses or {}
        self.fail_step = fail_step
        self.log: list[tuple] = []
        self._keepalive: list[object] = []
        self.released_tasks = 0
        self.exclusive_result = 0
        self._cdb = b""
        self._sg: tuple[int, int, int] | None = None
        self.device_handle = self._make_device()

    # -- COM plumbing ------------------------------------------------------

    def _com_handle(self, vtbl: ctypes.Structure) -> ctypes.c_void_p:
        vtbl_ptr = ctypes.pointer(vtbl)
        cell = ctypes.c_void_p(ctypes.cast(vtbl_ptr, ctypes.c_void_p).value)
        self._keepalive += [vtbl, vtbl_ptr, cell]
        return ctypes.cast(ctypes.pointer(cell), ctypes.c_void_p)

    def _make_device(self) -> ctypes.c_void_p:
        fields = dict.fromkeys(
            [name for name, _ in macos_scsi._DeviceVtbl._fields_]
        )
        types = dict(macos_scsi._DeviceVtbl._fields_)

        def stub(name):
            kind = types[name]
            if not isinstance(kind, type) or not issubclass(
                kind, ctypes._CFuncPtr
            ):
                return 0

            def impl(*args):
                self.log.append((name,) + args[1:])
                restype = kind._restype_
                if restype in (None,):
                    return None
                return 0

            fn = kind(impl)
            self._keepalive.append(fn)
            return fn

        for name in fields:
            fields[name] = stub(name)

        def obtain(_self):
            self.log.append(("ObtainExclusiveAccess",))
            return self.exclusive_result

        def release_exclusive(_self):
            self.log.append(("ReleaseExclusiveAccess",))
            return 0

        def release(_self):
            self.log.append(("DeviceRelease",))
            return 0

        def create_task(_self):
            self.log.append(("CreateSCSITask",))
            return self._make_task().value

        fields["ObtainExclusiveAccess"] = types["ObtainExclusiveAccess"](obtain)
        fields["ReleaseExclusiveAccess"] = types["ReleaseExclusiveAccess"](
            release_exclusive
        )
        fields["Release"] = types["Release"](release)
        fields["CreateSCSITask"] = types["CreateSCSITask"](create_task)
        self._keepalive += [
            fields["ObtainExclusiveAccess"],
            fields["ReleaseExclusiveAccess"],
            fields["Release"],
            fields["CreateSCSITask"],
        ]
        return self._com_handle(macos_scsi._DeviceVtbl(**fields))

    def _make_task(self) -> ctypes.c_void_p:
        types = dict(macos_scsi._TaskVtbl._fields_)
        fields = {}
        for name, kind in macos_scsi._TaskVtbl._fields_:
            if not isinstance(kind, type) or not issubclass(
                kind, ctypes._CFuncPtr
            ):
                fields[name] = 0
                continue

            def impl(*args, _name=name, _kind=kind):
                self.log.append((_name,))
                return 0 if _kind._restype_ is not None else None

            fn = kind(impl)
            self._keepalive.append(fn)
            fields[name] = fn

        def set_cdb(_task, cdb_ptr, size):
            if self.fail_step == "SetCommandDescriptorBlock":
                return -1
            self._cdb = bytes(
                ctypes.cast(
                    cdb_ptr, ctypes.POINTER(ctypes.c_uint8 * size)
                ).contents
            )
            self.log.append(("SetCommandDescriptorBlock", self._cdb))
            return 0

        def set_sg(_task, sg_ptr, entries, total, direction):
            if self.fail_step == "SetScatterGatherEntries":
                return -1
            element = sg_ptr[0]
            self._sg = (element.address, element.length, direction)
            self.log.append(("SetScatterGatherEntries", entries, total, direction))
            return 0

        def set_timeout(_task, _timeout_ms):
            if self.fail_step == "SetTimeoutDuration":
                return -1
            self.log.append(("SetTimeoutDuration", _timeout_ms))
            return 0

        def execute(_task, sense_ptr, status_ptr, transferred_ptr):
            if self.fail_step == "ExecuteTaskSync":
                return -1
            script = self.responses.get(self._cdb[0] if self._cdb else -1, {})
            payload = script.get("payload", b"")
            transferred = 0
            if self._sg is not None:
                address, length, direction = self._sg
                if direction == DATA_TRANSFER_FROM_TARGET and payload:
                    n = min(len(payload), length)
                    ctypes.memmove(address, payload, n)
                    transferred = n
                elif direction == DATA_TRANSFER_TO_TARGET:
                    self.log.append(
                        ("host-to-target-data", ctypes.string_at(address, length))
                    )
                    transferred = length
            sense = script.get("sense", bytes(18))
            ctypes.memmove(sense_ptr, sense, len(sense))
            ctypes.cast(status_ptr, ctypes.POINTER(ctypes.c_uint32))[0] = (
                script.get("task_status", 0x00)
            )
            ctypes.cast(transferred_ptr, ctypes.POINTER(ctypes.c_uint64))[0] = (
                transferred
            )
            self.log.append(("ExecuteTaskSync",))
            self._service_response = script.get("service_response", 2)
            return 0

        def service_response(_task, out_ptr):
            if self.fail_step == "GetSCSIServiceResponse":
                return -1
            ctypes.cast(out_ptr, ctypes.POINTER(ctypes.c_uint32))[0] = (
                self._service_response
            )
            return 0

        def release(_task):
            self.released_tasks += 1
            self.log.append(("TaskRelease",))
            return 0

        fields["SetCommandDescriptorBlock"] = types["SetCommandDescriptorBlock"](set_cdb)
        fields["SetScatterGatherEntries"] = types["SetScatterGatherEntries"](set_sg)
        fields["SetTimeoutDuration"] = types["SetTimeoutDuration"](set_timeout)
        fields["ExecuteTaskSync"] = types["ExecuteTaskSync"](execute)
        fields["GetSCSIServiceResponse"] = types["GetSCSIServiceResponse"](
            service_response
        )
        fields["Release"] = types["Release"](release)
        self._keepalive += [
            fields["SetCommandDescriptorBlock"],
            fields["SetScatterGatherEntries"],
            fields["SetTimeoutDuration"],
            fields["ExecuteTaskSync"],
            fields["GetSCSIServiceResponse"],
            fields["Release"],
        ]
        return self._com_handle(macos_scsi._TaskVtbl(**fields))


def device_over(target: FakeScsiTarget) -> MacScsiTaskDevice:
    device = MacScsiTaskDevice()
    device._device = target.device_handle
    return device


def test_inquiry_round_trip_delivers_payload_and_identity() -> None:
    inquiry_payload = (
        bytes([0x06]) + bytes(7)
        + b"NIKON   " + b"LS-9000 ED      " + b"1.00" + bytes(60)
    )
    target = FakeScsiTarget({0x12: {"payload": inquiry_payload}})
    device = device_over(target)
    device.obtain_exclusive_access()
    result = device.inquiry(allocation=96)
    assert result.good
    assert result.payload == inquiry_payload
    assert result.transferred == len(inquiry_payload)
    formatted = macos_scsi._format_inquiry(result.payload)
    assert "LS-9000 ED" in formatted and "NIKON" in formatted
    assert target.released_tasks == 1
    assert target._cdb == bytes([0x12, 0x00, 0x00, 0x00, 96, 0x00])


def test_check_condition_returns_sense_instead_of_raising() -> None:
    sense = bytes([0x70, 0x00, 0x02]) + bytes(9) + bytes([0x3A, 0x00]) + bytes(4)
    target = FakeScsiTarget({0x00: {"task_status": 0x02, "sense": sense}})
    device = device_over(target)
    device.obtain_exclusive_access()
    result = device.test_unit_ready()
    assert result.check_condition and not result.good
    assert result.sense == sense


def test_outbound_data_reaches_the_target_buffer() -> None:
    target = FakeScsiTarget()
    device = device_over(target)
    device.obtain_exclusive_access()
    body = bytes(range(16))
    result = device.perform_transaction(
        bytes([0x15, 0, 0, 0, len(body), 0]),
        direction=DATA_TRANSFER_TO_TARGET,
        data_out=body,
    )
    assert result.good
    assert ("host-to-target-data", body) in target.log


def test_transactions_refuse_before_exclusive_access() -> None:
    device = device_over(FakeScsiTarget())
    with pytest.raises(MacScsiTransportError, match="exclusive"):
        device.test_unit_ready()


def test_exclusive_access_failure_is_fatal_and_named() -> None:
    target = FakeScsiTarget()
    target.exclusive_result = -536870203  # kIOReturnExclusiveAccess shape
    device = device_over(target)
    with pytest.raises(MacScsiTransportError, match="ObtainExclusiveAccess"):
        device.obtain_exclusive_access()


@pytest.mark.parametrize(
    "step",
    [
        "SetCommandDescriptorBlock",
        "SetScatterGatherEntries",
        "SetTimeoutDuration",
        "ExecuteTaskSync",
        "GetSCSIServiceResponse",
    ],
)
def test_task_released_when_each_post_creation_step_fails(step: str) -> None:
    target = FakeScsiTarget(fail_step=step)
    device = device_over(target)
    device.obtain_exclusive_access()
    with pytest.raises(MacScsiTransportError, match=step):
        device.perform_transaction(
            bytes([0x12, 0, 0, 0, 96, 0]),
            direction=DATA_TRANSFER_FROM_TARGET,
            data_in_length=96,
        )
    assert target.released_tasks == 1, f"task leaked after {step} failure"


def test_invalid_cdb_is_refused_before_any_task_exists() -> None:
    target = FakeScsiTarget()
    device = device_over(target)
    device.obtain_exclusive_access()
    with pytest.raises(MacScsiTransportError, match="CDB length"):
        device.perform_transaction(b"\x00" * 7)
    assert ("CreateSCSITask",) not in target.log
    assert target.released_tasks == 0


# ---------------------------------------------------------------------------
# Independent ABI oracle: hard-coded from the SDK headers, NOT derived from
# the production declarations, so a slot swap or width change in the
# production vtables fails here even though the fake target would follow it.
# ---------------------------------------------------------------------------

_EXPECTED_UUIDS = {
    # SCSITaskLib.h
    "_UUID_SCSITASK_DEVICE_USER_CLIENT": "7D66678E-08A2-11D5-A1B8-0030657D052A",
    "_UUID_SCSITASK_DEVICE_INTERFACE": "1BBC4132-08A5-11D5-90ED-0030657D052A",
    # IOCFPlugIn.h
    "_UUID_IOCFPLUGIN_INTERFACE": "C244E858-109C-11D4-91D4-0050E4C6426F",
}

_IUNKNOWN_SLOTS = ["_reserved", "QueryInterface", "AddRef", "Release"]

# SCSITaskLib.h SCSITaskDeviceInterface, header order.
_EXPECTED_DEVICE_SLOTS = _IUNKNOWN_SLOTS + [
    "version",
    "revision",
    "IsExclusiveAccessAvailable",
    "AddCallbackDispatcherToRunLoop",
    "RemoveCallbackDispatcherFromRunLoop",
    "ObtainExclusiveAccess",
    "ReleaseExclusiveAccess",
    "CreateSCSITask",
]

# SCSITaskLib.h SCSITaskInterface, header order.
_EXPECTED_TASK_SLOTS = _IUNKNOWN_SLOTS + [
    "version",
    "revision",
    "IsTaskActive",
    "SetTaskAttribute",
    "GetTaskAttribute",
    "SetCommandDescriptorBlock",
    "GetCommandDescriptorBlockSize",
    "GetCommandDescriptorBlock",
    "SetScatterGatherEntries",
    "SetTimeoutDuration",
    "GetTimeoutDuration",
    "SetTaskCompletionCallback",
    "ExecuteTaskAsync",
    "ExecuteTaskSync",
    "AbortTask",
    "GetSCSIServiceResponse",
    "GetTaskState",
    "GetTaskStatus",
    "GetRealizedDataTransferCount",
    "GetAutoSenseData",
    "SetAutoSenseDataBuffer",
    "ResetForNewTask",
]

# IOCFPlugIn.h: IUNKNOWN_C_GUTS + IOCFPLUGINBASE.
_EXPECTED_PLUGIN_SLOTS = _IUNKNOWN_SLOTS + [
    "version", "revision", "Probe", "Start", "Stop",
]


def test_uuid_constants_match_the_sdk_headers() -> None:
    for name, canonical in _EXPECTED_UUIDS.items():
        values = getattr(macos_scsi, name)
        rendered = "".join(f"{b:02X}" for b in values)
        expected = canonical.replace("-", "")
        assert rendered == expected, f"{name} drifted from the SDK header"


def test_vtable_slot_order_matches_the_sdk_headers() -> None:
    assert [n for n, _ in macos_scsi._DeviceVtbl._fields_] == _EXPECTED_DEVICE_SLOTS
    assert [n for n, _ in macos_scsi._TaskVtbl._fields_] == _EXPECTED_TASK_SLOTS
    assert [n for n, _ in macos_scsi._IOCFPlugInVtbl._fields_] == _EXPECTED_PLUGIN_SLOTS


def test_vtable_struct_sizes_match_compiled_lp64_layout() -> None:
    # Sizes measured by a C program compiled against the SDK headers on
    # arm64 (LP64): IOCFPlugInInterface 64, SCSITaskDeviceInterface 88,
    # SCSITaskInterface 200; CFUUIDBytes 16, SCSITaskSGElement 16 with
    # fields at offsets 0 and 8.
    assert ctypes.sizeof(macos_scsi._IOCFPlugInVtbl) == 64
    assert ctypes.sizeof(macos_scsi._DeviceVtbl) == 88
    assert ctypes.sizeof(macos_scsi._TaskVtbl) == 200
    assert ctypes.sizeof(macos_scsi._CFUUIDBytes) == 16
    assert ctypes.sizeof(macos_scsi._SGElement) == 16
    assert macos_scsi._SGElement.address.offset == 0
    assert macos_scsi._SGElement.length.offset == 8


def test_close_reports_release_failures_after_finishing_cleanup() -> None:
    target = FakeScsiTarget()
    device = device_over(target)
    device.obtain_exclusive_access()

    release_result = {"value": -1}
    types = dict(macos_scsi._DeviceVtbl._fields_)

    def failing_release(_self):
        target.log.append(("ReleaseExclusiveAccess",))
        return release_result["value"]

    vtbl = macos_scsi._vtbl(target.device_handle, macos_scsi._DeviceVtbl)
    replacement = types["ReleaseExclusiveAccess"](failing_release)
    target._keepalive.append(replacement)
    vtbl.ReleaseExclusiveAccess = replacement

    with pytest.raises(MacScsiTransportError, match="ReleaseExclusiveAccess"):
        device.close()
    # cleanup still completed: device handle dropped, second close is a no-op
    assert not device._device
    device.close()


def test_cli_rejects_malformed_probe_ids() -> None:
    lines: list[str] = []
    assert macos_scsi.main(["--probe", "not-a-registry-id"], out=lines.append) == 2
    assert any("registry id" in line for line in lines)
    assert macos_scsi.main(["--probe", "-4"], out=lines.append) == 2
    assert macos_scsi.main(["--probe"], out=lines.append) == 2
    assert macos_scsi.main(["bogus"], out=lines.append) == 2


def test_oversize_transfer_refused_with_chunking_pointer() -> None:
    device = device_over(FakeScsiTarget())
    device._exclusive = True
    with pytest.raises(MacScsiTransportError, match="chunk_transfer_lengths"):
        device.perform_transaction(
            bytes(10),
            direction=DATA_TRANSFER_FROM_TARGET,
            data_in_length=MAX_TRANSFER_PER_TASK + 1,
        )


def test_chunk_transfer_lengths_policy() -> None:
    assert chunk_transfer_lengths(0) == []
    assert chunk_transfer_lengths(MAX_TRANSFER_PER_TASK) == [MAX_TRANSFER_PER_TASK]
    assert chunk_transfer_lengths(MAX_TRANSFER_PER_TASK + 1) == [
        MAX_TRANSFER_PER_TASK, 1,
    ]
    lengths = chunk_transfer_lengths(10 * MAX_TRANSFER_PER_TASK + 12345)
    assert sum(lengths) == 10 * MAX_TRANSFER_PER_TASK + 12345
    assert all(0 < n <= MAX_TRANSFER_PER_TASK for n in lengths)
    with pytest.raises(ValueError):
        chunk_transfer_lengths(-1)


def test_direction_guards_require_matching_buffers() -> None:
    device = device_over(FakeScsiTarget())
    device._exclusive = True
    with pytest.raises(MacScsiTransportError, match="data_out"):
        device.perform_transaction(bytes(6), direction=DATA_TRANSFER_TO_TARGET)
    with pytest.raises(MacScsiTransportError, match="data_in_length"):
        device.perform_transaction(bytes(6), direction=DATA_TRANSFER_FROM_TARGET)


def test_format_inquiry_handles_short_payloads() -> None:
    text = macos_scsi._format_inquiry(b"\x06\x00")
    assert "short INQUIRY payload" in text
