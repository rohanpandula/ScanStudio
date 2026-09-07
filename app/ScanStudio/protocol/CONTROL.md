# Scan Studio Control Channel Protocol v1

Contract for the local control channel that lets a CLI, a script, or an agent drive a running ScanStudio app the same way the GUI does. Every command maps onto exactly one existing `SessionModel` workflow method — the same method the GUI calls — so the GUI and the control channel can never disagree about what is allowed. This file is canonical; Swift types live in `ScanStudioKit/ControlWireProtocol.swift`.

## Transport

- The wire grammar is line-framed NDJSON with the same envelope shapes as `PROTOCOL.md`'s engine protocol:
  - **Request** (caller → dispatcher): `{"id": <u64>, "method": "<name>", "params": {…}}`.
  - **Response** (dispatcher → caller): `{"id": <u64>, "result": {…}}` or `{"id": <u64>, "error": {"code": "<CODE>", "message": "<human text>", "recoverable": <bool>, "guidance": "<text>", "gate": "<name>"}}`. Every request gets exactly one response.
  - **Event** (dispatcher → caller, unsolicited): `{"event": "<name>", "payload": {…}}`. Events may interleave with responses.
- In Phase 1 the dispatcher is in-process and transport-agnostic by construction (D-06): it accepts a decoded request value and returns an encodable response value, so Phase 2's socket server and any in-process test harness call the same API.
- JSON field names are camelCase on the wire, matching `ControlWireProtocol.swift`'s property names one-to-one.
- **Socket path.** The default is `~/.scanstudio/control.sock` (`ControlSocketPath.defaultPath()`); `scanstudio-cli --socket <path>` overrides it for any command.
- **Permissions are asserted, never trusted to `umask`.** The containing directory (`~/.scanstudio/`) is `chmod`'d to `0700` on every server start, and the socket itself is `chmod`'d to `0600` immediately after `bind` — both re-asserted every start, even if the directory already existed with some other mode.
- **`sun_path` bound.** A path that would not fit in the platform's `sockaddr_un.sun_path` in under 104 bytes including the NUL terminator is refused before any socket call.
- **Symlink refusal.** A path that `lstat` reports as an existing symlink is refused rather than bound through — a pre-placed symlink at the socket path is attacker-influenceable state, and following it would bind somewhere other than the intended path.
- **Probe-then-reclaim, in this exact order,** on every `start(path:)`: validate the path → prepare (and `chmod`) its directory → **probe** by dialing the path (`connect(2)`) → if the probe succeeds, refuse to start (another host already owns the path) → only once the probe fails with `ENOENT` or `ECONNREFUSED` — proof nothing live owns the path — does the server `unlink` it → `socket`/`bind`/`chmod`/`listen`. A stale socket left behind by a crash is therefore detected by a **failed connect**, never by `stat`: a crashed process's socket file is still present on disk and would satisfy any existence check, but only dialing it proves whether anything is actually listening.
- **Per-connection line bound.** A request line exceeding 1 MiB before a newline is refused with `INVALID_PARAMS`, and the connection is closed immediately after that refusal is written — never kept open past an oversized line.
- **Bounded outbound queue.** Each connection's outbound queue (responses and events not yet written) holds at most 256 entries. Responses are never dropped; only event lines (`control.snapshot`/`control.changed`) may be, drop-oldest, if a slow subscriber falls behind. A drop is never silent: the next event line on that connection is preceded by a `control.dropped` event naming how many were lost since the last notice. CLI-side handling of `control.dropped` (surfacing it to the operator, re-fetching a snapshot) is not built in Phase 2 — see OPS-10.

## Trust model

Filesystem permissions are the entire authentication boundary. Any process running as the same local user that owns `~/.scanstudio/control.sock` can open it and drive the scanner — the channel has no login, no token, and no per-caller identity beyond "same UID as the app." This is an accepted, deliberate consequence of a local-only, single-user design (PROJECT.md: "the channel is local-only; remote control adds an auth surface the app does not need for its purpose"). The socket's `0700`/`0600` modes keep a different local user out; they say nothing about which process owned by *this* user is asking, and that is intentional — a fresh agent, a script, and the GUI's own owner are all meant to be able to reach it.

