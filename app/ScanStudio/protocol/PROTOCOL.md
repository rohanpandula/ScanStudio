# Scan Studio Engine Protocol v1

Contract between the SwiftUI app and the `scanstudio-engine` subprocess. This file is canonical; the JSON files in `fixtures/` are golden examples that both the Rust and Swift test suites must parse.

## Transport

- The app spawns the engine and speaks over the engine's **stdin/stdout**. stderr is free-form diagnostics.
- **NDJSON**: exactly one JSON object per line, UTF-8, `\n` terminated. The engine flushes stdout after every line.
- Three wire shapes:
  - **Request** (app → engine): `{"id": <u64>, "method": "<name>", "params": {…}}` — `params` may be omitted.
  - **Response** (engine → app): `{"id": <u64>, "result": {…}}` or `{"id": <u64>, "error": {"code": "<CODE>", "message": "<human text>", "recoverable": <bool>}}`. Every request gets exactly one response.
  - **Event** (engine → app, unsolicited): `{"event": "<name>", "payload": {…}}`. Events may interleave with responses.
- Request `id`s are chosen by the app, must be unique per connection, and are echoed verbatim.
- **Forward compatibility**: both sides must ignore unknown fields; the app must ignore unknown event names; the engine answers unknown methods with `UNKNOWN_METHOD`.
- JSON field names are camelCase on the wire.

## Error codes

`UNKNOWN_METHOD`, `INVALID_PARAMS`, `UNKNOWN_DEVICE`, `NOT_CONNECTED`, `ALREADY_CONNECTED`, `NO_MEDIA`, `SCANNER_BUSY`, `UNKNOWN_JOB`, `FEED_JAM` (recoverable: true), `FILM_FEED_INTERRUPTED`, `INTERNAL`, `PROJECT_NOT_FOUND`, `MANIFEST_INVALID`, `ARCHIVE_COLLISION`, `MANUAL_REVIEW_REQUIRED`, `HW_MOTION_NOT_ARMED`.

`recoverable` is `true` only for faults where retrying the same operation can succeed (`FEED_JAM`). All others are `false`.

> **Real-backend recoverable policy (additive, 2026-07-24):** for bridge-sourced failures, `error.recoverable` reflects BRIDGE.md's own policy: `true` only when the underlying bridge code is `HARDWARE_LANE_BUSY` (retrying the identical request once the lane frees can succeed with no other action). Every other bridge code (`REFEED_REQUIRED`, `MANUAL_REVIEW_REQUIRED`, `FEEDER_PARKED`, `TRANSPORT_SMEAR_DETECTED`, ...) is `recoverable: false` because a different action is needed first. Unrecognized bridge codes default to `false`.

`FILM_FEED_INTERRUPTED` means a batch-positioning operation received the scanner's verified medium-not-present response (`02/3A/00`). Frames completed before the interruption remain durable. The preview registration is invalidated; the operator must refeed the film, acquire a fresh preview, and resume only unfinished frames.

## Methods

### `engine.hello`
params `{clientName: string, protocolVersion: 1}` → result `{engineName: "scanstudio-engine", engineVersion: string, protocolVersion: 1, capabilities: ["simulated-ls5000"]}`. Must be the first request; the engine answers other methods before hello with `INVALID_PARAMS`. The engine supports only version 1 and rejects any other `protocolVersion` with `INVALID_PARAMS`.

### `engine.shutdown`
params `{}` → result `{}`; then the engine cancels outstanding simulated work, flushes the response, and exits 0. Cancellation is bounded so an active operation cannot keep shutdown waiting on its normal simulated delay.

### `scanner.list`
`{}` → `{devices: [DeviceInfo]}`. Always exactly one simulated device in M1.

### `scanner.connect`
`{deviceId: string, options?: {timeScale?: number, faultInjection?: "none"|"demo"}}` → `{device: DeviceInfo, status: ScannerStatus}` and emits a `scanner.status` event. `timeScale` (default `1.0`) multiplies every simulated delay — tests use ~`0.01`. Errors: `UNKNOWN_DEVICE`, `ALREADY_CONNECTED`.

### `scanner.disconnect`
`{}` → `{}` and emits `scanner.status` with `connected: false`. Errors: `NOT_CONNECTED`, `SCANNER_BUSY` (transport operation active).

### `scanner.status`
`{}` → `ScannerStatus`. Error: `NOT_CONNECTED`.

### `sim.loadMedia`
`{carrier: "roll36"|"strip6"|"mounted"}` → `ScannerStatus`, and emits `scanner.status`. Simulator-only affordance (a real backend detects media; that is why the method lives under `sim.`). Frame counts: roll36 → 36, strip6 → 6, mounted → 1. Errors: `NOT_CONNECTED`, `SCANNER_BUSY`.

