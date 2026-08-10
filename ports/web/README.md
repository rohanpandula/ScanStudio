# ScanStudio web gateway

This directory contains the first browser/headless vertical slice for ScanStudio. It serves the existing React/Vite application, supervises one existing `scanstudio-engine` child, and relays the engine's protocol over HTTP and WebSocket endpoints protected by either the default token mode or an explicit trusted-LAN peer mode.

This slice is deliberately simulator-only. The gateway removes `SCANSTUDIO_BRIDGE_CMD`, `SCANSTUDIO_HW_MOTION`, and every `SCANSTUDIO_WEB_*` gateway secret/configuration variable from the engine environment, verifies at startup that `scanner.list` exposes exactly `sim-ls5000-0`, and has no USB/device mapping or privileged container mode. It does not configure the Python bridge, Nikon hardware, media motion, capture, project paths, or output storage.

## Runtime contract

The gateway sends `engine.hello` as the child's first NDJSON request, owns all correlation IDs, drains stderr, and starts serving only after the handshake and simulator-device check succeed. Engine events are broadcast unchanged to bounded per-observer queues and a bounded observer set. A slow or excess observer is disconnected rather than blocking the engine reader or growing memory without limit.

The engine child remains an exact executable invocation connected only through
its standard-input, standard-output, and standard-error pipes. Authentication
mode never adds an engine TCP listener, socket address, or gateway network
configuration to the child process.

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

Authentication mode is explicit and defaults to `token`. In token mode, login
exchanges the deployment token for an opaque `HttpOnly; SameSite=Strict`
cookie. A nonblank token is required even when the gateway binds to loopback.

`trusted-lan-no-login` mode has no login secret or browser auth cookie. Instead,
the gateway checks the actual ASGI socket peer on every API request, static-file
request, and WebSocket upgrade. It accepts only IPv4 loopback, RFC1918
(`10/8`, `172.16/12`, `192.168/16`), IPv6 loopback, and IPv6 ULA (`fc00::/7`).
IPv4-mapped forms of the accepted IPv4 ranges are accepted. Public, malformed,
missing, link-local, carrier-grade NAT (`100.64/10`), multicast, unspecified,
and other reserved peers are rejected. `Forwarded`, `X-Forwarded-For`, and
`X-Real-IP` are rejected rather than trusted; Uvicorn proxy-header processing
also remains disabled.

LAN mode also refuses to start unless the listen address is `0.0.0.0`, an
exact RFC1918 address, or an exact IPv6 ULA address. Loopback-only binds,
hostnames, public literals, link-local literals, and the IPv6 wildcard `::` are
rejected. Use token mode for those bind configurations.

This LAN classification is a best-effort convenience boundary, not network
authentication. NAT, port forwarding, source NAT, or a private-address reverse
proxy can make an untrusted client appear to have an allowed socket peer. Those
topologies are unsupported in `trusted-lan-no-login` mode. Use the default token
mode through a trusted HTTPS proxy or private VPN instead. Do not expose the LAN
mode port to the Internet.

Both modes retain the exact configured `Origin` requirement for state-changing
requests and WebSocket upgrades; there is no permissive CORS policy. Under
HTTPS token mode, set `SCANSTUDIO_WEB_COOKIE_SECURE=true`.

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

Python 3.13 or newer is required for development. The separately downloadable
macOS runtime is pinned more narrowly to CPython 3.13.14 and does not accept a
different patch release.

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
SCANSTUDIO_WEB_TOKEN="$(openssl rand -hex 32)" \
uv run scanstudio-web
```

The default bind is `127.0.0.1:8787` in token mode. Token mode requires a
deployment token for loopback and non-loopback binds alike. Requests are still
limited to explicit loopback origins. The defaults include the gateway's
`8787` origin and Vite's loopback `1420` development origin. Bind and port
remain configurable with `SCANSTUDIO_WEB_BIND` and `SCANSTUDIO_WEB_PORT`. To use
another frontend port, set `SCANSTUDIO_WEB_ALLOWED_ORIGINS` explicitly to its
exact origin.

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

The Compose default remains token mode and fails gateway startup if its token is
missing. To opt into the narrower trusted-LAN topology explicitly:

```sh
export SCANSTUDIO_WEB_AUTH_MODE=trusted-lan-no-login
unset SCANSTUDIO_WEB_TOKEN
export SCANSTUDIO_WEB_ALLOWED_ORIGINS="http://your-unraid-host:8787"
docker compose -f ports/web/compose.yaml up --build
```

Only use that mode when browsers connect directly from one of the documented
private ranges. Do not place it behind a reverse proxy, source-NAT gateway,
Internet-facing port forward, or any other hop that changes the socket peer.

For access beyond a trusted local network, use HTTPS through a trusted reverse proxy or a private VPN and set the exact `https://host[:port]` origin. The gateway and Compose then infer `SCANSTUDIO_WEB_COOKIE_SECURE=true`; an explicitly exported value still overrides that inference. The access token protects the application, but plain HTTP does not protect that token from network observers.

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
| `SCANSTUDIO_WEB_BIND` | `127.0.0.1` | Listen address; LAN mode permits only `0.0.0.0`, RFC1918, or IPv6 ULA |
| `SCANSTUDIO_WEB_PORT` | `8787` | Listen port |
| `SCANSTUDIO_WEB_AUTH_MODE` | `token` | `token` or explicit `trusted-lan-no-login` socket-peer mode |
| `SCANSTUDIO_WEB_TOKEN` | unset | Required for every bind in token mode; must be unset in LAN mode |
| `SCANSTUDIO_WEB_ALLOWED_ORIGINS` | loopback origins | Comma-separated exact HTTP(S) origins; required for non-loopback binds and all LAN-mode binds |
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
