# Scan Studio Control Channel Protocol v1

Contract for the local control channel that lets a CLI, a script, or an agent drive a running ScanStudio app the same way the GUI does. Every command maps onto exactly one existing `SessionModel` workflow method — the same method the GUI calls — so the GUI and the control channel can never disagree about what is allowed. This file is canonical; Swift types live in `ScanStudioKit/ControlWireProtocol.swift`.

## Transport

- The wire grammar is line-framed NDJSON with the same envelope shapes as `PROTOCOL.md`'s engine protocol:
  - **Request** (caller → dispatcher): `{"id": <u64>, "method": "<name>", "params": {…}}`.
  - **Response** (dispatcher → caller): `{"id": <u64>, "result": {…}}` or `{"id": <u64>, "error": {"code": "<CODE>", "message": "<human text>", "recoverable": <bool>, "guidance": "<text>", "gate": "<name>"}}`. Every request gets exactly one response.
  - **Event** (dispatcher → caller, unsolicited): `{"event": "<name>", "payload": {…}}`. Events may interleave with responses.
- The concrete socket transport (Unix-domain socket path, permissions, stale-socket handling) is Phase 2's decision and is deliberately unspecified here.
- In Phase 1 the dispatcher is in-process and transport-agnostic by construction (D-06): it accepts a decoded request value and returns an encodable response value, so Phase 2's socket server and any in-process test harness call the same API.
- JSON field names are camelCase on the wire, matching `ControlWireProtocol.swift`'s property names one-to-one.

## Versioning

- The first request on any connection must be `hello`, carrying `schemaVersion` in its params.
- The current schema version is **1** (`ControlSchema.version`).
- A `hello` whose `schemaVersion` does not match the current version is refused with `SCHEMA_VERSION_MISMATCH` before any other command can run on that connection.
- Any request arriving before a successful `hello` is refused with `HELLO_REQUIRED`.

## Error codes

| Code | Emitted when |
|------|--------------|
| `SCHEMA_VERSION_MISMATCH` | The connection's `hello` carried a `schemaVersion` this app does not support. |
| `HELLO_REQUIRED` | A request arrived before that connection completed a successful `hello`. |
| `UNKNOWN_COMMAND` | The request's `method` does not match any command this channel implements. |
| `INVALID_PARAMS` | The request's `params` failed to decode into the shape its `method` requires. |
| `CONTROLLER_BUSY` | A mutating or motion-capable command arrived while another such operation was already in flight; the message names the in-flight operation. |
| `CONFIRMATION_REQUIRED` | A motion-capable command arrived without the explicit confirmation flag its params require (for example `motionConfirmed` or `filmLoadedConfirmed`). |
| `GATE_REFUSED` | A physical-readiness gate (hardware motion, scan readiness, refeed, or a pending manual review) refused the command. |

When a failure originates in the engine or the bridge instead of the channel itself, the error body carries the engine's own `code` and `recoverable` flag verbatim rather than remapping them to one of the codes above — the same `NOT_CONNECTED`, `FEED_JAM`, or similar code the GUI would see reaches the caller unchanged.

A `GATE_REFUSED` body additionally carries `gate`, naming which gate refused (one of `hardwareMotionReadiness`, `scanReadiness`, `refeedRequired`, `manualReviewPending`), and `guidance`, the same operator-facing explanation the GUI would show next to a disabled action.

Every channel-level code above is `recoverable: false` — a refusal always requires the caller to change something (confirm, wait, resolve the gate) before retrying, never to retry the identical request unchanged. Channel error bodies never carry hardware diagnostic detail; a policy refusal exposes only `code`, `message`, `recoverable`, `guidance`, and `gate`.

## Methods

Every entry below states `{params}` → `{result}` in inline code, the `SessionModel` action it performs and any event it causes, then a closing `Errors:` sentence listing only the codes that command's own dispatcher arm can actually return. Shared types (`DeviceInfo`, `ScannerStatus`, `CaptureRecipe`, `ProcessingRecipe`, `OutputRecipe` and its four sub-recipes, `JobState`) are declared once, verbatim, in `PROTOCOL.md`'s `## Types` section and reused unchanged here (D-01) — they are not redeclared. `hardwareMotionReadiness`/`scanReadiness` cross the wire as their Swift enum case name (`HardwareMotionReadiness`/`ScanReadinessPolicy.Decision` in `ScanStudioKit`), computed by the dispatcher, never the enum itself.