### `scanner.acquireThumbnails`
`{frames?: [u32], filmProcess?: "positive"|"c41ColorNegative"|"bwNegative"|"kodachrome", operationId?: string}` (omitted `frames` = all loaded frames) → immediate ack `{accepted: true, frames: [u32]}`, then one `scanner.thumbnail` event per frame (~80 ms × timeScale apart), then `scanner.thumbnailsComplete`, then a post-preview `scanner.status`. Before a project exists, `filmProcess` selects the material used for preview (omission uses the deterministic C-41 default). With an active project, its persisted `filmProcess` is authoritative: omission or an equal supplied value is accepted, while a different supplied value is rejected with `INVALID_PARAMS`.

`operationId` is an additive asynchronous-correlation token. New ScanStudio clients send a fresh value for each accepted preview request. When present, the engine echoes it unchanged on every event produced by that preview worker: `scanner.thumbnail`, `scanner.thumbnailsFailed` (when applicable), `scanner.thumbnailsComplete`, and the post-preview `scanner.status`. The bridge protocol remains unchanged; the engine adds the token to bridge-derived events. Older callers may omit it, in which case those event payloads omit it too. While a preview is active, clients must fail closed on missing or mismatched tokens: such events cannot add thumbnails, report failure, complete the preview, clear its busy state, or authorize a second request. Generic untagged status events never terminate an active preview.

Errors: `NOT_CONNECTED`, `NO_MEDIA`, `SCANNER_BUSY`, `INVALID_PARAMS` (active-project material conflict).

### `roll.approve`

`{frameIndex: u32, operationId: string}` → `{}`. Explicitly records the
operator's approval for a single frame that the active **real-device** preview
marked as requiring manual review. `operationId` is required, nonempty, and
must exactly equal the token from the most recent successfully completed real
preview. That binding includes the current device-session epoch and bridge
process generation. Starting another preview, a failed preview, ejecting or
resetting media, disconnecting, reconnecting, or losing bridge ownership
invalidates it. Missing, empty, mismatched, or stale tokens return
`INVALID_PARAMS` before any bridge request is made. `frameIndex` is the
project-facing identifier; during the bound real preview it maps one-to-one to
BRIDGE.md's scanner-addressable slot. This request is non-motion: it does not
preview, scan, eject, check the motion latch, or refresh device status. It is
scoped to the currently open bridge device session and is never retried after
that session is lost.

The simulator has no manual-review gate and refuses this method with
`INVALID_PARAMS`. Errors: `NOT_CONNECTED`, `INVALID_PARAMS`, `INTERNAL` (for
a bridge refusal after a valid locally-bound approval; the bridge's specific
diagnostic remains in the message).

### `roll.setSpacingOffset`

`{frameIndex: u32, offsetRows: i64, operationId: string}` →
`{thumbnail: Thumbnail}`. Updates one real preview frame's absolute
scanner-native row offset and returns the exact replacement tile from the
bridge. Positive native rows move the Nikon-render-oriented image left;
negative rows move it right. Frame 1 accepts `0...144`; every other frame
accepts `-144...144`.

The frame and operation token must belong to the latest successfully completed
preview in the current device session and bridge generation. Validation is
local before the one bridge call. The request is non-motion: it does not
preview, scan, eject, refresh status, or check the motion latch. The returned
thumbnail carries the new `spacingOffset`, current boundary evidence, and a
fresh `imagePath`; changing the offset invalidates prior manual approval.

### `scan.start`
`{frames: [u32], recipe: CaptureRecipe, processing?: ProcessingRecipe, output?: OutputRecipe, frameAlignments?: {frameIndex: FrameAlignment}}` → `{jobId: string}`; the job runs on a worker thread and reports through events. `frameAlignments` remains additive for legacy/simulator compatibility, but a real LS-5000 capture uses the offset already installed in the preview-bound CoolScanPy roll session through `roll.setSpacingOffset`; the real derivative renderer must not apply those transport rows again as stored-image pixels. The optional recipes default deterministically for compatibility with earlier v1 clients. One job at a time. Errors: `NOT_CONNECTED`, `NO_MEDIA`, `SCANNER_BUSY`, `INVALID_PARAMS` (empty/out-of-range frames, invalid recipe values, or material conflicts). With an active project, its roll `filmProcess` is the capture-material authority: the engine normalizes the roll-wide `processing.filmProcess` to it for old clients that omitted that field. Every requested frame's `processingOverride.filmProcess`, if present, must match it. A legacy conflicting override is rejected before scanner access; it is never rendered or receipted as a different material in the same hardware batch. Per-frame capture/output overrides and same-process processing overrides otherwise apply to that frame. A request naming an excluded frame is rejected with `INVALID_PARAMS`. The engine threads the active project's directory internally for receipt persistence (the wire shape is unchanged).

### `scan.stop`
`{jobId: string, mode: "afterCurrentFrame"|"immediate"}` → `{acknowledged: bool, mode: string}` (`acknowledged: false` if the job already reached a terminal state). Error: `UNKNOWN_JOB`. Pause-after-current-frame in the UI is `afterCurrentFrame` stop + later resume via a new `scan.start` with the remaining frames — the engine job machine stays simple.

