# Scan Studio Bridge Protocol v1

Contract between the external `scanstudio-bridge` sidecar (GPL-3.0, wraps CoolscanPy, lives outside this repo) and its client (Phase 9's `RealLs5000` backend). This is a second, independent NDJSON-over-stdio boundary that mirrors PROTOCOL.md's style — it is not an extension of PROTOCOL.md and the two protocols never share a wire connection. No GPL code exists in this repo; this file is the wire contract only, read by anyone implementing either side without opening a bridge source file.

## Transport

- The engine spawns the bridge as a subprocess and speaks over the bridge's **stdin/stdout**. stderr is free-form diagnostics.
- **NDJSON**: exactly one JSON object per line, UTF-8, `\n` terminated. The bridge flushes stdout after every line.
- Three wire shapes:
  - **Request** (engine → bridge): `{"id": <u64>, "method": "<name>", "params": {…}}` — `params` may be omitted.
  - **Response** (bridge → engine): `{"id": <u64>, "result": {…}}` or `{"id": <u64>, "error": {"code": "<CODE>", "message": "<human text>", "recoverable": <bool>}}`. Every request gets exactly one response.
  - **Event** (bridge → engine, unsolicited): `{"event": "<name>", "payload": {…}}`. Events may interleave with responses.
- Request `id`s are chosen by the engine, must be unique per connection, and are echoed verbatim.
- **Forward compatibility**: both sides must ignore unknown fields; the engine must ignore unknown event names; the bridge answers unknown methods with `UNKNOWN_METHOD`.
- JSON field names are camelCase on the wire.

## Error codes

`UNKNOWN_METHOD`, `INVALID_PARAMS`, `NOT_CONNECTED`, `ALREADY_CONNECTED`, `DEVICE_NOT_FOUND`, `DEVICE_BUSY`, `NO_PREVIEW`, `UNKNOWN_JOB`, `HW_MOTION_NOT_ARMED`, `HARDWARE_LANE_BUSY`, `EJECT_FAILED`, `FEEDER_PARKED`, `FINGERPRINT_REFUSED`, `MANUAL_REVIEW_REQUIRED`, `REFEED_REQUIRED`, `ROLL_MISMATCH`, `TRANSPORT_SMEAR_DETECTED`, `GEOMETRY_VALIDATION_ERROR`, `SPLIT_ALIGNMENT_ERROR`, `BATCH_INTEGRITY_ERROR`, `NOT_IMPLEMENTED`, `INTERNAL` — 22 total.

`recoverable` is `true` only for `HARDWARE_LANE_BUSY`: retrying the identical request once the lane frees can succeed with no other action. Every other code needs a *different* action first — re-arm the latch, call `roll.approve`, physically refeed the strip, power-cycle the transport — so every other code is `recoverable: false`.

`UNKNOWN_METHOD`, `INVALID_PARAMS`, `NOT_CONNECTED`, `ALREADY_CONNECTED`, `NO_PREVIEW`, `UNKNOWN_JOB`, `HW_MOTION_NOT_ARMED`, `HARDWARE_LANE_BUSY`, and `INTERNAL` are bridge-native (session/protocol-level, no CoolscanPy exception behind them). The remaining codes are a direct rename of a CoolscanPy exception the bridge catches internally:

| CoolscanPy exception | Bridge error code |
|---|---|
| `DeviceNotFound` | `DEVICE_NOT_FOUND` |
| `DeviceBusy` | `DEVICE_BUSY` |
| `EjectFailed` | `EJECT_FAILED` |
| `FeederParked` | `FEEDER_PARKED` |
| `FingerprintRefused` | `FINGERPRINT_REFUSED` |
| `ManualReviewRequired` | `MANUAL_REVIEW_REQUIRED` |
| `RefeedRequired` | `REFEED_REQUIRED` |
| `RollMismatch` (base class, after every mapped subclass) | `ROLL_MISMATCH` — unclassified synchronized refusals, e.g. a stale unit attention breaking a ready group, or completed preview evidence from a different USB topology (added 2026-07-25 after a live case reached the app as `INTERNAL`) |
| `TransportSmearDetected` | `TRANSPORT_SMEAR_DETECTED` — only surfaced after the bridge's retry budget is exhausted (see SAFE-02 guardrails) |
| `GeometryValidationError` | `GEOMETRY_VALIDATION_ERROR` |
| `SplitAlignmentError` | `SPLIT_ALIGNMENT_ERROR` |
| `BatchIntegrityError` | `BATCH_INTEGRITY_ERROR` |
| `NotImplementedError` | `NOT_IMPLEMENTED` |

## Methods

Errors that can occur on any request — `UNKNOWN_METHOD` (unrecognized method name) and `INTERNAL` (unexpected bridge fault) — are omitted from the per-method lists below.

| Method | Params | Result | Notable errors |
|---|---|---|---|
| `bridge.hello` | `{clientName: string, protocolVersion: 1}` | `{bridgeName: "scanstudio-bridge", bridgeVersion: string, protocolVersion: 1, capabilities: ["ls5000-coolscanpy"]}` | `INVALID_PARAMS` |
| `bridge.shutdown` | `{}` | `{}` | — |
| `device.list` | `{}` | `{devices: [DeviceInfo]}` | — |
| `device.open` | `{deviceId: string}` | `{device: DeviceInfo, status: DeviceStatus}` | `DEVICE_NOT_FOUND`, `ALREADY_CONNECTED`, `DEVICE_BUSY` |
| `device.status` | `{}` | `DeviceStatus` | `NOT_CONNECTED` |
| `device.close` | `{}` | `{}` | `NOT_CONNECTED`, `HARDWARE_LANE_BUSY` |
| `roll.preview` | `{material: "colorNegative"\|"blackAndWhiteNegative", slots?: [number]}` | `{accepted: true}` | `NOT_CONNECTED`, `HW_MOTION_NOT_ARMED`, `HARDWARE_LANE_BUSY`; via `roll.previewError`: `FEEDER_PARKED`, `REFEED_REQUIRED`, `DEVICE_BUSY`, `ROLL_MISMATCH` |
| `roll.approve` | `{slot: number}` | `{}` | `NOT_CONNECTED`, `NO_PREVIEW` |
| `roll.setSpacingOffset` | `{slot: number, offsetRows: number}` | `{thumbnail: Thumbnail}` | `NOT_CONNECTED`, `NO_PREVIEW`, `INVALID_PARAMS` |
| `scan.start` | `{slots: [number], recipe: CaptureRecipe, output: OutputSpec}` | `{jobId: string}` | `NOT_CONNECTED`, `NO_PREVIEW`, `HW_MOTION_NOT_ARMED`, `HARDWARE_LANE_BUSY`, `INVALID_PARAMS`, `REFEED_REQUIRED`; via `scan.error`/`scan.frameFailed`: `ROLL_MISMATCH` |
| `scan.stop` | `{jobId: string}` | `{acknowledged: bool}` | `UNKNOWN_JOB` |
| `device.eject` | `{}` | `{}` | `NOT_CONNECTED`, `HW_MOTION_NOT_ARMED`, `HARDWARE_LANE_BUSY`, `EJECT_FAILED`, `FEEDER_PARKED` |

`device.list` always reflects a fresh device enumeration (no caching). `device.open` emits a `device.status` event on success, same as `device.close`. `device.status` returns the bridge's current session state; it never triggers hardware I/O.

### `bridge.hello`

Must be the first request; anything sent before it gets `INVALID_PARAMS`. Only `protocolVersion: 1` is supported — any other value is `INVALID_PARAMS`. Separately, at process startup — before this or any other request is even read off stdin — the bridge records a `bridge.provenance` telemetry entry (additive, 2026-07-23; not a wire response, `bridge.hello`'s own result is unchanged); see "`bridge.provenance` (additive, 2026-07-23)" near the end of this document.

### `bridge.shutdown`

`{}` → `{}`; then the bridge releases the hardware lane lock if held, closes the open device if one is open, best-effort bounded-cancels an in-flight job, flushes the response, and exits 0. Cancellation is bounded so an active operation cannot keep shutdown waiting on it indefinitely.

### `device.close`

Returns `HARDWARE_LANE_BUSY` while a job holds the lane — the safety rule holds even if the client misbehaves and tries to close underneath an active scan.

### `roll.preview` (MOTION-CAPABLE)

`material` is `"colorNegative"` or `"blackAndWhiteNegative"`. `slots` is optional and filters only *which* `roll.thumbnail` events fire — the bridge always physically reads the full roll regardless of `slots`. Immediate ack `{accepted: true}`, then one `roll.thumbnail` event per detected slot, then `roll.previewComplete`. This is SAFE-02's "feed" — there is no method literally named `feed` (see SAFE-02 guardrails).

### `roll.approve`

Records manual-review approval for one slot. Not motion-capable — no transport movement, no latch check. Required before scanning any slot whose last `roll.thumbnail` event had `needsApproval: true`; omitting it surfaces as `MANUAL_REVIEW_REQUIRED` when that slot's turn in `scan.start` comes up.

### `roll.setSpacingOffset`

Updates one detected slot's absolute native-preview-row offset in the current
CoolScanPy roll session and returns the freshly re-cropped `Thumbnail`. This is
not a display pan or a post-capture pixel crop: the active roll session consumes
the same offset when that slot is captured. It is non-motion-capable, so it
does not check the motion latch or move film. Valid offsets are `0...144` for
slot 1 and `-144...144` for every other slot. Changing an offset invalidates
that slot's prior manual approval.

### `scan.start` (MOTION-CAPABLE)

`slots` must be a subset of the last preview's detected slots. `recipe` is validated per "Recipe constraints" below — a mismatch is `INVALID_PARAMS` naming the first mismatched field, never silently substituted. `output` gives the destination directory plus a filename template. Once accepted, a worker thread reports progress and outcome purely through events: `scan.progress`, `scan.frameRetrying` (zero or more per slot), `scan.frameCompleted`, then `scan.completed`. Only one job runs at a time; a concurrent second `scan.start` gets `HARDWARE_LANE_BUSY`.

The engine may supply a private, job-owned `output` route when the user has elected not to retain a master TIFF. It remains a normal bridge capture contract: the bridge must write RGB plus applicable IR/meter artifacts exactly at that route and report those exact paths. The private route is not a user destination and must never be inferred from a project manifest or receipt as a retained output.

**Scan-worker soft timeout (additive, 2026-07-23).** The worker wraps every CoolscanPy/file call it makes (per-slot `Roll.scan`, each written TIFF) in call-boundary telemetry (one JSONL line entering the call, one leaving it — see "Telemetry" below). A second, independent watchdog thread polls that same state: if the call currently in flight has been entered for longer than `SCANSTUDIO_BRIDGE_SCAN_TIMEOUT` seconds (default `900`, env-overridable, read once per `scan.start`) with no matching exit yet, it writes one more telemetry line (`outcome: "timeout"`, naming the stuck call) and emits `scan.error` for the job — see the Events section below for its shape. This is report-only: the watchdog never kills, interrupts, or joins the worker thread, and never closes the device or touches the hardware lane — the worker thread and whatever call it is blocked inside are left running exactly as they were. If that call eventually does return on its own, the worker's normal completion sequence (up to and including `scan.completed`) still fires afterward, independent of whatever the watchdog already reported. Discovered live: a real fine-scan worker entered its transport call and never returned, with no diagnostic of any kind — this closes that gap by naming the stuck call instead of guessing.

**Durable per-frame failure reasons (additive, 2026-07-23).** Whenever a slot fails during `scan.start` — any exception the worker catches from the transport (a bounded-retry-exhausted transport fault, a `BridgeError` translated from a CoolscanPy exception, or a genuinely unexpected exception), or a per-slot skip a transport already knows the cause of without raising (today only `coolscanpy.ManualReviewRequired`, reported via the same internal summary the transport already returns) — the worker records one telemetry entry (`method: "scan.frameFailed"`, `outcome: "failed"`, `slot`, `reason_class` and `reason_message` naming the exact underlying exception, `elapsed` seconds since this job's worker started, plus any CoolscanPy-specific exception attributes present on it, e.g. a `TransportSmearDetected`'s `assessment`) and emits one `scan.frameFailed` event (see Events above) *before* `scan.completed`. This is additive alongside whatever job-level event that same failure already produces (`hardware.anomaly` for a retry-exhausted transport fault, `scan.error` for every other exception path) — `scan.frameFailed` always names the specific frame and its exact cause first. The `scan.start` telemetry closure that reports this job's own outcome (`outcome: "ok"` or `"error"`) keeps its pre-existing shape but gains `reasons: {slot: reason_class}` whenever at least one slot's failure reason is already known by the time that closure is written.

**Phase-boundary telemetry (additive, 2026-07-23).** Alongside the call-boundary `scan.call` telemetry above, the worker also records `scan.phase` entries (identical `enter`/`exit`/`elapsed_seconds` shape) for each coolscanpy-adjacent phase the transport genuinely exposes as separately observable: one `fine_scan:slot{N}` phase spanning a slot's entire fine-scan retry loop, and one phase per file write (`file_write.rgb:slot{N}`, `.ir:slot{N}`, `.meter:slot{N}`) — the file writes are also still recorded as `scan.call` entries under the identical name, since a write is simultaneously a fine-grained SDK/file call and a conceptual workflow step; `fine_scan:slot{N}` has no such `scan.call` sibling, since it is coarser than (wraps) the `roll.scan:slot{N}` `scan.call` entries already recorded per retry attempt underneath it. CoolscanPy exposes no separate position/autofocus/auto-exposure/read-pass sub-calls a caller can instrument individually — confirmed against CoolscanPy's own roll-feeder engine, which runs an entire fine-scan attempt inside one process-isolated subprocess call with no intermediate hook; `fine_scan:slot{N}` is the finest phase boundary honestly available at the transport level. Every `scan.call`/`scan.phase` `"exit"` entry (additive, 2026-07-23) also now carries `call_outcome: "return"|"raise"` and, only when raised, `exception_class` naming the raised exception's type — previously an `"exit"` entry looked identical whether the wrapped call returned normally or raised.

**Batch clamp-and-retry on a stale slot count (additive, 2026-07-25).** If `scan_many`'s own fresh transport re-read finds fewer scanner-addressable slots than `roll.preview` reported (a `RollMismatch` naming the out-of-table bound, e.g. "requested frame 38 is outside the scanner-addressable table 1..37"), the bridge drops every requested slot above that bound (each reported via `scan.frameFailed`) and retries `scan_many` exactly once with the surviving subset, instead of failing every requested slot when the still-addressable ones remain perfectly scannable.

**Attempts-root persistence (additive, 2026-07-23).** The bridge passes CoolscanPy's `Device.roll()` a caller-owned `attempts_root` (a fresh UUID directory under `~/.scanstudio/coolscanpy-attempts/`, one per `Roll` — i.e. once per `roll.preview` call that creates a new `Roll`, not per `scan.start` job, since the `Roll` already exists by the time any job starts) instead of accepting CoolscanPy's own default (a bare temp directory `Roll.close()` deletes the instant that `Roll` closes). This keeps a failed attempt's journal/manifest/raster evidence on disk past device close, for post-mortem inspection, instead of it surviving only by luck in a randomly-named, never-reported temp directory. The path is included as `attempts_root` in the `scan.start` telemetry closure (`outcome: "ok"` or `"error"`) whenever the active transport has one — `MockTransport` does not, so it is simply absent there, never reported as `null`.

### `scan.stop`

Stops **between transfers** only (mirrors CoolscanPy's `Roll.safe_stop()`): the in-flight slot always finishes and is reported via `scan.frameCompleted`, the next slot is skipped, no other slots are attempted. There is no `"immediate"` mode — no safe immediate abort exists against real hardware (see "Differences from PROTOCOL.md"). `acknowledged: false` if the job already reached a terminal state.

### `device.eject` (MOTION-CAPABLE)

Returns `HARDWARE_LANE_BUSY` while a scan job holds the lane — mirrors PROTOCOL.md's `scanner.eject`/`SCANNER_BUSY` rule. This gate is for a *client-initiated* eject only; it is separate from the bridge's own internal anomaly-response eject (see SAFE-02 guardrails), which does not go through this method at all.

**`{}` means confirmed ejected, never anything less (2026-07-26).** A transport that reports the film did not come out, a capability-gated no-op, or any accepted-without-progress outcome surfaces as a typed error, never as `{}`. This rule exists because an LS-5000 can acknowledge an eject command while the parked mechanism does not actuate.

- `EJECT_FAILED` — the eject could not run or the transport reported not-ejected. On the current CoolscanPy pin a real eject needs the `[scanner]` extra plus SANE in the bridge's own environment, so on a rig without them every real `device.eject` is this error, with the message naming the missing dependency.
- `FEEDER_PARKED` — the typed stalled outcome: the driver's traced eject reported accepted-without-confirmed-clear (CoolscanPy `FeederParked`). The film state is unknown-but-likely-inside, the session is left untouched, and a power cycle is the only demonstrated recovery. A client must NEVER auto-retry this (or any) eject outcome — retry decisions belong to the operator at the machine.

The bridge executes the eject against the open roll session when one exists (this is where CoolscanPy's vendor-traced `RESERVE_UNIT`-guarded held-session eject lands once the pin carries it — proven live 2026-07-20 from a normal post-traversal state), falling back to the device-level eject otherwise. Operationally, eject is only known-good from a normal post-traversal state; from a short-strip end-stop park or a wedged transport the eject can be accepted-but-inert with no probe able to distinguish that in advance (same incident file).

On success the film is out, so the preview no longer describes loaded media: the bridge invalidates its roll session (`previewEstablished` false, `slotCount` null), `scan.start` is back behind `NO_PREVIEW`, and a `device.status` event is emitted — after the lane release, per the terminal-event ordering rule below, so a client that polls on it always observes the lane free.

## Types

Notation: `Type` references another type defined in this block; `Type[]` is an array; `Type|null` is nullable; `[T, T]` is a fixed-length tuple; `{[key: string]: Type}` is a string-keyed map. Every field name below is the mechanical camelCase conversion of the matching CoolscanPy dataclass field, with one documented exception noted inline.

```
DeviceInfo
  deviceId: string                        // renames CoolscanPy's DeviceInfo.id
  vendor: string
  model: string
  capabilities: Capabilities

Capabilities
  irChannel: bool
  supportedDpi: number[]
  supportedDepths: number[]
  multiSample: bool
  supportedMultisamplePasses: number[]
  adapterFrameCapacity: number|null
  adapterFrameControl: bool
  autoExposure: bool
  registeredGeometry: bool
  canEject: bool

DeviceStatus
  connected: bool
  deviceId: string|null
  previewEstablished: bool
  slotCount: number|null                  // null until previewEstablished is true
  activeJobId: string|null
  laneHeld: bool
  motionArmed: bool                       // live re-check result, never a cached value (see SAFE-02 guardrails)
  filmPresent: bool|null                  // live, no-motion film-presence read; null when no trustworthy verdict is available (see prose below)

CaptureRecipe
  resolutionDpi: number
  bitDepth: number
  multisamplePasses: number
  channels: "rgb"|"rgbi"
  autofocus: bool
  autoExposure: bool

OutputSpec
  destination: string
  filenameTemplate: string                // "####" -> zero-padded slot number
  slotOutputs?: {string: {destination: string, filenameTemplate: string}} // optional exact decimal-slot map for one batch

Thumbnail
  slot: number
  boundaryRows: [number, number]
  spacingOffset: number
  needsApproval: bool
  warnings: string[]
  imagePath: string

ScanProgress
  jobId: string
  slot: number
  ordinal: number
  totalSlots: number
  fraction: number
  message: string

ExposureVector
  focusPosition: number
  exposureMultiplier: number
  redExposureUs: number
  greenExposureUs: number
  blueExposureUs: number

ClippingTelemetry
  fractions: [number, number, number]
  clipLevel: number
  warningFraction: number
  warning: bool

FocusDetailTelemetry
  method: string
  verdict: "measured"|"indeterminate"
  score: number|null
  textureSpan: number

TransportSmearAssessment
  verdict: "clean"|"smear"|"indeterminate"
  startRow: number|null
  suffixRows: number
  minimumMatches: number
  tailMedianRms: number|null
  tailMinCorr: number|null
  preTailMedianRms: number|null
  textureSpan: number|null
  reason: string

ArtifactEvidence
  sha256: string
  byteLength: number
  shape: number[]
  dtype: string

ApprovalReceipt
  reviewedFingerprintSha256: string
  slot: number
  spacingOffset: number
  thumbnailSha256: string
  reviewedLookupRow: number
  reviewedNativeOrigin: number
  reviewReasons: string[]

ExposureAuthority
  rgbSource: string
  irSource: string
  commandedChannelsRaw10ns: {R: number, G: number, B: number, IR: number}
  activeControllerChannelsRaw10ns: {R: number, G: number, B: number, IR: number}
  deviceBoundClampedChannelsRaw10ns: {R?: number, G?: number, B?: number}
  deviceExposureBoundsRaw10ns: [number, number]

ScanReceipt
  version: number
  slot: number
  spacingOffset: number
  dpi: number
  depth: number
  deviceId: string
  deviceModel: string
  reviewedFingerprintSha256: string
  freshFingerprintSha256: string
  manualApproval: ApprovalReceipt|null
  exposure: ExposureVector
  splitAlignment: object|null             // opaque, see note below
  clipping: ClippingTelemetry
  focusDetail: FocusDetailTelemetry
  transportSmear: TransportSmearAssessment
  artifacts: {[key: string]: ArtifactEvidence}
  storageTransform: string
  rgbPath: string
  irPath: string|null
  meterRgbiPath: string|null
  exposureAuthority: ExposureAuthority|null
```

`$ScanStudioSequence(N)` is an additive engine-to-bridge, job-local exact-name marker (`N` is a positive decimal integer). It resolves to just `N`, with no slot substitution. The engine uses it only after reserving a single-`#` automatic sequence before dispatch; it is not a user template token and must never be persisted in a project manifest, output recipe, or receipt.

`splitAlignment` is always `null` for the one wired route: single-pass RGBI4 shares one pass for RGB and IR, so CoolscanPy never populates a separate registration record for it. It stays an opaque nullable object rather than being fully typed until some future route actually populates it. `rgbPath`/`irPath` are bridge-added fields — CoolscanPy's roll engine returns in-memory arrays, never files; the bridge is what writes them to disk and records the paths (see "Image payloads").

`storageTransform` is mandatory, never `null` or empty: it is the versioned identifier for the numpy transform CoolscanPy applied between the scanner-native RGB/IR planes it captured and this receipt's `rgbPath`/`irPath` orientation, mirrored verbatim from CoolscanPy's own `Receipt.storage_transform`. Today every live capture reports exactly one value, `"swapaxes01-scanner-native-to-nikon-render-parity-v2"` (`coolscanpy.types.DIGITAL_ICE_STORAGE_TRANSFORM`). A historical value, `"rot90k1-scanner-native-to-storage-v1"`, may appear in archives whose provenance predates this field, but it is never emitted by a live bridge. A consumer that needs to bring CoolscanPy's main raster (`rgbPath`/`irPath`) into the same coordinate system as `meterRgbiPath` (scanner-native) MUST branch on this value and MUST refuse rather than guess when it sees a value it does not recognize. The two known transforms differ by a vertical flip, so silently picking one is worse than refusing.

`Thumbnail.imagePath` is also bridge-added, not a CoolscanPy path: the bridge transposes that slot's raw scanner-linear HxWx3 uint16 preview crop with `swapaxes(0,1)` (the same scanner-native-to-Nikon-render orientation as a saved capture; no axis is flipped), applies a 0.5th/99.5th percentile stretch, and writes the already-thumbnail-sized result as an 8-bit TIFF. A `roll.preview` uses `~/.scanstudio/previews/{preview-session-uuid}/slot-{NNNN}.tif`; every `roll.setSpacingOffset` response uses another fresh UUID path so image caches cannot keep showing the previous crop. This does not relax "Image payloads"'s no-bytes-on-the-wire rule: only a path crosses the wire, exactly like `rgbPath`/`irPath` already do.

`DeviceStatus.filmPresent` is a live, no-motion film-presence read, distinct from `previewEstablished` (which only means "a preview has run this session," never "film is physically loaded right now"). The bundled CoolScanPy asks the exact opened LS-5000 with TEST UNIT READY: `true` means the scanner reports medium gripped, `false` means its verified MEDIUM NOT PRESENT sense was observed, and `null` means no trustworthy verdict was available (for example, an active capture owns the interface, an older dependency lacks the method, or the scanner returned an unrecognised/malformed reply). `null` is never interpreted as absence. Presence is not motion readiness: a short strip parked at the transport end-stop can still report `true`.

CoolscanPy's `Frame.meter_rgbi` (a 285dpi auto-exposure prepass) is on `ScanReceipt` as `meterRgbiPath` starting this phase (Phase 10): the bridge writes `frame.meter_rgbi` (an HxWx4 uint16 array) to `{stem}_METER.tif` alongside the RGB/IR files, unconditionally whenever CoolscanPy supplies it — never fabricated; `null` only if absent.

`exposureAuthority` is a best-effort, additive copy of CoolscanPy's per-frame `active_exposure_authority` journal block. It distinguishes the guarded Nikon-parity RGB command from the active controller's accepted solve, preserves the controller-owned IR command, and records any RGB channels clamped to the device exposure window. It is `null` when the journal block is absent, malformed, or cannot be read; that telemetry failure never invalidates an otherwise completed frame receipt.

## Events

- `device.status` `{status: DeviceStatus}` — on any connection/session state change.
- `roll.thumbnail` `{slot: number, thumbnail: Thumbnail}` — one per detected slot during `roll.preview`.
- `roll.previewComplete` `{count: number, fingerprint: string}` — terminates a `roll.preview` sequence; `fingerprint` is the roll's bound identity, later compared against a fresh read at scan time (`FINGERPRINT_REFUSED` on mismatch).
- `scan.progress` `{jobId: string, slot: number, ordinal: number, totalSlots: number, fraction: number, message: string}` — periodic, while a slot is actively transferring.
- `scan.frameRetrying` `{jobId: string, slot: number, attempt: number, reason: string}` — bridge-specific; fires once per bounded-retry attempt (see SAFE-02 guardrails).
- `scan.frameCompleted` `{jobId: string, slot: number, receipt: ScanReceipt}`
- `scan.frameFailed` `{jobId: string, slot: number, code: string, message: string}` — additive (2026-07-23); fires for any slot failure before `scan.completed`, alongside whatever job-level event that same failure already produces (`hardware.anomaly` or `scan.error`) — see "Durable per-frame failure reasons" under `scan.start` above. `code` is one of the Error codes above.
- `scan.completed` `{jobId: string, summary: {completed: number[], failed: number[], stopped: bool}}` — emitted for every terminal job state. A slot present in the original `scan.start` `slots` list but absent from both `completed` and `failed` was never attempted (skipped after `scan.stop`); there is no separate "skipped" list.
- `hardware.anomaly` `{jobId: string|null, slot: number|null, code: string, message: string, ejected: bool}` — fires whenever the anomaly-halt sequence runs (see SAFE-02 guardrails).

## SAFE-02 guardrails

Three methods are MOTION-CAPABLE: `roll.preview`, `scan.start`, `device.eject`.

**Armed latch.** Re-checked live — never cached — on every motion-capable request: env `SCANSTUDIO_HW_MOTION == "1"` AND file `~/.scanstudio/hw-motion-armed` exists as a regular file with non-empty stripped authorization text. Either condition failing is `HW_MOTION_NOT_ARMED`. The packaged `ScanStudioLauncher` prepares both halves automatically when it selects a hardware bridge; its environment half ends with that app process, so a persistent latch alone cannot authorize later motion. Launching sends no hardware command — `roll.preview`, `scan.start`, and `device.eject` remain explicit actions. Direct bridge/developer launches must prepare their own authorization. There is no method literally named `feed` — `roll.preview` stands in for it, since a preview requires the same physical roll motion as a feed.

**Single hardware lane.** An advisory lock file, `~/.scanstudio/hw-lane.lock`, is held for the duration of any motion-capable operation. A second process contending for it gets `HARDWARE_LANE_BUSY`.

**Bounded retries.** A `scan.start` slot whose fine-scan attempt raises CoolscanPy's transport-smear fault is retried up to 2 additional times (3 attempts total), with a `scan.frameRetrying` event before each retry. If the retry budget is exhausted, the bridge runs the anomaly halt below and the slot's terminal error is `TRANSPORT_SMEAR_DETECTED`.

**Anomaly halt.** Triggered by: `FeederParked`, `FingerprintRefused`, `BatchIntegrityError`, `GeometryValidationError`, `SplitAlignmentError`, or a retry-exhausted transport smear. Sequence: best-effort eject (the armed latch is not re-checked here — the session is already armed and holding the lane), release the lane, write a telemetry entry, emit `hardware.anomaly`, fail the job. `ManualReviewRequired` and `RefeedRequired` do **not** trigger anomaly halt: neither implies an in-progress hardware fault mid-transport — `ManualReviewRequired` is a pre-flight check the bridge makes before attempting motion on a given slot (surfaces as that slot's failure, no eject needed since the slot was never fed), and `RefeedRequired` is a whole-batch precondition failure surfaced synchronously from `scan.start` itself, before any per-slot motion begins.

**Telemetry.** Every hardware-bound call appends one JSONL line under `~/.scanstudio/hw-telemetry/` before the call and one line after the outcome is known. Within `scan.start` specifically (additive, 2026-07-23), this is further subdivided per call the worker makes internally (`method: "scan.call"`, or for a coarser conceptual phase, `"scan.phase"` — additive, 2026-07-23, see "Phase-boundary telemetry" under `scan.start` above; `outcome: "enter"|"exit"|"timeout"`, a `call` field naming the specific operation, e.g. `roll.scan:slot4`, and on `"exit"`, `call_outcome: "return"|"raise"` plus `exception_class` when raised) — see "Scan-worker soft timeout" under `scan.start` above. A per-slot failure additionally gets its own `scan.frameFailed` entry (see "Durable per-frame failure reasons" under `scan.start` above), and the bridge records a one-time `bridge.provenance` entry at startup (see `bridge.hello` above).

## Recipe constraints

The only wired `material: "colorNegative"` combination is fixed: `resolutionDpi: 4000`, `bitDepth: 16`, `multisamplePasses: 4`, `channels: "rgbi"`, `autofocus: true`, `autoExposure: true` — fixed by the LS-5000's single-pass protocol, not client-configurable.

> **`capabilities.multiSample` semantics (clarified 2026-07-23):** the bool means "the transport exposes a *variable* multi-sample control", NOT "the hardware can multisample." The LS-5000 multisamples on every wired capture — fixed 4× per the contract above. The real CoolscanPy transport reports `false` here (no adjustable knob) while MockTransport reports `true`; clients must not interpret `false` as "no multisampling" and must not encode the mock's `true` as real-device behavior. `Capabilities.supportedMultisamplePasses` is the device-sourced accepted set for `CaptureRecipe.multisamplePasses` — always `[4]` for the LS-5000 today, per the fixed recipe constraint above — replacing what was previously hardcoded client-side; a future device with different pass options (e.g. a 9000 ED) supplies its own list here instead of requiring a code change. Any other value for any of those fields is `INVALID_PARAMS`, naming the first mismatched field. `"blackAndWhiteNegative"` fine scanning always returns `NOT_IMPLEMENTED` (preview still works for it). MockTransport enforces this identical contract by default, plus an opt-in permissive mode used only to test the rejection path itself.

> **Debug recipe gate (lab-only, additive, 2026-07-23):** when the bridge process has env `SCANSTUDIO_BRIDGE_DEBUG_RECIPE` set to exactly `"1"`, `scan.start`'s recipe validation for `material: "colorNegative"` ALSO accepts a second, fixed diagnostic recipe: `resolutionDpi: 1000`, `bitDepth: 8`, `multisamplePasses: 1`, `channels: "rgb"` — `autofocus`/`autoExposure` are unconstrained under this override (either boolean is accepted for either field). This exists to isolate which phase of a real scan is failing (see the `scan.phase` telemetry above) using a fast, low-res, single-pass, no-IR capture instead of waiting on the full fixed recipe above. Purely additive, never a replacement: the primary fixed recipe is still accepted whether or not the env var is set, `Capabilities.supportedMultisamplePasses` is unchanged by this gate (it advertises `[4]` regardless), and default behavior (env unset, or set to anything other than exactly `"1"`) is byte-identical to before this override existed. This gate is for a lab bench session only — a client must never set it as part of normal operation.

## Image payloads

No image bytes — base64 or otherwise — ever appear on the wire. `scan.start`'s `output.destination` and `output.filenameTemplate` (`####` → zero-padded slot number) tell the bridge where to write each slot's RGB TIFF (16-bit, tagged at `recipe.resolutionDpi`), plus, when capturing IR, an `_IR` sidecar (`{stem}_IR.tif`, matching CoolscanPy's own internal naming). `slotOutputs`, when present, must contain exactly each requested decimal slot key and supplies that slot's destination/template while preserving one `scan_many` batch. Any resolved path that escapes its selected destination — a `..` traversal, an absolute-path override baked into the template — or aliases another reserved artifact is `INVALID_PARAMS`, checked before any motion. `scan.frameCompleted`'s `receipt` carries the resulting `rgbPath`/`irPath`. `roll.thumbnail` carries no image, only transport bookkeeping.

## Differences from PROTOCOL.md

- `scan.stop` has no `mode` — no safe "immediate" abort exists against real hardware, unlike the simulated engine.
- `Thumbnail` carries transport bookkeeping (`boundaryRows`, `spacingOffset`, `needsApproval`, `warnings`), never an image or a brightness/tint pair.
- `CaptureRecipe.autofocus`/`.autoExposure` are plain booleans, distinct from the engine's `ProcessingRecipe.autofocusEachFrame`/`.autoExposureEachFrame` — Phase 9 maps between the two.
- `scan.completed`'s `summary` has only `completed`/`failed`/`stopped` — no `skipped` list like PROTOCOL.md's job summary; a requested-but-unattempted slot is simply absent from both arrays.
- Every method name, error code, and event name in this document is bridge-specific — none are shared with PROTOCOL.md even where the concept is analogous (e.g. `device.eject` vs. `scanner.eject`).

## Examples

`bridge.hello`:

```
{"id":1,"method":"bridge.hello","params":{"clientName":"scanstudio-engine","protocolVersion":1}}
{"id":1,"result":{"bridgeName":"scanstudio-bridge","bridgeVersion":"0.1.0","protocolVersion":1,"capabilities":["ls5000-coolscanpy"]}}
```

`roll.preview` refused, latch not armed:

```
{"id":2,"method":"roll.preview","params":{"material":"colorNegative"}}
{"id":2,"error":{"code":"HW_MOTION_NOT_ARMED","message":"motion refused: SCANSTUDIO_HW_MOTION unset or hw-motion-armed latch missing/empty","recoverable":false}}
```

`roll.thumbnail` + `roll.previewComplete`:

```
{"event":"roll.thumbnail","payload":{"slot":1,"thumbnail":{"slot":1,"boundaryRows":[12,884],"spacingOffset":3,"needsApproval":false,"warnings":[]}}}
{"event":"roll.previewComplete","payload":{"count":36,"fingerprint":"3f9a7e2c8b1d4560a9e4c1d7f6b2a830"}}
```

`scan.start` through completion (trimmed to one slot):

```
{"id":3,"method":"scan.start","params":{"slots":[1],"recipe":{"resolutionDpi":4000,"bitDepth":16,"multisamplePasses":4,"channels":"rgbi","autofocus":true,"autoExposure":true},"output":{"destination":"/path/to/scan-output/roll-042","filenameTemplate":"frame-####.tif"}}}
{"id":3,"result":{"jobId":"job-7f3a"}}
{"event":"scan.frameCompleted","payload":{"jobId":"job-7f3a","slot":1,"receipt":{"version":1,"slot":1,"spacingOffset":3,"dpi":4000,"depth":16,"deviceId":"ls5000-usb-0","deviceModel":"SUPER COOLSCAN 5000 ED","reviewedFingerprintSha256":"3f9a7e2c8b1d4560a9e4c1d7f6b2a830","freshFingerprintSha256":"3f9a7e2c8b1d4560a9e4c1d7f6b2a830","manualApproval":null,"exposure":{"focusPosition":812,"exposureMultiplier":1.0,"redExposureUs":1200.0,"greenExposureUs":950.0,"blueExposureUs":1400.0},"splitAlignment":null,"clipping":{"fractions":[0.001,0.0,0.0],"clipLevel":0.995,"warningFraction":0.02,"warning":false},"focusDetail":{"method":"laplacian-variance","verdict":"measured","score":184.2,"textureSpan":0.71},"transportSmear":{"verdict":"clean","startRow":null,"suffixRows":0,"minimumMatches":0,"tailMedianRms":null,"tailMinCorr":null,"preTailMedianRms":null,"textureSpan":null,"reason":"no repeated tail rows detected"},"artifacts":{"rgb":{"sha256":"a1b2c3d4e5f60718293a4b5c6d7e8f90","byteLength":25165824,"shape":[2954,4429,3],"dtype":"uint16"}},"storageTransform":"swapaxes01-scanner-native-to-nikon-render-parity-v2","rgbPath":"/path/to/scan-output/roll-042/frame-0001.tif","irPath":null}}}
{"event":"scan.completed","payload":{"jobId":"job-7f3a","summary":{"completed":[1],"failed":[],"stopped":false}}}
```

`hardware.anomaly`:

```
{"event":"hardware.anomaly","payload":{"jobId":"job-7f3a","slot":14,"code":"FEEDER_PARKED","message":"transport parked at end-stop after slot 14; power cycle required before further motion","ejected":true}}
```

### `roll.previewError` (additive, 2026-07-23)

Emitted by the preview worker instead of `roll.previewComplete` when the preview fails after acceptance (transport exception or CoolscanPy detection error such as RollSessionError). Payload: `{code: ErrorCode, message: string}`. Discovered live: detection RAISES rather than returning an empty session; without this event a worker death was silent.

**Terminal events fire after the lane is released (ordering, 2026-07-25).** `roll.previewComplete`, `roll.previewError`, `scan.error`, `scan.completed`, and the closing `scan.start` telemetry entry are all emitted only AFTER the worker has released the hardware lane. A client that reacts to a terminal event by polling `device.status` therefore always observes the lane free — previously the one-shot status poll could race the worker's cleanup, capture `laneHeld: true`, and (with no later re-poll) leave a UI stuck on "busy" forever, observed live 2026-07-25. Per-frame events (`scan.progress`, `scan.frameRetrying`, `scan.frameCompleted`, `scan.frameFailed`) and `hardware.anomaly` still fire while the lane is held, since they report on the in-flight hardware call. **Motion-operation gate (2026-07-25, same day):** a new motion request or `device.close` issued in the narrow window after the lane release but before the terminal event has been handed to the wire is refused with the recoverable `HARDWARE_LANE_BUSY` — never accepted — so one operation's terminal events can never interleave into a successor's. The gate drops the instant the terminal event is emitted; a client that reacts to the terminal event itself therefore never observes it.

**Typed preview failures (additive, 2026-07-25).** The bridge maps post-acceptance preview failures to typed codes instead of flattening them to `INTERNAL`: CoolscanPy's `FeederParked` → `FEEDER_PARKED`, `RefeedRequired` → `REFEED_REQUIRED`, `DeviceBusy` → `DEVICE_BUSY`. Two CoolscanPy-internal exception types known to leak past its public taxonomy are mapped explicitly: `IndexDecodeError` (the whole-roll transport table is inconsistent with one uniform traversal — observed live 2026-07-25 as `transport anchor residual is inconsistent with one affine preview traversal`) and `RollSessionError` (preview completed but no usable roll session, e.g. low alignment confidence or no scanner-addressable slots) both surface as `REFEED_REQUIRED`, with the underlying CoolscanPy detail preserved in `message` — the operator action for both is eject/refeed and preview again. `RollSessionIntegrityError` (artifact/journal self-check failures) stays `INTERNAL`: it indicates a driver-side defect, not an operator condition. Error telemetry lines for `roll.preview` and `scan.start` now also carry the `message` alongside `code` — the 2026-07-25 live failure was undiagnosable from telemetry precisely because only the bare code was recorded.

### `scan.error` (additive, 2026-07-23)

Emitted by the scan worker's soft-timeout watchdog (see "Scan-worker soft timeout" under `scan.start` above) when the call currently in flight has been entered for longer than `SCANSTUDIO_BRIDGE_SCAN_TIMEOUT` seconds with no matching exit. Payload: `{jobId: string, code: ErrorCode, message: string}` — same shape family as `roll.previewError`, plus `jobId` since a scan job (unlike a preview) has one. `code` is always `INTERNAL`: this is a bridge-side diagnostic report, not a CoolscanPy exception with its own code. `message` names the stuck call (e.g. `"scan worker soft timeout: no return from 'roll.scan:slot4' within 900.0s; ..."`).

Unlike `roll.previewError` replacing `roll.previewComplete`, `scan.error` does **not** replace `scan.completed` — it is a supplementary report, not a terminal one. The worker thread and the stuck call are left running untouched; `scan.completed` still fires normally afterward if that call ever returns on its own. A client may therefore see `scan.error` and, arbitrarily later (or never), also see `scan.completed` for the same `jobId` — treat `scan.error` as "the bridge itself has given up watching and is naming why," not as the job's own terminal outcome.

### `bridge.provenance` (additive, 2026-07-23)

Telemetry-only — never a wire event or part of any response, so a client never sees it directly. Recorded once, at bridge process startup, before the stdin loop reads even the first request (`bridge.hello` included). Entry: `{method: "bridge.provenance", outcome: "ok", file: string, version: string, head_sha: string|null}` — `file` is the running process's resolved `coolscanpy.__file__`, `version` is `coolscanpy.__version__`, and `head_sha` is that file's containing git checkout's HEAD commit (`null` if git is unavailable or the resolved directory is not a checkout; never raises).

Closes a stale-wheel blindspot: a stale cached build can silently keep running under an unchanged version string (the `scanstudio-bridge` sidecar's own `pyproject.toml` `[tool.uv.sources]` comment documents exactly this happening once already), with no prior way for anyone reading a live transcript or telemetry file to tell which actual coolscanpy content the bridge process had loaded.

### `scan.frameFailed` (additive, 2026-07-23)

Fires for any slot failure during `scan.start`, before `scan.completed` — see "Durable per-frame failure reasons" under `scan.start` above for the full contract (what triggers it, its telemetry entry shape, and how it relates to `hardware.anomaly`/`scan.error`). Payload: `{jobId: string, slot: number, code: ErrorCode, message: string}`.

```
{"event":"scan.frameFailed","payload":{"jobId":"job-7f3a","slot":1,"code":"MANUAL_REVIEW_REQUIRED","message":"frame 1 transport origin requires manual review"}}
```
