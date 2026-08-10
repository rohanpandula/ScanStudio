# ScanStudio web gateway

This directory contains the first browser/headless vertical slice for ScanStudio. It serves the existing React/Vite application, supervises one existing `scanstudio-engine` child, and relays the engine's protocol over authenticated HTTP and WebSocket endpoints.

This slice is deliberately simulator-only. The gateway removes `SCANSTUDIO_BRIDGE_CMD`, `SCANSTUDIO_HW_MOTION`, and every `SCANSTUDIO_WEB_*` gateway secret/configuration variable from the engine environment, verifies at startup that `scanner.list` exposes exactly `sim-ls5000-0`, and has no USB/device mapping or privileged container mode. It does not configure the Python bridge, Nikon hardware, media motion, capture, project paths, or output storage.

## Runtime contract

The gateway sends `engine.hello` as the child's first NDJSON request, owns all correlation IDs, drains stderr, and starts serving only after the handshake and simulator-device check succeed. Engine events are broadcast unchanged to bounded per-observer queues and a bounded observer set. A slow or excess observer is disconnected rather than blocking the engine reader or growing memory without limit.

The public engine allowlist is exactly:

- Observer-safe: `scanner.list`, `scanner.status`
- Controller-only: `scanner.connect`, `sim.loadMedia`, `scanner.acquireThumbnails`, `scanner.disconnect`

`scanner.connect` additionally requires `deviceId: "sim-ls5000-0"`. The gateway reserves and rejects `engine.hello` and `engine.shutdown`; it rejects every other method before writing anything to the subprocess.

Routes:

- `GET /api/v1/session`
- `POST /api/v1/session/login` with `{"token":"..."}`
- `POST /api/v1/control/claim`
- `POST /api/v1/control/heartbeat`
- `POST /api/v1/control/release`
- `POST /api/v1/engine/request` with `{"method":"...","params":{...}}`
- `WS /api/v1/engine/events`
- `GET /healthz` and `GET /startupz`

The two unauthenticated probes expose only stable readiness booleans/status.
Child PIDs and internal startup/fatal diagnostics are never returned publicly.

Login exchanges the deployment token for an opaque `HttpOnly; SameSite=Strict` cookie. State-changing requests and WebSocket upgrades require an exact configured `Origin`; there is no permissive CORS policy. Under HTTPS, set `SCANSTUDIO_WEB_COOKIE_SECURE=true`.

Control is a separate, tab-scoped capability. `POST /api/v1/control/claim` returns:

```json
{"leaseToken":"opaque-random-value","expiresInSeconds":30}
```

The web UI keeps that value only in the controller page's module memory, never
in browser storage, a shared cookie, or a URL. It sends the value as
`X-ScanStudio-Control-Lease` on controller-only engine requests, heartbeat,
release, and session checks. On secure origins, a Web Lock adds an advisory
per-origin controller-tab guard. A busy Web Lock never blocks a server claim,
because a frozen old page may outlive its server lease. When Web Locks are
unavailable (including trusted-LAN plain HTTP), the same page-local fallback is
used. The gateway's atomic claim remains the authority: concurrent pages can
both try, but only one receives a lease. Refreshing a fallback page drops its
in-memory bearer, so control may need to be reclaimed after the old lease
expires. The default lease is 30 seconds; the web UI heartbeats every 10
seconds, or every third of the configured lifetime when that is shorter.
Foregrounding the page checks immediately, accepted mutations renew the
server lease, and a `423` engine response demotes the page synchronously. A
missing, stale, expired, or other page's token fails closed.
Mutation reservations are revalidated under the lease mutex at the exact
engine-pipe enqueue boundary; slow pipe drain never holds that mutex, and a
released predecessor cannot enqueue after a replacement takes control.
WebSockets need only the auth cookie and exact Origin, so observer pages can
subscribe without taking control.

Engine responses retain their existing shape: `{"result": ...}` or the engine's complete `{"error": ...}` object. Gateway policy errors use the same outer error envelope with gateway-specific codes.

There is no event replay in this first slice. The browser re-reads
`scanner.list` and `scanner.status` before re-enabling controller actions, and
an event-stream interruption makes any active preview fail closed so the user
must request a fresh one. Later scan-capable phases still need authoritative
project/job hydration and bounded replay before terminal job events can be
exposed safely.

## Local development

Python 3.13 or newer is required.