### `scan.skipCurrentFrame`
`{jobId: string}` → `{acknowledged: bool}`. If the job's currently-active frame can be skipped, marks it `skipped` (no receipt written for that frame) and the job continues to its next frame without stopping — unlike `scan.stop`, the batch is not paused or halted. `acknowledged: false` if the job has already reached a terminal state or no frame is active in that instant. Error: `UNKNOWN_JOB`. Only supported against the simulated backend.

> **Real-hardware skip workflow (additive, 2026-07-24):** real hardware has no primitive capable of abandoning an in-flight frame (BRIDGE.md's `scan.stop` always lets the current slot finish). The real-hardware equivalent of "skip an upcoming frame" is `project.setFrameExcluded` on that frame, followed by `scan.stop{afterCurrentFrame}` and a fresh `scan.start`/resume — three already-existing methods, not a new one. `scan.skipCurrentFrame` itself continues to refuse for the Real backend.

### Known limitation: `project.setFrame*` / `project.setRollMetadata` do not re-read the manifest before writing

The engine's project-mutating handlers (`project.setFrameExcluded`, `project.setFrameCaptureOverride`, `project.setFrameProcessingOverride`, `project.setFrameOutputOverride`, `project.setFrameAlignment`, `project.setFrameMetadataOverride`, and `project.setRollMetadata`) write back a full-project snapshot built from `server.rs`'s in-memory `ProjectState.active`. They do **not** re-read the manifest first. This means a `project.setFrame*` call issued while or after a real (or simulated) batch is running can silently overwrite receipts that the scan worker thread durably wrote to the manifest, because the in-memory copy does not know about those disk writes. `project.pendingFrames` was fixed in 11-02 to read fresh from disk, but the mutators still carry this pre-existing clobber risk. The exact locations are `server.rs::apply_frame_mutation` and the inline `project.setRollMetadata` handler. A future phase should audit every project-mutating handler's read-modify-write discipline. The existing test `project_pending_frames_reports_the_remaining_resume_set` manually pushes a receipt into both disk and `project_state.active` "so the subsequent setFrameExcluded write does not clobber it" — its own comment is direct evidence this risk is known.

### `project.create`
`{name: string, carrier: "roll36"|"strip6"|"mounted", frameCount: u32, filmProcess: "positive"|"c41ColorNegative"|"bwNegative"|"kodachrome", directory?: string}` → `{project: ScanProject, directory: string}`. `roll36` is the legacy wire token for SA-30 35 mm roll film; its preview-established `frameCount` must be 1-40. `mounted` must be exactly 1, and `strip6` must be 1-6 (else `INVALID_PARAMS`). `directory` overrides the default `~/ScanStudio Projects/<slug>-<id>` location. The manifest is written atomically and becomes the engine's active project.

### `project.open`
`{directory: string}` → `{project: ScanProject, directory: string}`. Errors: `PROJECT_NOT_FOUND`, `MANIFEST_INVALID`.

### `project.list`
`{directory?: string}` (default: the default projects root) → `{projects: [ProjectSummary]}`. Scans immediate subdirectories, silently skipping unreadable/corrupt ones, sorted newest `createdAt` first.

### `project.setFrameExcluded`
`{frameIndex: u32, excluded: bool}` → `{project: ScanProject}`. Marks (or unmarks) one frame as excluded from future scan jobs; persisted to the manifest atomically before returning. Never touches any other frame or the roll-wide `recipes`. Errors: `PROJECT_NOT_FOUND` (no project open), `INVALID_PARAMS` (frame index does not exist in this project).

### `project.setFrameCaptureOverride`
`{frameIndex: u32, capture: CaptureRecipe|null}` → `{project: ScanProject}`. Sets (`capture` populated) or clears (`capture: null`, reverting the frame to the roll-wide default) this frame's independent capture override; persisted to the manifest atomically before returning. This method alone does not change what `scan.start` does with the frame — resolving overrides into actual scan execution is a later phase's concern. Errors: `PROJECT_NOT_FOUND`, `INVALID_PARAMS`.

### `project.setFrameProcessingOverride`
`{frameIndex: u32, processing: ProcessingRecipe|null}` → `{project: ScanProject}`. Sets or clears this frame's independent processing override (autofocus/auto-exposure, Digital ICE, and B&W software dust removal); same persistence and error contract as `setFrameCaptureOverride`. A non-null `processing.filmProcess` must equal the active project's `filmProcess` or the write is rejected with `INVALID_PARAMS`. `scan.start` retains the same refusal for legacy manifests that already contain a conflicting override, so a mixed-material batch is never captured.

### `project.setFrameOutputOverride`
`{frameIndex: u32, output: OutputRecipe|null}` → `{project: ScanProject}`. Sets or clears this frame's independent output override (archive/positive/preview); same persistence and error contract as `setFrameCaptureOverride`.

### `project.setFrameAlignment`
`{frameIndex: u32, alignment: FrameAlignment|null}` → `{project: ScanProject}`. Sets or clears the saved native-preview-row offset and derivative presentation transform for this frame. The row offset remains a draft, never proof that an offset is active in a later scanner session: after a new preview, the client must replay it through `roll.setSpacingOffset`, wait for the bridge-confirmed replacement thumbnail, and keep scanning unavailable if replay fails. `approved` is retained for manifest compatibility but does not replace preview-bound manual approval. A real derivative renderer never interprets these transport rows as stored-image crop pixels. `derivativeTransform`, however, is explicit user intent: mirrors are applied in the unrotated source axes, then the clockwise quarter-turn is applied to Positive/Preview derivatives only. Rotations other than `0|90|180|270` are rejected with `INVALID_PARAMS`. Archive RGB, IR, and meter capture files never consume this transform. Same persistence and error contract as `setFrameCaptureOverride`. Errors: `PROJECT_NOT_FOUND`, `INVALID_PARAMS`.

### `project.setRollMetadata`
`{metadata: MetadataSet}` → `{project: ScanProject}`. Sets the roll-wide metadata that every frame without its own override inherits; persisted atomically before returning. Errors: `PROJECT_NOT_FOUND`.

### `project.setFrameMetadataOverride`
`{frameIndex: u32, metadata: MetadataSet|null}` → `{project: ScanProject}`. Sets (`metadata` populated) or clears (`null`, reverting to the roll-wide default) this frame's independent metadata override — a whole-object swap, not a per-field merge; same persistence and error contract as `setFrameCaptureOverride`. Errors: `PROJECT_NOT_FOUND`, `INVALID_PARAMS`.

### `project.pendingFrames`
`{}` → `{frames: [u32], totalFrames: u32, completedCount: u32, excludedCount: u32}`. Returns every frame index that is neither excluded nor already carrying a completed receipt — the exact set a client should feed back into `scan.start` to resume a partially-completed roll. Error: `PROJECT_NOT_FOUND`.

> **Resume-correctness note (additive, 2026-07-24):** real-hardware scan receipts are now durably persisted to the manifest (mirroring the simulator), and this method always answers from a fresh disk read rather than a potentially stale in-memory snapshot. Reopening or resuming a real-hardware batch therefore sees the correct pending set.

### `project.analyzeFrameDefects`
`{frameIndex: u32, capture: CaptureRecipe, processing: ProcessingRecipe}` → `{frameIndex: u32, defects: [DefectInstance], simulated: bool, digitalIceEnabled: bool, transportSmearFlagged: bool, transportSmearReason: string|null}`. Resolves `capture`/`processing` against this frame's own `captureOverride`/`processingOverride` if present, else uses them as given. Then it chooses a data source for `defects`: the frame's most recent receipt with both `rgbPath` and `irPath` present AND both files existing on disk wins, and its real RGB+IR capture is analyzed through the IR-derived defect detector; otherwise the existing seeded synthetic generator is used (`simulated: true`). `digitalIceEnabled` echoes the resolved `processing.digitalIceEnabled` so an empty `defects` array is never ambiguous between "ICE is off" and "real analysis ran and found nothing". `transportSmearFlagged`/`transportSmearReason` reflect the frame's single most recent receipt's hardware telemetry: a `"clean"` verdict is not flagged; `"smear"` or `"indeterminate"` set the flag and expose the reason. This telemetry lookup is independent of which receipt (if any) supplied the real capture. Read-only: writes nothing to the manifest. Errors: `PROJECT_NOT_FOUND` (no project open), `INVALID_PARAMS` (frame index does not exist in this project).

### `exiftool.detect`
`{}` → `ExifToolDetection`. Pure capability query, not project-scoped: tries `SCANSTUDIO_EXIFTOOL_PATH` (if set to a non-empty value, that exact path only, no fallback), then the bare `exiftool` name on `PATH`. The first candidate that spawns `<candidate> -ver` successfully wins. Never errors — total failure reports `{available: false, path: null, version: null}`.

### `project.previewMetadataCommand`
`{frameIndex: u32}` → `{available: bool, exiftoolPath: string|null, targets: [string], arguments: [string]}`. Read-only dry run: resolves this frame's effective metadata (`metadataOverride` if set, else the roll-wide `rollMetadata`) and its target file list, then returns the exact, complete argument array — every `-Tag=value` plus `-overwrite_original` plus every target path, in the order they would actually be spawned — so a human reading the response can see every argument ExifTool will receive before anything runs. `targets` is empty when the frame has no receipts yet (nothing scanned) or its latest receipt recorded no `outputs`; this is not an error. Errors: `PROJECT_NOT_FOUND` (no project open), `INVALID_PARAMS` (frame index does not exist in this project).

### `project.applyMetadata`
`{frameIndex: u32}` → `{success: bool, exitCode: i32, stdout: string, stderr: string, targets: [string]}`. Rebuilds the exact same argument array `previewMetadataCommand` would show for this frame — server-side, from the active project's own resolved metadata and receipts; it never accepts or executes a client-supplied argument list — and spawns it directly via an argument-array subprocess (never a shell). Errors: `PROJECT_NOT_FOUND` (no project open), `INVALID_PARAMS` (frame index does not exist in this project; ExifTool is not available; or the frame has no scanned outputs yet).

## Types

```
DeviceInfo      {deviceId: "sim-ls5000-0", model: "SUPER COOLSCAN 5000 ED",
                 kind: "simulated", firmware: "1.03-sim", connection: "USB (simulated)"}
ScannerStatus   {connected: bool, adapter: string|null,      // simulator: "SA-30 (simulated)" | "SA-21 (simulated)" | "MA-21 (simulated)"; real: "SA-30" | "SA-21" | "MA-21"
                 mediaLoaded: bool, carrier: "roll36"|"strip6"|"mounted"|null,
                 frameCount: u32|null, lamp: "off"|"warming"|"stable",
                 transport: "idle"|"busy"|"locked", activeJobId: string|null,
                 motionArmed?: bool,
                 filmPresent?: bool}
CaptureRecipe   {resolutionDpi: u32 (default 4000), bitDepth: 8|16 (default 16),
                 multisamplePasses: 1|2|4|8|16 (default 1), channels: "rgb"|"rgbi" (default "rgbi")}
ProcessingRecipe {filmProcess: "positive"|"c41ColorNegative"|"bwNegative"|"kodachrome",
                  autofocusEachFrame: bool, autoExposureEachFrame: bool,
                  digitalIceEnabled: bool, digitalIceMode: "legacy"|"hybrid",
                  softwareDustRemovalBw: bool (default false)}
OutputRecipe    {archive: ArchiveRecipe, positive: PositiveRecipe, preview: PreviewRecipe,
                 autoCrop: bool}
ArchiveRecipe   {enabled: bool (default true), filenameTemplate: string, destination: string,
                 fullCapturePackage: bool (default true; requires enabled)}
PositiveRecipe  {enabled: bool, fileFormat: "tiff"|"jpeg",
                 colorProfile: "adobeRgb1998"|"sRgb"|"proPhotoRgb",
                 filenameTemplate: string, destination: string}
PreviewRecipe   {enabled: bool, fileFormat: "tiff"|"jpeg", maxLongEdgePx: u32,
                 filenameTemplate: string, destination: string}
WrittenOutputs  {archivePath?: string, positivePath?: string, previewPath?: string,
                 derivativeTransform: DerivativeTransform}
Thumbnail       {brightness?: number 0.25–0.85, tint?: number -0.5–0.5, imagePath?: string,
                 boundaryRows?: [u32, u32], spacingOffset?: i64,
                 needsApproval?: bool, warnings?: [string]}
ExposureVector       {focusPosition: i64, exposureMultiplier: number,
                      redExposureUs: number, greenExposureUs: number, blueExposureUs: number}
ClippingTelemetry    {fractions: [number, number, number], clipLevel: number,
                      warningFraction: number, warning: bool}
FocusDetailTelemetry {method: string, verdict: string, score: number|null, textureSpan: number}
TransportSmearAssessment
                     {verdict: string, startRow: u32|null, suffixRows: u32,
                      minimumMatches: u32, tailMedianRms: number|null, tailMinCorr: number|null,
                      preTailMedianRms: number|null, textureSpan: number|null, reason: string}
HardwareTelemetry    {exposure: ExposureVector, clipping: ClippingTelemetry,
                      focusDetail: FocusDetailTelemetry, transportSmear: TransportSmearAssessment}
FrameIdleSample      {frameIndex: u32, idleMs: u64}
DutyCycleReport      {perFrameIdleMs: [FrameIdleSample], meanIdleMs: number, maxIdleMs: u64}
NikonlookProvenance  {bundleVersion: string, layerAPath: "blind"|"hardwareExposure",
                      gains: [number, number, number]}
AutoCropOutcome      {mode: "image", applied: bool, roi?: {y1,y2,x1,x2},
                      sourceWidth: u32, sourceHeight: u32, reason?: string}
ExposureAuthority    {rgbSource: string, irSource: string,
                      commandedChannelsRaw10ns: {R,G,B,IR: u32},
                      activeControllerChannelsRaw10ns: {R,G,B,IR: u32},
                      deviceBoundClampedChannelsRaw10ns: {R?,G?,B?: u32},
                      deviceExposureBoundsRaw10ns: [u32, u32]}
ScanReceipt     {jobId, frameIndex, startedAt: ISO-8601 UTC string, durationMs: u64,
                 passes: u32, resolutionDpi: u32, bitDepth: u32, channels: string,
                 engineVersion: string, deviceId: string, simulated: true,
                 settingsFingerprint: 16-hex-char string,
                 processing?: ProcessingRecipe, output?: OutputRecipe, outputs?: WrittenOutputs,
                 rgbPath?: string, irPath?: string, meterRgbiPath?: string,
                 hardwareTelemetry?: HardwareTelemetry, nikonlook?: NikonlookProvenance,
                 autoCrop?: AutoCropOutcome, exposureAuthority?: ExposureAuthority}
DerivativeTransform {rotationDegrees: 0|90|180|270,
                     horizontalMirror: bool, verticalMirror: bool}
FrameAlignment  {offsetRows: i64, approved: bool,
                 derivativeTransform: DerivativeTransform}
MetadataSet     {camera?: string, lens?: string, filmStock?: string,
                 process?: "positive"|"c41ColorNegative"|"bwNegative"|"kodachrome",
                 iso?: u32, date?: PartialDate, location?: string, photographer?: string,
                 copyright?: string, rollId?: string, frameNumber?: u32, notes?: string,
                 keywords: [string]}
PartialDate     {kind: "exact", date: string} |
                {kind: "monthOnly", year: i32, month: u32} |
                {kind: "yearOnly", year: i32} |
                {kind: "unknown"}
ScanProject     {schemaVersion: 4, id: string, name: string, carrier: "roll36"|"strip6"|"mounted",
                 frameCount: u32, filmProcess: "positive"|"c41ColorNegative"|"bwNegative"|"kodachrome",
                 recipes: OutputRecipe, rollMetadata: MetadataSet,
                 createdAt: ISO-8601 UTC string, frames: [ProjectFrame]}
ProjectFrame    {index: u32, excluded: bool, captureOverride?: CaptureRecipe,
                 processingOverride?: ProcessingRecipe, outputOverride?: OutputRecipe,
                 alignment?: FrameAlignment, metadataOverride?: MetadataSet,
                 receipts: [ScanReceipt]}
PendingFramesResult {frames: [u32], totalFrames: u32, completedCount: u32, excludedCount: u32}
ProjectSummary  {id, name, carrier, frameCount, filmProcess, createdAt, directory: string}
DefectInstance  {id: u32, kind: "dust"|"scratch", severity: number 0.0-1.0,
                 classification: "willCorrect"|"uncertain", centerX: number 0-1, centerY: number 0-1,
                 radius: number, endX?: number, endY?: number}
ExifToolDetection {available: bool, path: string|null, version: string|null}
PreviewMetadataCommandResult {available: bool, exiftoolPath: string|null,
                 targets: [string], arguments: [string]}
ApplyMetadataResult {success: bool, exitCode: i32, stdout: string, stderr: string, targets: [string]}
```

`lamp` is a legacy simulator field, not a claim that the LS-5000 exposes a Nikon Scan “lamp stable” status. The product UI identifies the LS-5000's documented LED source and labels simulated readiness explicitly. A real backend must expose only hardware states established by the USB/SCSI spike.

`digitalIceMode` is meaningful only when `digitalIceEnabled` is true. `legacy` represents the scanner-compatible infrared dust/scratch workflow; `hybrid` preserves the infrared mask for the modern processing pipeline. For `bwNegative`, effective capture channels are forced to `rgb` and Digital ICE is forced off because the infrared channel cannot make an honest B&W ICE claim. `softwareDustRemovalBw` is an explicit, default-off RGB-only classical-CV option for B&W derivatives; it is ignored for every non-B&W process and never changes a retained, create-only archive master. When archive retention is enabled, archive writes are create-only (never overwrite); a naming/destination collision on the archive fails that frame with `ARCHIVE_COLLISION`. Positive and preview writes may overwrite an existing file — they are regenerable derivatives, not a retained archive master. Grain reduction, fading correction, and a Fine-quality variant are intentionally not part of the supported recipe.

`PartialDate` never invents precision it wasn't given — `monthOnly`/`yearOnly` carry no day/month value at all rather than a placeholder like `01`; `unknown` carries no date value whatsoever. `MetadataSet.process` is independent of `ScanProject.filmProcess` and is never auto-synced with it.

`Thumbnail`'s `brightness`/`tint` and `imagePath` are mutually exclusive: exactly one of the `{brightness, tint}` pair or `imagePath` is populated per instance, never both, never neither. The simulator populates `brightness`/`tint` and omits the real transport fields. A real backend populates `imagePath` (BRIDGE.md's bridge-written, Nikon-render-oriented preview tile), `boundaryRows`, `spacingOffset`, `needsApproval`, and `warnings`, while omitting `brightness`/`tint` rather than fabricating them. `spacingOffset` is the bridge-confirmed value active in this exact preview session; a project manifest value alone is not equivalent. Before sending `scan.start`, clients must inspect every requested frame's current completed-preview thumbnail. If any has `needsApproval: true`, the client must obtain explicit operator confirmation, send `roll.approve` for every such frame with that preview's exact `operationId`, and only then send the original complete frame list in one `scan.start`. Starting an unapproved subset and retrying the omitted frame as a second job is not equivalent: it loses the one-traversal transport assumption.

