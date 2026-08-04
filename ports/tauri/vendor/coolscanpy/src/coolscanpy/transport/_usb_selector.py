"""Translate local Coolscan device identifiers into an exact USB location."""

from __future__ import annotations

import re


_LOCAL_USB_DEVICE_ID_PATTERNS = (
    re.compile(r"usb:(?P<bus>\d+):(?P<address>\d+)"),
    re.compile(r"coolscan3:usb:(?:libusb:)?(?P<bus>\d+):(?P<address>\d+)"),
)


def parse_local_usb_device_id(device_id: str) -> tuple[int, int]:
    """Return ``(bus, address)`` for a local synthetic or SANE device ID.

    Remote SANE identifiers deliberately fail closed: a live status probe
    must never fall back from an opened device to an arbitrary matching USB
    scanner.
    """

    if not isinstance(device_id, str):
        raise TypeError("device_id must be a local USB device identifier string")
    for pattern in _LOCAL_USB_DEVICE_ID_PATTERNS:
        match = pattern.fullmatch(device_id)
        if match is None:
            continue
        bus = int(match.group("bus"))
        address = int(match.group("address"))
        if not 0 <= bus <= 999 or not 1 <= address <= 127:
            break
        return bus, address
    raise ValueError(
        "device_id must be 'usb:<bus>:<address>' or "
        "'coolscan3:usb:[libusb:]<bus>:<address>'; remote/non-USB IDs "
        "cannot select a local raw-USB scanner"
    )


__all__ = ["parse_local_usb_device_id"]
