import threading
from typing import Callable

from coolscanpy.session.backend import ScannerBackend, ScannerDevice
from coolscanpy.session.params import ScanParams
from coolscanpy.session.result import ScanResult
from coolscanpy.transport.sane import SaneBackend
from coolscanpy._logging import get_logger

logger = get_logger(__name__)


class ScannerService:
    """Orchestrates device enumeration, scan execution, and file writing."""

    def __init__(self) -> None:
        self._backend: ScannerBackend | None = None

    def _get_backend(self) -> ScannerBackend:
        if self._backend is None:
            self._backend = SaneBackend()
        return self._backend

    def list_devices(self) -> list[ScannerDevice]:
        return self._get_backend().list_devices()

    def refresh_devices(self) -> list[ScannerDevice]:
        backend = self._get_backend()
        refresh = getattr(backend, "refresh_devices", None)
        if callable(refresh):
            return refresh()
        return backend.list_devices()

    def probe_device(self, device_id: str) -> ScannerDevice:
        """Return one device from a fresh backend enumeration."""

        backend = self._get_backend()
        try:
            strict_probe = getattr(backend, "probe_device", None)
            if callable(strict_probe):
                device = strict_probe(device_id)
                if device is not None:
                    return device
                devices: list[ScannerDevice] = []
            else:
                devices = self.refresh_devices()
        except Exception as exc:
            raise RuntimeError(f"Could not probe scanner device {device_id!r}: fresh enumeration failed: {exc}") from exc

        for device in devices:
            if device.id == device_id:
                return device
        raise RuntimeError(f"Scanner device {device_id!r} was not found during fresh enumeration")

    def run_scan(
        self,
        device_id: str,
        params: ScanParams,
        progress: Callable[[float], None],
        cancel: threading.Event,
    ) -> ScanResult:
        backend = self._get_backend()
        return backend.scan(device_id, params, progress, cancel)

    def eject(self, device_id: str) -> bool:
        """Trigger a capability-gated film eject; False when unsupported.

        Mirrors the optional-method pattern in refresh_devices/probe_device
        above — only SaneBackend implements this today.
        """
        backend = self._get_backend()
        eject = getattr(backend, "eject", None)
        if not callable(eject):
            return False
        return bool(eject(device_id))