`ScannerStatus.filmPresent` mirrors BRIDGE.md's `DeviceStatus.filmPresent` for a real backend — a live, no-motion film-presence read. `true` means the scanner reports film gripped, `false` is the verified MEDIUM NOT PRESENT response, and `null` means no trustworthy verdict was available; `null` is never absence. A verified `false` also invalidates any preview-derived `mediaLoaded`/`frameCount` claim, so the emitted status carries `mediaLoaded: false` and `frameCount: null`; this cannot discard project receipts or the unfinished resume set. Presence is not motion readiness because an end-stop-parked strip can still report `true`. The simulator always omits this field (it has no bridge to source it from).

`ScannerStatus.motionArmed` is present only for a real bridge session and mirrors BRIDGE.md's live, no-motion `DeviceStatus.motionArmed` observation. It is informative, not authority: the packaged `ScanStudioLauncher` prepares the session environment and shared authorization latch when it selects a hardware bridge, while the bridge still re-checks both at every motion-capable request. Launch itself sends no hardware command; Preview, Scan, and Eject remain explicit user actions. Direct bridge/developer launches remain responsible for their own authorization. The simulator omits the field rather than fabricating a hardware-ready state.

`OutputRecipe.autoCrop` defaults to `false` when omitted. When enabled, each frame's derived positive and preview are cropped independently to the detected image area. The retained archive master remains full-frame. `ScanReceipt.autoCrop` records the half-open ROI or the reason the crop was not applied; an approved manual `FrameAlignment` takes precedence, and an unusable detection falls back to the uncropped derivative.