```sh
cd ports/tauri/app
npm ci
npm run build:web

cd ../../../app/ScanStudio/engine
cargo build --locked

cd ../../../ports/web
uv sync --locked --extra test
SCANSTUDIO_ENGINE_PATH=../../app/ScanStudio/engine/target/debug/scanstudio-engine \
SCANSTUDIO_WEB_STATIC_DIR=../tauri/app/dist \
uv run scanstudio-web
```

The default bind is `127.0.0.1:8787`. No deployment token is required only in that loopback-only development mode; requests are still limited to explicit loopback origins. The defaults include the gateway's `8787` origin and Vite's loopback `1420` development origin. To use another frontend port, set `SCANSTUDIO_WEB_ALLOWED_ORIGINS` explicitly to its exact origin.

Run gateway tests with the fake engine only:

```sh
cd ports/web
uv run --locked --extra test pytest
```

The tests do not import scanner transports, configure a bridge, or perform live operations.

## Docker / Unraid simulator preview

The multi-stage image builds the existing Vite application, compiles the existing Rust engine, installs the Python gateway, and copies only runtime artifacts into a non-root Python 3.13 image. Build stages are digest-pinned, and the repository license and third-party notices are retained at `/opt/scanstudio/licenses`. Build context must be the repository root; Compose handles that automatically.

```sh
export SCANSTUDIO_WEB_TOKEN="$(openssl rand -hex 32)"
export SCANSTUDIO_WEB_ALLOWED_ORIGINS="http://your-unraid-host:8787"
docker compose -f ports/web/compose.yaml up --build
```

For access beyond a trusted local network, use HTTPS through a trusted reverse proxy or a private VPN, set the exact `https://host[:port]` origin, and set `SCANSTUDIO_WEB_COOKIE_SECURE=true`. The access token protects the application, but plain HTTP does not protect that token from network observers.

The container intentionally has no `devices`, `privileged`, bridge command, motion authorization, or scan-output volume. Those boundaries must be designed and reviewed as a later hardware-capable phase.

This source milestone is not yet a published container release. Before an
image is distributed, generate and verify a dependency-complete notice/SBOM
for the locked Python, JavaScript, Rust, and base-image closure; the copied
repository notices are a floor, not that release evidence.

Do not run Uvicorn with multiple workers or reload mode. Sessions, the controller lease, and the exactly-one engine supervisor are process-local correctness boundaries; the `scanstudio-web` entry point always runs one worker.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCANSTUDIO_ENGINE_PATH` | `scanstudio-engine` | Fixed executable path; never evaluated by a shell |
| `SCANSTUDIO_WEB_BIND` | `127.0.0.1` | Listen address |
| `SCANSTUDIO_WEB_PORT` | `8787` | Listen port |
| `SCANSTUDIO_WEB_TOKEN` | unset | Required for every non-loopback bind |
| `SCANSTUDIO_WEB_ALLOWED_ORIGINS` | loopback origins | Comma-separated exact HTTP(S) origins; required for non-loopback binds |
| `SCANSTUDIO_WEB_COOKIE_SECURE` | inferred from HTTPS-only origins | Mark the session cookie Secure |
| `SCANSTUDIO_WEB_STATIC_DIR` | unset | Existing simulator-web Vite `dist` directory to serve |
| `SCANSTUDIO_WEB_LEASE_TTL_SECONDS` | `30` | Controller lease lifetime, 5–300 seconds |
| `SCANSTUDIO_WEB_SESSION_TTL_SECONDS` | `43200` | In-memory browser session lifetime |
| `SCANSTUDIO_WEB_MAX_AUTH_SESSIONS` | `256` | Hard cap on active authenticated browser sessions |
| `SCANSTUDIO_WEB_MAX_EVENT_SUBSCRIBERS` | `64` | Hard cap on active event WebSockets |
| `SCANSTUDIO_WEB_ENGINE_WRITE_TIMEOUT_SECONDS` | `5` | Fail-closed timeout for a blocked engine stdin pipe |

When `SCANSTUDIO_WEB_STATIC_DIR` is explicitly set, startup fails unless that
directory contains both `index.html` and the compatible
`scanstudio-web-runtime.json` emitted only by `npm run build:web`. An ordinary
desktop build therefore cannot be served accidentally, and readiness never
reports success for a configured but incompatible bundle.

All browser sessions and leases are intentionally ephemeral and are invalidated when the gateway restarts.
