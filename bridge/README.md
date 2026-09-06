# ScanStudio bridge

`scanstudio-bridge` is the headless Python service between ScanStudio’s Rust
engine and CoolscanPy. It exchanges newline-delimited JSON over stdin/stdout;
responses and asynchronous scan events share that connection. It has no GUI.

The released ScanStudio app includes the bridge, its Python runtime, libusb,
licenses, and corresponding source. App users should follow the
[ScanStudio installation guide](../README.md) instead of installing a second
bridge. ScanStudio supports Apple Silicon Macs running macOS 14 or newer.
The standalone [CoolscanPy driver](../coolscanpy/README.md) has its own platform
and scanner support boundaries.

## What it owns

The bridge discovers and opens positively identified supported LS-5000 units,
requests roll previews, handles frame review and capture, writes output and
receipt evidence, and reports typed failures. Discovery alone is not evidence
that a scanner, holder, or film process can complete a capture.

The supported roll path uses direct USB for color-negative capture and eject.
Eject does not require SANE or `scanimage`; the optional `scanner` extra is for
CoolscanPy’s legacy SANE plain-scan path. The Rust engine and native app own
project persistence, user-facing recovery, and processed output presentation.

Read the [bridge wire protocol](../app/ScanStudio/protocol/BRIDGE.md) for
methods, events, field names, and errors. The separate
[app/engine protocol](../app/ScanStudio/protocol/PROTOCOL.md) is not a bridge
connection.

## Develop and test

Use Python 3.13 or newer and the repository’s pinned uv toolchain. From the
repository root:

```sh
cd bridge
uv sync --locked
uv run --locked pytest
bash scripts/smoke_bridge.sh
```

The lockfile uses checkout-local `../coolscanpy`; no archaeology checkout or
separate installed driver is needed. Unit tests substitute hardware dispatch.
The smoke script launches the actual console entry point with the mock
transport and a temporary state directory, and checks that unarmed preview is
refused. These checks do not move a scanner or establish hardware acceptance.

The console entry point is `scanstudio-bridge`. Production defaults to the
CoolscanPy transport. `SCANSTUDIO_BRIDGE_TRANSPORT=mock` selects the mock;
`SCANSTUDIO_BRIDGE_BASE_DIR` isolates process ownership and telemetry storage
for a development run. Use the packaged app for attended hardware work.

## Stop, recovery, and monitoring

Motion requires both `SCANSTUDIO_HW_MOTION=1` and a valid nonempty authorization
latch. The packaged launcher prepares these for its owned app session. Starting
the app does not itself request scanner movement. A process-ownership lock and
one hardware lane prevent competing bridge sessions from controlling the unit.

`scan.stop` is a request to stop safely, not an immediate physical abort. Its
acknowledgement is not a completed-job event: wait for `scan.completed` and the
app’s recovery instructions. An early acknowledged Stop remains bound to the
accepted job through worker startup and batch reservation. Shutdown refuses to
claim completion while an owned worker remains active. Confirmed eject comes
from the driver; the bridge does not issue a second confirmation probe.

The bridge records session provenance, call/phase outcomes, and anomalies under
`~/.scanstudio/hw-telemetry/` by default. Capture journals and durable project
receipts provide different evidence; no single log contains every UI progress
update. Follow the [Mac acceptance and full-roll guide](../docs/MAC-ACCEPTANCE.md)
for exact paths, continuous observation, stop/reopen/resume, and image checks.
Preserve live receipts and originals. Monitoring is not an automatic retry loop.

## Distribution and license

The bridge and CoolscanPy are GPL-3.0-only; see [LICENSE](LICENSE). Their source
and notices accompany packaged distributions. The app/engine’s MIT license
does not make the combined bundle MIT-only.

ScanStudio releases verify the bridge suite, exact packaged runtime, and
matching published CoolscanPy source before publishing a signed app. Driver
changes must reach the canonical driver release first; a version string alone
is not proof of parity.