`FrameAlignment.derivativeTransform` and `WrittenOutputs.derivativeTransform` default to identity when omitted so older manifests and receipts remain readable. New scans persist the selected per-frame transform before `scan.start`; the renderer applies it after crop/color processing to both Positive and Preview outputs, and records the exact applied value under `WrittenOutputs` for reproducible rerendering. In the current app, an edit made after a project already exists remains a session draft until that next scan boundary; it never rewrites existing outputs in place. The archive master, bridge RGB/IR files, and meter sidecar remain byte-untouched.

`ArchiveRecipe.enabled` defaults to `true` when omitted, preserving older projects. At least one retained output (`archive`, positive TIFF, or positive JPEG) is required for every effective frame recipe. When archive retention is disabled, `WrittenOutputs.archivePath` is absent; the real backend still reports bridge provenance in `rgbPath`/`irPath` while routing the mandatory physical capture into an engine-owned private working directory. That temporary capture is cleaned only after the observed bridge terminal closure and successful derivative completion; otherwise it is recovery-held and never represented as a user output.

`ScanReceipt.rgbPath`/`irPath`/`meterRgbiPath`/`hardwareTelemetry` are populated only by a real backend, forwarding BRIDGE.md's `ScanReceipt.rgbPath`/`irPath`/`meterRgbiPath` and `exposure`/`clipping`/`focusDetail`/`transportSmear` telemetry verbatim (mirrored field-for-field under `HardwareTelemetry`'s `ExposureVector`/`ClippingTelemetry`/`FocusDetailTelemetry`/`TransportSmearAssessment`). `rgbPath`/`irPath` are bridge-written capture-file locations, deliberately distinct from `outputs`/`WrittenOutputs` (engine-rendered retained files) — the two are never merged. The simulator omits all four (it has no bridge-sourced capture-file locations or hardware telemetry to report).

