"""Motion-free LS-5000 adapter-identity probe over raw USB.

The LS-5000 reports which film adapter is inserted through INQUIRY EVPD
page ``01h``: a NUL-terminated ASCII name enumerated by the interface
specification's Table 2-2-2-2-1 (``Mount`` = MA-21 mount adapter,
``6Strip`` = SA-21 six-frame strip feeder, ``36Strip`` = SA-30
thirty-six-frame strip feeder, ``240`` = IA-20, ``Feeder`` = SF-210
slide feeder). The advertised EVPD page list (page ``00h``) is likewise
adapter-dependent: live probing shows the MA-21 drops pages ``47h`` and
``E2h`` that the strip feeders advertise, which is why a strip-captured
command trace cannot be replayed verbatim against a mount adapter
(ScanStudio issue #70).

This probe sends only standard INQUIRY and INQUIRY with EVPD set — the
same deliberately motion-free dialect as ``coolscanpy.cli.vpd_dump``,
whose two-step header-then-body handshake and validation rules are
reproduced here (kept self-contained so the transport layer does not
import from the CLI layer). It never sends SCAN, SET WINDOW, READ, or an
eject or positioning command.
"""

from __future__ import annotations

from dataclasses import dataclass

from coolscanpy._logging import get_logger
from coolscanpy.transport.adapter_status import (
    _connect_device,
    _perform_transaction,
)

logger = get_logger(__name__)

_STANDARD_INQUIRY_CDB = "120000002480"
_STANDARD_INQUIRY_LENGTH = 0x24
_EVPD_HEADER_LENGTH = 0x04
_INQUIRY_DATA_PHASE = 0x03
_GOOD_SENSE = "000000"
_DEFAULT_TIMEOUT_MS = 5_000
_PAGE_LIST_PAGE = 0x00
_ADAPTER_PAGE = 0x01
_MAX_INQUIRY_ALLOCATION = 0xFF

#: Spec Table 2-2-2-2-1 "ASCII information" values for the two strip
#: feeders. Only these adapters match the captured preview/scan traces
#: (the trace was recorded behind an SA-30, and the specification gates
#: perforation reads to SA-21/SA-30), so only they are eligible for the
#: strip-plan workflows.
STRIP_FEEDER_ADAPTERS: tuple[str, ...] = ("6Strip", "36Strip")

#: Spec Table 2-2-2-2-1 adapter name for each known ASCII value, for
#: operator-facing messages.
ADAPTER_MODEL_NAMES: dict[str, str] = {
    "Mount": "MA-21 mount adapter",
    "6Strip": "SA-21 6-frame strip feeder",
    "36Strip": "SA-30 36-frame strip feeder",
    "240": "IA-20 240-film adapter",
    "Feeder": "SF-210 slide feeder",
}


class AdapterIdentityError(RuntimeError):
    """The scanner refused or returned an invalid INQUIRY transaction."""


@dataclass(frozen=True)
class AdapterIdentity:
    """One motion-free reading of the inserted adapter's identity.

    ``adapter_ascii`` is the raw NUL-stripped page-01h string (for
    example ``"Mount"`` or ``"36Strip"``); ``advertised_vpd_pages`` is
    the page-00h list. Both come from the same claimed USB session, so
    they describe the same adapter state.
    """

    adapter_ascii: str
    advertised_vpd_pages: tuple[int, ...]
    device_id: str | None = None

    @property
    def adapter_model(self) -> str:
        """Spec model name for the adapter, or the raw string if unknown."""

        return ADAPTER_MODEL_NAMES.get(self.adapter_ascii, self.adapter_ascii)

    @property
    def is_strip_feeder(self) -> bool:
        return self.adapter_ascii in STRIP_FEEDER_ADAPTERS


def _validated_inquiry_payload(result: object, *, label: str) -> bytes:
    """Return data only from a complete, successful Nikon INQUIRY reply.

    Mirrors ``cli.vpd_dump._validated_inquiry_payload``: full Nikon
    status envelope, matching sense, data-in phase, GOOD sense.
    """

    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise AdapterIdentityError(f"{label} result has no integer protocol phase")

    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes):
        raise AdapterIdentityError(f"{label} result has no bytes payload")

    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise AdapterIdentityError(f"{label} result must have an 8-byte status")

    sense = getattr(result, "sense", None)
    status_sense = status[1:4].hex()
    if not isinstance(sense, str) or sense != status_sense:
        raise AdapterIdentityError(
            f"{label} result sense does not match its 8-byte status"
        )
    if status[5:] != bytes(3):
        raise AdapterIdentityError(
            f"{label} result has a malformed Nikon status envelope"
        )
    if phase != _INQUIRY_DATA_PHASE or sense != _GOOD_SENSE or status[0] != 0x00:
        raise AdapterIdentityError(f"{label} refused with sense {sense}")
    return payload


def _inquiry_cdb(*, page_code: int, allocation: int) -> str:
    if not 0 <= page_code <= 0xFF:
        raise ValueError("VPD page code must fit in one byte")
    if not 1 <= allocation <= _MAX_INQUIRY_ALLOCATION:
        raise AdapterIdentityError(
            f"INQUIRY allocation {allocation} does not fit the captured CDB"
        )
    return bytes((0x12, 0x01, page_code, 0x00, allocation, 0x80)).hex()


