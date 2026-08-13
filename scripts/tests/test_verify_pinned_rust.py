from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFIER_PATH = REPOSITORY_ROOT / "scripts" / "verify_pinned_rust.py"
SPEC = importlib.util.spec_from_file_location("verify_pinned_rust", VERIFIER_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


HOST_KEY = ("Linux", "x86_64")
EXPECTED_HOST = VERIFIER.HOSTS[HOST_KEY]
EXPECTED_ACTIVE = f"{VERIFIER.VERSION}-{EXPECTED_HOST}"


def rustc_vv(
    *,
    release: str = VERIFIER.VERSION,
    commit_hash: str = VERIFIER.RUSTC_COMMIT,
    host: str = EXPECTED_HOST,
) -> str:
    return (
        f"rustc {release} ({commit_hash[:9]} 2026-08-01)\n"
        "binary: rustc\n"
        f"commit-hash: {commit_hash}\n"
        "commit-date: 2026-08-01\n"
        f"host: {host}\n"
        f"release: {release}\n"
        "LLVM version: 19.1.0"
    )


def cargo_vv(
    *,
    release: str = VERIFIER.VERSION,
    commit_hash: str = VERIFIER.CARGO_COMMIT,
    host: str = EXPECTED_HOST,
) -> str:
    return (
        f"cargo {release} ({commit_hash[:9]} 2026-08-01)\n"
        f"release: {release}\n"
        f"commit-hash: {commit_hash}\n"
        "commit-date: 2026-08-01\n"
        f"host: {host}"
    )


def fake_output(
    *,
    rustc: str,
    cargo: str,
    active: str = EXPECTED_ACTIVE,
    rustc_path: str | None = None,
    cargo_path: str | None = None,
):
    """Build an ``output(*command)`` stand-in keyed on the exact argv tuples
    verify_pinned_rust.main() issues, in the order it issues them."""
    rustc_path = (
        rustc_path or f"/home/runner/.rustup/toolchains/{EXPECTED_ACTIVE}/bin/rustc"
    )
    cargo_path = (
        cargo_path or f"/home/runner/.rustup/toolchains/{EXPECTED_ACTIVE}/bin/cargo"
    )

    def run(*command: str) -> str:
        if command == ("rustc", "-Vv"):
            return rustc
        if command == ("cargo", "-Vv"):
            return cargo
        if command == ("rustup", "show", "active-toolchain"):
            return f"{active} (default)"
        if command == ("rustup", "which", "--toolchain", EXPECTED_ACTIVE, "rustc"):
            return rustc_path
        if command == ("rustup", "which", "--toolchain", EXPECTED_ACTIVE, "cargo"):
            return cargo_path
        raise AssertionError(f"unexpected command: {command!r}")

    return run


class VerifyPinnedRustTests(unittest.TestCase):
    def run_main(self, **overrides: object) -> int:
        defaults: dict[str, object] = {"rustc": rustc_vv(), "cargo": cargo_vv()}
        defaults.update(overrides)
        with (
            mock.patch.object(VERIFIER.platform, "system", return_value=HOST_KEY[0]),
            mock.patch.object(VERIFIER.platform, "machine", return_value=HOST_KEY[1]),
            mock.patch.object(VERIFIER, "output", side_effect=fake_output(**defaults)),
        ):
            return VERIFIER.main()

    def test_accepts_exact_pinned_toolchain(self) -> None:
        self.assertEqual(self.run_main(), 0)

    def test_unsupported_host_returns_nonzero_before_any_subprocess_call(self) -> None:
        with (
            mock.patch.object(VERIFIER.platform, "system", return_value="Plan9"),
            mock.patch.object(VERIFIER.platform, "machine", return_value="mips"),
            mock.patch.object(VERIFIER, "output") as output,
        ):
            self.assertEqual(VERIFIER.main(), 1)
        output.assert_not_called()

    def test_rejects_tampered_rustc_release(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "unexpected rustc release"):
            self.run_main(rustc=rustc_vv(release="1.0.0"))

    def test_rejects_tampered_rustc_commit_hash(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "unexpected rustc commit"):
            self.run_main(rustc=rustc_vv(commit_hash="0" * 40))

    def test_rejects_tampered_cargo_commit_hash(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "unexpected cargo commit"):
            self.run_main(cargo=cargo_vv(commit_hash="f" * 40))

    def test_rejects_host_mismatch_between_reported_and_expected_platform(
        self,
    ) -> None:
        # A foreign or cross-compiled rustc binary can report a different
        # host triple than the one the running platform resolves to.
        with self.assertRaisesRegex(RuntimeError, "unexpected rustc host"):
            self.run_main(rustc=rustc_vv(host="aarch64-apple-darwin"))

    def test_rejects_wrong_active_toolchain(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "unexpected active Rust toolchain"):
            self.run_main(active="1.0.0-x86_64-unknown-linux-gnu")

    def test_rejects_toolchain_path_escaping_exact_rustup_tree(self) -> None:
        with self.assertRaisesRegex(
            RuntimeError, "escaped the exact rustup toolchain"
        ):
            self.run_main(rustc_path="/opt/attacker-controlled/rustc")


if __name__ == "__main__":
    unittest.main()