`ScanReceipt.nikonlook` records which nikonlook color pipeline actually rendered a C41 frame's positive: `bundleVersion` (the loaded bundle's own version string, e.g. `"nikonlook-v2"`), `layerAPath` (`"blind"` or `"hardwareExposure"` — which Layer-A gain estimator ran; see PARITY.md and `resources/nikonlook-v2/PROVENANCE.md` for why these can render materially different output on the same frame), and `gains` (the exact per-channel `[R, G, B]` multiplier `apply()` used). Present on both real and simulated receipts for a C41 frame once its positive/preview has rendered — this is engine-rendering provenance, not bridge-sourced hardware telemetry, so it is not restricted to real backends the way `hardwareTelemetry` is. Absent (not `null`) for every non-C41 frame (nikonlook never runs for Positive/Kodachrome/BwNegative) and for any receipt written before this field existed.

`ScanReceipt.exposureAuthority` is populated only by the real backend and forwarded verbatim from CoolscanPy's per-frame `active_exposure_authority` journal. It records the guarded RGB command source, the active controller's accepted solve (including its unchanged IR command), the device exposure bounds, and the sparse set of RGB channels clamped into those bounds. It is absent for simulated and legacy receipts and whenever the bridge cannot read a valid journal block; absence is never replaced with invented values.

