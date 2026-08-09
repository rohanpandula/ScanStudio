"""Offline tests for the Linux SG_IO transport.

The kernel boundary is three module seams (``_open_node``, ``_ioctl``,
``_close_fd``), so a complete fake kernel can be scripted on any platform
-- no Linux, no hardware. The fake parses the REAL ``sg_io_hdr`` buffer
through ctypes, so the struct plumbing under test is the production
layout, not a stand-in. Alongside the behavior tests, an independent ABI
oracle pins the LP64 field offsets and header constants hand-derived
from ``include/scsi/sg.h`` @ v6.6 -- deliberately NOT computed from the
production struct, so a drifted declaration fails even though the fake
would follow it.
"""

from __future__ import annotations

import ctypes
import errno

import pytest

from coolscanpy.transport import linux_sg
from coolscanpy.transport.linux_sg import (
    DATA_TRANSFER_FROM_TARGET,
    DATA_TRANSFER_TO_TARGET,
    MAX_TRANSFER_PER_IO,
    LinuxSgDevice,
    LinuxSgTransportError,
    SgDeviceInfo,
    chunk_transfer_lengths,
    list_sg_devices,
)

_SG_IO = 0x2285
_SG_GET_VERSION_NUM = 0x2282


class FakeSgKernel:
    """A scripted sg node behind the module's three syscall seams.

    ``responses`` maps a CDB opcode byte to a dict with optional keys
    ``payload`` (bytes returned target->initiator), ``status``,
    ``host_status``, ``driver_status``, and ``sense``. Unknown opcodes
    complete GOOD with no data.
    """

    def __init__(
        self,
        responses: dict[int, dict] | None = None,
        *,
        version: int = 30536,
        open_errno: int | None = None,
        eintr_before_success: int = 0,
    ) -> None:
        self.responses = responses or {}
        self.version = version
        self.open_errno = open_errno
        self.eintr_before_success = eintr_before_success
        self.log: list[tuple] = []
        self.open_flags: int | None = None
        self.closed_fds: list[int] = []
        self._next_fd = 7

    def install(self, monkeypatch: pytest.MonkeyPatch) -> "FakeSgKernel":
        monkeypatch.setattr(linux_sg, "_open_node", self._open_node)
        monkeypatch.setattr(linux_sg, "_ioctl", self._ioctl)
        monkeypatch.setattr(linux_sg, "_close_fd", self._close_fd)
        return self

    # -- seams -------------------------------------------------------------

    def _open_node(self, path: str) -> int:
        self.log.append(("open", path))
        if self.open_errno is not None:
            raise OSError(self.open_errno, errno.errorcode[self.open_errno], path)
        return self._next_fd

    def _close_fd(self, fd: int) -> None:
        self.log.append(("close", fd))
        self.closed_fds.append(fd)

    def _ioctl(self, fd: int, request: int, buffer: object) -> int:
        if request == _SG_GET_VERSION_NUM:
            self.log.append(("version", fd))
            assert isinstance(buffer, ctypes.c_int)
            buffer.value = self.version
            return 0
        assert request == _SG_IO, f"unexpected ioctl 0x{request:x}"
        if self.eintr_before_success > 0:
            self.eintr_before_success -= 1
            self.log.append(("sg_io_eintr", fd))
            raise InterruptedError(errno.EINTR, "Interrupted system call")
        hdr = buffer
        assert isinstance(hdr, linux_sg._SgIoHdr)
        assert hdr.interface_id == ord("S")
        assert hdr.iovec_count == 0
        cdb = ctypes.string_at(hdr.cmdp, hdr.cmd_len)
        self.log.append(("sg_io", fd, cdb, hdr.dxfer_direction, hdr.dxfer_len,
                         hdr.timeout))
        script = self.responses.get(cdb[0], {})
        payload = script.get("payload", b"")
        if payload:
            assert hdr.dxfer_direction == linux_sg.DATA_TRANSFER_FROM_TARGET
            n = min(len(payload), hdr.dxfer_len)
            ctypes.memmove(hdr.dxferp, payload, n)
            hdr.resid = hdr.dxfer_len - n
        elif hdr.dxfer_direction == linux_sg.DATA_TRANSFER_TO_TARGET:
            self.log.append(
                ("received", ctypes.string_at(hdr.dxferp, hdr.dxfer_len))
            )
            hdr.resid = 0
        else:
            hdr.resid = hdr.dxfer_len
        sense = script.get("sense", b"")
        if sense:
            ctypes.memmove(hdr.sbp, sense, min(len(sense), hdr.mx_sb_len))
        hdr.sb_len_wr = min(len(sense), hdr.mx_sb_len)
        hdr.status = script.get("status", 0x00)
        hdr.host_status = script.get("host_status", 0)
        hdr.driver_status = script.get("driver_status", 0)
        return 0


