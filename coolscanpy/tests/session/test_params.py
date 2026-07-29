"""Tests for ScanParams dataclass and ScanMode validation."""

import math

import pytest
from coolscanpy.session.params import RegisteredScanGeometry, ScanMode, ScanParams
from coolscanpy.session.backend import ScannerCapabilities


class TestScanMode:
    def test_enum_values(self) -> None:
        assert ScanMode.NEGATIVE.value == "Negative"
        assert ScanMode.POSITIVE.value == "Positive"
        assert ScanMode.TRANSPARENCY.value == "Transparency"

    def test_from_value(self) -> None:
        assert ScanMode("Negative") == ScanMode.NEGATIVE
        assert ScanMode("Positive") == ScanMode.POSITIVE


class TestScanParams:
    def test_default_construction(self) -> None:
        params = ScanParams(dpi=3600, depth=16, capture_ir=False)
        assert params.dpi == 3600
        assert params.depth == 16
        assert params.capture_ir is False
        assert params.area is None
        assert params.auto_exposure is False
        assert params.frame is None
        assert params.registered_geometry is None

    def test_with_area(self) -> None:
        params = ScanParams(dpi=2400, depth=8, capture_ir=True, area=(0, 0, 36, 24))
        assert params.area == (0, 0, 36, 24)

    def test_registered_geometry_keeps_position_and_window_typed_together(self) -> None:
        geometry = RegisteredScanGeometry(frame=3, subframe_mm=6.35, br_y_device_px=5003)
        current_position = RegisteredScanGeometry(subframe_mm=6.35, br_y_device_px=5003)
        params = ScanParams(dpi=4000, depth=16, capture_ir=True, registered_geometry=geometry)

        assert params.registered_geometry == geometry
        assert geometry.frame == 3
        assert geometry.subframe_mm == 6.35
        assert geometry.br_y_device_px == 5003
        assert current_position.frame is None

    @pytest.mark.parametrize(
        "kwargs",
        [
            {"frame": 0, "subframe_mm": 1.0, "br_y_device_px": 100},
            {"frame": 1, "subframe_mm": -0.01, "br_y_device_px": 100},
            {"frame": 1, "subframe_mm": math.nan, "br_y_device_px": 100},
            {"frame": 1, "subframe_mm": 1.0, "br_y_device_px": -1},
            {"frame": 1, "subframe_mm": 1.0, "br_y_device_px": True},
        ],
    )
    def test_registered_geometry_rejects_impossible_values(self, kwargs) -> None:
        with pytest.raises(ValueError):
            RegisteredScanGeometry(**kwargs)

    def test_frozen(self) -> None:
        params = ScanParams(dpi=1200, depth=16, capture_ir=False)
        with pytest.raises(Exception):
            params.dpi = 2400  # type: ignore[misc]


class TestCapabilityFiltering:
    def test_sources_filtered_by_caps(self) -> None:
        caps = ScannerCapabilities(
            ir_channel=False,
            supported_dpi=(300, 600, 1200, 2400),
            supported_depths=(8, 16),
            sources=(ScanMode.NEGATIVE, ScanMode.POSITIVE),
        )
        assert ScanMode.TRANSPARENCY not in caps.sources
        assert ScanMode.NEGATIVE in caps.sources
        assert len(caps.sources) == 2

    def test_empty_sources_means_no_film(self) -> None:
        caps = ScannerCapabilities(
            ir_channel=False,
            supported_dpi=(),
            supported_depths=(),
            sources=(),
        )
        assert len(caps.sources) == 0

    def test_dpi_range_from_caps(self) -> None:
        caps = ScannerCapabilities(
            ir_channel=True,
            supported_dpi=(300, 600, 1200, 2400, 3600),
            supported_depths=(16,),
            sources=(ScanMode.NEGATIVE, ScanMode.TRANSPARENCY),
        )
        assert 3600 in caps.supported_dpi
        assert 75 not in caps.supported_dpi