`settingsFingerprint` = lowercase hex of FNV-1a 64 over the ASCII string `"{resolutionDpi}:{bitDepth}:{multisamplePasses}:{channels}"`. Golden value: `"4000:16:2:rgbi"` → `1a3d265e0b54bbd2` (as in fixture 09).

`DefectInstance.severity` mirrors `processing::ice::DefectMap`'s own renormalized convention (0.0=clean/most-certain .. 1.0=most severe/least certain); `classification` is `uncertain` once `severity` reaches `DEFECT_CLASSIFICATION_THRESHOLD` (0.78), else `willCorrect` — the same red/will-correct vs amber/uncertain split Phase 17 will apply to real per-pixel `ice::DefectMap` data once it clusters that data into instances. `endX`/`endY` are populated only when `kind` is `scratch` (the trace's second endpoint); `radius` is the dust marker's radius for `dust` and the trace's half-width for `scratch`. Every field in this response is synthetic/simulated (DEF-02) even though the wire shape is designed so Phase 17 can populate it from real IR-derived detections without a protocol change.

ExifTool never writes to an archive path. When a master exists, `previewMetadataCommand` and `applyMetadata` include only its `.xmp` sidecar plus any derivatives; for derivative-only receipts they target just those retained derivatives and create no archive XMP. This is structurally enforced (`assert_no_archive_target`), not left to caller discipline. `applyMetadata` always rebuilds its own argument array server-side from the active project's resolved metadata — it never accepts or executes a client-supplied argument list.