_INQUIRY_PAYLOAD = (
    bytes([0x06, 0x00, 0x02, 0x02, 91]) + bytes(3)
    + b"Nikon   " + b"LS-9000 ED      " + b"1.00"
    + bytes(96 - 36)
)


# ---------------------------------------------------------------------------
# Behavior through the real struct plumbing.
# ---------------------------------------------------------------------------


def test_inquiry_round_trip_delivers_payload_and_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    kernel = FakeSgKernel({0x12: {"payload": _INQUIRY_PAYLOAD}}).install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        result = device.inquiry()
    assert result.good
    assert result.transferred == 96
    assert result.payload[8:16] == b"Nikon   "
    assert ("close", 7) in kernel.log


def test_check_condition_returns_sense_instead_of_raising(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sense = bytes([0x70, 0, 0x02, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x3A, 0x00, 0, 0, 0, 0])
    FakeSgKernel({0x00: {"status": 0x02, "sense": sense}}).install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        result = device.test_unit_ready()
    assert not result.good
    assert result.check_condition
    assert result.sense == sense


def test_outbound_data_reaches_the_kernel_buffer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    kernel = FakeSgKernel().install(monkeypatch)
    body = bytes(range(16))
    with LinuxSgDevice.open("/dev/sg1") as device:
        result = device.perform_transaction(
            bytes([0x2A, 0, 0, 0, 0, 0, 0, 0, len(body), 0]),
            direction=DATA_TRANSFER_TO_TARGET,
            data_out=body,
        )
    assert result.good
    assert ("received", body) in kernel.log


def test_open_claim_maps_ebusy_to_named_contention_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    FakeSgKernel(open_errno=errno.EBUSY).install(monkeypatch)
    with pytest.raises(LinuxSgTransportError, match="held by another client"):
        LinuxSgDevice.open("/dev/sg1")


def test_open_uses_excl_nonblock_rdwr() -> None:
    # The claim IS the open flags; pin them at the os level.
    seen: dict[str, int] = {}

    real_open = linux_sg.os.open

    def spy(path: str, flags: int) -> int:
        seen["flags"] = flags
        raise OSError(errno.ENOENT, "spy stops before any real fd")

    linux_sg.os.open = spy  # type: ignore[assignment]
    try:
        with pytest.raises(LinuxSgTransportError):
            LinuxSgDevice.open("/dev/sg99")
    finally:
        linux_sg.os.open = real_open  # type: ignore[assignment]
    import os as real_os

    assert seen["flags"] == real_os.O_RDWR | real_os.O_EXCL | real_os.O_NONBLOCK


def test_pre_v3_sg_driver_is_refused_and_fd_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    kernel = FakeSgKernel(version=20134).install(monkeypatch)
    with pytest.raises(LinuxSgTransportError, match="below the v3"):
        LinuxSgDevice.open("/dev/sg1")
    assert kernel.closed_fds == [7]


def test_eintr_during_sg_io_is_retried(monkeypatch: pytest.MonkeyPatch) -> None:
    kernel = FakeSgKernel(
        {0x12: {"payload": _INQUIRY_PAYLOAD}}, eintr_before_success=2
    ).install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        result = device.inquiry()
    assert result.good
    assert kernel.log.count(("sg_io_eintr", 7)) == 2


def test_host_adapter_fault_raises_named_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    FakeSgKernel({0x00: {"host_status": 0x07}}).install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        with pytest.raises(LinuxSgTransportError, match="host adapter fault"):
            device.test_unit_ready()


def test_driver_sense_bit_is_tolerated_other_bits_raise(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sense = bytes([0x70] + [0] * 17)
    FakeSgKernel(
        {0x00: {"status": 0x02, "driver_status": 0x08, "sense": sense}}
    ).install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        result = device.test_unit_ready()
    assert result.check_condition

    FakeSgKernel({0x00: {"driver_status": 0x06}}).install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        with pytest.raises(LinuxSgTransportError, match="sg driver fault"):
            device.test_unit_ready()


def test_transactions_refuse_after_close(monkeypatch: pytest.MonkeyPatch) -> None:
    FakeSgKernel().install(monkeypatch)
    device = LinuxSgDevice.open("/dev/sg1")
    device.close()
    with pytest.raises(LinuxSgTransportError, match="not open"):
        device.test_unit_ready()


def test_invalid_cdb_is_refused_before_any_syscall(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    kernel = FakeSgKernel().install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        baseline = len(kernel.log)
        with pytest.raises(LinuxSgTransportError, match="CDB length"):
            device.perform_transaction(bytes(7))
        assert len(kernel.log) == baseline


def test_oversize_transfer_refused_with_chunking_pointer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    FakeSgKernel().install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        with pytest.raises(LinuxSgTransportError, match="chunk_transfer_lengths"):
            device.perform_transaction(
                bytes([0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
                direction=DATA_TRANSFER_FROM_TARGET,
                data_in_length=MAX_TRANSFER_PER_IO + 1,
            )


def test_direction_guards_require_matching_buffers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    FakeSgKernel().install(monkeypatch)
    with LinuxSgDevice.open("/dev/sg1") as device:
        with pytest.raises(LinuxSgTransportError, match="requires data_out"):
            device.perform_transaction(bytes(6), direction=DATA_TRANSFER_TO_TARGET)
        with pytest.raises(LinuxSgTransportError, match="requires data_in_length"):
            device.perform_transaction(bytes(6), direction=DATA_TRANSFER_FROM_TARGET)
        with pytest.raises(LinuxSgTransportError, match="timeout_ms"):
            device.test_unit_ready(timeout_ms=0)


# ---------------------------------------------------------------------------
# Discovery from a fake sysfs tree.
# ---------------------------------------------------------------------------


def test_list_sg_devices_reads_sysfs_identity(tmp_path) -> None:
    for name, vendor, model, rev, scsi_type in (
        ("sg0", "ATA     ", "Some Disk       ", "1.0 ", "0"),
        ("sg2", "Nikon   ", "LS-9000 ED      ", "1.00", "6"),
    ):
        d = tmp_path / name / "device"
        d.mkdir(parents=True)
        (d / "vendor").write_text(vendor + "\n")
        (d / "model").write_text(model + "\n")
        (d / "rev").write_text(rev + "\n")
        (d / "type").write_text(scsi_type + "\n")
    (tmp_path / "sg1").mkdir()  # no device dir: fields all None

    devices = list_sg_devices(sysfs_root=str(tmp_path), dev_root="/dev")
    assert [d.node for d in devices] == ["/dev/sg0", "/dev/sg1", "/dev/sg2"]
    nikon = devices[2]
    assert nikon == SgDeviceInfo(
        node="/dev/sg2",
        vendor="Nikon",
        product="LS-9000 ED",
        revision="1.00",
        scsi_type=6,
    )
    assert nikon.looks_like_nikon_coolscan
    assert not devices[0].looks_like_nikon_coolscan
    assert devices[1].vendor is None


def test_list_sg_devices_missing_root_is_empty(tmp_path) -> None:
    assert list_sg_devices(sysfs_root=str(tmp_path / "absent")) == []


# ---------------------------------------------------------------------------
# CLI.
# ---------------------------------------------------------------------------


def test_cli_rejects_malformed_probe_arguments(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lines: list[str] = []
    assert linux_sg.main(["--probe"], out=lines.append) == 2
    assert linux_sg.main(["--probe", "sg1"], out=lines.append) == 2
    assert linux_sg.main(["--frobnicate"], out=lines.append) == 2
    assert any("usage:" in line for line in lines)


def test_cli_probe_runs_the_motion_free_sequence(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    d = tmp_path / "sg1" / "device"
    d.mkdir(parents=True)
    (d / "vendor").write_text("Nikon\n")
    (d / "model").write_text("LS-9000 ED\n")
    (d / "rev").write_text("1.00\n")
    (d / "type").write_text("6\n")
    monkeypatch.setattr(linux_sg, "_SYSFS_SCSI_GENERIC", str(tmp_path))
    kernel = FakeSgKernel({0x12: {"payload": _INQUIRY_PAYLOAD}}).install(monkeypatch)

    lines: list[str] = []
    assert linux_sg.main(["--probe", "/dev/sg1"], out=lines.append) == 0
    joined = "\n".join(lines)
    assert "<- Nikon" in joined
    assert "TEST UNIT READY: status=0x00" in joined
    assert "product 'LS-9000 ED'" in joined
    sg_io_cdbs = [entry[2][0] for entry in kernel.log if entry[0] == "sg_io"]
    assert sg_io_cdbs == [0x00, 0x12]  # TUR then INQUIRY, nothing that moves film


# ---------------------------------------------------------------------------
# The independent ABI oracle: offsets and constants hand-derived from
# include/scsi/sg.h @ v6.6 (LP64), NOT computed from the production struct.
# ---------------------------------------------------------------------------

_EXPECTED_LP64_OFFSETS = {
    "interface_id": 0,
    "dxfer_direction": 4,
    "cmd_len": 8,
    "mx_sb_len": 9,
    "iovec_count": 10,
    "dxfer_len": 12,
    "dxferp": 16,
    "cmdp": 24,
    "sbp": 32,
    "timeout": 40,
    "flags": 44,
    "pack_id": 48,
    # 4 pad bytes: next field is a pointer needing 8-byte alignment.
    "usr_ptr": 56,
    "status": 64,
    "masked_status": 65,
    "msg_status": 66,
    "sb_len_wr": 67,
    "host_status": 68,
    "driver_status": 70,
    "resid": 72,
    "duration": 76,
    "info": 80,
}


def test_sg_io_hdr_matches_hand_derived_lp64_layout() -> None:
    assert ctypes.sizeof(linux_sg._SgIoHdr) == 88
    for name, expected in _EXPECTED_LP64_OFFSETS.items():
        actual = getattr(linux_sg._SgIoHdr, name).offset
        assert actual == expected, (
            f"sg_io_hdr.{name} at offset {actual}, header derivation says "
            f"{expected}"
        )
    assert [name for name, _ in linux_sg._SgIoHdr._fields_] == list(
        _EXPECTED_LP64_OFFSETS
    )


def test_constants_match_the_kernel_headers() -> None:
    # include/scsi/sg.h @ v6.6, values quoted in the module comments.
    assert linux_sg._SG_IO == 0x2285
    assert linux_sg._SG_GET_VERSION_NUM == 0x2282
    assert linux_sg.DATA_TRANSFER_NONE == -1
    assert linux_sg.DATA_TRANSFER_TO_TARGET == -2
    assert linux_sg.DATA_TRANSFER_FROM_TARGET == -3
    assert linux_sg._INTERFACE_ID == ord("S")
    # include/scsi/scsi_device.h @ v6.6: SCSI_SENSE_BUFFERSIZE.
    assert linux_sg._SENSE_BUFFER_SIZE == 96


def test_transfer_ceiling_stays_in_lockstep_with_the_macos_lane() -> None:
    from coolscanpy.transport.macos_scsi import MAX_TRANSFER_PER_TASK

    assert MAX_TRANSFER_PER_IO == MAX_TRANSFER_PER_TASK
    assert chunk_transfer_lengths(MAX_TRANSFER_PER_IO + 1) == [
        MAX_TRANSFER_PER_IO,
        1,
    ]
