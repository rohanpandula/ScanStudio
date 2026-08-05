"""The python-sane-shaped plain surface: ``get_devices``/``open``/``Device``.

This module is thin by design: it adapts ``session.service.ScannerService``
(itself backed by ``transport.sane.SaneBackend``) to the fixed, typed option
attributes and constraint-introspection shape the public API contract
describes. It adds exactly two pieces of new behavior beyond adaptation and
argument validation, both explicitly called for by the API contract:

* an in-process registry so a second ``open()`` of an already-open device
  raises :class:`~coolscanpy.exceptions.DeviceBusy` instead of silently
  racing it (there is no cross-process reservation for the plain scan path);
* a non-blocking per-device lock so a concurrent ``scan()``/``roll()`` call
  raises :class:`~coolscanpy.exceptions.DeviceBusy` rather than blocking.

``coolscanpy.session.service.ScannerService`` and ``coolscanpy.transport.sane``
are imported lazily (inside functions, not at module level) so that plain
``import coolscanpy`` stays cheap and does not pull in ``cv2``/``python-sane``
-- matching this package's existing convention that only the code paths
which actually need the SANE-backed transport pay for it (see the
``[scanner]`` extra in ``pyproject.toml``).

Enumeration itself never requires python-sane to be installed: ``get_devices()``
tries the SANE route first, and falls back to direct USB enumeration whenever
SANE is unavailable, fails to enumerate, or finds no Coolscan unit (``pyusb``,
already a runtime dependency, matching the LS-5000's fixed vendor/product id) -- see
``_usb_fallback_device_infos``. That fallback device carries reduced,
conservative capabilities, since there is no SANE session to negotiate the
rest against. SANE-only operations (``Device.scan()``, ``Device.eject()``)
still raise ``ImportError`` when actually called on such a device -- only
enumeration and the roll-feeder extension, which never uses SANE, are
unaffected by its absence.
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import TYPE_CHECKING, Callable

from coolscanpy.exceptions import DeviceBusy, DeviceNotFound, EjectFailed
from coolscanpy.session.backend import ScannerCapabilities, ScannerDevice
from coolscanpy.session.params import ScanParams
from coolscanpy.types import (
    Capabilities,
    DeviceInfo,
    Material,
    Option,
    OptionType,
    OptionUnit,
)

if TYPE_CHECKING:
    from coolscanpy._roll import Roll
    from coolscanpy.session.service import ScannerService

_COOLSCAN3_PREFIX = "coolscan3:"

_OPTION_NAMES: tuple[str, ...] = (
    "resolution",
    "depth",
    "samples",
    "autofocus",
    "auto_exposure",
)

# The Nikon Coolscan LS-5000's fixed USB identity. The roll engine's capture
# subprocess (protocol.ls5000_single_pass.worker) locates the physical unit
# itself with this exact pair -- it never consumes a device id from this
# module -- so these are duplicated constants, not a shared import, matching
# that module's pinned/untouched status.
_LS5000_USB_VENDOR_ID = 0x04B0
_LS5000_USB_PRODUCT_ID = 0x4002
_USB_FALLBACK_ID_PREFIX = "usb"

# Nikon Coolscan USB identity table, referenced from nkscan (Apache-2.0,
# activexray/nkscan @ 87a1724886f8262e7791731ca055aa00ad6632fb;
# src/scanners/{ls40,ls50,ls5000}, src/devices.rs). Verified from source, not
# from memory: LS-40 = 0x4000 (Coolscan IV), LS-50 = 0x4001 (Coolscan V),
# LS-5000 = 0x4002 (Coolscan 5000 ED). FireWire models (LS-8000/9000/4000)
# expose no USB ids and are found by SCSI only, so they are out of scope here.
# Of which only the LS-5000 (0x4002) is driven; the other models are listed
# by discovery as recognized-but-unsupported (labeled, never connectable).
_NIKON_COOLSCAN_USB_MODELS: dict[int, dict[int, str]] = {
    _LS5000_USB_VENDOR_ID: {
        0x4000: "LS-40 ED",
        0x4001: "LS-50 ED",
        _LS5000_USB_PRODUCT_ID: "LS-5000 ED",
    },
}


def _default_service_factory() -> "ScannerService":
    from coolscanpy.session.service import ScannerService

    return ScannerService()


# Rebindable so tests can substitute a service that wraps a fake backend
# without touching hardware or python-sane. See tests/test_facade.py.
_service_factory: Callable[[], "ScannerService"] = _default_service_factory

_open_devices: set[str] = set()
_open_devices_lock = threading.Lock()


def _register_open_device(device_id: str) -> None:
    with _open_devices_lock:
        if device_id in _open_devices:
            raise DeviceBusy(f"device {device_id!r} is already open in this process")
        _open_devices.add(device_id)


def _unregister_open_device(device_id: str) -> None:
    with _open_devices_lock:
        _open_devices.discard(device_id)


def _is_coolscan_device_id(device_id: str) -> bool:
    """True for a Coolscan LS-5000 SANE device id, direct or via saned.

    ``get_devices()`` scope is one vendor: filter out every other SANE
    backend's device (pieusb, generic flatbeds, etc.) so a caller never sees
    a non-Coolscan unit, matching the module-level scope note. Imports
    ``transport.sane`` lazily -- see the module docstring.
    """

    from coolscanpy.transport.sane import _strip_net_prefix

    return _strip_net_prefix(device_id).startswith(_COOLSCAN3_PREFIX)


def _capabilities_from(caps: ScannerCapabilities) -> Capabilities:
    return Capabilities(
        ir_channel=caps.ir_channel,
        supported_dpi=caps.supported_dpi,
        supported_depths=caps.supported_depths,
        multi_sample=caps.multi_sample,
        adapter_frame_capacity=caps.adapter_frame_capacity,
        adapter_frame_control=caps.adapter_frame_control,
        auto_exposure=caps.auto_exposure,
        registered_geometry=caps.registered_geometry,
        can_eject=caps.can_eject,
    )


def _device_info_from(device: ScannerDevice) -> DeviceInfo:
    return DeviceInfo(
        id=device.id,
        vendor=device.vendor,
        model=device.model,
        capabilities=_capabilities_from(device.capabilities),
    )


def _usb_fallback_capabilities() -> Capabilities:
    """Conservative capabilities for a device found only via direct USB.

    No SANE session exists to negotiate a real capability set, so this
    reports only what holds for every LS-5000 regardless of software stack:
    a fixed 4000 dpi / 16-bit native fine-scan (what the roll engine's
    single-pass capture always requests, independent of ``Device.resolution``/
    ``.depth``) and frame-position addressing, so ``Device.roll()``'s
    capability gate passes. Everything SANE would otherwise negotiate
    per-unit (hardware multi-sample, auto-exposure, registered-geometry
    positioning, medium eject) is conservatively false/absent rather than
    guessed -- those remain genuinely SANE-only.
    """

    return Capabilities(
        ir_channel=True,
        supported_dpi=(4_000,),
        supported_depths=(16,),
        multi_sample=False,
        adapter_frame_capacity=None,
        adapter_frame_control=True,
        auto_exposure=False,
        registered_geometry=False,
        can_eject=False,
    )


def _usb_fallback_device_infos() -> list[DeviceInfo]:
    """Enumerate attached Nikon Coolscan units directly over USB, no python-sane.

    Used by :func:`get_devices` only when python-sane is not importable.
    ``usb.core`` is imported lazily here, matching this package's convention
    of scoping USB imports to the code that actually touches the bus.

    Every model in the nkscan-referenced PID table is reported by its real
    model name (LS-40 / LS-50 / LS-5000); only the LS-5000 carries
    ``supported=True``. A recognized-but-unsupported unit (LS-50, LS-40) is
    therefore visible in discovery instead of silently missing from the
    list -- labeled, and not connectable (Lane D, #14). An unknown Nikon
    product id is skipped rather than guessed.

    The returned id is synthetic (``"usb:<bus>:<address>"``): honest about
    the USB topology it was found on, but not a SANE device string, since
    none was ever negotiated. Nothing downstream needs it to be one --
    :meth:`Device.roll`'s capture subprocess locates the physical unit itself
    by the same fixed vendor/product id (see
    ``protocol.ls5000_single_pass.worker``), never through this id; the id
    here only labels the in-process open-device registry and the ``Receipt``
    metadata a roll capture carries.
    """

    import usb.core

    from coolscanpy.protocol.ls5000_single_pass.usb_backend import (
        get_libusb_backend,
    )

    capabilities = _usb_fallback_capabilities()
    product_table = _NIKON_COOLSCAN_USB_MODELS[_LS5000_USB_VENDOR_ID]
    found = usb.core.find(
        find_all=True,
        idVendor=_LS5000_USB_VENDOR_ID,
        backend=get_libusb_backend(),
    )
    infos: list[DeviceInfo] = []
    for device in found:
        model = product_table.get(device.idProduct)
        if model is None:
            continue
        infos.append(
            DeviceInfo(
                id=f"{_USB_FALLBACK_ID_PREFIX}:{device.bus}:{device.address}",
                vendor="Nikon",
                model=model,
                capabilities=capabilities,
                supported=device.idProduct == _LS5000_USB_PRODUCT_ID,
            )
        )
    return infos


def get_devices(local_only: bool = False) -> list[DeviceInfo]:
    """Enumerate attached Nikon Coolscan units.

    Mirrors ``sane.get_devices()``; unlike SANE, this never returns a
    non-Coolscan device -- there is no backend negotiation. ``local_only`` is
    accepted for signature-compatibility with ``sane.get_devices()`` and is
    currently always true (no network transport exists for this package).

    A supported LS-5000 is connectable (``supported=True``). Any other Nikon
    Coolscan found on the bus (LS-50, LS-40) is reported by name with
    ``supported=False`` so it is visible rather than silently missing -- see
    :func:`_usb_fallback_device_infos`.

    Tries the SANE route first. When SANE is unavailable, its enumeration
    fails, or it finds no Coolscan, falls back to direct USB enumeration -- see
    :func:`_usb_fallback_device_infos`.
    """

    del local_only
    sane_error: Exception | None = None
    try:
        service = _service_factory()
        devices = service.list_devices()
    except Exception as error:
        sane_error = error
        devices = []
    infos = [
        _device_info_from(device)
        for device in devices
        if _is_coolscan_device_id(device.id)
    ]
    if infos:
        return infos
    try:
        return _usb_fallback_device_infos()
    except Exception as usb_error:
        if sane_error is None:
            raise
        raise RuntimeError(
            "neither SANE nor direct USB could enumerate a Coolscan LS-5000 "
            f"(SANE: {type(sane_error).__name__}: {sane_error}; "
            f"USB: {type(usb_error).__name__}: {usb_error})"
        ) from usb_error


def open(devname: str) -> "Device":
    """Open one Coolscan LS-5000. Mirrors ``sane.open(devname)``.

    ``devname`` is either ``"ls5000"`` (friendly alias for "the one attached
    unit") or an exact :class:`~coolscanpy.types.DeviceInfo.id` string
    returned by :func:`get_devices`.
    """

    infos = get_devices()
    if devname == "ls5000":
        if not infos:
            raise DeviceNotFound("no Coolscan LS-5000 unit is attached")
        if len(infos) > 1:
            raise DeviceNotFound(
                "more than one Coolscan LS-5000 unit is attached; "
                "disambiguate via get_devices()"
            )
        info = infos[0]
    else:
        matches = [candidate for candidate in infos if candidate.id == devname]
        if not matches:
            raise DeviceNotFound(
                f"no attached Coolscan LS-5000 unit matches {devname!r}"
            )
        info = matches[0]

    if not info.supported:
        # Recognize-and-refuse (Lane D): a Nikon Coolscan that is not the
        # LS-5000 is listed in discovery but must never be opened. Fail-closed.
        raise DeviceNotFound(
            f"{info.model} is recognized but not supported; "
            "only the LS-5000 is supported"
        )

    _register_open_device(info.id)
    try:
        return Device(info, _service_factory())
    except BaseException:
        _unregister_open_device(info.id)
        raise


class Device:
    """One opened Coolscan LS-5000 unit.

    Construct via :func:`open`, not directly, except in tests that want to
    drive a specific :class:`DeviceInfo`/service pair without going through
    device enumeration.
    """

    def __init__(self, info: DeviceInfo, service: ScannerService) -> None:
        self._info = info
        self._service = service
        self._lock = threading.Lock()
        self._roll_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._cancel_event: threading.Event | None = None
        self._closed = False
        self._faulted_reason: str | None = None

        caps = info.capabilities
        self.resolution = max(caps.supported_dpi) if caps.supported_dpi else 4000
        self.depth = (
            16
            if 16 in caps.supported_depths
            else (max(caps.supported_depths) if caps.supported_depths else 16)
        )
        self.samples = 1
        self.autofocus = True
        self.auto_exposure = False

    def __setattr__(self, name: str, value: object) -> None:
        if name in _OPTION_NAMES:
            self._validate_option(name, value)
        object.__setattr__(self, name, value)

    def _validate_option(self, name: str, value: object) -> None:
        caps = self._info.capabilities
        if name == "resolution":
            if (
                isinstance(value, bool)
                or not isinstance(value, int)
                or value not in caps.supported_dpi
            ):
                raise ValueError(
                    f"resolution {value!r} is not in supported_dpi {caps.supported_dpi}"
                )
        elif name == "depth":
            if (
                isinstance(value, bool)
                or not isinstance(value, int)
                or value not in caps.supported_depths
            ):
                raise ValueError(
                    f"depth {value!r} is not in supported_depths {caps.supported_depths}"
                )
        elif name == "samples":
            allowed = (1, 4) if caps.multi_sample else (1,)
            if (
                isinstance(value, bool)
                or not isinstance(value, int)
                or value not in allowed
            ):
                raise ValueError(f"samples {value!r} is not in {allowed}")
        elif name == "autofocus":
            if not isinstance(value, bool):
                raise TypeError("autofocus must be a bool")
        elif name == "auto_exposure":
            if not isinstance(value, bool):
                raise TypeError("auto_exposure must be a bool")
            if value and not caps.auto_exposure:
                raise ValueError("device has no auto_exposure capability")

    @property
    def capabilities(self):
        return self._info.capabilities

    @property
    def option_names(self) -> list[str]:
        """Mirrors sane's ``optlist``."""

        return list(_OPTION_NAMES)

    def __getitem__(self, name: str) -> Option:
        """Mirrors sane's ``dev['name']`` descriptor lookup."""

        caps = self._info.capabilities
        if name == "resolution":
            return Option(
                name="resolution",
                title="Resolution",
                desc="Scan resolution, in dots per inch.",
                type=OptionType.INT,
                unit=OptionUnit.DPI,
                constraint=tuple(caps.supported_dpi),
                active=True,
                settable=len(caps.supported_dpi) > 1,
            )
        if name == "depth":
            return Option(
                name="depth",
                title="Depth",
                desc="Bits per sample.",
                type=OptionType.INT,
                unit=OptionUnit.NONE,
                constraint=tuple(caps.supported_depths),
                active=True,
                settable=len(caps.supported_depths) > 1,
            )
        if name == "samples":
            constraint = (1, 4) if caps.multi_sample else (1,)
            return Option(
                name="samples",
                title="Samples",
                desc="Hardware oversampling passes per line.",
                type=OptionType.INT,
                unit=OptionUnit.NONE,
                constraint=constraint,
                active=True,
                settable=caps.multi_sample,
            )
        if name == "autofocus":
            return Option(
                name="autofocus",
                title="Autofocus",
                desc="Autofocus before each scan.",
                type=OptionType.BOOL,
                unit=OptionUnit.NONE,
                constraint=None,
                active=True,
                settable=True,
            )
        if name == "auto_exposure":
            return Option(
                name="auto_exposure",
                title="Auto exposure",
                desc="Hardware auto-exposure metering.",
                type=OptionType.BOOL,
                unit=OptionUnit.NONE,
                constraint=None,
                active=caps.auto_exposure,
                settable=caps.auto_exposure,
            )
        raise KeyError(name)

    def scan(self, *, progress: Callable[[float], None] | None = None):
        """Blocking. Returns a uint16 ``(H, W, 3)`` scanner-linear RGB array.

        The plain, roll-independent scan path: a single ad-hoc capture at
        whatever resolution/depth/samples are currently set. Never touches
        roll bookkeeping, never produces a Receipt, never returns IR.
        """

        self._acquire_io_lock("scan")
        try:
            cancel_event = threading.Event()
            with self._state_lock:
                self._cancel_event = cancel_event
            params = ScanParams(
                dpi=self.resolution,
                depth=self.depth,
                capture_ir=False,
                autofocus=self.autofocus,
                samples_per_scan=self.samples,
                auto_exposure=self.auto_exposure,
            )
            result = self._service.run_scan(
                self._info.id,
                params,
                progress if progress is not None else (lambda _fraction: None),
                cancel_event,
            )
            return result.rgb
        except BaseException as error:
            self._mark_fault_if_cleanup_error(error)
            raise
        finally:
            with self._state_lock:
                self._cancel_event = None
            self._release_io_lock()

    def _acquire_io_lock(self, operation: str) -> None:
        """Claim this device's one in-process hardware-I/O lane."""

        with self._state_lock:
            self._require_usable_locked()
            if not self._lock.acquire(blocking=False):
                raise DeviceBusy(
                    f"device {self._info.id} is busy; cannot start {operation}"
                )

    def _release_io_lock(self) -> None:
        self._lock.release()

    def cancel(self) -> None:
        """Mirrors ``sane.SaneDev.cancel()``. Call from a different thread
        than the one blocked in :meth:`scan`."""

        with self._state_lock:
            event = self._cancel_event
        if event is not None:
            event.set()

    def roll(
        self,
        *,
        material: Material = Material.COLOR_NEGATIVE,
        attempts_root: str | Path | None = None,
    ) -> "Roll":
        """Open the 40-slot roll-feeder extension.

        ``attempts_root`` selects a caller-owned directory for per-attempt
        preview, transport-table, journal, and capture evidence. Caller-owned
        evidence survives :meth:`Roll.close`; omitting it keeps the temporary,
        self-cleaning default.
        """

        with self._state_lock:
            self._require_usable_locked()
            caps = self._info.capabilities
            if caps.adapter_frame_capacity is None and not caps.adapter_frame_control:
                raise ValueError("no roll adapter is attached/detected on this device")
            if not self._roll_lock.acquire(blocking=False):
                raise DeviceBusy(f"a Roll is already open on device {self._info.id}")
            try:
                from coolscanpy._roll import Roll

                return Roll(
                    self,
                    material,
                    attempts_root=(
                        None if attempts_root is None else Path(attempts_root)
                    ),
                )
            except BaseException:
                self._roll_lock.release()
                raise

    def _release_roll_lock(self) -> None:
        with self._state_lock:
            if self._roll_lock.locked():
                self._roll_lock.release()

    def eject(self) -> bool:
        """Capability-gated vendor eject/unload."""

        self._acquire_io_lock("eject")
        try:
            try:
                return bool(self._service.eject(self._info.id))
            except RuntimeError as error:
                self._mark_fault_if_cleanup_error(error)
                raise EjectFailed(str(error)) from error
        finally:
            self._release_io_lock()

    def film_present(self) -> bool | None:
        """Return whether the scanner currently reports film gripped.

        This is a motion-free raw-USB TEST UNIT READY query. ``None`` means
        the status could not be determined (for example, an active capture
        owns the interface or the scanner returned an unrecognised sense);
        it must never be interpreted as film absent. A parked short strip can
        still report ``True`` because this is a presence signal, not a motion
        readiness signal.
        """

        self._acquire_io_lock("film status")
        try:
            from coolscanpy.transport.adapter_status import probe_adapter_status

            return probe_adapter_status(device_id=self._info.id).film_present
        finally:
            self._release_io_lock()

    def close(self) -> None:
        """Idempotent. Releases any transport claim this Device holds."""

        with self._state_lock:
            if self._closed:
                return
            if self._roll_lock.locked():
                raise DeviceBusy("close the Roll before closing its Device")
            if not self._lock.acquire(blocking=False):
                raise DeviceBusy(
                    f"device {self._info.id} is busy; cannot start device close"
                )
            self._closed = True
            _unregister_open_device(self._info.id)
        try:
            pass
        finally:
            self._release_io_lock()

    def _require_open(self) -> None:
        with self._state_lock:
            self._require_usable_locked()

    def _require_usable_locked(self) -> None:
        if self._closed:
            raise RuntimeError("this Device has been closed")
        if self._faulted_reason is not None:
            raise DeviceBusy(
                f"device {self._info.id} is faulted after a SANE cleanup failure; "
                "close and reopen it before more scanner I/O "
                f"({self._faulted_reason})"
            )

    def _mark_faulted(self, reason: str) -> None:
        with self._state_lock:
            if not self._closed:
                self._faulted_reason = reason

    def _mark_fault_if_cleanup_error(self, error: BaseException) -> None:
        """Make an uncertain SANE owner terminal without eager SANE imports."""

        try:
            from coolscanpy.transport.sane import SaneCleanupError
        except ImportError:
            return
        pending: list[BaseException] = [error]
        seen: set[int] = set()
        while pending:
            candidate = pending.pop()
            if id(candidate) in seen:
                continue
            seen.add(id(candidate))
            if isinstance(candidate, SaneCleanupError):
                self._mark_faulted(str(candidate))
                return
            for linked in (candidate.__cause__, candidate.__context__):
                if isinstance(linked, BaseException):
                    pending.append(linked)

    def __enter__(self) -> "Device":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
