"""Raw scanner transport backends (SANE-based and direct libsane RGBI)."""

from __future__ import annotations

__all__ = ["strip_net_prefix"]


def strip_net_prefix(device_id: str) -> str:
    """Drop a leading `net:<host>:` so backend-prefix checks work over saned.

    Handles both `net:192.0.2.10:coolscan3:...` and bracketed IPv6 hosts
    (`net:[2001:db8::1]:coolscan3:...`).
    """
    if not device_id.startswith("net:"):
        return device_id
    rest = device_id[len("net:") :]
    if rest.startswith("["):  # bracketed IPv6 host
        close = rest.find("]:")
        return rest[close + 2 :] if close > 0 else device_id
    host, sep, backend_part = rest.partition(":")
    return backend_part if sep and host else device_id
