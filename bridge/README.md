# scanstudio-bridge

A headless NDJSON-over-stdio service that wraps CoolscanPy's LS-5000 roll-feeder
engine so the Scan Studio Rust engine can drive real Nikon SUPER COOLSCAN 5000 ED
hardware. The canonical wire-protocol spec is in this repository at
`app/ScanStudio/protocol/BRIDGE.md` — read that file for every method, error
code, type, and event this service implements.

License: GPL-3.0-only

## Development

```
uv sync
uv run pytest
```

This project uses the checkout-local `../coolscanpy` source through the locked
`uv` configuration. It does not require a sibling archaeology checkout.

Motion is refused unless both `SCANSTUDIO_HW_MOTION=1` is set and an armed-latch
file is present — see BRIDGE.md's SAFE-02 guardrails section for the full policy.
