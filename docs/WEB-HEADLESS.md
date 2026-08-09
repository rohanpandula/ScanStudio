# ScanStudio web and headless roadmap

ScanStudio's browser edition is a new host for the existing application, not a
new scanning implementation. The browser uses the same React session model as
the Tauri desktop port. A small Python service supervises the same Rust engine,
which continues to use the same Python bridge and CoolScanPy hardware path.

See [ADR 0001](adr/0001-web-headless-runtime.md) for the decision and safety
boundaries.

## Milestone 1: simulator appliance

Goal: prove the complete browser transport without filesystem writes or scanner
motion.

- authenticated browser session;
- one renewable controller lease and read-only observers;
- one supervised engine child and mandatory protocol handshake;
- HTTP request/response relay and ordered WebSocket events;
- existing Device Bar and Contact Sheet running in a browser;
- simulated six-frame strip load and preview;
- multi-stage Docker image with no bridge configured;
- unit tests plus a browser-to-engine simulator smoke test.

The gateway deliberately rejects every engine method outside the milestone's
allowlist. A build that renders more controls does not make those operations
available server-side.

The macOS app exposes this local preview as a session-only Settings toggle. It
starts off, binds to loopback, generates a fresh access token per app launch,
and stops the gateway during app termination. In this milestone the toggled
service owns a separate simulator engine; it does not attach to or control the
native app's scanner session. Docker lifecycle remains controlled by the
container runtime rather than a desktop process.

## Milestone 2: server storage and reconnect

- Replace local file dialogs with server-defined project and output roots.
- Accept opaque project/storage IDs, never arbitrary absolute browser input.
- Map real preview artifacts to short-lived authenticated IDs.
- Add a state snapshot and bounded event replay so a refreshed browser can
  rehydrate without restarting the engine or scanner session.
- Correct the engine's documented stale project-mutation risk before allowing
  mutations concurrent with active receipt persistence.
- Add graceful drain behavior and an explicit update-safe/idle signal.

## Milestone 3: owner-attended container validation

- Package the Python bridge, CoolScanPy, system libusb/SANE runtime, ExifTool,
  licenses, notices, and corresponding source.
- Persist `HOME`/bridge state under `/config` and projects under
  `/data/projects`.
- Pass only the required USB device where practical. For hotplug support,
  document the broader `/dev/bus/usb` plus cgroup-rule and host-udev tradeoff.
- Preserve the existing two-part motion arm. Container startup must never
  create or silently modify the latch.
- Validate preview, approval, one short real capture, safe stop, restart, and
  recovery through the repository's live-operation runbook.

## Milestone 4: Unraid release

- Publish a pinned multi-architecture policy (x86-64 first) and image digest.
- Provide an Unraid Community Applications template for port, `/config`,
  `/data/projects`, PUID/PGID, scanner group, and USB mapping.
- Recommend Tailscale or an authenticated TLS reverse proxy; never direct
  Internet exposure.
- Disable unattended restarts while a job or held preview registration is
  active.
- Add capacity and retention guidance. A 4000 dpi, 16-bit RGBI frame can consume
  hundreds of megabytes across archive, positive, IR, meter, and evidence data.

## Mobile direction

There is no separate mobile app in this plan. The shared browser UI adapts in
place:

- desktop retains the two/three-pane scanning cockpit;
- tablet uses a narrower navigation rail and workspace;
- phone stacks device controls above one primary workspace, uses 44 px touch
  targets, safe-area insets, and `100dvh`;
- motion-capable actions remain explicit and never depend on hover.

This keeps a future native mobile shell possible without making it a dependency
of the headless scanner service.