`getpeereid()` — reading the connecting peer's UID/GID off the accepted socket and refusing anything that does not match the server's own UID — is available hardening on macOS that Phase 2 deliberately did not add. It would not change the trust model for the scenario this milestone is built for (multiple agents or scripts all running as the same local user); Phase 2's threat register treats same-user-any-process as the accepted baseline, not a gap left open by omission. A later phase could add it as defence in depth against a same-user sandboxed or lower-privilege process that should not reach the socket.

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

Every channel-level code above is `recoverable: false` — a refusal always requires the caller to change something (confirm, wait, resolve the gate) before retrying, never to retry the identical request unchanged; an engine- or bridge-originated code instead carries the engine's own `recoverable` flag verbatim, exactly as it does for `code` itself. Channel error bodies never carry hardware diagnostic detail; a policy refusal exposes only `code`, `message`, `recoverable`, `guidance`, and `gate`.

## Methods

Every entry below states `{params}` → `{result}` in inline code, the `SessionModel` action it performs and any event it causes, then a closing `Errors:` sentence listing only the codes that command's own dispatcher arm can actually return. Shared types (`DeviceInfo`, `ScannerStatus`, `CaptureRecipe`, `ProcessingRecipe`, `OutputRecipe` and its four sub-recipes, `JobState`) are declared once, verbatim, in `PROTOCOL.md`'s `## Types` section and reused unchanged here (D-01) — they are not redeclared. `hardwareMotionReadiness`/`scanReadiness` cross the wire as their Swift enum case name (`HardwareMotionReadiness`/`ScanReadinessPolicy.Decision` in `ScanStudioKit`), computed by the dispatcher, never the enum itself.

