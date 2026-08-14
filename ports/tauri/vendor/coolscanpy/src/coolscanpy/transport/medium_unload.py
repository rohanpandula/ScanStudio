"""Standalone raw-USB medium unload (film eject) for the LS-5000.

This is the eject path for callers that hold no capture worker: it replays
the same wire truths the held-session eject replays
(``protocol.ls5000_single_pass.worker._perform_vendor_eject``, proven live
2026-07-20) without needing a reserved capture session, a bundled plan, or
SANE.

Why it exists at all: the previous ``Device.eject()`` drove SANE's
``coolscan3`` backend, which needs a host ``scanimage`` binary an
application bundle cannot ship, and which was observed
accepted-but-inert against a mounted slide on real hardware. This module
replaces that path end to end.

Command sequence (trace is authority, specification is corroboration --
see the cross-check in each constant's comment below)::

    RESERVE_UNIT   16 00 00 00 00 00
    SET PARAMETER  e0 00 d0 00 00 00 00 00 09 00  + 9-byte parameter block
    EXECUTE        c1 00 00 00 00 00
    RELEASE_UNIT   17 00 00 00 00 00

The two motion commands are the specification's own "Unload object"
operation: SET PARAMETER (E0h) carries operation code D0h in CDB byte 2
(Table 2-15-1, ``LS5kIFSpec.md:9675-9736``; Table 2-15-3 assigns D0h =
"Unload object", ``:9868-9979``), and EXECUTE (C1h) starts it
(``:9741-9753``). The specification also states plainly that "The medium
is ejected by the eject command" (``:1198-1200``).

Confirmation is never assumed. The unload command returning GOOD status
means *accepted*, not *completed* -- so this module confirms mechanically
by re-reading the motion-free presence probe
(:func:`~coolscanpy.transport.adapter_status.probe_adapter_status`) until
the scanner reports the medium gone. A definitive "still present" at the
deadline is reported as accepted-without-progress; an indeterminate
reading at the deadline is reported as unconfirmed. Neither is ever
reported as success.

The unload command itself is never retried. Only the read-only presence
probe is repeated. Re-issuing an accepted-but-unactuated eject is the
documented way to deepen the transport wedge this package refuses to
create (INCIDENT-20260719).

Adapter gating: the specification's per-adapter capability table (VPD
page E1h byte 30 bit 0, "Unload object" under "Execute operation support
D0", ``:4863-4930``) marks the MA-21 mount adapter ``[0]`` -- it does not
support this operation -- while SA-21, SA-30, IA-20 and SF-210 are all
``[1]``. Live VPD dumps agree bit-for-bit: an MA-21 reports byte 30 =
``0x00`` and an SA-30 reports ``0x45`` (bit 0 Unload object, bit 2
Absolute positioning, bit 6 SA Lock -- exactly the specification's SA-30
column). That is the mechanism behind the accepted-but-inert mount-adapter
eject seen live, so this module reads the bit and refuses *before*
commanding motion when it definitively says unsupported. An unreadable or
absent capability page is never treated as a refusal -- absent
information must not block an eject that would otherwise work, so the
sequence proceeds and the confirmation gate remains the arbiter.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from coolscanpy._logging import get_logger
from coolscanpy.transport.adapter_status import (
    _connect_device,
    _perform_transaction,
    probe_adapter_status,
)

logger = get_logger(__name__)

# -- traced wire constants ------------------------------------------------
#
# Every byte below is copied from the held-session eject
# (``protocol.ls5000_single_pass.worker``), which took them byte-exact from
# the vendor's own Nikon Scan 4 USB capture. They are duplicated here rather
# than imported because that module is a hash-pinned capture component; this
# transport lane must not be able to change the capture bundle's identity.
# ``tests/transport/test_medium_unload.py`` asserts the two copies stay
# identical, so a divergence fails the suite instead of the hardware.

#: Traced RESERVE_UNIT (canonical plan command 17). The vendor capture sends
#: the eject inside this single reservation.
RESERVE_UNIT_CDB = "160000000000"

#: Traced end-of-session eject, vendor capture command 9843.
#: ``e0 00 d0 00 00 00 00 00 09 00`` decodes exactly onto the
#: specification's SET PARAMETER CDB (Table 2-15-1): byte 0 opcode E0h,
#: byte 1 LUN, byte 2 operation code **D0h = Unload object**, bytes 3-7
#: reserved, byte 8 parameter length, byte 9 control.
UNLOAD_SET_PARAMETER_CDB = "e000d000000000000900"

#: The 9-byte parameter block from the same traced command, replayed
#: verbatim. Two deliberate divergences from the specification are recorded
#: here rather than "corrected":
#:
#: * Parameter length is 9, not the specification's recommended 13d
#:   (Table 2-15-1). The trace is authority; 9 is what the vendor sent and
#:   what the scanner accepted.
#: * Table 2-15-4 (``LS5kIFSpec.md:10039-10205``) marks D0h "No parameter",
#:   yet the traced block's "Second setting value" field (bytes 5-8) is
#:   non-zero (``031ad070``) -- a stale vendor buffer for a field the
#:   operation ignores.
#:
#: There is exactly one eject in the 9,977-command capture, so no second
#: sample exists to prove which bytes vary. Replayed, never computed.
UNLOAD_PARAMETER_DATA_OUT = "0000000000031ad070"

#: Traced EXECUTE, vendor capture command 9844 (+1.76 ms after the CDB
#: above). The specification requires EXECUTE to start the operation the
#: preceding SET PARAMETER selected.
EXECUTE_CDB = "c10000000000"

#: Traced RELEASE_UNIT. The vendor capture contains no RELEASE_UNIT
#: anywhere, including after its own eject; releasing the reservation is
#: this package's own session-hygiene convention, matching the held-session
#: teardown, and is issued only after the eject has been accepted.
RELEASE_UNIT_CDB = "170000000000"

_SET_PARAMETER_PHASE = 0x02
_NO_DATA_PHASE = 0x01
_GOOD_SENSE = "000000"
_DEFAULT_TIMEOUT_MS = 30_000

# -- capability gate ------------------------------------------------------

#: VPD page carrying "Execute operation support" (2-2-2-5 "Other
#: information page", ``LS5kIFSpec.md:3602-3643``).
_CAPABILITY_PAGE = 0xE1
#: Byte 30 of that page is the D0h operation group; bit 0 is "Unload
#: object" (``:4863-4930``).
_UNLOAD_SUPPORT_BYTE = 30
_UNLOAD_SUPPORT_BIT = 0x01

# -- confirmation window --------------------------------------------------
#
# Observed good clears span roughly 14.2 s (the vendor pcap) to 57 s (a live
# 36-exposure roll), with a live post-traversal roll confirmed clear about
# 20 s after its host-side call had already given up. A short window would
# therefore turn a physically successful roll eject into a false negative,
# so the default mirrors the capture worker's own completion budget --
# comfortably over twice the slowest observed good clear.
DEFAULT_CONFIRM_DEADLINE_SECONDS = 120.0
DEFAULT_CONFIRM_POLL_SECONDS = 1.0


class MediumUnloadError(RuntimeError):
    """Base class for a raw-USB unload that did not verifiably succeed."""


class UnloadNotSupported(MediumUnloadError):
    """The inserted adapter advertises no "Unload object" support.

    Read from VPD page E1h byte 30 bit 0 before any motion command is sent,
    so the transport is left exactly as it was found. The MA-21 mount
    adapter is the known case: the medium stays gripped and only the
    adapter's manual eject button or a power cycle (which ejects on power-on)
    frees it.
    """


class UnloadAcceptedWithoutProgress(MediumUnloadError):
    """The scanner accepted the unload but the medium is still present.

    The commands completed with GOOD status and the presence probe still
    definitively reports film gripped at the confirmation deadline. The
    unload is deliberately not retried.
    """


class UnloadUnconfirmed(MediumUnloadError):
    """The unload could not be confirmed either way.

    The commands were accepted but no trustworthy presence verdict was
    available before the deadline. Whether the medium left the transport is
    unknown, so this is never reported as success.
    """


@dataclass(frozen=True)
class UnloadOutcome:
    """Evidence from one confirmed unload.

    Only ever constructed for a *confirmed* outcome: either the medium was
    already absent before anything was commanded (``already_clear``), or the
    presence probe definitively reported it gone afterwards. Every
    unconfirmed or refused case raises instead.
    """

    ejected: bool
    already_clear: bool
    #: ``name -> 8-byte status hex`` for each command actually sent, in
    #: order. Empty when the probe short-circuited an empty transport.
    command_statuses: tuple[tuple[str, str], ...] = ()
    #: Presence senses observed while confirming, oldest first.
    confirm_senses: tuple[str, ...] = ()
    confirm_seconds: float = 0.0
    device_id: str | None = None
    #: ``True``/``False`` when the capability page was read and decoded,
    #: ``None`` when it was unreadable and the sequence proceeded anyway.
    unload_supported: bool | None = None
    adapter_capability_byte: int | None = None


def _validated_no_data_result(
    result: object,
    *,
    label: str,
    expected_phase: int,
) -> bytes:
    """Return the 8-byte status only from a complete, GOOD Nikon reply.

    Mirrors ``cli.wedge_recovery._validate_no_data_result`` -- full Nikon
    status envelope, sense matching the envelope, expected protocol phase,
    GOOD sense -- so this lane accepts exactly what the other owner-gated
    SET PARAMETER/EXECUTE lane accepts.
    """

    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise MediumUnloadError(f"{label} result has no integer protocol phase")
    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes) or payload:
        raise MediumUnloadError(f"{label} result must have an empty bytes payload")
    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise MediumUnloadError(f"{label} result must have an 8-byte status")
    sense = getattr(result, "sense", None)
    if not isinstance(sense, str) or sense != status[1:4].hex():
        raise MediumUnloadError(f"{label} result sense does not match its 8-byte status")
    if status[5:] != bytes(3):
        raise MediumUnloadError(f"{label} result has a malformed Nikon status envelope")
    if phase != expected_phase:
        raise MediumUnloadError(
            f"{label} returned phase 0x{phase:02x}, expected 0x{expected_phase:02x}"
        )
    if status[0] != 0x00 or sense != _GOOD_SENSE:
        raise MediumUnloadError(f"{label} refused with sense {sense}")
    return status


def _send(
    ep_out: object,
    ep_in: object,
    *,
    seq: str,
    name: str,
    cdb: str,
    label: str,
    expected_phase: int,
    data_out: str | None = None,
    data_timeout_ms: int,
) -> bytes:
    entry: dict[str, object] = {"seq": seq, "name": name, "cdb": cdb}
    if data_out is not None:
        entry["data_out"] = data_out
    try:
        result = _perform_transaction(
            ep_out,
            ep_in,
            entry,
            data_timeout_ms=data_timeout_ms,
        )
    except MediumUnloadError:
        raise
    except Exception as error:
        raise MediumUnloadError(f"{label} transaction failed: {error}") from error
    return _validated_no_data_result(
        result,
        label=label,
        expected_phase=expected_phase,
    )


def _read_unload_capability(
    ep_out: object,
    ep_in: object,
) -> tuple[bool | None, int | None]:
    """Read VPD page E1h byte 30 bit 0 ("Unload object" supported).

    Returns ``(supported, capability_byte)``. ``(None, None)`` means the page
    could not be read or decoded -- deliberately *not* a refusal, so a
    scanner or adapter whose capability page this package cannot parse still
    gets its eject attempted.
    """

    try:
        from coolscanpy.transport.adapter_identity import _fetch_vpd_page

        payload = _fetch_vpd_page(ep_out, ep_in, _CAPABILITY_PAGE)
    except Exception as error:
        logger.debug(f"unload capability page E1h unreadable: {error}")
        return None, None
    if len(payload) <= _UNLOAD_SUPPORT_BYTE:
        logger.debug(
            "unload capability page E1h is %d bytes, too short for byte %d",
            len(payload),
            _UNLOAD_SUPPORT_BYTE,
        )
        return None, None
    capability_byte = payload[_UNLOAD_SUPPORT_BYTE]
    return bool(capability_byte & _UNLOAD_SUPPORT_BIT), capability_byte


def _confirm_medium_gone(
    *,
    device_id: str | None,
    deadline_seconds: float,
    poll_seconds: float,
    probe: object,
) -> tuple[bool, bool, tuple[str, ...], float]:
    """Poll the motion-free presence probe until the medium is gone.

    Returns ``(confirmed_absent, last_reading_was_present, senses, seconds)``.
    Only the read-only probe repeats here; the unload command is never
    re-sent.
    """

    started = time.monotonic()
    deadline = started + deadline_seconds
    senses: list[str] = []
    last_present = False
    while True:
        status = probe(device_id=device_id)
        present = getattr(status, "film_present", None)
        raw = getattr(status, "raw_status", None)
        if isinstance(raw, str):
            senses.append(raw)
        if present is False:
            return True, False, tuple(senses), time.monotonic() - started
        last_present = present is True
        now = time.monotonic()
        if now >= deadline:
            return False, last_present, tuple(senses), now - started
        time.sleep(min(poll_seconds, max(0.0, deadline - now)))


def unload_medium(
    *,
    device_id: str | None = None,
    confirm_deadline_seconds: float = DEFAULT_CONFIRM_DEADLINE_SECONDS,
    confirm_poll_seconds: float = DEFAULT_CONFIRM_POLL_SECONDS,
    data_timeout_ms: int = _DEFAULT_TIMEOUT_MS,
) -> UnloadOutcome:
    """Eject the loaded medium over raw USB and confirm it actually left.

    Needs no SANE, no ``scanimage``, and no held capture session. Returns an
    :class:`UnloadOutcome` only when the result is confirmed; every other
    path raises a typed :class:`MediumUnloadError` subclass.

    Order of operations, all fail-closed:

    1. Probe presence first. A definitively empty transport short-circuits
       to a no-op success -- nothing is commanded and nothing moves. (The
       specification's own no-medium status, 02h-3Ah-00h, is exactly what
       the probe classifies as absent; see ``LS5kIFSpec.md:1198-1200``.)
    2. Open the interface and read the adapter's "Unload object" capability
       bit. A definitive "unsupported" raises :class:`UnloadNotSupported`
       before any motion command is sent.
    3. Send RESERVE_UNIT, the traced SET PARAMETER/EXECUTE pair, then
       RELEASE_UNIT, validating each reply.
    4. Confirm mechanically with the motion-free presence probe until the
       medium is definitively gone or the deadline expires.

    :raises UnloadNotSupported: the adapter advertises no unload support.
    :raises UnloadAcceptedWithoutProgress: accepted, but film still present
        at the deadline.
    :raises UnloadUnconfirmed: accepted, but no trustworthy verdict before
        the deadline.
    :raises MediumUnloadError: the scanner could not be opened, or a command
        was refused or malformed.
    """

    if confirm_deadline_seconds < 0:
        raise ValueError("confirm_deadline_seconds must be nonnegative")
    if confirm_poll_seconds <= 0:
        raise ValueError("confirm_poll_seconds must be positive")

    # 1. Empty transport short-circuit: never command motion to eject
    #    nothing. Only a *definitive* absent reading short-circuits; an
    #    unknown verdict falls through to the real sequence.
    preflight = probe_adapter_status(device_id=device_id)
    if preflight.film_present is False:
        logger.info("unload: transport already reports no medium; nothing to eject")
        return UnloadOutcome(
            ejected=True,
            already_clear=True,
            confirm_senses=(
                (preflight.raw_status,) if isinstance(preflight.raw_status, str) else ()
            ),
            device_id=device_id,
        )

    try:
        if device_id is None:
            device, interface, ep_out, ep_in, usb_util = _connect_device()
        else:
            device, interface, ep_out, ep_in, usb_util = _connect_device(
                device_id=device_id
            )
    except Exception as error:
        raise MediumUnloadError(f"could not open the scanner: {error}") from error

    statuses: list[tuple[str, str]] = []
    try:
        # 2. Capability gate, inside the same claimed session as the eject
        #    so the bit and the motion describe the same adapter state.
        supported, capability_byte = _read_unload_capability(ep_out, ep_in)
        if supported is False:
            raise UnloadNotSupported(
                "the inserted adapter does not support the Unload object "
                f"operation (VPD page E1h byte 30 = 0x{capability_byte:02x}, "
                "bit 0 clear) -- no eject command was sent and the transport "
                "was not moved; the medium is still gripped. Free it with the "
                "adapter's manual eject button, or power-cycle the scanner "
                "(it ejects on power-on)."
            )

        # 3. The traced sequence, in the traced order. No command here is
        #    ever retried.
        statuses.append(
            (
                "RESERVE_UNIT",
                _send(
                    ep_out,
                    ep_in,
                    seq="unload-reserve",
                    name="RESERVE_UNIT",
                    cdb=RESERVE_UNIT_CDB,
                    label="RESERVE UNIT",
                    expected_phase=_NO_DATA_PHASE,
                    data_timeout_ms=data_timeout_ms,
                ).hex(),
            )
        )
        try:
            statuses.append(
                (
                    "SET_PARAMETER:D0",
                    _send(
                        ep_out,
                        ep_in,
                        seq="unload-set-parameter",
                        name="SET_PARAMETER:D0",
                        cdb=UNLOAD_SET_PARAMETER_CDB,
                        label="SET PARAMETER Unload object",
                        expected_phase=_SET_PARAMETER_PHASE,
                        data_out=UNLOAD_PARAMETER_DATA_OUT,
                        data_timeout_ms=data_timeout_ms,
                    ).hex(),
                )
            )
            statuses.append(
                (
                    "EXECUTE",
                    _send(
                        ep_out,
                        ep_in,
                        seq="unload-execute",
                        name="EXECUTE",
                        cdb=EXECUTE_CDB,
                        label="EXECUTE Unload object",
                        expected_phase=_NO_DATA_PHASE,
                        data_timeout_ms=data_timeout_ms,
                    ).hex(),
                )
            )
        finally:
            # Release the reservation whether or not the pair succeeded --
            # a refused eject must not leave the unit reserved. The release
            # is attempted exactly once and never masks the original error.
            try:
                statuses.append(
                    (
                        "RELEASE_UNIT",
                        _send(
                            ep_out,
                            ep_in,
                            seq="unload-release",
                            name="RELEASE_UNIT",
                            cdb=RELEASE_UNIT_CDB,
                            label="RELEASE UNIT",
                            expected_phase=_NO_DATA_PHASE,
                            data_timeout_ms=data_timeout_ms,
                        ).hex(),
                    )
                )
            except MediumUnloadError as error:
                logger.debug(f"unload could not release the unit: {error}")
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception as error:  # pragma: no cover - release is best-effort
            logger.debug(f"unload could not release interface: {error}")
        try:
            usb_util.dispose_resources(device)
        except Exception as error:  # pragma: no cover - dispose is best-effort
            logger.debug(f"unload could not dispose resources: {error}")

    # 4. Accepted is not ejected. Confirm mechanically, or refuse.
    confirmed, still_present, senses, seconds = _confirm_medium_gone(
        device_id=device_id,
        deadline_seconds=confirm_deadline_seconds,
        poll_seconds=confirm_poll_seconds,
        probe=probe_adapter_status,
    )
    frozen_statuses = tuple(statuses)
    if confirmed:
        logger.info("unload confirmed: medium absent after %.1fs", seconds)
        return UnloadOutcome(
            ejected=True,
            already_clear=False,
            command_statuses=frozen_statuses,
            confirm_senses=senses,
            confirm_seconds=seconds,
            device_id=device_id,
            unload_supported=supported,
            adapter_capability_byte=capability_byte,
        )
    if still_present:
        raise UnloadAcceptedWithoutProgress(
            "the scanner accepted the unload command but still reports the "
            f"medium present after {seconds:.0f}s -- accepted without "
            "progress. The eject was deliberately not retried; free the "
            "medium with the adapter's manual eject button, or power-cycle "
            "the scanner (it ejects on power-on)."
        )
    raise UnloadUnconfirmed(
        "the scanner accepted the unload command but its state could not be "
        f"confirmed within {seconds:.0f}s (presence readings: "
        f"{', '.join(senses) if senses else 'none'}) -- whether the medium "
        "left the transport is unknown. Check the transport before feeding "
        "anything else."
    )


__all__ = [
    "DEFAULT_CONFIRM_DEADLINE_SECONDS",
    "DEFAULT_CONFIRM_POLL_SECONDS",
    "EXECUTE_CDB",
    "MediumUnloadError",
    "RELEASE_UNIT_CDB",
    "RESERVE_UNIT_CDB",
    "UNLOAD_PARAMETER_DATA_OUT",
    "UNLOAD_SET_PARAMETER_CDB",
    "UnloadAcceptedWithoutProgress",
    "UnloadNotSupported",
    "UnloadOutcome",
    "UnloadUnconfirmed",
    "unload_medium",
]
