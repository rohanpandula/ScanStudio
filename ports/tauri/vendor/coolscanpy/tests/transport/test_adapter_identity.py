"""Adapter-identity probe: decoding, classification, and preflight (#70).

Payload bytes are live captures from a real LS-5000 ED (fw 1.03) with the
MA-21 inserted (2026-08-10 session) and the canonical SA-30 trace
(`replay-first-rgbi4-plan.jsonl` sequences 6 and 30).
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from coolscanpy._roll import Roll
from coolscanpy.exceptions import AdapterUnsupported
from coolscanpy.transport import adapter_identity as ai

# Live MA-21 page 01h: header + sublength 6 + "Mount\0".
MOUNT_PAGE_01 = bytes.fromhex("0601000706" + b"Mount\x00".hex())
# Canonical SA-30 page 01h (plan seq 30): sublength 8 + "36Strip\0".
STRIP_PAGE_01 = bytes.fromhex("0601000908" + b"36Strip\x00".hex())
# Canonical strip-feeder page 00h (plan seq 6): 19 pages including E2h.
STRIP_PAGE_00 = bytes.fromhex("0600001300014041475051606162c1d1e1e3f0f8e2fbfc")
# Live MA-21 page 00h: 17 pages -- 47h and E2h are absent.
MOUNT_PAGE_00 = bytes.fromhex("060000110001404150516061" + "62c1d1e1e3f0f8fbfc")


def test_decode_adapter_ascii_mount() -> None:
    assert ai._decode_adapter_ascii(MOUNT_PAGE_01) == "Mount"


def test_decode_adapter_ascii_strip() -> None:
    assert ai._decode_adapter_ascii(STRIP_PAGE_01) == "36Strip"


def test_decode_adapter_ascii_rejects_empty() -> None:
    with pytest.raises(ai.AdapterIdentityError):
        ai._decode_adapter_ascii(bytes.fromhex("06010001" + "00"))


def test_decode_page_list_bounds() -> None:
    pages = ai._decode_page_list(STRIP_PAGE_00)
    assert 0xE2 in pages
    assert len(pages) == 0x13
    mount_pages = ai._decode_page_list(MOUNT_PAGE_00)
    assert 0xE2 not in mount_pages
    assert 0x47 not in mount_pages
    assert 0x01 in mount_pages


def test_identity_classification() -> None:
    mount = ai.AdapterIdentity(
        adapter_ascii="Mount", advertised_vpd_pages=ai._decode_page_list(MOUNT_PAGE_00)
    )
    assert not mount.is_strip_feeder
    assert mount.adapter_model == "MA-21 mount adapter"

    strip = ai.AdapterIdentity(
        adapter_ascii="36Strip", advertised_vpd_pages=ai._decode_page_list(STRIP_PAGE_00)
    )
    assert strip.is_strip_feeder
    assert strip.adapter_model == "SA-30 36-frame strip feeder"

    unknown = ai.AdapterIdentity(adapter_ascii="Widget", advertised_vpd_pages=())
    assert not unknown.is_strip_feeder
    assert unknown.adapter_model == "Widget"


def test_spec_table_covers_both_strip_feeders() -> None:
    # Spec Table 2-2-2-2-1: the SA-21 reports "6Strip". A stock SA-21 must
    # never be refused by the preflight allowlist.
    assert ai.STRIP_FEEDER_ADAPTERS == ("6Strip", "36Strip")
    assert ai.ADAPTER_MODEL_NAMES["6Strip"].startswith("SA-21")


def _stub_roll() -> SimpleNamespace:
    return SimpleNamespace(
        _device=SimpleNamespace(_info=SimpleNamespace(id="usb:1:3"))
    )


def test_preflight_refuses_mount_adapter(monkeypatch: pytest.MonkeyPatch) -> None:
    identity = ai.AdapterIdentity(
        adapter_ascii="Mount", advertised_vpd_pages=ai._decode_page_list(MOUNT_PAGE_00)
    )
    monkeypatch.setattr(ai, "probe_adapter_identity", lambda **_kw: identity)
    with pytest.raises(AdapterUnsupported) as excinfo:
        Roll._require_strip_feeder_adapter(_stub_roll())
    assert excinfo.value.adapter == "Mount"
    assert excinfo.value.supported == ("6Strip", "36Strip")
    assert "MA-21" in str(excinfo.value)
    assert "slide" in str(excinfo.value)


def test_preflight_allows_both_strip_feeders(monkeypatch: pytest.MonkeyPatch) -> None:
    for ascii_name in ("6Strip", "36Strip"):
        identity = ai.AdapterIdentity(
            adapter_ascii=ascii_name,
            advertised_vpd_pages=ai._decode_page_list(STRIP_PAGE_00),
        )
        monkeypatch.setattr(ai, "probe_adapter_identity", lambda **_kw: identity)
        Roll._require_strip_feeder_adapter(_stub_roll())


def test_preflight_refuses_unknown_adapter_string(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    identity = ai.AdapterIdentity(adapter_ascii="Feeder", advertised_vpd_pages=())
    monkeypatch.setattr(ai, "probe_adapter_identity", lambda **_kw: identity)
    with pytest.raises(AdapterUnsupported) as excinfo:
        Roll._require_strip_feeder_adapter(_stub_roll())
    assert excinfo.value.adapter == "Feeder"


def test_preflight_fails_open_on_probe_uncertainty(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _refused(**_kw: object) -> ai.AdapterIdentity:
        raise ai.AdapterIdentityError("interface owned by an active capture")

    monkeypatch.setattr(ai, "probe_adapter_identity", _refused)
    Roll._require_strip_feeder_adapter(_stub_roll())

    def _unexpected(**_kw: object) -> ai.AdapterIdentity:
        raise RuntimeError("libusb exploded")

    monkeypatch.setattr(ai, "probe_adapter_identity", _unexpected)
    Roll._require_strip_feeder_adapter(_stub_roll())
