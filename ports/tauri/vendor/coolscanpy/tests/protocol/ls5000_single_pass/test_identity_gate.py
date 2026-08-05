"""Unit tests for the LS-5000 ED scanner identity gate.

Covers the Lane A identity policy (D1, locked): accept a genuine Nikon
``LS-5000 ED`` at ANY firmware revision, keep the exact 36-byte INQUIRY length
check, and hard-fail any other vendor/product.

Cases exercised:
  - revision 1.03 -> pass, canonical label reflects 1.03
  - revision 1.02 (the exact #21/#15 INQUIRY tuple) -> pass, revision recorded
    in the returned label
  - wrong product (LS-50 ED) -> typed SynchronizedProtocolError
  - unknown vendor -> typed SynchronizedProtocolError
  - short payload (non-36-byte) -> typed SynchronizedProtocolError
"""

from __future__ import annotations

import pytest

from coolscanpy.protocol.ls5000_single_pass import worker as worker_module


def _inquiry(vendor: str, product: str, revision: str, *, size: int = 36) -> bytes:
    """Build a standard SCSI INQUIRY response buffer (default 36 bytes).

    Layout matches the worker gate: bytes 8:16 = vendor id, 16:32 = product id,
    32:36 = product revision level. Non-ASCII-safe bytes are omitted; the worker
    decodes with ``errors="replace"`` so garbage never crashes the gate.

    A non-36 ``size`` yields a genuine short/long buffer (built from the full
    36-byte payload then truncated or zero-padded) so the gate's exact-length
    check is exercised on a real underlying buffer length.
    """
    buf = bytearray(36)
    buf[8:16] = vendor.ljust(8, " ").encode("ascii", errors="replace")[:8]
    buf[16:32] = product.ljust(16, " ").encode("ascii", errors="replace")[:16]
    buf[32:36] = revision.ljust(4, " ").encode("ascii", errors="replace")[:4]
    if size == 36:
        return bytes(buf)
    if size < 36:
        return bytes(buf[:size])
    return bytes(buf) + bytes(size - 36)


def test_identity_accepts_revision_103() -> None:
    """Firmware 1.03 is the reference revision and must pass."""
    payload = _inquiry("Nikon", "LS-5000 ED", "1.03")
    assert worker_module._validate_scanner_identity(payload) == "Nikon LS-5000 ED 1.03"


def test_identity_accepts_revision_102_and_records_it() -> None:
    """The exact #21/#15 tuple (Nikon / LS-5000 ED / 1.02) must pass.

    The revision is "recorded" by being carried in the returned canonical label,
    which run_live_capture writes into the frame/session journal and the
    diagnostic log line.
    """
    payload = _inquiry("Nikon", "LS-5000 ED", "1.02")
    label = worker_module._validate_scanner_identity(payload)
    assert label == "Nikon LS-5000 ED 1.02"
    assert label.endswith(" 1.02")  # the accepted revision is surfaced


def test_identity_accepts_other_valid_revisions() -> None:
    """Any genuine LS-5000 ED revision passes (D1: relax revision, not vendor/product)."""
    for rev in ("1.00", "1.01", "1.99"):
        payload = _inquiry("Nikon", "LS-5000 ED", rev)
        assert worker_module._validate_scanner_identity(payload) == f"Nikon LS-5000 ED {rev}"


def test_identity_rejects_wrong_product_ls50_ed() -> None:
    """LS-50 ED (a different scanner) must fail with the typed error."""
    payload = _inquiry("Nikon", "LS-50 ED", "1.03")
    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="unexpected scanner identity",
    ):
        worker_module._validate_scanner_identity(payload)


def test_identity_rejects_unknown_vendor() -> None:
    """A non-Nikon vendor must fail closed with the typed error."""
    payload = _inquiry("ACME", "LS-5000 ED", "1.03")
    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="unexpected scanner identity",
    ):
        worker_module._validate_scanner_identity(payload)


def test_identity_rejects_short_payload() -> None:
    """A non-36-byte INQUIRY is rejected by the exact length check."""
    payload = _inquiry("Nikon", "LS-5000 ED", "1.03", size=20)
    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="expected 36",
    ):
        worker_module._validate_scanner_identity(payload)


def test_identity_rejects_long_payload() -> None:
    """A >36-byte INQUIRY is also rejected by the exact length check."""
    payload = _inquiry("Nikon", "LS-5000 ED", "1.03", size=48)
    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="expected 36",
    ):
        worker_module._validate_scanner_identity(payload)
