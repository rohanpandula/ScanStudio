"""Tests for SANE capability detection from raw option maps.

This package only reaches coolscan3 devices (get_devices() filters to them;
see _device.py), so film-source and IR detection are exercised against
coolscan3-shaped (or coolscan3-adjacent, e.g. coolscan2) option maps here.
"""

from dataclasses import dataclass
from typing import Any

import numpy as np

from coolscanpy.transport.sane import (
    _caps_from_options,
    _detect_auto_exposure,
    _detect_registered_geometry,
    _split_rgbi,
)


@dataclass
class FakeOption:
    """Stand-in for python-sane's Option (only the fields _caps_from_options reads)."""

    constraint: Any = None
    desc: str = ""
    unit: int | None = None


class TestCapsFromOptions:
    def test_depth_drops_1_bit_lineart(self) -> None:
        # _detect_depths does not consult device_id; a coolscan3 id here is
        # arbitrary, kept only for realism.
        caps = _caps_from_options({"depth": FakeOption(constraint=[1, 8, 16])}, "coolscan3:usb:libusb:001:007")
        assert caps.supported_depths == (8, 16)

    def test_resolution_range_is_intersected_with_canonical_stops(self) -> None:
        # Range (25, 3600) must intersect canonical stops, not be read as three values.
        caps = _caps_from_options(
            {"resolution": FakeOption(constraint=(25.0, 3600.0, 1.0))},
            "coolscan3:usb:libusb:001:007",
        )
        assert caps.supported_dpi == (75, 150, 300, 600, 1200, 2400, 3600)

    def test_film_scanner_inference_is_device_id_only(self) -> None:
        # No option map, arbitrary vendor id: sources come from the coolscan3
        # device-id prefix alone now, so an unrecognized id gets none.
        caps = _caps_from_options({}, "othervendor:libusb:001:001")
        assert caps.sources == ()

    def test_roll_adapter_frame_range_is_reported_as_capacity(self) -> None:
        caps = _caps_from_options(
            {
                "frame": FakeOption(constraint=(1, 40, 1)),
                "infrared": FakeOption(),
            },
            "coolscan3:usb:libusb:001:007",
        )

        assert caps.adapter_frame_capacity == 40

    def test_parked_adapter_keeps_frame_control_without_inventing_capacity(self) -> None:
        caps = _caps_from_options(
            {
                "frame": FakeOption(constraint=(1, 0, 1)),
                "infrared": FakeOption(),
            },
            "coolscan3:usb:libusb:001:007",
        )

        assert caps.adapter_frame_control is True
        assert caps.adapter_frame_capacity is None

    def test_usable_eject_option_is_reported_to_the_ui(self) -> None:
        caps = _caps_from_options(
            {
                "frame": FakeOption(constraint=(1, 40, 1)),
                "eject": FakeOption(),
            },
            "coolscan3:usb:libusb:001:007",
        )

        assert caps.can_eject is True

    def test_missing_eject_option_defaults_false(self) -> None:
        caps = _caps_from_options(
            {"source": FakeOption(constraint=["Negative"])},
            "plustek:libusb:001:008",
        )

        assert caps.can_eject is False

    # ── plain flatbed: no source, no film signals → still skipped ───────

    def test_flatbed_without_source_skipped(self) -> None:
        opt = {
            "mode": FakeOption(constraint=["Color", "Gray", "Lineart"]),
            "depth": FakeOption(constraint=[8, 16]),
            "resolution": FakeOption(constraint=[75, 150, 300, 600]),
            "invert": FakeOption(desc="Invert image"),  # generic, not negative-film
        }
        caps = _caps_from_options(opt, "genesys:libusb:001:002")
        assert caps.sources == ()
        assert caps.ir_channel is False
        assert caps.adapter_frame_capacity is None

    def test_ir_from_dedicated_option(self) -> None:
        opt = {
            "source": FakeOption(constraint=["Transparency"]),
            "ir": FakeOption(),
        }
        caps = _caps_from_options(opt, "plustek:libusb:001:008")
        assert caps.ir_channel is True


class TestAutoExposureAndRegisteredGeometryCapabilities:
    """Coverage for the Scan-tab archival-recipe controls: hardware
    auto-exposure and registered geometry are both presence-only UI gates,
    mirroring _detect_ir/_detect_multi_sample above."""

    def test_auto_exposure_true_with_ae_option(self) -> None:
        assert _detect_auto_exposure({"ae": FakeOption()}) is True

    def test_auto_exposure_false_without_ae_option(self) -> None:
        assert _detect_auto_exposure({"infrared": FakeOption()}) is False

    def test_registered_geometry_true_with_both_options(self) -> None:
        assert _detect_registered_geometry({"subframe": FakeOption(), "br_y": FakeOption()}) is True

    def test_registered_geometry_false_with_only_subframe(self) -> None:
        assert _detect_registered_geometry({"subframe": FakeOption()}) is False

    def test_registered_geometry_false_with_only_br_y(self) -> None:
        assert _detect_registered_geometry({"br_y": FakeOption()}) is False

    def test_registered_geometry_false_with_neither(self) -> None:
        assert _detect_registered_geometry({}) is False

    def test_caps_from_options_wires_both_fields(self) -> None:
        caps = _caps_from_options(
            {
                "frame": FakeOption(constraint=(1, 40, 1)),
                "infrared": FakeOption(),
                "ae": FakeOption(),
                "subframe": FakeOption(),
                "br_y": FakeOption(),
            },
            "coolscan3:usb:libusb:001:007",
        )
        assert caps.auto_exposure is True
        assert caps.registered_geometry is True

    def test_caps_from_options_defaults_both_false(self) -> None:
        caps = _caps_from_options(
            {
                "source": FakeOption(constraint=["Negative", "Positive", "Transparency"]),
                "resolution": FakeOption(constraint=[300, 600, 1200, 2400, 3600]),
                "depth": FakeOption(constraint=[8, 16]),
            },
            "plustek:libusb:001:008",
        )
        assert caps.auto_exposure is False
        assert caps.registered_geometry is False


class TestSplitRgbi:
    def test_splits_four_channels(self) -> None:
        arr = np.arange(2 * 3 * 4, dtype=np.uint16).reshape(2, 3, 4)
        rgb, ir = _split_rgbi(arr)
        assert rgb.shape == (2, 3, 3)
        assert ir.shape == (2, 3)
        assert np.array_equal(rgb, arr[:, :, :3])
        assert np.array_equal(ir, arr[:, :, 3])
