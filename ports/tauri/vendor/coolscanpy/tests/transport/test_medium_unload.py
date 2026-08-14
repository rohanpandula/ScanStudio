"""Hardware-free tests for the standalone raw-USB medium unload.

These prove the exact traced byte sequence reaches the wire, that the
confirmation gate never reports success it did not observe, and that the
adapter capability bit refuses a mount adapter before any motion command is
sent. No hardware, no SANE, no python-sane.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import pytest

from coolscanpy.protocol.ls5000_single_pass.worker import TransactionResult
from coolscanpy.transport import adapter_identity, medium_unload
from coolscanpy.transport.adapter_status import AdapterStatus

# VPD page E1h exactly as real hardware returned it, transcribed row for row
# from live dumps of each adapter. Byte 30 is the specification's "Execute
# operation support D0" group and bit 0 of it is "Unload object".
SA30_PAGE_E1 = bytes.fromhex(
    "06e10023830c80b090da7b0000000000"  # bytes 0-15
    "00001000030000000100190003004500"  # bytes 16-31
    "000000000c0400"  # bytes 32-38
)
MA21_PAGE_E1 = bytes.fromhex(
    "06e10023820c80b0909a7c0000000000"  # bytes 0-15
    "00001000030002000100090003000000"  # bytes 16-31
    "000000000c0400"  # bytes 32-38
)
# A well-formed page too short to carry byte 30.
SHORT_PAGE_E1 = bytes.fromhex("06e1000401020304")


@dataclass
class _FakeInterface:
    bInterfaceNumber: int = 3


@dataclass
class _FakeUsbUtil:
    released: list[tuple[object, int]] = field(default_factory=list)
    disposed: list[object] = field(default_factory=list)

    def release_interface(self, device: object, number: int) -> None:
        self.released.append((device, number))

    def dispose_resources(self, device: object) -> None:
        self.disposed.append(device)


def _good_status() -> bytes:
    """The Nikon GOOD status envelope: condition 00h, sense 000000."""

    return bytes(8)


def _result(
    *,
    phase: int,
    payload: bytes = b"",
    status: bytes | None = None,
    sense: str | None = None,
) -> TransactionResult:
    resolved_status = _good_status() if status is None else status
    return TransactionResult(
        phase=phase,
        payload=payload,
        status=resolved_status,
        sense=resolved_status[1:4].hex() if sense is None else sense,
        stall_recoveries=0,
    )


class _Wire:
    """Records every CDB the module sends and replies from a script."""

    def __init__(
        self,
        *,
        capability_page: bytes | None = SA30_PAGE_E1,
        refuse: dict[str, TransactionResult] | None = None,
    ) -> None:
        self.entries: list[dict] = []
        self._capability_page = capability_page
        self._refuse = refuse or {}

    def __call__(
        self,
        ep_out: object,
        ep_in: object,
        entry: dict,
        *,
        data_timeout_ms: int,
        deadline_monotonic: float | None = None,
    ) -> TransactionResult:
        self.entries.append(dict(entry))
        cdb = entry["cdb"]
        if cdb in self._refuse:
            return self._refuse[cdb]
        if cdb.startswith("1201e1"):
            if self._capability_page is None:
                raise RuntimeError("page E1h refused")
            allocation = bytes.fromhex(cdb)[4]
            if allocation == 0x04:
                return _result(phase=0x03, payload=self._capability_page[:4])
            return _result(phase=0x03, payload=self._capability_page[:allocation])
        if cdb == medium_unload.UNLOAD_SET_PARAMETER_CDB:
            return _result(phase=0x02)
        return _result(phase=0x01)

    @property
    def cdbs(self) -> list[str]:
        return [entry["cdb"] for entry in self.entries]

    @property
    def motion_cdbs(self) -> list[str]:
        """Every CDB except the read-only INQUIRY capability reads."""

        return [cdb for cdb in self.cdbs if not cdb.startswith("12")]


def _install(
    monkeypatch: pytest.MonkeyPatch,
    *,
    wire: _Wire,
    preflight: bool | None = True,
    confirmations: list[bool | None] | None = None,
) -> tuple[_FakeUsbUtil, list[str | None]]:
    usb_util = _FakeUsbUtil()
    monkeypatch.setattr(
        medium_unload,
        "_connect_device",
        lambda **_kwargs: (object(), _FakeInterface(), object(), object(), usb_util),
    )
    monkeypatch.setattr(medium_unload, "_perform_transaction", wire)
    # The capability read goes out through adapter_identity's own bound
    # transaction helper, so the same wire has to stand in for both.
    monkeypatch.setattr(adapter_identity, "_perform_transaction", wire)
    monkeypatch.setattr(medium_unload.time, "sleep", lambda _seconds: None)

    remaining = list(confirmations or [])
    probed: list[str | None] = []

    def probe(*, device_id: str | None = None) -> AdapterStatus:
        probed.append(device_id)
        if len(probed) == 1:
            present = preflight
        else:
            present = remaining.pop(0) if remaining else True
        raw = {True: "000000", False: "023a00", None: "020401"}[present]
        return AdapterStatus(
            film_present=present,
            frame_capacity=40 if present is True else None,
            raw_status=raw,
            device_id=device_id,
        )

    monkeypatch.setattr(medium_unload, "probe_adapter_status", probe)
    return usb_util, probed


# ===========================================================================
# The traced byte sequence
# ===========================================================================


class TestTracedByteSequence:
    def test_constants_match_the_capture_worker_byte_for_byte(self) -> None:
        """The standalone lane must not drift from the held-session eject."""

        from coolscanpy.protocol.ls5000_single_pass import worker

        assert medium_unload.UNLOAD_SET_PARAMETER_CDB == worker.VENDOR_EJECT_CDB
        assert medium_unload.UNLOAD_PARAMETER_DATA_OUT == worker.VENDOR_EJECT_DATA_OUT
        assert medium_unload.EXECUTE_CDB == worker.EXECUTE_CDB

    def test_constants_are_the_exact_traced_values(self) -> None:
        assert medium_unload.RESERVE_UNIT_CDB == "160000000000"
        assert medium_unload.UNLOAD_SET_PARAMETER_CDB == "e000d000000000000900"
        assert medium_unload.UNLOAD_PARAMETER_DATA_OUT == "0000000000031ad070"
        assert medium_unload.EXECUTE_CDB == "c10000000000"
        assert medium_unload.RELEASE_UNIT_CDB == "170000000000"

    def test_set_parameter_cdb_decodes_onto_the_spec_layout(self) -> None:
        """Table 2-15-1: byte 2 is the operation code; D0h = Unload object."""

        cdb = bytes.fromhex(medium_unload.UNLOAD_SET_PARAMETER_CDB)
        assert len(cdb) == 10
        assert cdb[0] == 0xE0  # SET PARAMETER
        assert cdb[1] == 0x00  # LUN 0
        assert cdb[2] == 0xD0  # operation code: Unload object
        assert cdb[3:8] == bytes(5)  # reserved
        assert cdb[8] == len(bytes.fromhex(medium_unload.UNLOAD_PARAMETER_DATA_OUT))
        assert cdb[9] == 0x00  # control byte

    def test_sends_the_exact_sequence_in_the_traced_order(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[False])

        outcome = medium_unload.unload_medium(device_id="usb:1:2")

        assert outcome.ejected is True
        assert outcome.already_clear is False
        assert wire.motion_cdbs == [
            "160000000000",  # RESERVE_UNIT
            "e000d000000000000900",  # SET PARAMETER, operation code D0h
            "c10000000000",  # EXECUTE
            "170000000000",  # RELEASE_UNIT
        ]

    def test_set_parameter_carries_the_traced_parameter_block(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[False])

        medium_unload.unload_medium()

        (set_parameter,) = [
            entry
            for entry in wire.entries
            if entry["cdb"] == medium_unload.UNLOAD_SET_PARAMETER_CDB
        ]
        assert set_parameter["data_out"] == "0000000000031ad070"

    def test_no_other_command_carries_a_data_out_payload(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[False])

        medium_unload.unload_medium()

        for entry in wire.entries:
            if entry["cdb"] != medium_unload.UNLOAD_SET_PARAMETER_CDB:
                assert "data_out" not in entry

    def test_reports_each_command_status(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[False])

        outcome = medium_unload.unload_medium()

        assert [name for name, _status in outcome.command_statuses] == [
            "RESERVE_UNIT",
            "SET_PARAMETER:D0",
            "EXECUTE",
            "RELEASE_UNIT",
        ]
        assert all(status == "00" * 8 for _name, status in outcome.command_statuses)


# ===========================================================================
# Adapter capability gate (the mount-adapter refusal)
# ===========================================================================


class TestCapabilityGate:
    def test_live_page_fixtures_match_the_specification_table(self) -> None:
        """SA-30 byte 30 = 0x45, MA-21 byte 30 = 0x00 (spec :4863-4930)."""

        for page in (SA30_PAGE_E1, MA21_PAGE_E1):
            # Four-byte VPD header plus the specification's 35d page length.
            assert len(page) == 4 + 0x23
            assert page[1] == 0xE1

        # SA-30 column: Unload object [1], Absolute positioning [1],
        # SA Lock [1], everything else in the group [0].
        assert SA30_PAGE_E1[30] == 0x45
        assert SA30_PAGE_E1[30] & 0x01  # bit 0 Unload object -> [1]
        # MA-21 column: every D0-group operation [0].
        assert MA21_PAGE_E1[30] == 0x00
        assert not MA21_PAGE_E1[30] & 0x01  # bit 0 Unload object -> [0]

    def test_live_page_fixtures_carry_each_adapter_host_cooperation_byte(
        self,
    ) -> None:
        """Byte 4 is [83h] for SA-21/SA-30 and [82h] for other adapters."""

        assert SA30_PAGE_E1[4] == 0x83
        assert MA21_PAGE_E1[4] == 0x82

    def test_mount_adapter_refuses_before_sending_any_motion_command(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire(capability_page=MA21_PAGE_E1)
        _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.UnloadNotSupported, match="Unload object"):
            medium_unload.unload_medium()

        assert wire.motion_cdbs == []

    def test_refusal_names_the_physical_remedy(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire(capability_page=MA21_PAGE_E1)
        _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.UnloadNotSupported) as caught:
            medium_unload.unload_medium()

        message = str(caught.value)
        assert "manual eject button" in message
        assert "power-cycle" in message

    def test_strip_feeder_capability_permits_the_sequence(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire(capability_page=SA30_PAGE_E1)
        _install(monkeypatch, wire=wire, confirmations=[False])

        outcome = medium_unload.unload_medium()

        assert outcome.ejected is True
        assert outcome.unload_supported is True
        assert outcome.adapter_capability_byte == 0x45

    def test_unreadable_capability_page_proceeds_rather_than_refusing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Absent information must never block an otherwise-working eject."""

        wire = _Wire(capability_page=None)
        _install(monkeypatch, wire=wire, confirmations=[False])

        outcome = medium_unload.unload_medium()

        assert outcome.ejected is True
        assert outcome.unload_supported is None
        assert wire.motion_cdbs == [
            "160000000000",
            "e000d000000000000900",
            "c10000000000",
            "170000000000",
        ]

    def test_capability_page_too_short_for_byte_30_proceeds(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire(capability_page=SHORT_PAGE_E1)
        _install(monkeypatch, wire=wire, confirmations=[False])

        outcome = medium_unload.unload_medium()

        assert outcome.ejected is True
        assert outcome.unload_supported is None
        assert outcome.adapter_capability_byte is None


# ===========================================================================
# Presence-confirmation settle semantics
# ===========================================================================


class TestConfirmationGate:
    def test_definitive_absent_confirms_the_eject(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[False])

        outcome = medium_unload.unload_medium()

        assert outcome.ejected is True
        assert outcome.confirm_senses[-1] == "023a00"

    def test_absent_after_indeterminate_drain_still_confirms(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """LV-2's shape: post-motion unit attentions before the verdict."""

        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[None, None, False])

        outcome = medium_unload.unload_medium()

        assert outcome.ejected is True
        assert outcome.confirm_senses == ("020401", "020401", "023a00")

    def test_absent_after_present_still_confirms(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Film in motion still reads present; only the deadline decides."""

        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[True, True, False])

        assert medium_unload.unload_medium().ejected is True

    def test_definitive_present_at_deadline_is_accepted_without_progress(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[True])

        with pytest.raises(
            medium_unload.UnloadAcceptedWithoutProgress,
            match="accepted without progress",
        ):
            medium_unload.unload_medium(confirm_deadline_seconds=0.0)

    def test_indeterminate_at_deadline_is_unconfirmed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[None])

        with pytest.raises(
            medium_unload.UnloadUnconfirmed, match="could not be confirmed"
        ):
            medium_unload.unload_medium(confirm_deadline_seconds=0.0)

    def test_the_unload_command_is_never_retried_while_confirming(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """INCIDENT-20260719: only the read-only probe may repeat."""

        wire = _Wire()
        _install(monkeypatch, wire=wire, confirmations=[None, None, None, False])

        medium_unload.unload_medium()

        assert wire.motion_cdbs.count(medium_unload.UNLOAD_SET_PARAMETER_CDB) == 1
        assert wire.motion_cdbs.count(medium_unload.EXECUTE_CDB) == 1

    def test_confirmation_probes_the_same_device_id(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _usb_util, probed = _install(monkeypatch, wire=wire, confirmations=[False])

        medium_unload.unload_medium(device_id="usb:1:7")

        assert probed == ["usb:1:7", "usb:1:7"]

    def test_rejects_a_nonpositive_poll_interval(self) -> None:
        with pytest.raises(ValueError, match="confirm_poll_seconds"):
            medium_unload.unload_medium(confirm_poll_seconds=0.0)

    def test_rejects_a_negative_deadline(self) -> None:
        with pytest.raises(ValueError, match="confirm_deadline_seconds"):
            medium_unload.unload_medium(confirm_deadline_seconds=-1.0)

    def test_default_deadline_covers_the_slowest_observed_good_clear(self) -> None:
        """A 57 s live roll clear must not be reported as a failure."""

        assert medium_unload.DEFAULT_CONFIRM_DEADLINE_SECONDS >= 114.0


# ===========================================================================
# Empty transport
# ===========================================================================


class TestEmptyTransport:
    def test_absent_medium_short_circuits_without_commanding_motion(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire()
        _install(monkeypatch, wire=wire, preflight=False)

        outcome = medium_unload.unload_medium()

        assert outcome.ejected is True
        assert outcome.already_clear is True
        assert outcome.command_statuses == ()
        assert wire.entries == []

    def test_absent_medium_never_opens_the_interface(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        opened: list[object] = []

        def refuse_connect(**_kwargs):
            opened.append(object())
            raise AssertionError("must not open the interface for an empty transport")

        monkeypatch.setattr(medium_unload, "_connect_device", refuse_connect)
        monkeypatch.setattr(
            medium_unload,
            "probe_adapter_status",
            lambda **_kwargs: AdapterStatus(
                film_present=False, frame_capacity=None, raw_status="023a00"
            ),
        )

        assert medium_unload.unload_medium().already_clear is True
        assert opened == []

    def test_unknown_preflight_verdict_proceeds_with_the_sequence(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """An unreadable preflight is not evidence the transport is empty."""

        wire = _Wire()
        _install(monkeypatch, wire=wire, preflight=None, confirmations=[False])

        outcome = medium_unload.unload_medium()

        assert outcome.already_clear is False
        assert wire.motion_cdbs[0] == "160000000000"


# ===========================================================================
# Fail-closed plumbing
# ===========================================================================


class TestFailClosed:
    def test_a_refused_command_raises_and_never_reports_success(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        refusal = _result(
            phase=0x01,
            status=bytes.fromhex("02052400") + bytes(4),
        )
        wire = _Wire(refuse={medium_unload.RESERVE_UNIT_CDB: refusal})
        _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.MediumUnloadError, match="RESERVE UNIT"):
            medium_unload.unload_medium()

    def test_a_refused_execute_still_releases_the_unit(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        refusal = _result(
            phase=0x01,
            status=bytes.fromhex("02052400") + bytes(4),
        )
        wire = _Wire(refuse={medium_unload.EXECUTE_CDB: refusal})
        _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.MediumUnloadError, match="EXECUTE"):
            medium_unload.unload_medium()

        assert wire.motion_cdbs[-1] == medium_unload.RELEASE_UNIT_CDB

    def test_an_unexpected_phase_is_refused(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire(
            refuse={medium_unload.UNLOAD_SET_PARAMETER_CDB: _result(phase=0x01)}
        )
        _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.MediumUnloadError, match="phase"):
            medium_unload.unload_medium()

    def test_a_malformed_status_envelope_is_refused(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        wire = _Wire(
            refuse={
                medium_unload.RESERVE_UNIT_CDB: _result(
                    phase=0x01, status=bytes(5) + b"\x01\x00\x00"
                )
            }
        )
        _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.MediumUnloadError, match="malformed"):
            medium_unload.unload_medium()

    def test_the_interface_is_always_released_and_disposed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        refusal = _result(
            phase=0x01,
            status=bytes.fromhex("02052400") + bytes(4),
        )
        wire = _Wire(refuse={medium_unload.RESERVE_UNIT_CDB: refusal})
        usb_util, _probed = _install(monkeypatch, wire=wire)

        with pytest.raises(medium_unload.MediumUnloadError):
            medium_unload.unload_medium()

        assert len(usb_util.released) == 1
        assert len(usb_util.disposed) == 1

    def test_a_failure_to_open_the_scanner_is_typed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            medium_unload,
            "probe_adapter_status",
            lambda **_kwargs: AdapterStatus(
                film_present=True, frame_capacity=40, raw_status="000000"
            ),
        )

        def refuse(**_kwargs):
            raise OSError("device busy")

        monkeypatch.setattr(medium_unload, "_connect_device", refuse)

        with pytest.raises(
            medium_unload.MediumUnloadError, match="could not open the scanner"
        ):
            medium_unload.unload_medium()

    def test_every_refusal_type_is_a_runtime_error(self) -> None:
        """Device.eject()'s except-RuntimeError arm must catch them all."""

        for error_type in (
            medium_unload.MediumUnloadError,
            medium_unload.UnloadNotSupported,
            medium_unload.UnloadAcceptedWithoutProgress,
            medium_unload.UnloadUnconfirmed,
        ):
            assert issubclass(error_type, RuntimeError)
