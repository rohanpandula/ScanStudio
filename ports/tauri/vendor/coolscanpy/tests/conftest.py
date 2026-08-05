"""Root pytest configuration for coolscanpy's acquisition-layer test suite.

Deliberately minimal, and deliberately not a copy of NegPy's tests/conftest.py:
that file installs a session-scoped, autouse PyQt6 QApplication fixture (plus
QT_QPA_PLATFORM/XDG_RUNTIME_DIR env setup) for a desktop app's whole suite.
coolscanpy has no Qt dependency at all, and no test here ever requests a Qt
fixture, so bringing that file over verbatim would import PyQt6 for no
reason. NegPy's --metrics-out perf-metrics harness (tests/metrics/conftest.py)
is likewise out of scope for this package's test suite.

Every scanner test in this suite fakes the boundary just below the module
under test with small classes local to that test file (FakeOption,
FakeSaneDev, FakeRawDevice, FakeRunner, and friends) rather than shared
pytest fixtures — there never was a shared fixture library to port. The one
cross-file dependency (tests/transport/test_full_negative_capture.py reuses
a handful of SANE doubles defined in tests/transport/test_coolscan_ir.py) is
preserved as a direct module import, matching the source layout.
"""

from __future__ import annotations

import struct

import pytest


@pytest.fixture(autouse=True)
def _accepted_nikon_density_test_backend(monkeypatch: pytest.MonkeyPatch) -> None:
    """Emulate the accepted macOS ``log10`` only in tests on other hosts.

    Production must keep refusing a host whose libm differs by one ULP from
    the Nikon/macOS reference triplet.  Linux CI still needs to exercise the
    transport, ownership, and failure-cleanup paths that construct density
    evidence, though.  Patch only the three exact reference inputs and leave
    every other ``log10`` call on the real host implementation.
    """
    from coolscanpy.protocol.ls5000_single_pass import density

    try:
        density.verify_nikon_density_arithmetic_backend()
    except RuntimeError as error:
        if "host math.log10 is not bit-exact" not in str(error):
            raise
    else:
        return

    host_log10 = density.math.log10
    accepted: dict[float, float] = {}
    for numerator, denominator, row_mean, expected_hex in zip(
        density._ARITHMETIC_REFERENCE_NUMERATORS,
        density._ARITHMETIC_REFERENCE_DENOMINATORS,
        density._ARITHMETIC_REFERENCE_ROW_MEANS,
        density._ARITHMETIC_REFERENCE_BINARY64_BE_HEX,
        strict=True,
    ):
        product = float(numerator) * row_mean
        quotient = product / float(denominator)
        ratio = density.FULL_SCALE / quotient
        accepted[ratio] = struct.unpack(">d", bytes.fromhex(expected_hex))[0]

    def accepted_log10(value: float) -> float:
        return accepted.get(value, host_log10(value))

    monkeypatch.setattr(density.math, "log10", accepted_log10)
    density.verify_nikon_density_arithmetic_backend()
