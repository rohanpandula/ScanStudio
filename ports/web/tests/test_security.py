from __future__ import annotations

import pytest

from scanstudio_web.security import AuthManager, socket_peer_is_trusted_lan
from scanstudio_web.settings import ConfigurationError, Settings


def test_bracketed_non_ipv6_origin_cannot_widen_to_unbracketed_dns() -> None:
    manager = AuthManager(
        Settings(
            shared_token="test-access-token",
            allowed_origins=("https://vdead.evil.example",),
        )
    )

    assert manager.origin_is_allowed("https://[vdead.evil.example]") is False
    with pytest.raises(ConfigurationError, match="numeric IPv6"):
        Settings(
            shared_token="test-access-token",
            allowed_origins=("https://[vdead.evil.example]",),
        )


@pytest.mark.parametrize(
    "origin",
    [
        "https://[v1.fe80]",
        "https://[fd00::1%25en0]",
        "https://scanner%2eexample.test",
        "https://scanner.example.test,evil.example.test",
        "https://[fd00::1]:",
        "https://scanner.example.test:0",
    ],
)
def test_auth_manager_rejects_non_origin_host_syntax(origin) -> None:
    manager = AuthManager(
        Settings(
            shared_token="test-access-token",
            allowed_origins=("https://scanner.example.test",),
        )
    )

    assert manager.origin_is_allowed(origin) is False
    with pytest.raises(
        ConfigurationError,
        match="invalid host|invalid port|numeric IPv6",
    ):
        Settings(
            shared_token="test-access-token",
            allowed_origins=(origin,),
        )


@pytest.mark.parametrize(
    "peer",
    [
        "127.0.0.1",
        "127.255.255.254",
        "10.0.0.1",
        "10.255.255.254",
        "172.16.0.1",
        "172.31.255.254",
        "192.168.0.1",
        "192.168.255.254",
        "::1",
        "fc00::1",
        "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        "::ffff:127.0.0.1",
        "::ffff:192.168.1.10",
    ],
)
def test_socket_peer_classifier_accepts_only_documented_lan_ranges(peer) -> None:
    assert socket_peer_is_trusted_lan(peer) is True


@pytest.mark.parametrize(
    "peer",
    [
        None,
        "",
        "localhost",
        "not-an-address",
        "0.0.0.0",
        "8.8.8.8",
        "100.64.0.1",
        "169.254.1.1",
        "172.15.255.255",
        "172.32.0.1",
        "192.0.2.1",
        "224.0.0.1",
        "255.255.255.255",
        "::",
        "2001:4860:4860::8888",
        "fe80::1",
        "fe80::1%en0",
        "fec0::1",
        "ff02::1",
        "::ffff:100.64.0.1",
        "::ffff:8.8.8.8",
    ],
)
def test_socket_peer_classifier_rejects_every_other_address_class(peer) -> None:
    assert socket_peer_is_trusted_lan(peer) is False
