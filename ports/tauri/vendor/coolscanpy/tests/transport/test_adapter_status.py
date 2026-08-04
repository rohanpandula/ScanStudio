"""Hardware-free tests for the motion-free LS-5000 film-presence probe."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import SimpleNamespace

import pytest

from coolscanpy.protocol.ls5000_single_pass.worker import TransactionResult
from coolscanpy.transport import adapter_status


@dataclass
class _FakeInterface:
    bInterfaceNumber: int = 3


@dataclass
class _FakeUsbUtil:
    released: list[tuple[object, int]] = field(default_factory=list)
    disposed: list[object] = field(default_factory=list)

    def release_interface(self, device: object, number: int) -> None:
        self.released.append((device, number))

    def dispose_resources(self, device: object) -> None:
        self.disposed.append(device)


def _transaction_result(
    sense: str,
    *,
    phase: int = 0x01,
    payload: bytes = b"",
    status: bytes | None = None,
) -> TransactionResult:
    if status is None:
        condition = 0x00 if sense == "000000" else 0x02
        byte_four = {
            "020401": 0x01,
            "023a00": 0x01,
            "062800": 0x01,
        }.get(sense, 0x00)
        status = (
            bytes((condition,)) + bytes.fromhex(sense) + bytes((byte_four,)) + bytes(3)
        )
    return TransactionResult(
        phase=phase,
        payload=payload,
        status=status,
        sense=sense,
        stall_recoveries=0,
    )


def _install_connect(
    monkeypatch: pytest.MonkeyPatch,
    *,
    device: object | None = None,
    usb_util: _FakeUsbUtil | None = None,
) -> tuple[object, _FakeInterface, object, object, _FakeUsbUtil]:
    resolved_device = device if device is not None else object()
    interface = _FakeInterface()
    ep_out = object()
    ep_in = object()
    resolved_usb_util = usb_util or _FakeUsbUtil()
    monkeypatch.setattr(
        adapter_status,
        "_connect_device",
        lambda: (
            resolved_device,
            interface,
            ep_out,
            ep_in,
            resolved_usb_util,
        ),
    )
    return resolved_device, interface, ep_out, ep_in, resolved_usb_util


def _install_transaction_sequence(
    monkeypatch: pytest.MonkeyPatch,
    senses: list[str],
) -> list[dict[str, object]]:
    remaining = list(senses)
    calls: list[dict[str, object]] = []

    def perform(
        ep_out: object,
        ep_in: object,
        entry: dict,
        *,
        data_timeout_ms: int,
        deadline_monotonic: float | None = None,
    ) -> TransactionResult:
        calls.append(
            {
                "ep_out": ep_out,
                "ep_in": ep_in,
                "entry": entry,
                "data_timeout_ms": data_timeout_ms,
                "deadline_monotonic": deadline_monotonic,
            }
        )
        assert remaining
        return _transaction_result(remaining.pop(0))

    monkeypatch.setattr(adapter_status, "_perform_transaction", perform)
    return calls


@pytest.mark.parametrize(
    ("sense", "expected"),
    (
        ("000000", True),
        ("023a00", False),
        ("020401", None),
        ("020402", None),
        ("062800", None),
        ("ffffff", None),
    ),
)
def test_classify_film_presence_is_strict(
    sense: str,
    expected: bool | None,
) -> None:
    assert adapter_status._classify_film_presence(sense) is expected


def test_explicit_local_sane_id_targets_and_reports_exact_usb_device(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from coolscanpy.protocol.ls5000_single_pass import worker

    device = SimpleNamespace(bus=1, address=7)
    interface = _FakeInterface()
    usb_util = _FakeUsbUtil()
    selections: list[tuple[int | None, int | None]] = []

    def connect(
        *,
        expected_usb_bus: int | None = None,
        expected_usb_address: int | None = None,
    ):
        selections.append((expected_usb_bus, expected_usb_address))
        return device, interface, object(), object(), usb_util

    monkeypatch.setattr(worker, "_connect_device", connect)
    _install_transaction_sequence(monkeypatch, ["000000"])

    result = adapter_status.probe_adapter_status(
        device_id="coolscan3:usb:libusb:001:007"
    )

    assert selections == [(1, 7)]
    assert result.device_id == "usb:1:7"
    assert result.film_present is True


@pytest.mark.parametrize(
    "device_id",
    (
        "net:scanner:coolscan3:usb:libusb:001:007",
        "coolscan3:usb:not-a-location",
        "usb:1:0",
    ),
)
def test_nonlocal_or_invalid_device_id_fails_closed_before_usb(
    monkeypatch: pytest.MonkeyPatch,
    device_id: str,
) -> None:
    connected = False

    def forbidden_connect(**_kwargs: object):
        nonlocal connected
        connected = True
        raise AssertionError("invalid IDs must not reach USB")

    monkeypatch.setattr(
        "coolscanpy.protocol.ls5000_single_pass.worker._connect_device",
        forbidden_connect,
    )

    result = adapter_status.probe_adapter_status(device_id=device_id)

    assert result.film_present is None
    assert result.raw_status is None
    assert connected is False


@pytest.mark.parametrize(
    ("sense", "film_present", "capacity"),
    (
        ("000000", True, 40),
        ("023a00", False, None),
        ("020401", None, None),
    ),
)
def test_probe_surfaces_only_proven_presence_states(
    monkeypatch: pytest.MonkeyPatch,
    sense: str,
    film_present: bool | None,
    capacity: int | None,
) -> None:
    device, interface, _ep_out, _ep_in, usb_util = _install_connect(monkeypatch)
    _install_transaction_sequence(monkeypatch, [sense])

    result = adapter_status.probe_adapter_status()

    assert result.film_present is film_present
    assert result.frame_capacity == capacity
    assert result.raw_status == sense
    assert usb_util.released == [(device, interface.bInterfaceNumber)]
    assert usb_util.disposed == [device]


def test_startup_unit_attention_chain_is_drained_before_classification(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_connect(monkeypatch)
    chain = ["062900", "063f04", "062800", "063f03", "000000"]
    calls = _install_transaction_sequence(monkeypatch, chain)

    result = adapter_status.probe_adapter_status(settle_poll_seconds=0)

    assert result.film_present is True
    assert result.raw_status == "000000"
    assert result.sense_history == tuple(chain)
    assert len(calls) == len(chain)


def test_zero_settle_budget_runs_one_query_then_reports_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_connect(monkeypatch)
    calls = _install_transaction_sequence(monkeypatch, ["062900"])

    result = adapter_status.probe_adapter_status(
        settle_deadline_seconds=0,
        settle_poll_seconds=0,
    )

    assert result.film_present is None
    assert result.raw_status == "062900"
    assert result.sense_history == ("062900",)
    assert len(calls) == 1


@pytest.mark.parametrize(
    "invalid_result",
    (
        SimpleNamespace(payload=b"", status=bytes(8), sense="000000"),
        _transaction_result("000000", phase=0x02),
        _transaction_result("000000", payload=b"unexpected"),
        _transaction_result("000000", status=bytes(7)),
        _transaction_result(
            "000000",
            status=b"\x00" + bytes.fromhex("023a00") + bytes(4),
        ),
        _transaction_result(
            "023a00",
            status=bytes.fromhex("00023a0001000000"),
        ),
    ),
)
def test_malformed_worker_result_fails_soft_to_unknown(
    monkeypatch: pytest.MonkeyPatch,
    invalid_result: object,
) -> None:
    _install_connect(monkeypatch)
    monkeypatch.setattr(
        adapter_status,
        "_perform_transaction",
        lambda *_args, **_kwargs: invalid_result,
    )

    result = adapter_status.probe_adapter_status()

    assert result.film_present is None
    assert result.raw_status is None


def test_connect_and_transaction_failures_degrade_to_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        adapter_status,
        "_connect_device",
        lambda: (_ for _ in ()).throw(RuntimeError("not attached")),
    )
    assert adapter_status.probe_adapter_status().film_present is None

    device, interface, _ep_out, _ep_in, usb_util = _install_connect(monkeypatch)
    monkeypatch.setattr(
        adapter_status,
        "_perform_transaction",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError("claim conflict")),
    )
    assert adapter_status.probe_adapter_status().film_present is None
    assert usb_util.released == [(device, interface.bInterfaceNumber)]
    assert usb_util.disposed == [device]


def test_cleanup_failure_does_not_erase_a_valid_verdict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    usb_util = _FakeUsbUtil()
    usb_util.release_interface = (  # type: ignore[method-assign]
        lambda _device, _number: (_ for _ in ()).throw(OSError("already gone"))
    )
    device, _interface, _ep_out, _ep_in, _ = _install_connect(
        monkeypatch,
        usb_util=usb_util,
    )
    _install_transaction_sequence(monkeypatch, ["000000"])

    result = adapter_status.probe_adapter_status()

    assert result.film_present is True
    assert usb_util.disposed == [device]


@pytest.mark.parametrize(
    ("keyword", "value"),
    (
        ("data_timeout_ms", 0),
        ("data_timeout_ms", True),
        ("settle_deadline_seconds", float("nan")),
        ("settle_poll_seconds", float("inf")),
        ("settle_poll_seconds", "0.1"),
    ),
)
def test_invalid_timing_is_rejected_before_connect(
    monkeypatch: pytest.MonkeyPatch,
    keyword: str,
    value: object,
) -> None:
    connected = False

    def forbidden_connect():
        nonlocal connected
        connected = True
        raise AssertionError("invalid timing must not reach USB")

    monkeypatch.setattr(adapter_status, "_connect_device", forbidden_connect)
    with pytest.raises((TypeError, ValueError)):
        adapter_status.probe_adapter_status(**{keyword: value})
    assert connected is False
