"""Tests for ScannerService with a FakeBackend."""

import sys
import threading
import time

import numpy as np
import pytest

from coolscanpy.session.backend import ScanMode, ScannerCapabilities, ScannerDevice
from coolscanpy.session.params import ScanParams
from coolscanpy.session.result import ScanResult
from coolscanpy.transport.sane import SaneBackend
from coolscanpy.session.service import ScannerService


class FakeBackend:
    """In-memory ScannerBackend for testing."""

    def __init__(
        self,
        devices: list[ScannerDevice] | None = None,
        *,
        fresh_devices: list[ScannerDevice] | None = None,
    ) -> None:
        self._devices = devices or []
        self._fresh_devices = fresh_devices if fresh_devices is not None else self._devices
        self._should_raise: Exception | None = None
        self._scan_delay: float = 0.0
        self.refresh_calls = 0
        self.scan_calls = 0

    def list_devices(self) -> list[ScannerDevice]:
        if self._should_raise:
            raise self._should_raise
        return self._devices

    def refresh_devices(self) -> list[ScannerDevice]:
        self.refresh_calls += 1
        if self._should_raise:
            raise self._should_raise
        self._devices = self._fresh_devices
        return self._devices

    def scan(
        self,
        device_id: str,
        params: ScanParams,
        progress,
        cancel: threading.Event,
    ) -> ScanResult:
        self.scan_calls += 1
        if self._should_raise:
            raise self._should_raise

        if progress:
            progress(0.0)

        # Simulate scan work
        if self._scan_delay > 0 and not cancel.is_set():
            time.sleep(min(self._scan_delay, 0.5))

        if cancel.is_set():
            raise RuntimeError("Scan cancelled")

        h, w = 100, 150
        rgb = np.ones((h, w, 3), dtype=np.uint16) * 30000

        ir = None
        if params.capture_ir:
            ir = np.ones((h, w), dtype=np.uint16) * 10000

        if progress:
            progress(1.0)

        return ScanResult(rgb=rgb, ir=ir, dpi=params.dpi, device_model="FakeScanner")


@pytest.fixture
def fake_caps() -> ScannerCapabilities:
    return ScannerCapabilities(
        ir_channel=True,
        supported_dpi=(300, 600, 1200, 2400, 3600),
        supported_depths=(8, 16),
        sources=(ScanMode.NEGATIVE, ScanMode.POSITIVE, ScanMode.TRANSPARENCY),
    )


@pytest.fixture
def fake_device(fake_caps: ScannerCapabilities) -> ScannerDevice:
    return ScannerDevice(id="fake:001", vendor="FakeCorp", model="ScanMaster 9000", capabilities=fake_caps)