## Events

- `scanner.status` `{status: ScannerStatus, operationId?: string}` — on any status change. `operationId` is present only for the status emitted by a correlated preview worker; unrelated status events omit it.
- `scanner.thumbnail` `{frameIndex: u32, thumbnail: Thumbnail, operationId?: string}`
- `scanner.thumbnailsFailed` `{code: string, message: string, operationId?: string}` — a failed preview's terminal diagnosis. When emitted, it precedes that operation's zero-count `scanner.thumbnailsComplete`; both carry the same `operationId` when the request supplied one.
- `scanner.thumbnailsComplete` `{count: u32, operationId?: string}`
- `scan.jobState` `{jobId, state: JobState}` — on every job-state transition.
- `scan.progress` `{jobId, frameIndex, frameOrdinal, totalFrames, pass, totalPasses, framePercent: 0–100, jobPercent: 0–100, etaSeconds: number}` — every ~150 ms × timeScale while scanning.
- `scan.frameState` `{jobId, frameIndex, state: FrameState, attempt: u32, error?: {code, message, recoverable}}`
- `scan.frameCompleted` `{jobId, frameIndex, receipt: ScanReceipt}`
- `scan.completed` `{jobId, summary: {completed: [u32], failed: [u32], skipped: [u32], stopped: bool, dutyCycle?: DutyCycleReport}}` — emitted for every terminal state (also after stops/failures). `dutyCycle` is present only for real-backend jobs with at least one observed frame-to-frame transition; it is omitted (not `null`) otherwise, and for all simulated jobs. It is a passive measurement — it reports per-frame idle milliseconds, mean, and max — and does not gate or fail anything; comparing it against timing targets is a separate, owner-attended live concern, not a judgment made by the engine.

## State machines

**JobState** `queued → scanning → {completed | failed | stoppingAfterCurrentFrame | stoppingImmediately}`; `stoppingAfterCurrentFrame → {stopped | completed}` (completed when the stopped frame was the last one anyway); `stoppingImmediately → stopped`; `queued → stopped` (stop before first frame). Terminal: `completed`, `stopped`, `failed`. No other transitions are legal — the engine has a transition table and tests assert illegal transitions are rejected.

**FrameState** `waiting → active → {completed | failed | skipped}`; `failed → active` (retry, attempt+1). Project-level "excluded" frames never enter a job at all — exclusion is not a job state.

## Determinism

Thumbnails derive from FNV-1a 64 (offset basis `14695981039346656037`, prime `1099511628211`) over the ASCII string `"{deviceId}:{frameIndex}"`:

```
h          = fnv1a64("sim-ls5000-0:{frameIndex}")
brightness = 0.25 + 0.6 * (((h >> 8) & 0xFFFF) / 65535.0)
tint       = (((h >> 24) & 0xFF) / 255.0) - 0.5
```

Golden values (asserted by both test suites, tolerance 1e-9):

| frameIndex | brightness | tint |
|---|---|---|
| 1 | 0.573579766536965 | 0.37058823529411766 |
| 13 | 0.6080407415884641 | -0.3588235294117647 |
| 36 | 0.6227077134355687 | -0.3588235294117647 |

## Timing (× timeScale)

Thumbnail: 80 ms/frame. Scan: 500 ms per-frame overhead + 350 ms when per-frame autofocus is enabled + 250 ms when per-frame auto exposure is enabled + 700 ms per pass. Progress events every 150 ms. `etaSeconds` = remaining passes/overheads at current timeScale.

## Fault injection

`faultInjection: "demo"`: frame 13's first attempt fails with `FEED_JAM` at ~40% frame progress (`scan.frameState` → `failed`, attempt 1, recoverable error attached); the engine automatically retries once and succeeds (`active`, attempt 2). Everything else behaves as `"none"`. Default is `"none"`.

## Fixtures

`fixtures/*.json` each contain one wire object. Naming: `NN-<kind>.json`. Both test suites must: parse every fixture, decode typed payloads for the shapes they implement, re-serialize, and compare as parsed JSON values (not byte equality; float tolerance 1e-9).

### `scanner.thumbnailsFailed` (additive, 2026-07-23)

Emitted by the real backend immediately before `scanner.thumbnailsComplete` when a preview fails — either a bridge-reported detection error (`roll.previewError`, e.g. CoolscanPy RollSessionError "no scanner-addressable slots") or a stalled bridge event stream (`code: BRIDGE_STREAM_STALLED`). Payload: `{code: string, message: string, operationId?: string}`. When the initiating request carried an `operationId`, both this failure and the following zero-count completion carry that same ID. A zero-count completion preceded by this event is a FAILURE, not an empty success. Clients that predate this event ignore it per the forward-compatibility rule.