Every code below is channel-level (D-03) unless marked "passthrough", meaning the engine's or bridge's own code and `recoverable` flag cross the channel verbatim (for example `NOT_CONNECTED`, `EJECT_FAILED`, `FEEDER_PARKED` — see `PROTOCOL.md`'s Error codes section for the full engine vocabulary). A channel-level code is always `recoverable: false`.

### `hello`
`{schemaVersion: number, clientName: string, clientBuild?: string}` → `{schemaVersion: number, appName: string, appVersion?: string}`. Must be the first request on any connection; every other command sent first is refused with `HELLO_REQUIRED`. A second `hello` on an already-greeted connection is idempotent — it re-validates and returns the same shape, rather than being refused. Errors: `SCHEMA_VERSION_MISMATCH`.

### `status`
`{}` → `{device?: DeviceInfo, scanner?: ScannerStatus, projectName?: string, projectDirectory?: string, jobId?: string, jobState?: JobState, refeedRequired: boolean, hardwareMotionReadiness: string, motionAllowed: boolean, motionGuidance?: string, mutatingOperationInFlight?: string, selectedFrames: [number], scanReadiness: string, scanReadinessReason?: string, lastErrorMessage?: string}`. A full session snapshot built from `SessionModel` public state only — no `await`, no engine request. `mutatingOperationInFlight` is the D-07 arbitration signal, `nil` when idle. This is also the exact snapshot shape `events.subscribe` streams. Errors: none.

### `scanner.list`
`{}` → `{devices: [DeviceInfo]}`. Routes to `refreshAvailableDevices(rescan: false)`. Errors: `CONTROLLER_BUSY`; passthrough (for example a recoverable `INTERNAL` with a `BRIDGE_STARTUP_FAILED:` prefix).

### `scanner.rescan`
`{}` → `{devices: [DeviceInfo]}`. Routes to `refreshAvailableDevices(rescan: true)` — one deliberate re-attempt of the real backend's startup. Errors: `CONTROLLER_BUSY`; passthrough (`ALREADY_CONNECTED`).

### `scanner.connect`
`{deviceId?: string}` → `{}`. Routes to `connect(deviceId:)`. An absent `deviceId` lets `DeviceSelectionPolicy` resolve the target, exactly like the GUI's no-argument connect. Emits `scanner.status`. Poll `status` afterward for the connected `device`. Errors: `CONTROLLER_BUSY`; `GATE_REFUSED` with no `gate` (an unknown device id — an app-level precondition, not a physical gate); passthrough (`UNKNOWN_DEVICE`, `ALREADY_CONNECTED`).

### `scanner.disconnect`
`{}` → `{}`. Routes to `disconnect()`. Emits `scanner.status` with `connected: false`. Errors: `CONTROLLER_BUSY`; passthrough (`NOT_CONNECTED`, `SCANNER_BUSY`).

### `preview.acquire`
`{filmLoadedConfirmed: boolean, intent?: "initial"|"replaceFilmProcess"|"refreshSavedProject", filmProcess?: FilmProcess}` (absent `intent` = `"initial"`) → `{outcome: "started"|"rejected"|"failedToStart", intentToken: string}`. **Requires `filmLoadedConfirmed: true`.** Pre-checks `hardwareMotionReadiness.allowsMotion` (the motion component of `ScanPanelView.canAcquireThumbnails`'s own `.disabled` binding), then routes to `requestPreview(_:)`, which emits `scanner.thumbnail` per frame and `scanner.thumbnailsComplete`. A `"rejected"`/`"failedToStart"` `outcome` is still a *success* response — the request was accepted and answered definitively; this is the one D-05 command where a non-`"started"` outcome is not itself a failure. Errors: `CONFIRMATION_REQUIRED` (missing `filmLoadedConfirmed`); `GATE_REFUSED`, gate `hardwareMotionReadiness`; `INVALID_PARAMS` (`intent` is `"replaceFilmProcess"` with no `filmProcess`, or an unrecognized `intent` string); `CONTROLLER_BUSY`.

### `frames.list`
`{}` → `{frames: [{index: number, excluded: boolean, selected: boolean, hasThumbnail: boolean, state?: string, manualReviewDecision?: "useFrameAnyway"|"dontScan", errorCode?: string}], selectedFrames: [number]}`. Built from `SessionModel` state only — no engine request. `errorCode` carries only the bare failure code string, never a full error payload or any hardware-diagnostic detail (T-01-05). Errors: none.

### `frames.include`
`{frameIndex: number}` → `{}`. Validates `frameIndex` against the open project's actual frame indices, then routes to `setFrameExcluded(_:excluded: false)`. Errors: `INVALID_PARAMS` (no project open, or `frameIndex` is not one of the project's frame indices); `CONTROLLER_BUSY`; passthrough.

### `frames.exclude`
`{frameIndex: number}` → `{}`. The same validation and the same `setFrameExcluded(_:excluded:)` method as `frames.include` — only the flag differs (`true` here). Errors: `INVALID_PARAMS`; `CONTROLLER_BUSY`; passthrough.

### `review.approve`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`** — this command starts a scan (`approvePendingManualReviewAndStart()`), even though its name does not say so; this is a Phase 1 tightening beyond the GUI's own literal confirmation-flag enumeration, per PROJECT.md's standing "no scanner motion without an explicit confirmation flag" constraint. Refused with `GATE_REFUSED` when no manual review is currently pending, so "approved" can never be confused with "there was nothing to approve." Emits `roll.approve` per flagged frame, then `scan.start`, on success. Attended-scan-recovery approval (`approveEveryFrameAndScan()`) is a different action with different confirmation semantics and is not reachable through this command — see Not yet implemented. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `manualReviewPending`; `CONTROLLER_BUSY`; passthrough.

### `settings.get`
`{}` → `{capture: CaptureRecipe, processing: ProcessingRecipe}`. Built from `SessionModel` state only. `processing.digitalIceEnabled` reports the *effective* value: it is gated off unless `capture.channels == "rgbi"` and `processing.filmProcess != "bwNegative"`, even if a prior `settings.set` asked for it on — this asymmetry is `SessionModel`'s existing behavior, not a channel-specific rule. Errors: none.

### `settings.set`
`{capture: CaptureRecipe, processing: ProcessingRecipe}` → `{}`. Routes to `applySettingsRecipes(capture:processing:)` — the one `SessionModel` entry point for this command; the dispatcher never writes an individual settings field itself. Refused with `CONTROLLER_BUSY` while a job is active or a batch resume is in flight, mirroring `BatchInspectorView`'s own rule that the settings editors are not rendered during a job and are disabled during a resume — `applySettingsRecipes` is synchronous and holds no busy flag of its own, so this is an explicit dispatcher-level check, not the generic D-07 arbitration signal. Errors: `CONTROLLER_BUSY`.

### `outputs.get`
`{}` → `{outputs: OutputRecipe}`. Built from `SessionModel` state only. Errors: none.

### `outputs.set`
`{outputs: OutputRecipe}` → `{}`. Routes to `applyOutputRecipe(_:)`, which delegates to the same private path `roll.open` already uses to seed a project's recipes. Same `isJobActive`/`isResumingBatch` busy rule as `settings.set`. Errors: `CONTROLLER_BUSY`.

### `roll.save`
`{name: string, carrier: SimulatedFilmCarrier, frameCount: number, filmProcess: FilmProcess}` → `{saved: boolean, projectName?: string, projectDirectory?: string}`. Routes to `saveRollAndScanSelectedFrames(name:carrier:frameCount:filmProcess:)`, which creates the project from the current preview and starts (or pauses for manual review) the currently selected frames in one step. Errors: `GATE_REFUSED` with no `gate` (a project is already open, or no frames are selected — both app-level preconditions); `CONTROLLER_BUSY`; passthrough.

### `roll.open`
`{directory: string}` → `{}`. Routes to `openProject(directory:)`. Errors: `GATE_REFUSED` with no `gate` (another project action, scan, or frame-alignment change is already in progress); `CONTROLLER_BUSY`; passthrough (`PROJECT_NOT_FOUND`, `MANIFEST_INVALID`).

### `roll.list`
`{}` → `{projects: [{id: string, name: string, carrier: SimulatedFilmCarrier, frameCount: number, filmProcess: FilmProcess, createdAt: string, directory: string}]}`. Routes to `refreshRecentProjects()`, refreshing `SessionModel.recentProjects` from the engine's default projects root. An empty list on success is a valid, displayable state. Errors: `CONTROLLER_BUSY`; passthrough.

### `scan.start`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `scanReadiness(for: selectedFrames)` — verbatim the expression `ScanPanelView`'s Scan button binds its `.disabled` state to — then routes to `startMockScan()`, the one entry point for both real and simulated devices. `CONTROLLER_BUSY` also covers the window while the GUI-only attended-scan-recovery approval (`approveEveryFrameAndScan()` — see Not yet implemented) is in flight: that approval now participates in the same D-07 busy indicator as every other mutating action, so `scan.start` can never report a typed success for a request that approval silently absorbed instead. Emits `scan.jobState`/`scan.progress`/`scan.frameState` as the job proceeds. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `scanReadiness`; `CONTROLLER_BUSY`; passthrough.

### `scan.stop`
`{mode?: "afterCurrentFrame"|"immediate"}` (absent `mode` = `"afterCurrentFrame"`) → `{}`. Routes to `stopAfterCurrentFrame()` or `stopImmediately()`. Refused with `GATE_REFUSED` when no job is active, rather than silently reporting success for nothing having happened. Errors: `INVALID_PARAMS` (unrecognized `mode`); `GATE_REFUSED` with no `gate` (no active job); `CONTROLLER_BUSY`; passthrough.

### `scan.resume`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `scanReadiness(for: pendingFrames)` — verbatim the expression `ScanPanelView`'s Resume Batch button binds its `.disabled` state to — then routes to `resumeBatch()`. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `scanReadiness`; `CONTROLLER_BUSY`; passthrough.

### `scanner.eject`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `hardwareMotionReadiness.allowsMotion`, then routes to `eject()`, which re-checks the same readiness internally as defence in depth. Accepts a device that has never completed a preview (D-10/D-11 — the 2026-09-07 incident this phase fixes: a scanner reporting `filmPresent: true, mediaLoaded: false` must still be able to eject). Emits `scanner.status` with `filmPresent`/`mediaLoaded` cleared. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `hardwareMotionReadiness`; `CONTROLLER_BUSY`; passthrough (`HW_MOTION_NOT_ARMED`, `EJECT_FAILED`, `FEEDER_PARKED`).

### `diagnostics.export`
`{directory: string}` → `{path: string, entries: [string]}`. Validates `directory` before any write — it must be an absolute path, must contain no `..` path component, and must be an existing directory — then composes `SessionModel.diagnosticBundleEntryNames(previewConsent:)`, `makeDiagnosticBundleData(previewConsent:)`, and `DiagnosticBundleFileWriter.write(_:to:)`, the same three calls the GUI's own Save Diagnostic Bundle action makes. `previewConsent` is always `nil`: film bytes require exact per-export consent, and the control channel has no consent affordance in Phase 1 (T-01-05). The filename is always generated by the dispatcher from the current timestamp, never taken from the request — the directory is the only caller-controlled part of the write destination (T-01-20). Errors: `INVALID_PARAMS` (`directory` is relative, contains `..`, does not exist, or the write itself failed).

### `events.subscribe`
`{}` → `{subscribed: boolean, snapshot: <the same shape `status` returns>}`, then a `control.snapshot` event carrying that same snapshot immediately, and one `control.changed` event carrying a fresh snapshot after every subsequent `SessionModel` mutation. Never reads the engine client's own event stream directly — `SessionModel` already owns that stream's one consumer. Errors: none.

### `job.get`
`{}` → `{jobId?: string, jobState?: JobState, progress?: {jobId: string, frameIndex: number, frameOrdinal: number, totalFrames: number, pass: number, totalPasses: number, framePercent: number, jobPercent: number, etaSeconds: number}, completedFrameCount: number, pendingFrameCount: number, receiptCount: number, frameErrorCodes: {[frameIndex: string]: string}}`. Built from `SessionModel` state only. `receiptCount` rather than the receipts themselves — this is a status call, not an export. Errors: none.

## Read-only commands

`status`, `frames.list`, `settings.get`, `outputs.get`, and `job.get` are answered entirely from in-memory `SessionModel` state and issue no engine request (CTRL-03). Repeating any of them never reconnects, never re-arms discovery, and never changes scanner or engine state — a caller can poll them freely.

## Arbitration

Exactly one mutating operation runs at a time (D-07). A second mutating or motion-capable command arriving while one is already in flight is refused with `CONTROLLER_BUSY`, naming the in-flight operation. The channel never queues a refused request, never retries it automatically, and never re-issues a physical operation on its own (D-09) — a refusal is returned once, and the caller decides whether to try again.

## Not yet implemented

Recorded here so both gaps stay visible in the spec, not only in a plan:

- **Attended-scan-recovery approval** (`SessionModel.approveEveryFrameAndScan()`, the path behind `ContentView.swift`'s attended-retry banner) has no D-05 command name yet. It approves every frame in the roll against a different confirmation contract than `review.approve`'s single-boundary approval and needs its own command; this is Phase 2 / CLI-05 work.
- **`ControlErrorPayload.recoverable`** is currently always `false` on every operation-failure path this channel produces from its own `outcome` translation (`ControlChannelDispatcher.outcome(id:errorMessageBefore:)`), because `SessionModel` retains only the rendered failure message, not the engine's typed `recoverable` flag. An engine- or bridge-originated failure's own `code` still passes through verbatim; only the boolean is flattened. The upgrade path is having `SessionModel` retain the typed error payload instead of only its rendered string (Phase 2 / OUT-03).
