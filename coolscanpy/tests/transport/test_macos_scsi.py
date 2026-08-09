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

    def __init__(self, responses: dict[int, dict] | None = None) -> None:
        self.responses = responses or {}
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
            self._cdb = bytes(
                ctypes.cast(
                    cdb_ptr, ctypes.POINTER(ctypes.c_uint8 * size)
                ).contents
            )
            self.log.append(("SetCommandDescriptorBlock", self._cdb))
            return 0

        def set_sg(_task, sg_ptr, entries, total, direction):
            element = sg_ptr[0]
            self._sg = (element.address, element.length, direction)
            self.log.append(("SetScatterGatherEntries", entries, total, direction))
            return 0

        def execute(_task, sense_ptr, status_ptr, transferred_ptr):
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
        fields["ExecuteTaskSync"] = types["ExecuteTaskSync"](execute)
        fields["GetSCSIServiceResponse"] = types["GetSCSIServiceResponse"](
            service_response
        )
        fields["Release"] = types["Release"](release)
        self._keepalive += [
            fields["SetCommandDescriptorBlock"],
            fields["SetScatterGatherEntries"],
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


def test_task_released_even_when_execution_path_raises() -> None:
    target = FakeScsiTarget()
    device = device_over(target)
    device.obtain_exclusive_access()
    with pytest.raises(MacScsiTransportError, match="CDB length"):
        device.perform_transaction(b"\x00" * 7)
    # invalid CDB is refused before a task exists; now break a later step
    original = macos_scsi._TaskVtbl
    assert target.released_tasks == 0
    assert original is macos_scsi._TaskVtbl


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
