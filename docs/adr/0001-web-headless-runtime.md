# ADR 0001: Web and headless runtime

- Status: Accepted for an incremental implementation
- Date: 2026-08-09
- Branch: `feature/scanstudio-web`

## Context

ScanStudio has three mature boundaries already:

1. SwiftUI and React/Tauri clients project session state and send commands.
2. `scanstudio-engine` owns projects, scan jobs, rendering, manifests, receipts,
   evidence, and the public NDJSON protocol.
3. The Python `scanstudio-bridge` and CoolScanPy own hardware sessions,
   registration, motion safety, and USB/SANE access.

The React client is already mostly platform-neutral. Its `SessionStore` depends
on a two-method `EngineTransport`; only the current transport and a small set of
host services are Tauri-specific.

The target is a browser-accessible, headless ScanStudio appliance that can run
on an x86-64 Linux/Unraid host while preserving native macOS, Windows, and Linux
clients. It must remain safe when a browser disconnects, when multiple tabs are
open, and when the physical scanner has exclusive state that cannot be replayed.

## Decision

Add a Python 3.13 FastAPI gateway that owns exactly one long-lived
`scanstudio-engine` subprocess. It performs the mandatory `engine.hello`
handshake, correlates protocol responses, and relays engine events over a
same-origin WebSocket.

Reuse the React 19 + TypeScript + Vite interface in `ports/tauri/app`. Select a
Tauri or web transport at runtime; do not create a second browser UI or a second
client-side state model.

The initial vertical slice is simulator-only and permits only:

- `scanner.list`
- `scanner.connect` for `sim-ls5000-0`
- `scanner.status`
- `sim.loadMedia`
- `scanner.acquireThumbnails`
- `scanner.disconnect`

It proves authentication, container delivery, request/response correlation,
event streaming, reconnect behavior, and the shared interface without touching
hardware or writing scan output.

Real capture remains behind later acceptance gates. The production topology is:

```text
browser
  -> HTTPS reverse proxy or private VPN
  -> FastAPI gateway (one controller lease, observers allowed)
  -> scanstudio-engine (one long-lived process)
  -> scanstudio-bridge (one long-lived Python process)
  -> CoolScanPy / libusb
  -> Nikon LS-5000
```

## Options considered

| Option | Three-year engineering TCO (assumption) | Risk | Decision |
| --- | ---: | --- | --- |
| Reuse React; Python gateway relays the existing engine protocol | 5–9 engineer-weeks | Medium | Chosen |
| Add HTTP/WebSocket directly to the Rust engine | 6–11 engineer-weeks | Medium | Rejected for now; it expands the engine's security and lifecycle surface |
| Rewrite engine workflow in Python | 30–60+ engineer-weeks | Very high | Rejected; duplicates tested policy, rendering, and receipt logic |
| Remote-control the Tauri desktop app | 10–18 engineer-weeks | High | Rejected; keeps a hidden GUI dependency and poor server lifecycle semantics |

The estimates are directional for a single maintainer and include maintenance,
not calendar commitments. The chosen approach has the smallest new authority:
the gateway supervises and transports; it does not decide scan policy.

## Consequences

### Easier

- Improvements to the engine or Python hardware layer reach every frontend.
- The existing React UI and its tests become both the Windows/Linux desktop UI
  and browser UI.
- Browser disconnects do not own or cancel scanner jobs.
- Docker can package one stateful scanner appliance without a desktop session.
- A future native mobile client can use the same gateway protocol without
  changing scanner logic.

### Harder

- The gateway must preserve process ordering and fail closed if the engine dies.
- A browser cannot choose server directories with its local file picker.
  Storage selection needs an allowlisted server-side model.
- Engine paths cannot be exposed as arbitrary file URLs. Real previews require
  opaque, authenticated artifact identifiers.
- One active project and one scanner mean the appliance cannot be horizontally
  scaled. One browser gets a renewable controller lease; others are observers.
- Browser reconnect requires an authoritative state-hydration endpoint before
  real capture is enabled.

## Real-hardware release gates

The simulator milestone does not enable the bridge. Real USB capture is enabled
only after all of the following are implemented and verified:

1. Authentication, exact WebSocket Origin checks, request limits, and HTTPS or
   a trusted private network are documented and tested.
2. Project and output paths are canonicalized beneath configured persistent
   roots; symlinks and traversal cannot escape them.
3. Preview files are served through opaque authenticated IDs, never caller-
   supplied filesystem paths.
4. Reconnect hydrates device, media, project, preview registration, approvals,
   and active-job state without replaying a motion command.
5. SIGTERM stops accepting new motion, requests an after-current-frame stop,
   waits for terminal evidence, then closes the engine and bridge.
6. Docker runs as a non-root user, without `--privileged`, with only the needed
   USB device access and persistent `/config` and `/data/projects` mounts.
7. Existing SAFE-02 motion arming, hardware-lane locking, evidence retention,
   and GPL corresponding-source distribution remain intact.
8. A container-specific, owner-attended LS-5000 run passes the Nikon live
   operation runbook and records before/after state, hashes, logs, receipts,
   rollback, and final media state.

## Deployment boundary

This milestone's supported image is simulator-only and contains neither USB
access nor the Python bridge/CoolScanPy. The future hardware-capable container
target is Linux x86-64 with a USB LS-5000. It will not contain the Swift app,
Nikon Scan/noVNC VM, Windows WSL2 path, or macOS FireWire driver. The scanner
must be owned by one host at a time; a VM and container cannot safely share it.

That future hardware bundle will include GPL-3.0-only bridge/CoolScanPy
components and must ship their licenses, notices, and corresponding source. It
must not be labeled as MIT-only.