Every code below is channel-level (D-03) unless marked "passthrough", meaning the engine's or bridge's own code and `recoverable` flag cross the channel verbatim (for example `NOT_CONNECTED`, `EJECT_FAILED`, `FEEDER_PARKED` — see `PROTOCOL.md`'s Error codes section for the full engine vocabulary). A channel-level code is always `recoverable: false`.

### `hello`
`{schemaVersion: number, clientName: string, clientBuild?: string}` → `{schemaVersion: number, appName: string, appVersion?: string}`. Must be the first request on any connection; every other command sent first is refused with `HELLO_REQUIRED`. A second `hello` on an already-greeted connection is idempotent — it re-validates and returns the same shape, rather than being refused. Errors: `SCHEMA_VERSION_MISMATCH`.

### `status`
`{}` → `{device?: DeviceInfo, scanner?: ScannerStatus, projectName?: string, projectDirectory?: string, jobId?: string, jobState?: JobState, refeedRequired: boolean, hardwareMotionReadiness: string, motionAllowed: boolean, motionGuidance?: string, mutatingOperationInFlight?: string, selectedFrames: [number], scanReadiness: string, scanReadinessReason?: string, lastErrorMessage?: string, lastControlRefusal?: {command?: string, code: string, gate?: string, timestamp: string, sequence: number}}`. A full session snapshot built from `SessionModel` public state only — no `await`, no engine request. `mutatingOperationInFlight` is the D-07 arbitration signal, `nil` when idle. This is also the exact snapshot shape `events.subscribe` streams. Errors: none.

`lastControlRefusal` (SAFE-04) is the most recent wire-level refusal any connection triggered — `command` is the refused method name (`nil` only for a request too malformed to identify one, for example an oversized line), `code`/`gate` mirror the refusal's own `ControlErrorPayload.code`/`.gate`, and `sequence` is a monotonically increasing counter so two otherwise-identical refusals (same command/code/gate) are still distinguishable as separate occurrences. Every dispatcher-level refusal is recorded here — `CONFIRMATION_REQUIRED`, `GATE_REFUSED`, `CONTROLLER_BUSY`, `INVALID_PARAMS`, `UNKNOWN_COMMAND`, `SCHEMA_VERSION_MISMATCH`, `HELLO_REQUIRED` — regardless of which connection triggered it, so an `events.subscribe` follower on a *different* connection observes it too, on the very next `control.changed`. **Parse-time CLI refusals never reach the socket, by design (D-11)** — `scanstudio-cli`'s own `--confirm-motion`/`--film-loaded` gate and `frames select`/`include`/`exclude`'s CUPS range shape check both decide before any connection opens, so neither ever produces a `lastControlRefusal` for any subscriber to see; that class of refusal is recorded only by the CLI's own exit code and JSON error body on the process that hit it (a transcript covering it end-to-end is Phase 5's job, not this channel's).

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

### `frames.select`
`{indices?: [number], all?: boolean, none?: boolean}` → `{}`. **Exactly one of `indices`/`all`/`none` must be present** — any other combination is refused with `INVALID_PARAMS` before any `SessionModel` call. Not a motion command — no confirmation flag. The bulk, *pre-project* counterpart to `frames.include`/`frames.exclude`: routes to `setFrameSelection(_:)` (the `indices` arm, validated against the *previewed* frame count, `status.frameCount` — there is no project yet for this arm to validate membership against), `selectAllFrames()` (the `all` arm), or `clearFrameSelection()` (the `none` arm) — the same three GUI selection actions the contact sheet's own toolbar offers. Exists so a pure CLI/attach-mode caller (no GUI ever driven) can populate `selectedFrameIndices` — `roll.save`'s own "select at least one frame" precondition — from a cold session, closing the gap `roll.save`'s own refusal message otherwise leaves unsatisfiable through any documented command. Refused once a project already exists (`GATE_REFUSED`, no gate — use `frames.include`/`frames.exclude` to refine the selection instead) or while a job is active or a resume is in flight (`CONTROLLER_BUSY`, mirroring `settings.set`/`outputs.set`'s identical rule — none of the three have a busy flag of their own). Errors: `INVALID_PARAMS` (not exactly one of `indices`/`all`/`none`; an `indices` entry outside the previewed frame range; no preview has completed yet); `GATE_REFUSED` with no `gate` (a project already exists); `CONTROLLER_BUSY`.

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
`{name: string, carrier: SimulatedFilmCarrier, frameCount: number, filmProcess: FilmProcess, motionConfirmed: boolean}` → `{saved: boolean, projectName?: string, projectDirectory?: string}`. **Requires `motionConfirmed: true`** — it creates the project and immediately starts the scan of the selected frames, even though its name does not say so. Routes to `saveRollAndScanSelectedFrames(name:carrier:frameCount:filmProcess:)`, which creates the project from the current preview and starts (or pauses for manual review) the currently selected frames in one step. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED` with no `gate` (a project is already open, or no frames are selected — both app-level preconditions); `CONTROLLER_BUSY`; passthrough.

### `roll.open`
`{directory: string}` → `{}`. Routes to `openProject(directory:)`. Errors: `GATE_REFUSED` with no `gate` (another project action, scan, or frame-alignment change is already in progress); `CONTROLLER_BUSY`; passthrough (`PROJECT_NOT_FOUND`, `MANIFEST_INVALID`).

### `roll.list`
`{}` → `{projects: [{id: string, name: string, carrier: SimulatedFilmCarrier, frameCount: number, filmProcess: FilmProcess, createdAt: string, directory: string}]}`. Routes to `refreshRecentProjects()`, refreshing `SessionModel.recentProjects` from the engine's default projects root. An empty list on success is a valid, displayable state. Errors: `CONTROLLER_BUSY`; passthrough.

### `scan.start`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `scanReadiness(for: selectedFrames)` — verbatim the expression `ScanPanelView`'s Scan button binds its `.disabled` state to — then routes to `startMockScan()`, the one entry point for both real and simulated devices. `CONTROLLER_BUSY` also covers the window while the GUI-only attended-scan-recovery approval (`approveEveryFrameAndScan()` — see Not yet implemented) is in flight: that approval now participates in the same D-07 busy indicator as every other mutating action, so `scan.start` can never report a typed success for a request that approval silently absorbed instead. Emits `scan.jobState`/`scan.progress`/`scan.frameState` as the job proceeds. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `scanReadiness`; `CONTROLLER_BUSY`; passthrough.

### `scan.stop`
`{mode?: "afterCurrentFrame"|"immediate"}` (absent `mode` = `"afterCurrentFrame"`) → `{}`. Routes to `stopAfterCurrentFrame()` or `stopImmediately()`. Refused with `GATE_REFUSED` when no job is active, rather than silently reporting success for nothing having happened. Errors: `INVALID_PARAMS` (unrecognized `mode`); `GATE_REFUSED` with no `gate` (no active job); `CONTROLLER_BUSY`; passthrough.

### `scan.resume`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `scanReadiness(for: pendingFrames)` — verbatim the expression `ScanPanelView`'s Resume Batch button binds its `.disabled` state to — then routes to `resumeBatch()`, whose own guard additionally refuses with `GATE_REFUSED` (no `gate`) rather than a silent success when a resume is already in flight, a scan is already starting, or an attended-scan-recovery or manual-review approval is in progress — reasons the dispatcher's own pre-check cannot see directly. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `scanReadiness`; `GATE_REFUSED` with no `gate` (resume already in flight, a scan already starting, or an approval in progress); `CONTROLLER_BUSY`; passthrough.

### `scanner.eject`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `hardwareMotionReadiness.allowsMotion`, then `DeviceBarEjectPolicy.canOffer` — the identical function `DeviceBarView`'s Eject button gates its own visibility on, fed connected/transport-idle/no-active-job/media/film state — then routes to `eject()`, which re-checks both gates internally as defence in depth. Accepts a device that has never completed a preview (D-10/D-11 — the 2026-09-07 incident this phase fixes: a scanner reporting `filmPresent: true, mediaLoaded: false` must still be able to eject). A disconnected, mid-job, or mid-transport-activity caller is refused rather than reaching the engine — states the GUI's own Eject button is never even rendered for. Emits `scanner.status` with `filmPresent`/`mediaLoaded` cleared. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `hardwareMotionReadiness`; `GATE_REFUSED` with no `gate` (disconnected, transport not idle, a job is active, or no film to release); `CONTROLLER_BUSY`; passthrough (`HW_MOTION_NOT_ARMED`, `EJECT_FAILED`, `FEEDER_PARKED`).

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

## Exit codes

`scanstudio-cli` follows `sysexits.h`-style conventions (D-10). Exactly one function, `ControlCLIExitCode.forErrorCode(_:)`, decides a process exit value from an error `code` string; no command computes one inline except the parse-time `--confirm-motion`/`--film-loaded` gates below, whose value is fixed by D-11 rather than looked up.

| Exit | Meaning | Triggered by |
|------|---------|--------------|
| 0 | Success | |
| 64 | Usage / validation | ArgumentParser's own usage errors; channel `INVALID_PARAMS`; CLI-originated `INVALID_RANGE` (a malformed CUPS frame range, rejected before any connection opens) |
| 65 | Typed engine or gate error | `GATE_REFUSED`, and every other engine- or bridge-passthrough code this repository does not individually enumerate — the documented default, not a fallback for an unhandled case; also a `--wait`ed job whose terminal state is `failed` |
| 69 | No host reachable | `HOST_UNREACHABLE` — the control socket could not be dialed at the given (or default) path |
| 70 | Internal error | Channel `UNKNOWN_COMMAND`; CLI-originated `INTERNAL` (an unexpected condition after a request already succeeded, for example a response that failed to decode) |
| 75 | Busy / conflict | `CONTROLLER_BUSY` |
| 77 | Confirmation required | `CONFIRMATION_REQUIRED`, decided client-side at parse time — before any connection opens — for every motion-capable subcommand (D-11) |
| 78 | Schema / version mismatch | `SCHEMA_VERSION_MISMATCH`, `HELLO_REQUIRED` |

`--wait`'s own exit code is decided the same way, from the job's final aggregate rather than a second table: `completed` and `stopped` both exit 0 (the job reached a terminal state without error — a caller who asked to stop gets a clean exit, not a failure), `failed` exits 65.

## Command-line mapping

One row per `scanstudio-cli` subcommand group (the full D-08 tree, sixteen groups). "Confirmation flag" is the CLI's own parse-time gate (D-11); "—" means the subcommand carries no motion and needs none. Every row additionally carries the read-only baseline (`0, 65, 69, 70, 75`) or the confirmation-gated baseline (`0, 65, 69, 70, 75, 77`); a "+" column notes any exit code a row can reach beyond that baseline.

| Subcommand | Channel method(s) | Confirmation flag | Exit codes |
|---|---|---|---|
| `connect [--device <id>]` | `scanner.connect` | — | 0, 65, 69, 70, 75 |
| `disconnect` | `scanner.disconnect` | — | 0, 65, 69, 70, 75 |
| `rescan` | `scanner.rescan` | — | 0, 65, 69, 70, 75 |
| `status [--job <id>]` | `status`, or `job.get` when `--job` is given | — | 0, 65 (`JOB_NOT_FOUND` when `--job` names an id that does not match the tracked job), 69, 70 |
| `preview --film-loaded [--intent …] [--film-process …]` | `preview.acquire` | `--film-loaded` | 0, 64 (`--intent replaceFilmProcess` with no `--film-process`, or an unrecognized `--intent`), 65, 69, 70, 75, 77 |
| `frames list` / `frames select <range>\|--all\|--none` / `frames include <range>` / `frames exclude <range>` | `frames.list` / `frames.select` / `frames.include` / `frames.exclude` | — | 0, 64 (a malformed CUPS range, or not exactly one of the range argument/`--all`/`--none` for `select`, both refused client-side, D-12), 65, 69, 70, 75 |
| `review approve --confirm-motion` | `review.approve` | `--confirm-motion` | 0, 65, 69, 70, 75, 77 |
| `settings get` / `settings set […]` | `settings.get` / `settings.set` | — | 0, 65, 69, 70, 75 |
| `outputs get` / `outputs set […]` | `outputs.get` / `outputs.set` | — | 0, 65, 69, 70, 75 |
| `roll save --name … --carrier … --frame-count … --film-process … --confirm-motion` / `roll open <directory>` / `roll list` | `roll.save` / `roll.open` / `roll.list` | `--confirm-motion` (`save` only) | 0, 65, 69, 70, 75, 77 (`save`); 0, 65, 69, 70, 75 (`open`/`list`) |
| `scan --confirm-motion [--wait]` | `scan.start` | `--confirm-motion` | 0, 65 (also a `--wait`ed `failed` terminal state), 69, 70, 75, 77 |
| `stop [--immediate]` | `scan.stop` | — (stopping never starts motion) | 0, 65 (`GATE_REFUSED` when no job is active), 69, 70, 75 |
| `resume --confirm-motion [--wait]` | `scan.resume` | `--confirm-motion` | 0, 65 (also a `--wait`ed `failed` terminal state), 69, 70, 75, 77 |
| `eject --confirm-motion` | `scanner.eject` | `--confirm-motion` | 0, 65, 69, 70, 75, 77 |
| `diagnostics export --to <dir>` | `diagnostics.export` | — | 0, 64 (`directory` is relative, contains `..`, or does not exist), 69, 70 |
| `events --follow` | `events.subscribe`, then every subsequent event on that connection | — | 0, 64 (`--follow` omitted), 69, 70 |

Two facts about this table a reader will otherwise get wrong:

- **`scanner.list` has no subcommand in Phase 2.** Device discovery is `rescan` (`scanner.rescan`); the currently connected device, if any, is reported by `status`, not by a listing command. A caller that wants "what's out there" calls `rescan`; a caller that wants "what am I connected to" calls `status`.
- **`roll save` is motion-confirmed at both layers, and the two layers are independent, not redundant.** The wire's own `roll.save` params carry `motionConfirmed`, refused with `CONFIRMATION_REQUIRED` before any `SessionModel` call if it is absent or `false` — closed at the wire by plan 02-01 Task 3 (`ControlRollSaveParams.motionConfirmed`). Threat register entry **T-02-27 is closed**: this wire-level gate plus the CLI's own layer below are the closing mitigation, not an open, standing risk. The CLI *additionally* requires `--confirm-motion` at parse time, before any connection opens — a tightening beyond D-08's literal `roll save --name` tree added by plan 02-05, mirroring `review.approve`'s identical precedent from Phase 1. The residual asymmetry, recorded here as a decision rather than a discovered surprise: `motionConfirmed` is a caller-supplied boolean like any other field, so a raw-socket caller bypassing the CLI entirely still decides its own value — the wire gate proves the field was sent as `true`, not that a human confirmed anything. The CLI's `--confirm-motion` flag is a second, independent gate at the layer a human or script most often touches; neither layer substitutes for the other.

## Not yet implemented

Recorded here so both gaps stay visible in the spec, not only in a plan:

- **Attended-scan-recovery approval** (`SessionModel.approveEveryFrameAndScan()`, the path behind `ContentView.swift`'s attended-retry banner) has no channel command yet. It approves every frame in the roll against a different confirmation contract than `review.approve`'s single-boundary approval and needs its own command; D-08's command tree does not include it, so this work is carried past Phase 2 to a later phase.