def _perform_inquiry(
    ep_out: object,
    ep_in: object,
    *,
    cdb: str,
    allocation: int,
    label: str,
) -> bytes:
    try:
        result = _perform_transaction(
            ep_out,
            ep_in,
            {
                "seq": label,
                "name": "INQUIRY",
                "cdb": cdb,
                "request_len": allocation,
                "request_parts": [allocation],
            },
            data_timeout_ms=_DEFAULT_TIMEOUT_MS,
        )
    except Exception as error:
        raise AdapterIdentityError(f"{label} transaction failed: {error}") from error
    return _validated_inquiry_payload(result, label=label)


def _fetch_vpd_page(ep_out: object, ep_in: object, page_code: int) -> bytes:
    """Fetch one VPD page with the captured four-byte-header handshake.

    Responses are bounded by the length learned from the header read, so
    the transport's allocation-padded stale tails are never attributed
    to the page (the same rule as ``cli.vpd_dump``).
    """

    label = f"page {page_code:02X}h"
    header = _perform_inquiry(
        ep_out,
        ep_in,
        cdb=_inquiry_cdb(page_code=page_code, allocation=_EVPD_HEADER_LENGTH),
        allocation=_EVPD_HEADER_LENGTH,
        label=f"{label} header",
    )
    if len(header) < _EVPD_HEADER_LENGTH:
        raise AdapterIdentityError(
            f"{label} header returned {len(header)} bytes, fewer than four"
        )
    if header[0] != 0x06 or header[1] != page_code or header[2] != 0x00:
        raise AdapterIdentityError(
            f"{label} header is unexpected: {header[:4].hex()}"
        )
    page_total = _EVPD_HEADER_LENGTH + header[3]
    body = _perform_inquiry(
        ep_out,
        ep_in,
        cdb=_inquiry_cdb(page_code=page_code, allocation=page_total),
        allocation=page_total,
        label=f"{label} body",
    )
    if len(body) < page_total:
        raise AdapterIdentityError(
            f"{label} body returned {len(body)} bytes, expected {page_total}"
        )
    return body[:page_total]


def _decode_page_list(payload: bytes) -> tuple[int, ...]:
    """Decode the page-00h supported-page list from its bounded payload."""

    return tuple(payload[_EVPD_HEADER_LENGTH:])


def _decode_adapter_ascii(payload: bytes) -> str:
    """Decode the page-01h adapter string.

    Layout observed live and in the captured trace: four-byte VPD header,
    one sub-length byte counting the ASCII bytes including their NUL
    terminator, then the string (``06 01 00 07 06 "Mount" 00`` for the
    MA-21; ``06 01 00 09 08 "36Strip" 00`` for the SA-30).
    """

    body = payload[_EVPD_HEADER_LENGTH:]
    if not body:
        raise AdapterIdentityError("page 01h carries no adapter string")
    ascii_length = body[0]
    raw = bytes(body[1 : 1 + ascii_length])
    text = raw.split(b"\x00", 1)[0]
    if not text:
        raise AdapterIdentityError(
            f"page 01h adapter string is empty: {payload.hex()}"
        )
    try:
        decoded = text.decode("ascii")
    except UnicodeDecodeError as error:
        raise AdapterIdentityError(
            f"page 01h adapter string is not ASCII: {payload.hex()}"
        ) from error
    return decoded


def probe_adapter_identity(*, device_id: str | None = None) -> AdapterIdentity:
    """Read the inserted adapter's identity. Motion-free; INQUIRY only.

    Raises :class:`AdapterIdentityError` when any reply is refused or
    malformed — callers that treat identity as optional telemetry should
    catch it and carry ``None`` (never guess an adapter).
    """

    device, interface, ep_out, ep_in, usb_util = _connect_device(device_id=device_id)
    try:
        standard = _perform_inquiry(
            ep_out,
            ep_in,
            cdb=_STANDARD_INQUIRY_CDB,
            allocation=_STANDARD_INQUIRY_LENGTH,
            label="standard INQUIRY",
        )
        if len(standard) != _STANDARD_INQUIRY_LENGTH:
            raise AdapterIdentityError(
                f"standard INQUIRY returned {len(standard)} bytes, "
                f"expected {_STANDARD_INQUIRY_LENGTH}"
            )
        page_list = _decode_page_list(
            _fetch_vpd_page(ep_out, ep_in, _PAGE_LIST_PAGE)
        )
        if _ADAPTER_PAGE not in page_list:
            raise AdapterIdentityError(
                "page 00h does not advertise the page 01h adapter string"
            )
        adapter_ascii = _decode_adapter_ascii(
            _fetch_vpd_page(ep_out, ep_in, _ADAPTER_PAGE)
        )
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception:  # pragma: no cover - release is best-effort
            logger.debug("adapter-identity release_interface failed", exc_info=True)
        try:
            usb_util.dispose_resources(device)
        except Exception:  # pragma: no cover - dispose is best-effort
            logger.debug("adapter-identity dispose_resources failed", exc_info=True)

    identity = AdapterIdentity(
        adapter_ascii=adapter_ascii,
        advertised_vpd_pages=page_list,
        device_id=device_id,
    )
    logger.info(
        "adapter identity: %s (%s), %d VPD pages advertised",
        identity.adapter_ascii,
        identity.adapter_model,
        len(identity.advertised_vpd_pages),
    )
    return identity