class TestScannerServiceWithFakeBackend:
    def test_list_devices(self, fake_device: ScannerDevice) -> None:
        service = ScannerService()
        service._backend = FakeBackend(devices=[fake_device])
        devices = service.list_devices()
        assert len(devices) == 1
        assert devices[0].id == "fake:001"
        assert devices[0].vendor == "FakeCorp"

    def test_probe_device_returns_the_exact_device_from_fresh_enumeration(
        self,
        fake_caps: ScannerCapabilities,
    ) -> None:
        stale_device = ScannerDevice(
            id="fake:stale",
            vendor="FakeCorp",
            model="Disconnected Scanner",
            capabilities=fake_caps,
        )
        fresh_device = ScannerDevice(
            id="fake:fresh",
            vendor="FakeCorp",
            model="Connected Scanner",
            capabilities=fake_caps,
        )
        backend = FakeBackend(
            devices=[stale_device],
            fresh_devices=[fresh_device],
        )
        service = ScannerService()
        service._backend = backend

        assert service.list_devices() == [stale_device]

        probed = service.probe_device(fresh_device.id)

        assert probed is fresh_device
        assert backend.refresh_calls == 1
        assert backend.scan_calls == 0

    def test_probe_device_reports_the_requested_id_when_missing(
        self,
        fake_device: ScannerDevice,
    ) -> None:
        service = ScannerService()
        service._backend = FakeBackend(fresh_devices=[fake_device])

        with pytest.raises(
            RuntimeError,
            match=r"Scanner device 'fake:missing' was not found during fresh enumeration",
        ):
            service.probe_device("fake:missing")

    def test_probe_device_wraps_enumeration_failure_with_context(self) -> None:
        enumeration_error = OSError("SANE bus unavailable")
        backend = FakeBackend()
        backend._should_raise = enumeration_error
        service = ScannerService()
        service._backend = backend

        with pytest.raises(
            RuntimeError,
            match=r"Could not probe scanner device 'fake:001': fresh enumeration failed: SANE bus unavailable",
        ) as raised:
            service.probe_device("fake:001")

        assert raised.value.__cause__ is enumeration_error
        assert backend.refresh_calls == 1
        assert backend.scan_calls == 0

    def test_probe_device_preserves_production_sane_initialization_failure(
        self,
        monkeypatch,
    ) -> None:
        initialization_error = OSError("saned unavailable")

        class FailingSaneModule:
            def init(self) -> None:
                raise initialization_error

        monkeypatch.setitem(sys.modules, "sane", FailingSaneModule())
        service = ScannerService()
        service._backend = SaneBackend()

        with pytest.raises(
            RuntimeError,
            match=(
                r"Could not probe scanner device 'net:scanner:coolscan3:usb': "
                r"fresh enumeration failed: SANE initialization failed: saned unavailable"
            ),
        ) as raised:
            service.probe_device("net:scanner:coolscan3:usb")

        assert raised.value.__cause__ is not None
        assert raised.value.__cause__.__cause__ is initialization_error

    def test_probe_device_preserves_selected_production_device_open_failure(
        self,
        monkeypatch,
    ) -> None:
        device_id = "net:scanner:coolscan3:usb"
        open_error = PermissionError("scanner is busy")

        class FailingSaneModule:
            def init(self) -> None:
                pass

            def get_devices(self):
                return [(device_id, "Nikon", "LS-5000 ED", "film scanner")]

            def open(self, requested_device_id: str):
                assert requested_device_id == device_id
                raise open_error

        monkeypatch.setitem(sys.modules, "sane", FailingSaneModule())
        service = ScannerService()
        service._backend = SaneBackend()

        with pytest.raises(
            RuntimeError,
            match=(
                r"Could not probe scanner device 'net:scanner:coolscan3:usb': fresh enumeration failed: "
                r"Could not open scanner device 'net:scanner:coolscan3:usb' during fresh probe: scanner is busy"
            ),
        ) as raised:
            service.probe_device(device_id)

        assert raised.value.__cause__ is not None
        assert raised.value.__cause__.__cause__ is open_error

    def test_run_scan(self, fake_device: ScannerDevice) -> None:
        service = ScannerService()
        service._backend = FakeBackend(devices=[fake_device])

        params = ScanParams(dpi=1200, depth=16, capture_ir=False)
        progress_values: list[float] = []
        cancel = threading.Event()

        result = service.run_scan(fake_device.id, params, lambda p: progress_values.append(p), cancel)

        assert result.rgb.shape == (100, 150, 3)
        assert result.rgb.dtype == np.uint16
        assert result.ir is None
        assert result.dpi == 1200
        assert progress_values == [0.0, 1.0]

    def test_scan_with_ir(self, fake_device: ScannerDevice) -> None:
        service = ScannerService()
        service._backend = FakeBackend(devices=[fake_device])

        params = ScanParams(dpi=2400, depth=16, capture_ir=True)
        cancel = threading.Event()

        result = service.run_scan(fake_device.id, params, lambda _: None, cancel)

        assert result.ir is not None
        assert result.ir.shape == (100, 150)

    def test_cancel_scan(self, fake_device: ScannerDevice) -> None:
        service = ScannerService()
        backend = FakeBackend(devices=[fake_device])
        backend._scan_delay = 5.0  # Long delay
        service._backend = backend

        params = ScanParams(dpi=1200, depth=16, capture_ir=False)
        cancel = threading.Event()

        # Set cancel immediately
        cancel.set()
        with pytest.raises(RuntimeError, match="Scan cancelled"):
            service.run_scan(fake_device.id, params, lambda _: None, cancel)

    def test_no_devices_returns_empty(self) -> None:
        service = ScannerService()
        service._backend = FakeBackend(devices=[])
        devices = service.list_devices()
        assert devices == []


class TestRenderScanFilename:
    def test_basic_template(self) -> None:
        from coolscanpy.session.filenames import render_scan_filename

        result = render_scan_filename('{{ date }}_{{ "%03d" % seq }}', "20260511", 1)
        assert result == "20260511_001"

    def test_seq_increments(self) -> None:
        from coolscanpy.session.filenames import render_scan_filename

        assert render_scan_filename('{{ date }}_{{ "%03d" % seq }}', "20260511", 5) == "20260511_005"

    def test_invalid_template_falls_back(self) -> None:
        from coolscanpy.session.filenames import render_scan_filename

        result = render_scan_filename("{{ unclosed", "20260511", 1)
        assert result == "20260511_001"
