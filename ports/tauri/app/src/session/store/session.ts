// SessionStore: the policy layer's typed store (04-02 Task 3). A plain
// TypeScript class with subscription callbacks -- no Redux/MobX; Phase 5 adds
// a thin useSyncExternalStore hook on top of this exact shape.
//
// This task implements the Job Lifecycle policy end to end and declares the
// FULL state shape the remaining six named policies (04-CONTEXT structure
// decision 2) will use; the non-job fields are data-model decisions here, not
// implementations. Policies are enforced from PROTOCOL.md's State machines
// section via assertJobTransition/assertFrameTransition -- an illegal
// transition arriving over the wire is routed to the onIntegrityError
// channel, never silently applied (threat T-04.02-02).
//
// Store design notes:
// - getState() returns a deeply cloned snapshot (structuredClone); external
//   mutation of the snapshot can never corrupt the store's internal graph.
// - Unknown event names are silent no-ops (PROTOCOL.md forward compatibility:
//   "the app must ignore unknown event names").
// - scan.* events are jobId-scoped (SessionModel's eventIsRelevant): while a
//   scan.start request is in flight (or no job exists), scan events are
//   buffered; once the response establishes the jobId, matching events apply
//   and events for any other job are dropped -- never applied to the wrong
//   job.

import { decodeEvent, type EngineTransport } from "../wire/codec";
import { newOperationId } from "../webApis";
import {
  assertFrameTransition,
  assertJobTransition,
  isTerminalJobState,
} from "./machines";
import * as defectsStore from "./defects";
import * as metadataStore from "./metadata";
import {
  type ApplyMetadataResult,
  type AnalyzeFrameDefectsResult,
  type CaptureRecipe,
  type DerivativeTransform,
  type DeviceInfo,
  type DutyCycleReport,
  type EngineError,
  type ExifToolDetection,
  type FrameAlignment,
  type FrameState,
  type JobState,
  type MetadataSet,
  type OutputRecipe,
  type PendingFramesResult,
  type PreviewMetadataCommandResult,
  type ProcessingRecipe,
  type ProjectSummary,
  type ScanProject,
  type ScanReceipt,
  type ScannerStatus,
  type Thumbnail,
  isEngineError,
  isDutyCycleReport,
  isFrameState,
  isJobState,
  isScanProject,
  isScanReceipt,
  isScannerStatus,
  isThumbnail,
} from "../wire/types";

export type FilmProcess = "positive" | "c41ColorNegative" | "bwNegative" | "kodachrome";

export interface ConnectOptions {
  timeScale?: number;
  faultInjection?: "none" | "demo";
}

export type StopMode = "afterCurrentFrame" | "immediate";

export interface ScanStartResult {
  jobId: string;
}

export interface ScanStopResult {
  acknowledged: boolean;
  mode: string;
}

export interface ScanCompletedSummary {
  completed: number[];
  failed: number[];
  skipped: number[];
  stopped: boolean;
}

export interface ConnectionState {
  connected: boolean;
  device: DeviceInfo | null;
  status: ScannerStatus | null;
}

// The full state shape every one of the 7 named policies needs. Only the
// job/frame fields are actively written by this task; the rest are declared
// so Plan 03 adds policy logic without re-architecting the state.
// - thumbnails / activeOperationId / latestCompletedPreviewOperationId:
//   preview correlation + approval binding + needsApproval gating.
// - connection: approval binding invalidation, spacing-offset replay gating,
//   and the skipCurrentFrame device-kind gate all read it.
// - jobId/jobState/frameStates/frameAttempts/frameErrors/frameReceipts:
//   job lifecycle + error taxonomy (FEED_JAM recoverable retries).
export interface SessionState {
  connection: ConnectionState;
  project: ScanProject | null;
  thumbnails: Record<number, Thumbnail>;
  // Provenance binding: the operationId of the preview that produced each
  // thumbnail. startScan's needsApproval gate only trusts tiles bound to the
  // CURRENT completed-preview operationId -- a tile from a superseded preview
  // is stale and cannot authorize a scan (review HIGH: cross-preview frame
  // subsets).
  thumbnailOperationIds: Record<number, string>;
  activeOperationId: string | null;
  latestCompletedPreviewOperationId: string | null;
  // Approvals recorded per operationId: an approval is only reachable while
  // its key IS the latest completed preview's operationId, so a superseded
  // token's approvals are unreachable without an explicit clear. Keyed by
  // operationId (the plan's "e.g. Map<operationId, Set<frameIndex>>" as a
  // shallow-clone-friendly Record<operationId, frameIndex[]>).
  approvedFrames: Record<string, number[]>;
  // Preview outcome exposed on state (05-03 Task 1): mirrors the private
  // #previewOutcome tracker so a failed preview is observable -- otherwise a
  // failed preview is indistinguishable from "never previewed". "failed" also
  // carries the wire thumbnailsFailed code/message verbatim in previewError
  // for the contact sheet's failure banner (never invented copy).
  previewOutcome: "active" | "succeeded" | "failed" | null;
  previewError: { code: string; message: string } | null;
  // A request can be rejected before the asynchronous preview operation is
  // accepted (for example HW_MOTION_NOT_ARMED). Keep that transport phase
  // separate from scanner.thumbnailsFailed so typed hardware guidance and
  // diagnostics remain reachable without inventing an async failure event.
  previewRequestFailure: { operationId: string; error: EngineError } | null;
  // Material selected for the next preview before a project exists, and the
  // material actually committed by the most recent correlated completion.
  // Project creation uses only the committed value; an ACK is not enough.
  previewFilmProcessSelection: FilmProcess;
  previewFilmProcess: FilmProcess | null;
  // Real hardware publishes its authoritative detected carrier/count in a
  // correlated status after thumbnailsComplete. Project attachment must wait
  // for that status rather than reusing the previous preview's dimensions.
  previewStatusOperationId: string | null;
  // True while project.create/open owns the project boundary, including
  // persistence of pre-project alignment drafts after an attachment.
  projectChangePending: boolean;
  // True while scanner.connect/disconnect or simulated media loading owns
  // the device-session boundary.
  connectionChangePending: boolean;
  // Serializes user-visible spacing/alignment writes against preview,
  // project, and scan boundaries so a late response cannot mutate drafts
  // after a project attachment has already persisted its snapshot.
  frameAlignmentMutationPending: boolean;
  // Subscriber-only UI selection state (05-03 Task 1): frame indices
  // 1..status.frameCount selected by the user. No wire call is attached; it
  // survives unrelated store notifications and is reset only by the
  // selection methods themselves.
  selectedFrameIndices: number[];
  // Independent presentation focus. Selecting frames decides what will be
  // scanned; focusing one frame decides what rotate/flip shortcuts edit.
  // Keeping the two concepts separate lets a six-frame batch stay selected
  // while one portrait frame is corrected.
  focusedFrameIndex: number | null;
  // Saved project.setFrameAlignment drafts (Record<frameIndex, FrameAlignment>)
  // replayed through roll.setSpacingOffset after each successful preview, and
  // the set of frames whose replay has NOT succeeded -- startScan blocks any
  // requested frame still in it (scanning stays unavailable if replay fails).
  frameAlignmentDrafts: Record<number, FrameAlignment>;
  failedFrameAlignmentReplayIndices: Set<number>;
  // Non-zero transport offsets must be rebound to the current real-device
  // preview before capture. While any requested frame is still awaiting that
  // confirmation, scan.start remains closed.
  pendingFrameAlignmentReplayIndices: Set<number>;
  jobId: string | null;
  jobState: JobState | null;
  frameStates: Record<number, FrameState>;
  frameAttempts: Record<number, number>;
  frameErrors: Record<number, EngineError>;
  frameReceipts: Record<number, ScanReceipt[]>;
  // True from the moment scan startup begins persisting frame geometry until
  // scan.start has either established the job or failed. Transform controls
  // are locked across that whole boundary so the manifest cannot lag the UI.
  scanStartPending: boolean;
  // A typed feed interruption invalidates the preview registration but must
  // not discard durable receipts from frames that already finished.
  filmFeedInterrupted: EngineError | null;
  // Latest scan.progress fields for the active job (06-03 Task 1): overall
  // job percent and ETA in seconds, plus the currently-active frame. Cleared
  // on job start and left stale (never updated for a foreign job) on
  // completion -- the run panel renders the last known values.
  scanProgress: { jobPercent: number; etaSeconds: number } | null;
  // Last job's completion summary (06-03 Task 1): the authoritative
  // completed/failed/skipped frame lists from scan.completed. The run panel
  // uses skipped to badge unreached frames after a cooperative stop -- the
  // engine reports them via this summary, not as individual frameState
  // events. Cleared on the next job start.
  lastCompletedSummary: {
    completed: number[];
    failed: number[];
    skipped: number[];
    stopped: boolean;
    dutyCycle?: DutyCycleReport;
  } | null;
}

/** One physical/project boundary owns the session at a time. */
export function sessionOperationBusy(state: Readonly<SessionState>): boolean {
  return (
    state.activeOperationId !== null ||
    state.projectChangePending ||
    state.connectionChangePending ||
    state.frameAlignmentMutationPending ||
    state.scanStartPending ||
    (state.jobState !== null && !isTerminalJobState(state.jobState))
  );
}

interface JobStateEventPayload {
  jobId: string;
  state: unknown;
}

interface FrameStateEventPayload {
  jobId: string;
  frameIndex: unknown;
  state: unknown;
  attempt: unknown;
  error?: unknown;
}

interface FrameCompletedEventPayload {
  jobId: string;
  frameIndex: unknown;
  receipt: unknown;
}

interface ScanCompletedEventPayload {
  jobId: string;
  summary?: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function createInitialState(): SessionState {
  return {
    connection: { connected: false, device: null, status: null },
    project: null,
    thumbnails: {},
    thumbnailOperationIds: {},
    activeOperationId: null,
    latestCompletedPreviewOperationId: null,
    approvedFrames: {},
    previewOutcome: null,
    previewError: null,
    previewRequestFailure: null,
    previewFilmProcessSelection: "c41ColorNegative",
    previewFilmProcess: null,
    previewStatusOperationId: null,
    projectChangePending: false,
    connectionChangePending: false,
    frameAlignmentMutationPending: false,
    selectedFrameIndices: [],
    focusedFrameIndex: null,
    frameAlignmentDrafts: {},
    failedFrameAlignmentReplayIndices: new Set(),
    pendingFrameAlignmentReplayIndices: new Set(),
    jobId: null,
    jobState: null,
    frameStates: {},
    frameAttempts: {},
    frameErrors: {},
    frameReceipts: {},
    scanStartPending: false,
    filmFeedInterrupted: null,
    scanProgress: null,
    lastCompletedSummary: null,
  };
}

export interface PreProjectPreviewRegistration {
  operationId: string;
  carrier: "roll36" | "strip6" | "mounted" | null;
  frameCount: number;
  filmProcess: FilmProcess;
}

function projectHasExactFrameSet(project: ScanProject): boolean {
  if (project.frames.length !== project.frameCount) return false;
  const indices = new Set(project.frames.map((frame) => frame.index));
  if (indices.size !== project.frameCount) return false;
  for (let frameIndex = 1; frameIndex <= project.frameCount; frameIndex += 1) {
    if (!indices.has(frameIndex)) return false;
  }
  return true;
}

/**
 * Returns the evidence that may be attached to a newly-created project.
 * Every frame must be present and correlated to the one completed operation;
 * partial, stale, failed, or still-replaying previews fail closed.
 */
export function preProjectPreviewRegistration(
  state: Readonly<SessionState>,
): PreProjectPreviewRegistration | null {
  if (
    state.project !== null ||
    state.previewOutcome !== "succeeded" ||
    state.previewFilmProcess === null ||
    state.latestCompletedPreviewOperationId === null ||
    state.activeOperationId !== null ||
    state.frameAlignmentMutationPending ||
    state.failedFrameAlignmentReplayIndices.size > 0 ||
    state.pendingFrameAlignmentReplayIndices.size > 0
  ) {
    return null;
  }
  const status = state.connection.status;
  if (
    status?.mediaLoaded !== true ||
    status.connected !== true ||
    !Number.isInteger(status.frameCount) ||
    (status.frameCount ?? 0) <= 0
  ) {
    return null;
  }
  const frameCount = status.frameCount as number;
  const operationId = state.latestCompletedPreviewOperationId;
  if (
    state.connection.device?.kind === "real" &&
    state.previewStatusOperationId !== operationId
  ) {
    return null;
  }
  const thumbnailIndices = Object.keys(state.thumbnails).map(Number);
  if (thumbnailIndices.length !== frameCount) return null;
  for (let frameIndex = 1; frameIndex <= frameCount; frameIndex += 1) {
    if (
      state.thumbnails[frameIndex] === undefined ||
      state.thumbnailOperationIds[frameIndex] !== operationId
    ) {
      return null;
    }
  }
  return {
    operationId,
    carrier: status.carrier,
    frameCount,
    filmProcess: state.previewFilmProcess,
  };
}

// ---------------------------------------------------------------------------
// Recipe mirroring helpers (04-03 Task 2) -- pure functions, no `this`.
// Client-side pre-validation duplicating PROTOCOL.md's recipe constraints so
// the UI can pre-validate, while the engine's own INVALID_PARAMS remains the
// authority and is surfaced verbatim when the wire call itself fails.
// ---------------------------------------------------------------------------

export interface ResolvedCaptureRecipe {
  resolutionDpi: number;
  bitDepth: 8 | 16;
  multisamplePasses: 1 | 2 | 4 | 8 | 16;
  channels: "rgb" | "rgbi";
}

export interface ResolvedRecipes {
  capture: ResolvedCaptureRecipe;
  processing: ProcessingRecipe | undefined;
  output: OutputRecipe | undefined;
}

export const IDENTITY_DERIVATIVE_TRANSFORM: DerivativeTransform = {
  rotationDegrees: 0,
  horizontalMirror: false,
  verticalMirror: false,
};

function normalizedDerivativeTransform(
  transform?: DerivativeTransform,
): DerivativeTransform {
  return transform === undefined
    ? { ...IDENTITY_DERIVATIVE_TRANSFORM }
    : { ...transform };
}

function frameAlignmentEquals(
  left: FrameAlignment | undefined,
  right: FrameAlignment | undefined,
): boolean {
  if (left === undefined || right === undefined) return left === right;
  const leftTransform = normalizedDerivativeTransform(left.derivativeTransform);
  const rightTransform = normalizedDerivativeTransform(right.derivativeTransform);
  return (
    left.offsetRows === right.offsetRows &&
    left.approved === right.approved &&
    leftTransform.rotationDegrees === rightTransform.rotationDegrees &&
    leftTransform.horizontalMirror === rightTransform.horizontalMirror &&
    leftTransform.verticalMirror === rightTransform.verticalMirror
  );
}

function normalizedScannerStatus(status: ScannerStatus): ScannerStatus {
  if (status.filmPresent !== false) return status;
  // The live sensor verdict is stronger than preview-derived registration.
  return { ...status, mediaLoaded: false, frameCount: null };
}

function isFilmFeedInterrupted(error: EngineError): boolean {
  if (error.code === "FILM_FEED_INTERRUPTED") return true;
  // Legacy engines folded the bridge classification into an INTERNAL or
  // ROLL_MISMATCH message. Retain that compatibility without treating every
  // generic roll mismatch as verified film absence.
  const normalized = `${error.code} ${error.message}`.toUpperCase();
  const compact = normalized.replace(/[^A-Z0-9_]/g, "");
  return (
    normalized.includes("FILM_FEED_INTERRUPTED") ||
    (normalized.includes("ROLL_MISMATCH") &&
      compact.includes("SYNCHRONIZEDPROTOCOLERROR") &&
      compact.includes("SENSE023A00"))
  );
}

// ---------------------------------------------------------------------------
// Multisample-pass device policy (defect fix: the picker and
// applyRecipeDefaults used to hardcode [1,2,4,8,16]/1 with zero device
// awareness, so a real LS-5000 scan.start got refused with INVALID_PARAMS --
// "multisamplePasses must be one of [4] for this device", real_backend.rs's
// scan_start). Mirrors Swift's MultisamplePassPolicy (SessionModel.swift)
// exactly: a real LS-5000 only accepts the device's own bridge-reported set
// (DeviceInfo.supportedMultisamplePasses, wired through engine domain.rs --
// always [4] today per RealLs5000::supported_multisample_passes' own doc
// comment); the simulator keeps the fuller historical [1,2,4,8,16] range.
// ---------------------------------------------------------------------------

/** The simulator's own fuller, historical range -- unchanged. */
export const SIMULATED_MULTISAMPLE_PASSES: readonly number[] = [1, 2, 4, 8, 16];
/**
 * Matches real_backend.rs's derive_supported_multisample_passes /
 * DeviceInfo.supportedMultisamplePasses today: always [4] for the LS-5000.
 * Used only when a connected real device's own wire-reported value is
 * absent (an older engine build predating that field) -- once every engine
 * build forwards it, this fallback becomes unreachable but stays correct.
 */
export const REAL_DEVICE_MULTISAMPLE_PASSES_FALLBACK: readonly number[] = [4];

/**
 * The multisamplePasses options a picker should offer for `device` (`null`
 * or `undefined` -- no device connected yet -- gets the fuller
 * simulator-shaped range, matching this picker's own pre-existing behavior
 * before any device connects). Mirrors Swift's
 * `MultisamplePassPolicy.supportedOptions(for:)` exactly, including
 * treating an empty wire-reported list as absent rather than offering zero
 * options.
 */
export function multisampleOptionsForDevice(device?: DeviceInfo | null): number[] {
  if (device === null || device === undefined) return [...SIMULATED_MULTISAMPLE_PASSES];
  const supported = device.supportedMultisamplePasses;
  if (supported !== undefined && supported.length > 0) {
    return [...supported].sort((a, b) => a - b);
  }
  return device.kind === "real"
    ? [...REAL_DEVICE_MULTISAMPLE_PASSES_FALLBACK]
    : [...SIMULATED_MULTISAMPLE_PASSES];
}

/**
 * The value a recipe should carry given `options`: `current` unchanged if
 * it's still supported, otherwise coerced to the closest allowed value
 * (nearest by absolute difference; ties break toward the lower value)
 * rather than always snapping to the first/lowest entry -- mirrors Swift's
 * `MultisamplePassPolicy.coerce(_:into:)` exactly, so a hypothetical future
 * [4, 8]-only device coerces a stored 6 to 4 and a stored 9 to 8, never
 * both to the same value. An empty `options` list is a no-op (returns
 * `current` unchanged) rather than crashing or fabricating a value with no
 * basis.
 */
export function coerceMultisamplePasses(current: number, options: readonly number[]): number {
  if (options.length === 0) return current;
  if (options.includes(current)) return current;
  let best = options[0];
  for (const candidate of options.slice(1)) {
    const bestDistance = Math.abs(best - current);
    const candidateDistance = Math.abs(candidate - current);
    if (
      candidateDistance < bestDistance ||
      (candidateDistance === bestDistance && candidate < best)
    ) {
      best = candidate;
    }
  }
  return best;
}

/**
 * Fills in the documented defaults from PROTOCOL.md: CaptureRecipe
 * resolutionDpi 4000, bitDepth 16, multisamplePasses 1, channels "rgbi";
 * ArchiveRecipe.enabled true and fullCapturePackage true. Preview/positive
 * have no PROTOCOL.md-documented default `enabled` value and are left as
 * given -- no invented defaults.
 *
 * multisamplePasses is additionally coerced into `device`'s own supported
 * options (multisampleOptionsForDevice/coerceMultisamplePasses above): the
 * PROTOCOL.md default of 1 is fed in as the "current" value when the caller
 * supplied none, so a real LS-5000 (whose only accepted value is 4)
 * resolves straight to 4 instead of the simulator-only default of 1 the
 * engine's own scan.start gate would then reject with INVALID_PARAMS.
 * `device` omitted (or null) -- any caller with no device context yet --
 * keeps today's simulator/no-device behavior (default 1) unchanged.
 */
export function applyRecipeDefaults(
  capture?: CaptureRecipe,
  processing?: ProcessingRecipe,
  output?: OutputRecipe,
  device?: DeviceInfo | null,
): ResolvedRecipes {
  const multisampleOptions = multisampleOptionsForDevice(device);
  return {
    capture: {
      resolutionDpi: capture?.resolutionDpi ?? 4000,
      bitDepth: capture?.bitDepth ?? 16,
      multisamplePasses: coerceMultisamplePasses(
        capture?.multisamplePasses ?? 1,
        multisampleOptions,
      ) as ResolvedCaptureRecipe["multisamplePasses"],
      channels: capture?.channels ?? "rgbi",
    },
    processing,
    output:
      output === undefined
        ? undefined
        : {
            ...output,
            archive: {
              ...output.archive,
              enabled: output.archive.enabled ?? true,
              fullCapturePackage: output.archive.fullCapturePackage ?? true,
            },
            autoCrop: output.autoCrop ?? false,
          },
  };
}

/**
 * B&W's effective processing: "For bwNegative, effective capture channels
 * are forced to rgb and Digital ICE is forced off because the infrared
 * channel cannot make an honest B&W ICE claim." The extra `channels` field
 * carries the effective capture channels (mirroring domain.rs
 * CaptureRecipe::effective_for_process); the engine ignores unknown fields
 * in the processing payload per the forward-compatibility rule, and the
 * store mirrors the same forcing on the capture recipe it forwards.
 */
export interface EffectiveProcessingRecipe extends ProcessingRecipe {
  channels: "rgb" | "rgbi";
}

export function resolveEffectiveProcessing(
  processing: ProcessingRecipe,
  captureChannels: "rgb" | "rgbi" = "rgbi",
): EffectiveProcessingRecipe {
  const isBwNegative = processing.filmProcess === "bwNegative";
  return {
    ...processing,
    channels: isBwNegative ? "rgb" : captureChannels,
    digitalIceEnabled: isBwNegative ? false : processing.digitalIceEnabled,
  };
}

export interface RecipeValidationContext {
  activeProjectFilmProcess?: FilmProcess;
  frameProcessingOverrides?: Record<number, ProcessingRecipe>;
  excludedFrameIndices?: Set<number>;
  requestedFrames: number[];
  // Device-aware multisamplePasses bound (multisampleOptionsForDevice
  // above). Omitted, this keeps validating against the full historical
  // {1,2,4,8,16} set, matching every caller that predates device
  // awareness. startScan's own call site supplies the connected device's
  // actual options so a value that reaches validateRecipe already
  // out-of-range for THIS device (bypassing applyRecipeDefaults'
  // coercion, or called directly as in the tests below) is still rejected
  // locally instead of round-tripping to the engine's INVALID_PARAMS.
  supportedMultisamplePasses?: number[];
}

export type RecipeValidationResult =
  | { valid: true }
  | { valid: false; field: string; message: string };

const VALID_BIT_DEPTHS = [8, 16];
const VALID_MULTISAMPLE_PASSES = [1, 2, 4, 8, 16];
const VALID_CHANNELS = ["rgb", "rgbi"];

/**
 * Validates a resolved recipe against PROTOCOL.md's constraints, in order:
 * bitDepth in {8,16}; multisamplePasses in {1,2,4,8,16}; channels in
 * {"rgb","rgbi"}; at least one retained output (archive.enabled ||
 * positive.enabled); NOT (fullCapturePackage && !archive.enabled); every
 * per-frame processingOverride.filmProcess must match the active project's
 * filmProcess; no requested frame may be excluded.
 */
export function validateRecipe(
  recipe: {
    capture: {
      resolutionDpi: number;
      bitDepth: number;
      multisamplePasses: number;
      channels: string;
    };
    processing?: ProcessingRecipe;
    output?: OutputRecipe;
  },
  ctx: RecipeValidationContext,
): RecipeValidationResult {
  const { capture, output } = recipe;
  if (!VALID_BIT_DEPTHS.includes(capture.bitDepth)) {
    return {
      valid: false,
      field: "capture.bitDepth",
      message: `bitDepth must be 8 or 16 (got ${capture.bitDepth})`,
    };
  }
  // Intersect, never replace: the device's advertised set narrows the
  // protocol invariant {1,2,4,8,16}, but a device advertising a value
  // outside it must not widen what this validator accepts.
  const multisampleOptions = ctx.supportedMultisamplePasses
    ? ctx.supportedMultisamplePasses.filter((passes) =>
        VALID_MULTISAMPLE_PASSES.includes(passes),
      )
    : VALID_MULTISAMPLE_PASSES;
  if (!multisampleOptions.includes(capture.multisamplePasses)) {
    return {
      valid: false,
      field: "capture.multisamplePasses",
      message: `multisamplePasses must be one of ${multisampleOptions.join(", ")} (got ${capture.multisamplePasses})`,
    };
  }
  if (!VALID_CHANNELS.includes(capture.channels)) {
    return {
      valid: false,
      field: "capture.channels",
      message: `channels must be "rgb" or "rgbi" (got ${capture.channels})`,
    };
  }
  if (
    output !== undefined &&
    !(output.archive.enabled === true || output.positive.enabled === true || output.preview.enabled)
  ) {
    return {
      valid: false,
      field: "output",
      message:
        "at least one retained output is required: archive.enabled, positive.enabled, or preview.enabled must be true",
    };
  }
  if (
    output !== undefined &&
    output.archive.fullCapturePackage === true &&
    output.archive.enabled === false
  ) {
    return {
      valid: false,
      field: "output.archive.fullCapturePackage",
      message: "fullCapturePackage: true requires archive.enabled: true",
    };
  }
  if (ctx.activeProjectFilmProcess !== undefined) {
    const overrides = ctx.frameProcessingOverrides ?? {};
    for (const frameKey of Object.keys(overrides)) {
      const override = overrides[Number(frameKey)];
      if (
        override.filmProcess !== undefined &&
        override.filmProcess !== ctx.activeProjectFilmProcess
      ) {
        return {
          valid: false,
          field: "processingOverride.filmProcess",
          message:
            `frame ${frameKey} processingOverride.filmProcess "${override.filmProcess}" ` +
            `does not match the active project's filmProcess "${ctx.activeProjectFilmProcess}"`,
        };
      }
    }
  }
  const excluded = ctx.excludedFrameIndices ?? new Set<number>();
  for (const frame of ctx.requestedFrames) {
    if (excluded.has(frame)) {
      return {
        valid: false,
        field: "frames",
        message: `frame ${frame} is an excluded frame; a request naming an excluded frame is rejected with INVALID_PARAMS`,
      };
    }
  }
  return { valid: true };
}

export class SessionStore {
  #state: SessionState = createInitialState();
  #listeners = new Set<() => void>();
  #integrityCallbacks = new Set<(error: unknown) => void>();
  // Preview-outcome tracker for preview correlation (04-03 Task 1): "active"
  // while a preview is in flight, resolving to "succeeded" via a correlated
  // thumbnailsComplete, or "failed" via a correlated thumbnailsFailed +
  // zero-count thumbnailsComplete pair. Only "active" refuses a second
  // acquireThumbnails; a resolved lane is free again. The mirrored state
  // field (state.previewOutcome) is kept in lockstep at every assignment so
  // views can observe the outcome.
  #previewOutcome: "active" | "failed" | "succeeded" | null = null;
  #pendingPreviewFilmProcess: { operationId: string; filmProcess: FilmProcess } | null = null;
  #activePreviewAuthorizationEpoch: number | null = null;

  // Selection range-extend anchor (05-03 Task 1): the frame index of the
  // last non-extend toggle, which shift-extend ranges start from (mirrors
  // ThumbnailGridView's extendingSelectionIfShiftHeld as a policy).
  #selectionAnchor: number | null = null;

  // Any media/device/preview ownership change retires a scan-start
  // authorization captured before an awaited manifest write. This is local
  // bookkeeping only; it never sends a scanner command.
  #scanAuthorizationEpoch = 0;

  // Separately scopes asynchronous saved-offset replays. A new preview or
  // media epoch makes late responses from the previous replay inert.
  #alignmentReplayEpoch = 0;

  // JobId scoping state (review HIGH): scan.* events whose jobId does not
  // match the established job are dropped; while a scan.start request is in
  // flight (jobId not yet returned), scan events are buffered here and
  // replayed through #handleEvent once the response establishes the jobId --
  // the engine's single-writer stdout can enqueue a job's first events ahead
  // of its own response line.
  #jobBoundaryPending = false;
  #pendingScanEvents: unknown[] = [];

  #invalidateScanAuthorization(): void {
    this.#scanAuthorizationEpoch += 1;
    this.#alignmentReplayEpoch += 1;
    this.#state.pendingFrameAlignmentReplayIndices = new Set();
  }

  #assertScanAuthorizationCurrent(epoch: number, projectId: string | null): void {
    if (
      this.#scanAuthorizationEpoch !== epoch ||
      (this.#state.project?.id ?? null) !== projectId ||
      this.#state.filmFeedInterrupted !== null
    ) {
      throw {
        code: "INVALID_PARAMS",
        message:
          "scan.start authorization changed while frame transforms were being saved; " +
          "review the current preview and start the scan again",
        recoverable: false,
      } satisfies EngineError;
    }
  }

  constructor(private transport: EngineTransport) {
    this.transport.subscribeEvents((raw) => this.#handleEvent(raw));
  }

  /** Registers a change listener; returns an unsubscribe function. */
  subscribe(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  /**
   * Returns a deeply cloned snapshot of the current state. The snapshot is
   * never the live internal object and shares no nested references with it,
   * so external mutation of the snapshot cannot corrupt the store (review
   * MEDIUM: the previous shallow clone exposed live Records/Set/arrays).
   */
  getState(): Readonly<SessionState> {
    return structuredClone(this.#state);
  }

  /**
   * Registers a callback invoked whenever an integrity anomaly is detected
   * (an illegal state transition arriving over the wire). The dispatch loop
   * never crashes and never silently applies the bad transition.
   */
  onIntegrityError(callback: (error: unknown) => void): () => void {
    this.#integrityCallbacks.add(callback);
    return () => {
      this.#integrityCallbacks.delete(callback);
    };
  }

  /** Thin forward to scanner.connect; records the connected device + status. */
  async connect(
    deviceId: string,
    options?: ConnectOptions,
  ): Promise<{ device: DeviceInfo; status: ScannerStatus }> {
    if (sessionOperationBusy(this.#state)) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scanner operation to finish before connecting a device",
        recoverable: false,
      } satisfies EngineError;
    }
    const params: Record<string, unknown> = { deviceId };
    if (options !== undefined) params.options = options;
    this.#state.connectionChangePending = true;
    this.#notify();
    try {
      const result = (await this.transport.sendRequest("scanner.connect", params)) as {
        device: DeviceInfo;
        status: ScannerStatus;
      };
      const status = normalizedScannerStatus(result.status);
      this.#state.connection = { connected: true, device: result.device, status };
      // Approval-binding trigger 6 (reconnect): a new successful connect
      // invalidates any prior completed-preview token.
      this.#invalidatePreviewRegistration();
      this.#state.filmFeedInterrupted = null;
      return { ...result, status };
    } finally {
      this.#state.connectionChangePending = false;
      this.#notify();
    }
  }

  /** Thin forward to scanner.disconnect; clears the connected device. */
  async disconnect(): Promise<unknown> {
    if (sessionOperationBusy(this.#state)) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scanner operation to finish before disconnecting the device",
        recoverable: false,
      } satisfies EngineError;
    }
    this.#state.connectionChangePending = true;
    this.#notify();
    try {
      const result = await this.transport.sendRequest("scanner.disconnect", {});
      this.#state.connection = { connected: false, device: null, status: null };
      // Approval-binding trigger 5 (disconnect): the current device-session
      // binding cannot survive a lost session.
      this.#invalidatePreviewRegistration();
      this.#state.filmFeedInterrupted = null;
      return result;
    } finally {
      this.#state.connectionChangePending = false;
      this.#notify();
    }
  }

  /** Thin forward to scanner.list; no state field represents the listing. */
  async listDevices(): Promise<{ devices: DeviceInfo[] }> {
    return (await this.transport.sendRequest("scanner.list", {})) as {
      devices: DeviceInfo[];
    };
  }

  /** Thin forward to scanner.status; refreshes connection.status. */
  async refreshStatus(): Promise<ScannerStatus> {
    const recoveryCandidate =
      this.#state.connection.device?.kind === "real" &&
      this.#state.previewOutcome === "succeeded" &&
      this.#state.latestCompletedPreviewOperationId !== null &&
      this.#state.previewStatusOperationId === null &&
      this.#state.activeOperationId === null
        ? {
            operationId: this.#state.latestCompletedPreviewOperationId,
            authorizationEpoch: this.#scanAuthorizationEpoch,
          }
        : null;
    const received = (await this.transport.sendRequest("scanner.status", {})) as ScannerStatus;
    const status = normalizedScannerStatus(received);
    const previous = this.#state.connection.status;
    this.#state.connection = !status.connected
      ? { connected: false, device: null, status }
      : this.#state.connection.device !== null
        ? { ...this.#state.connection, status }
        : { ...this.#state.connection, connected: false, status };
    const refreshEstablishesCompletedPreview =
      recoveryCandidate !== null &&
      this.#scanAuthorizationEpoch === recoveryCandidate.authorizationEpoch &&
      this.#state.latestCompletedPreviewOperationId === recoveryCandidate.operationId &&
      this.#state.previewOutcome === "succeeded" &&
      status.connected === true &&
      status.mediaLoaded === true &&
      status.filmPresent !== false &&
      Number.isInteger(status.frameCount) &&
      (status.frameCount ?? 0) > 0;
    if (refreshEstablishesCompletedPreview) {
      this.#state.previewStatusOperationId = recoveryCandidate.operationId;
    }
    const registrationChanged =
      status.connected === false ||
      status.filmPresent === false ||
      (!refreshEstablishesCompletedPreview && previous !== null &&
        ((previous.mediaLoaded === true && status.mediaLoaded === false) ||
          previous.carrier !== status.carrier ||
          previous.frameCount !== status.frameCount));
    if (status.filmPresent === false || registrationChanged) {
      if (this.#state.activeOperationId !== null) {
        this.#invalidateRegistrationPreservingActivePreviewLane();
      } else {
        this.#invalidatePreviewRegistration();
      }
    }
    if (
      status.motionArmed === true &&
      this.#state.previewRequestFailure?.error.code === "HW_MOTION_NOT_ARMED"
    ) {
      this.#state.previewRequestFailure = null;
    }
    this.#notify();
    return status;
  }

  /** Thin forward to sim.loadMedia; refreshes connection.status. */
  async loadMedia(carrier: "roll36" | "strip6" | "mounted"): Promise<ScannerStatus> {
    if (sessionOperationBusy(this.#state)) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scanner operation to finish before loading simulated media",
        recoverable: false,
      } satisfies EngineError;
    }
    this.#state.connectionChangePending = true;
    this.#notify();
    try {
      const received = (await this.transport.sendRequest("sim.loadMedia", { carrier })) as ScannerStatus;
      const status = normalizedScannerStatus(received);
      this.#state.connection = { ...this.#state.connection, status };
      // Approval-binding trigger 3 (media reset): a succeeding loadMedia
      // invalidates any prior completed-preview token. A media reset also
      // starts the next preview fresh: the previous preview outcome (and its
      // error, if any) no longer describes the loaded media.
      this.#invalidatePreviewRegistration();
      this.#state.filmFeedInterrupted = null;
      return status;
    } finally {
      this.#state.connectionChangePending = false;
      this.#notify();
    }
  }

  /**
   * Ejects loaded media through the engine's bounded request channel. This
   * mirrors the engine's real-backend safety gate locally: no eject request
   * is sent while a preview, scan, project/device transition, or another
   * physical boundary owns the session. The authoritative scanner.status
   * event emitted by the engine updates media state on success.
   */
  async eject(): Promise<void> {
    if (sessionOperationBusy(this.#state)) {
      throw {
        code: "SCANNER_BUSY",
        message: "wait for the active scanner operation to finish before ejecting media",
        recoverable: true,
      } satisfies EngineError;
    }
    if (!this.#state.connection.connected) {
      throw {
        code: "NOT_CONNECTED",
        message: "scanner is not connected",
        recoverable: true,
      } satisfies EngineError;
    }
    if (this.#state.connection.status?.mediaLoaded !== true) {
      throw {
        code: "NO_MEDIA",
        message: "no media is loaded",
        recoverable: true,
      } satisfies EngineError;
    }
    this.#state.connectionChangePending = true;
    this.#notify();
    try {
      await this.transport.sendRequest("scanner.eject", {});
      // Ejection changes physical registration even if a transport adapter
      // delays the status event; never let the old preview authorize capture.
      this.#invalidatePreviewRegistration();
      this.#state.filmFeedInterrupted = null;
    } finally {
      this.#state.connectionChangePending = false;
      this.#notify();
    }
  }

  /**
   * Toggles frame selection (05-03 Task 1, UI-only state -- no wire call).
   * Non-extend toggles membership (add if absent, remove if present) and
   * updates the range anchor; extend selects the inclusive range from the
   * last non-extend anchor to frameIndex, clamped to the currently loaded
   * 1..status.frameCount. Ignored entirely (no-op) when no media is loaded
   * or the index is outside the loaded range.
   */
  toggleFrameSelection(frameIndex: number, extend: boolean): void {
    const frameCount = this.#state.connection.status?.frameCount ?? null;
    if (frameCount === null || !Number.isInteger(frameIndex) || frameIndex < 1 || frameIndex > frameCount) {
      return;
    }
    if (!extend) {
      const selected = this.#state.selectedFrameIndices;
      this.#state.selectedFrameIndices = selected.includes(frameIndex)
        ? selected.filter((index) => index !== frameIndex)
        : [...selected, frameIndex];
      this.#selectionAnchor = frameIndex;
    } else {
      const anchor = this.#selectionAnchor ?? frameIndex;
      const start = Math.max(1, Math.min(anchor, frameIndex));
      const end = Math.min(frameCount, Math.max(anchor, frameIndex));
      const range: number[] = [];
      for (let index = start; index <= end; index += 1) {
        range.push(index);
      }
      this.#state.selectedFrameIndices = range;
    }
    this.#state.focusedFrameIndex = frameIndex;
    this.#notify();
  }

  /** Changes the transform/inspection target without changing scan selection. */
  focusFrame(frameIndex: number): void {
    const frameCount = this.#state.connection.status?.frameCount ?? null;
    if (
      frameCount === null ||
      !Number.isInteger(frameIndex) ||
      frameIndex < 1 ||
      frameIndex > frameCount
    ) {
      return;
    }
    if (this.#state.focusedFrameIndex === frameIndex) return;
    this.#state.focusedFrameIndex = frameIndex;
    this.#notify();
  }

  /** Selects every loaded frame 1..frameCount; no-op when no media is loaded. */
  selectAll(): void {
    const frameCount = this.#state.connection.status?.frameCount ?? null;
    if (frameCount === null || frameCount < 1) return;
    const all: number[] = [];
    for (let index = 1; index <= frameCount; index += 1) {
      all.push(index);
    }
    this.#state.selectedFrameIndices = all;
    if (
      this.#state.focusedFrameIndex === null ||
      this.#state.focusedFrameIndex > frameCount
    ) {
      this.#state.focusedFrameIndex = 1;
    }
    this.#notify();
  }

  /** Empties the selection. */
  clearSelection(): void {
    if (this.#state.selectedFrameIndices.length === 0) return;
    this.#state.selectedFrameIndices = [];
    this.#notify();
  }

  /** Selects the material for the next preview when no project is active. */
  setPreviewFilmProcess(filmProcess: FilmProcess): void {
    if (this.#state.project !== null || sessionOperationBusy(this.#state)) return;
    if (this.#state.previewFilmProcessSelection === filmProcess) return;
    this.#state.previewFilmProcessSelection = filmProcess;
    if (this.#state.previewFilmProcess !== null) {
      // The visible thumbnails were rendered for a different material. Do
      // not let the project form silently save that completed registration
      // after the operator has selected a new process for the roll.
      this.#invalidatePreviewRegistration();
    }
    this.#notify();
  }

  /**
   * Forward to scanner.acquireThumbnails with a fresh correlation token.
   * Preview correlation policy (04-03 Task 1): a fresh newOperationId()
   * (crypto.randomUUID when the context provides it -- see webApis.ts for
   * why Windows historically did not) is generated per accepted preview; a
   * second call while one is active is
   * refused locally with no wire call; the previous completed-preview token
   * is cleared immediately at call time (roll.approve trigger 1 -- the new
   * preview supersedes it whether or not it succeeds); and a rejected wire
   * request releases the preview lane, so the store never stays busy on a
   * request the engine did not accept.
   */
  async acquireThumbnails(
    frames?: number[],
    filmProcess?: FilmProcess,
  ): Promise<{ accepted: boolean; frames: number[] }> {
    if (this.#state.connectionChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the device connection change to finish before requesting a preview",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before requesting a preview",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.frameAlignmentMutationPending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active frame-alignment change to finish before requesting a preview",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scan to finish before requesting a preview",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.activeOperationId !== null) {
      throw {
        code: "INVALID_PARAMS",
        message:
          "a thumbnail preview is already active; wait for it to complete before requesting another",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.project !== null &&
      filmProcess !== undefined &&
      filmProcess !== this.#state.project.filmProcess
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "filmProcess conflicts with the active project's filmProcess",
        recoverable: false,
      } satisfies EngineError;
    }
    // newOperationId never throws by contract, but the pre-wire section must
    // stay visible if a platform surprise ever violates that again: the
    // Windows insecure-context TypeError thrown here (bare crypto.randomUUID,
    // pre-fix) was swallowed by the caller's rejection consumer and left no
    // trace at all. Any throw before the wire call now records a typed
    // request failure so the existing failure banner renders it.
    let operationId: string;
    try {
      operationId = newOperationId();
    } catch (error) {
      const requestError: EngineError = {
        code: "INTERNAL",
        message:
          error instanceof Error
            ? `preview operation id could not be created: ${error.message}`
            : "preview operation id could not be created",
        recoverable: false,
      };
      this.#state.previewRequestFailure = { operationId: "preview-id-unavailable", error: requestError };
      this.#notify();
      throw error;
    }
    const effectiveFilmProcess =
      this.#state.project?.filmProcess ??
      filmProcess ??
      this.#state.previewFilmProcessSelection;
    this.#previewOutcome = "active";
    this.#state.previewOutcome = "active";
    this.#state.previewError = null;
    this.#state.previewRequestFailure = null;
    this.#state.previewFilmProcess = null;
    this.#state.previewStatusOperationId = null;
    if (this.#state.project === null && frames === undefined) {
      // A pre-project full preview replaces the prior registration. Clear
      // its tiles so a shorter real re-preview cannot retain out-of-range
      // thumbnails that permanently prevent attachment.
      this.#state.thumbnails = {};
      this.#state.thumbnailOperationIds = {};
      this.#state.selectedFrameIndices = [];
      this.#state.focusedFrameIndex = null;
      this.#selectionAnchor = null;
    }
    this.#state.activeOperationId = operationId;
    this.#state.latestCompletedPreviewOperationId = null;
    this.#pendingPreviewFilmProcess = { operationId, filmProcess: effectiveFilmProcess };
    this.#invalidateScanAuthorization();
    this.#activePreviewAuthorizationEpoch = this.#scanAuthorizationEpoch;
    const params: Record<string, unknown> = {
      operationId,
      filmProcess: effectiveFilmProcess,
    };
    if (frames !== undefined) params.frames = frames;
    // Subscribers must see the lane become active before a slow transport ACK
    // so a second click cannot queue another motion-capable request.
    this.#notify();
    try {
      const result = (await this.transport.sendRequest("scanner.acquireThumbnails", params)) as {
        accepted: boolean;
        frames: number[];
      };
      this.#notify();
      return result;
    } catch (error) {
      // Events can arrive before the request response. A late rejection must
      // not erase a correlated completion/failure (or a replacement lane).
      if (
        this.#state.activeOperationId === operationId &&
        this.#previewOutcome === "active"
      ) {
        this.#previewOutcome = null;
        this.#state.previewOutcome = null;
        this.#state.previewError = null;
        this.#state.activeOperationId = null;
        this.#pendingPreviewFilmProcess = null;
        this.#activePreviewAuthorizationEpoch = null;
        const requestError: EngineError = isEngineError(error)
          ? error
          : {
              code: "INTERNAL",
              message: error instanceof Error ? error.message : "preview request failed",
              recoverable: false,
            };
        this.#state.previewRequestFailure = { operationId, error: requestError };
        if (isEngineError(error)) {
          if (
            error.code === "HW_MOTION_NOT_ARMED" &&
            this.#state.connection.device?.kind === "real" &&
            this.#state.connection.status !== null
          ) {
            this.#state.connection = {
              ...this.#state.connection,
              status: { ...this.#state.connection.status, motionArmed: false },
            };
          }
        }
        this.#notify();
      }
      throw error;
    }
  }

  /**
   * roll.approve binding (04-03 Task 1): operationId must exactly equal the
   * token of the most recent successfully completed preview. Local
   * validation runs before any wire call; on success the frameIndex is
   * recorded as approved under that exact operationId (keyed by
   * operationId, so a superseded token's approvals become unreachable
   * without an explicit clear).
   */
  async approveFrame(frameIndex: number, options?: { attended?: boolean }): Promise<void> {
    const operationId = this.#state.latestCompletedPreviewOperationId;
    if (operationId === null) {
      throw {
        code: "INVALID_PARAMS",
        message: "No completed preview to approve against",
        recoverable: false,
      } satisfies EngineError;
    }
    // Attended binding (feed-detector round; ScanStudio #24/#16/#42).
    // `attended` is omitted from the params entirely unless the caller opted
    // in, so an ordinary approval stays byte-identical on the wire. It is
    // the driver, not this store, that decides whether a roll may bind
    // below "high"; an ineligible roll comes back INVALID_PARAMS.
    const params: Record<string, unknown> = { frameIndex, operationId };
    if (options?.attended === true) params.attended = true;
    await this.transport.sendRequest("roll.approve", params);
    const approved = this.#state.approvedFrames[operationId] ?? [];
    if (!approved.includes(frameIndex)) {
      approved.push(frameIndex);
    }
    this.#state.approvedFrames = { ...this.#state.approvedFrames, [operationId]: approved };
    this.#notify();
  }

  /**
   * Attended binding (feed-detector round; ScanStudio #24/#16/#42). Approves
   * EVERY requested frame against the current completed preview as an
   * operator-attended acceptance, so a roll whose lattice confidence is
   * below what unattended scanning requires can still be scanned with a
   * human watching. Anything less than every requested frame is refused by
   * the driver, so this deliberately has no partial-subset form -- the same
   * whole-batch shape the needsApproval gate above already enforces.
   */
  async approveEveryFrameAttended(frames: readonly number[]): Promise<void> {
    if (frames.length === 0) {
      throw {
        code: "INVALID_PARAMS",
        message: "attended approval requires at least one frame",
        recoverable: false,
      } satisfies EngineError;
    }
    for (const frameIndex of frames) {
      await this.approveFrame(frameIndex, { attended: true });
    }
  }

  /**
   * roll.setSpacingOffset (04-03 Task 2): local range validation (frame 1:
   * 0..144, every other frame: -144..144) and a completed-preview token
   * check run BEFORE any wire call. The store trusts ONLY the
   * server-returned replacement thumbnail as the confirmed offset -- never
   * the locally requested value (T-04.03-02) -- and changing the offset
   * invalidates that frame's prior recorded approval.
   */
  async setSpacingOffset(frameIndex: number, offsetRows: number): Promise<void> {
    if (this.#state.connectionChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the device connection change to finish before adjusting spacing",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before adjusting spacing",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.frameAlignmentMutationPending ||
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active frame-alignment or scan boundary to finish before adjusting spacing",
        recoverable: false,
      } satisfies EngineError;
    }
    const bounds = frameIndex === 1 ? { min: 0, max: 144 } : { min: -144, max: 144 };
    if (offsetRows < bounds.min || offsetRows > bounds.max) {
      throw {
        code: "INVALID_PARAMS",
        message: `offsetRows ${offsetRows} is outside the supported range for frame ${frameIndex} (${bounds.min}..${bounds.max})`,
        recoverable: false,
      } satisfies EngineError;
    }
    const operationId = this.#state.latestCompletedPreviewOperationId;
    if (operationId === null) {
      throw {
        code: "INVALID_PARAMS",
        message: "No completed preview to set a spacing offset against",
        recoverable: false,
      } satisfies EngineError;
    }
    this.#state.frameAlignmentMutationPending = true;
    this.#notify();
    try {
      const result = (await this.transport.sendRequest("roll.setSpacingOffset", {
        frameIndex,
        offsetRows,
        operationId,
      })) as { thumbnail?: unknown } | undefined;
      if (this.#state.latestCompletedPreviewOperationId !== operationId) {
        throw {
          code: "INVALID_PARAMS",
          message: "the spacing-offset response belongs to a superseded preview",
          recoverable: false,
        } satisfies EngineError;
      }
      // Fail closed: a malformed response is never applied; the prior tile and
      // its approvals stay authoritative.
      if (result === undefined || !isThumbnail(result.thumbnail)) return;
      this.#state.thumbnails = { ...this.#state.thumbnails, [frameIndex]: result.thumbnail };
      this.#state.thumbnailOperationIds = {
        ...this.#state.thumbnailOperationIds,
        [frameIndex]: operationId,
      };
      // Changing the offset invalidates prior manual approval for that frame.
      const approved = this.#state.approvedFrames[operationId];
      if (approved !== undefined) {
        const remaining = approved.filter((frame) => frame !== frameIndex);
        if (remaining.length === 0) {
          const next = { ...this.#state.approvedFrames };
          delete next[operationId];
          this.#state.approvedFrames = next;
        } else {
          this.#state.approvedFrames = { ...this.#state.approvedFrames, [operationId]: remaining };
        }
      }
      // Keep the confirmed transport offset and the independent presentation
      // transform together in the one FrameAlignment object the engine owns.
      // Persistence is intentionally deferred to the scan-start boundary.
      const prior = this.#frameAlignmentFor(frameIndex);
      this.#state.frameAlignmentDrafts = {
        ...this.#state.frameAlignmentDrafts,
        [frameIndex]: {
          offsetRows: result.thumbnail.spacingOffset ?? offsetRows,
          approved: false,
          derivativeTransform: normalizedDerivativeTransform(prior?.derivativeTransform),
        },
      };
    } finally {
      this.#state.frameAlignmentMutationPending = false;
      this.#notify();
    }
  }

  /**
   * project.setFrameAlignment (04-03 Task 2): saves the draft locally and to
   * the project manifest. A saved alignment is a DRAFT, never proof that an
   * offset is active in a later scanner session: after the next successful
   * preview it is replayed through roll.setSpacingOffset (see
   * #replayFrameAlignmentDrafts), and scanning stays unavailable for any
   * frame whose replay has not succeeded.
   */
  async setFrameAlignmentDraft(
    frameIndex: number,
    alignment: FrameAlignment | null,
  ): Promise<void> {
    if (this.#state.connectionChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the device connection change to finish before saving frame transforms",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before saving frame transforms",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.frameAlignmentMutationPending ||
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active frame-alignment or scan boundary to finish before saving frame transforms",
        recoverable: false,
      } satisfies EngineError;
    }
    this.#state.frameAlignmentMutationPending = true;
    this.#notify();
    try {
      const result = (await this.transport.sendRequest("project.setFrameAlignment", {
        frameIndex,
        alignment,
      })) as { project?: unknown } | undefined;
      if (alignment === null) {
        const next = { ...this.#state.frameAlignmentDrafts };
        delete next[frameIndex];
        this.#state.frameAlignmentDrafts = next;
        // Removing the draft also removes any prior replay failure for the
        // frame (review HIGH): a cleared alignment must not stay blocked by a
        // failure that referred to the deleted offset.
        this.#state.failedFrameAlignmentReplayIndices.delete(frameIndex);
        this.#state.pendingFrameAlignmentReplayIndices.delete(frameIndex);
      } else {
        this.#state.frameAlignmentDrafts = {
          ...this.#state.frameAlignmentDrafts,
          [frameIndex]: alignment,
        };
      }
      if (result !== undefined && isScanProject(result.project)) {
        this.#state.project = result.project;
      }
    } finally {
      this.#state.frameAlignmentMutationPending = false;
      this.#notify();
    }
  }

  #frameAlignmentFor(frameIndex: number): FrameAlignment | undefined {
    return (
      this.#state.frameAlignmentDrafts[frameIndex] ??
      this.#state.project?.frames.find((frame) => frame.index === frameIndex)?.alignment
    );
  }

  /** Returns a materialized identity for legacy or transform-free frames. */
  frameDerivativeTransform(frameIndex: number): DerivativeTransform {
    return normalizedDerivativeTransform(
      this.#frameAlignmentFor(frameIndex)?.derivativeTransform,
    );
  }

  /** Transform edits are drafts until the next scan-start persistence gate. */
  frameTransformsAreEditable(): boolean {
    return this.#state.activeOperationId !== null ||
      this.#state.projectChangePending ||
      this.#state.frameAlignmentMutationPending ||
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
      ? false
      : true;
  }

  setFrameDerivativeTransform(
    frameIndex: number,
    transform: DerivativeTransform,
  ): void {
    if (!this.frameTransformsAreEditable()) return;
    if (!isRecord(transform) || ![0, 90, 180, 270].includes(transform.rotationDegrees)) {
      return;
    }
    const base = this.#frameAlignmentFor(frameIndex);
    this.#state.frameAlignmentDrafts = {
      ...this.#state.frameAlignmentDrafts,
      [frameIndex]: {
        offsetRows: base?.offsetRows ?? 0,
        approved: base?.approved ?? false,
        derivativeTransform: { ...transform },
      },
    };
    this.#notify();
  }

  rotateFrames(frameIndices: number[], degrees: -90 | 90): void {
    if (!this.frameTransformsAreEditable()) return;
    for (const frameIndex of frameIndices) {
      const current = this.frameDerivativeTransform(frameIndex);
      const rotationDegrees = ((current.rotationDegrees + degrees + 360) % 360) as
        DerivativeTransform["rotationDegrees"];
      const base = this.#frameAlignmentFor(frameIndex);
      this.#state.frameAlignmentDrafts[frameIndex] = {
        offsetRows: base?.offsetRows ?? 0,
        approved: base?.approved ?? false,
        derivativeTransform: { ...current, rotationDegrees },
      };
    }
    this.#state.frameAlignmentDrafts = { ...this.#state.frameAlignmentDrafts };
    this.#notify();
  }

  toggleHorizontalMirror(frameIndices: number[]): void {
    this.#toggleMirror(frameIndices, "horizontalMirror");
  }

  toggleVerticalMirror(frameIndices: number[]): void {
    this.#toggleMirror(frameIndices, "verticalMirror");
  }

  #toggleMirror(
    frameIndices: number[],
    axis: "horizontalMirror" | "verticalMirror",
  ): void {
    if (!this.frameTransformsAreEditable()) return;
    for (const frameIndex of frameIndices) {
      const current = this.frameDerivativeTransform(frameIndex);
      const base = this.#frameAlignmentFor(frameIndex);
      this.#state.frameAlignmentDrafts[frameIndex] = {
        offsetRows: base?.offsetRows ?? 0,
        approved: base?.approved ?? false,
        derivativeTransform: { ...current, [axis]: !current[axis] },
      };
    }
    this.#state.frameAlignmentDrafts = { ...this.#state.frameAlignmentDrafts };
    this.#notify();
  }

  resetFrameTransforms(frameIndices: number[]): void {
    if (!this.frameTransformsAreEditable()) return;
    for (const frameIndex of frameIndices) {
      const base = this.#frameAlignmentFor(frameIndex);
      if (base === undefined) continue;
      this.#state.frameAlignmentDrafts[frameIndex] = {
        offsetRows: base.offsetRows,
        approved: base.approved,
        derivativeTransform: { ...IDENTITY_DERIVATIVE_TRANSFORM },
      };
    }
    this.#state.frameAlignmentDrafts = { ...this.#state.frameAlignmentDrafts };
    this.#notify();
  }

  /**
   * project.setFrameCaptureOverride (06-02 Task 3): whole-object-swap
   * override semantics -- a populated capture recipe replaces the frame's
   * override in full (never a merged patch), and `null` reverts the frame to
   * the roll-wide default. The server-returned project is the authority and
   * replaces local project state; frame-related session bindings that depend
   * on the frame set are untouched (this does not change the scanned frame
   * set, only its recipes).
   */
  async setFrameCaptureOverride(
    frameIndex: number,
    capture: CaptureRecipe | null,
  ): Promise<void> {
    const result = (await this.transport.sendRequest("project.setFrameCaptureOverride", {
      frameIndex,
      capture,
    })) as { project?: unknown } | undefined;
    if (result !== undefined && isScanProject(result.project)) {
      this.#state.project = result.project;
    }
    this.#notify();
  }

  /**
   * project.setFrameProcessingOverride (06-02 Task 3): whole-object-swap
   * override semantics (a populated processing recipe replaces in full; null
   * reverts to the roll default). The server-returned project replaces local
   * project state.
   */
  async setFrameProcessingOverride(
    frameIndex: number,
    processing: ProcessingRecipe | null,
  ): Promise<void> {
    const result = (await this.transport.sendRequest("project.setFrameProcessingOverride", {
      frameIndex,
      processing,
    })) as { project?: unknown } | undefined;
    if (result !== undefined && isScanProject(result.project)) {
      this.#state.project = result.project;
    }
    this.#notify();
  }

  /**
   * project.setFrameOutputOverride (06-02 Task 3): whole-object-swap
   * override semantics (a populated output recipe replaces in full; null
   * reverts to the roll default). The server-returned project replaces local
   * project state.
   */
  async setFrameOutputOverride(
    frameIndex: number,
    output: OutputRecipe | null,
  ): Promise<void> {
    const result = (await this.transport.sendRequest("project.setFrameOutputOverride", {
      frameIndex,
      output,
    })) as { project?: unknown } | undefined;
    if (result !== undefined && isScanProject(result.project)) {
      this.#state.project = result.project;
    }
    this.#notify();
  }

  /**
   * Adapter exposing the transport's sendRequest as the metadata module's
   * injected request channel, so the store's metadata methods delegate to the
   * same wrapper functions every other caller uses -- the wire method/param
   * strings live in exactly one place (metadata.ts).
   */
  #metadataRequest(): metadataStore.MetadataRequest {
    return (method: string, params?: unknown) => this.transport.sendRequest(method, params);
  }

  /**
   * exiftool.detect (07-01 Task 1): thin forward to the capability probe.
   * Returns the engine's detection verbatim ({available, path, version});
   * the engine never errors on this call, so a total failure is reported as
   * available: false rather than a rejection.
   */
  async detectExifTool(): Promise<ExifToolDetection> {
    return metadataStore.detectExifTool(this.#metadataRequest());
  }

  /**
   * project.previewMetadataCommand (07-01 Task 1): read-only dry run that
   * returns the exact, complete argument array ExifTool would receive for
   * this frame, before anything runs. Errors (PROJECT_NOT_FOUND /
   * INVALID_PARAMS) propagate to the caller's existing error-display path.
   */
  async previewMetadataCommand(frameIndex: number): Promise<PreviewMetadataCommandResult> {
    return metadataStore.previewMetadataCommand(this.#metadataRequest(), frameIndex);
  }

  /**
   * project.applyMetadata (07-01 Task 1): runs ExifTool against the frame's
   * scanned outputs. Mirrors SessionModel.swift's one-shot "returns nil on
   * failure" pattern: a rejection resolves to null (never throws), so the
   * caller renders the resolved exitCode/stdout/stderr truthfully -- never
   * an invented success message (threat T-07-04). The engine rebuilds the
   * argument array server-side and verifies the fingerprint of the exact
   * preview the operator saw; this method never sends a client argument list.
   */
  async applyMetadata(
    frameIndex: number,
    previewFingerprint: string,
  ): Promise<ApplyMetadataResult | null> {
    return metadataStore.applyMetadata(
      this.#metadataRequest(),
      frameIndex,
      previewFingerprint,
    );
  }

  /**
   * project.setRollMetadata (07-01 Task 1): whole-object metadata swap for
   * the roll-wide default every frame without its own override inherits.
   * Sends the complete MetadataSet (never a per-field diff); the
   * server-returned project replaces local project state.
   */
  async setRollMetadata(metadata: MetadataSet): Promise<void> {
    const result = await metadataStore.setRollMetadata(this.#metadataRequest(), metadata);
    if (isScanProject(result.project)) {
      this.#state.project = result.project;
    }
    this.#notify();
  }

  /**
   * project.setFrameMetadataOverride (07-01 Task 1): whole-object-swap
   * override semantics -- a populated MetadataSet replaces the frame's
   * override in full (never a per-field merge), and `null` reverts the frame
   * to the roll-wide default. The server-returned project replaces local
   * project state.
   */
  async setFrameMetadataOverride(
    frameIndex: number,
    metadata: MetadataSet | null,
  ): Promise<void> {
    const result = await metadataStore.setFrameMetadataOverride(
      this.#metadataRequest(),
      frameIndex,
      metadata,
    );
    if (isScanProject(result.project)) {
      this.#state.project = result.project;
    }
    this.#notify();
  }

  /**
   * project.analyzeFrameDefects (07-02 Task 2): read-only defect analysis for
   * one frame. The engine resolves the frame's effective capture/processing
   * (including its own overrides), chooses the data source, and reports the
   * `simulated` flag honestly. The caller renders the result verbatim --
   * never re-deriving the classification threshold or masking the flag.
   */
  async analyzeFrameDefects(
    frameIndex: number,
  ): Promise<AnalyzeFrameDefectsResult> {
    return defectsStore.analyzeFrameDefects(
      (method: string, params?: unknown) => this.transport.sendRequest(method, params),
      frameIndex,
    );
  }

  /**
   * Replays every saved frame-alignment draft through roll.setSpacingOffset
   * after a successful preview (PROTOCOL.md project.setFrameAlignment: "after
   * a new preview, the client must replay it through roll.setSpacingOffset,
   * wait for the bridge-confirmed replacement thumbnail, and keep scanning
   * unavailable if replay fails"). Failures land in
   * failedFrameAlignmentReplayIndices, which startScan's pre-wire-call gate
   * blocks on; a later successful replay removes the frame again.
   */
  async #replayFrameAlignmentDrafts(
    operationId: string,
    replayEpoch: number,
  ): Promise<void> {
    // Derivative transforms are presentation-only. Only a non-zero native
    // transport offset needs a bridge-confirmed replay; sending an identity
    // offset to roll.setSpacingOffset would incorrectly make simulator scans
    // depend on a real-device-only method.
    const targets = Object.entries(this.#state.frameAlignmentDrafts)
      .filter(([, draft]) => draft.offsetRows !== 0)
      .map(([frameKey]) => Number(frameKey))
      .sort((a, b) => a - b);

    for (const [frameKey, draft] of Object.entries(this.#state.frameAlignmentDrafts)) {
      if (draft.offsetRows === 0) {
        this.#state.failedFrameAlignmentReplayIndices.delete(Number(frameKey));
      }
    }
    this.#state.pendingFrameAlignmentReplayIndices = new Set(targets);
    this.#notify();

    for (const frameIndex of targets) {
      if (
        this.#alignmentReplayEpoch !== replayEpoch ||
        this.#state.latestCompletedPreviewOperationId !== operationId
      ) {
        return;
      }
      const draft = this.#state.frameAlignmentDrafts[frameIndex];
      try {
        await this.setSpacingOffset(frameIndex, draft.offsetRows);
        if (
          this.#alignmentReplayEpoch !== replayEpoch ||
          this.#state.latestCompletedPreviewOperationId !== operationId
        ) {
          return;
        }
        this.#state.failedFrameAlignmentReplayIndices.delete(frameIndex);
      } catch {
        if (this.#alignmentReplayEpoch !== replayEpoch) return;
        this.#state.failedFrameAlignmentReplayIndices.add(frameIndex);
      } finally {
        if (this.#alignmentReplayEpoch === replayEpoch) {
          this.#state.pendingFrameAlignmentReplayIndices.delete(frameIndex);
          this.#notify();
        }
      }
    }
  }

  /** Thin forward to project.create; records the active project. */
  async createProject(
    name: string,
    carrier: "roll36" | "strip6" | "mounted",
    frameCount: number,
    filmProcess: "positive" | "c41ColorNegative" | "bwNegative" | "kodachrome",
    directory?: string,
  ): Promise<{ project: ScanProject; directory: string }> {
    if (this.#state.connectionChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the device connection change to finish before creating a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.activeOperationId !== null) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active preview to finish before creating a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.frameAlignmentMutationPending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active frame-alignment change to finish before creating a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scan to finish before creating a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before creating a project",
        recoverable: false,
      } satisfies EngineError;
    }
    this.#state.projectChangePending = true;
    this.#notify();
    try {
      const registration = preProjectPreviewRegistration(this.#state);
      const attachCandidate =
        registration !== null &&
        registration.frameCount === frameCount &&
        registration.filmProcess === filmProcess &&
        (registration.carrier === null || registration.carrier === carrier)
          ? { ...registration, authorizationEpoch: this.#scanAuthorizationEpoch }
          : null;
      const params: Record<string, unknown> = { name, carrier, frameCount, filmProcess };
      if (directory !== undefined) params.directory = directory;
      const rawResult = await this.transport.sendRequest("project.create", params);
      if (
        !isRecord(rawResult) ||
        !isScanProject(rawResult.project) ||
        typeof rawResult.directory !== "string"
      ) {
        throw {
          code: "INTERNAL",
          message: "project.create returned an invalid project",
          recoverable: false,
        } satisfies EngineError;
      }
      const result = {
        project: rawResult.project,
        directory: rawResult.directory,
      };
      const responseMatchesRequest =
        result.project.carrier === carrier &&
        result.project.frameCount === frameCount &&
        result.project.filmProcess === filmProcess;
      const attachmentProjectUsable =
        responseMatchesRequest && projectHasExactFrameSet(result.project);
      const currentRegistration = preProjectPreviewRegistration(this.#state);
      const attachmentStillCurrent =
        attachCandidate !== null &&
        this.#scanAuthorizationEpoch === attachCandidate.authorizationEpoch &&
        currentRegistration?.operationId === attachCandidate.operationId &&
        currentRegistration.frameCount === attachCandidate.frameCount &&
        currentRegistration.filmProcess === attachCandidate.filmProcess &&
        currentRegistration.carrier === attachCandidate.carrier;

      // project.create makes the returned project active in the engine. Adopt
      // any structurally valid response even if its identity fields disagree,
      // but detach the preview and surface the protocol violation fail-closed.
      this.#state.project = result.project;
      if (attachmentProjectUsable && attachmentStillCurrent) {
        this.#attachProjectToPreview(result.project);
        // Pre-project rotation/mirroring/spacing drafts become durable at
        // the same attachment boundary. Without this write, closing and
        // reopening the newly-created project silently loses those edits.
        const persistenceEpoch = this.#scanAuthorizationEpoch;
        const draftFrames = Object.keys(this.#state.frameAlignmentDrafts).map(Number);
        await this.#persistFrameGeometryBeforeScan(
          draftFrames,
          persistenceEpoch,
          result.project.id,
        );
      } else {
        this.#resetSessionBinding(result.project);
      }
      if (!responseMatchesRequest) {
        throw {
          code: "INTERNAL",
          message: "project.create returned a project that does not match the requested carrier, frame count, and film process",
          recoverable: false,
        } satisfies EngineError;
      }
      if (attachmentStillCurrent && !attachmentProjectUsable) {
        throw {
          code: "INTERNAL",
          message: "project.create returned a malformed frame set for the completed preview",
          recoverable: false,
        } satisfies EngineError;
      }
      return {
        project: this.#state.project ?? result.project,
        directory: result.directory,
      };
    } finally {
      this.#state.projectChangePending = false;
      this.#notify();
    }
  }

  /**
   * Resets every project-scoped binding on a successful project change:
   * completed-preview token, approvals, thumbnail provenance, alignment
   * drafts (rebuilt from the project's own frames), replay failures, and the
   * job id plus its pending-event buffer.
   */
  #resetSessionBinding(project: ScanProject): void {
    this.#state.latestCompletedPreviewOperationId = null;
    this.#state.activeOperationId = null;
    this.#previewOutcome = null;
    this.#state.previewOutcome = null;
    this.#state.previewError = null;
    this.#state.previewRequestFailure = null;
    this.#state.previewFilmProcess = null;
    this.#state.previewStatusOperationId = null;
    this.#pendingPreviewFilmProcess = null;
    this.#activePreviewAuthorizationEpoch = null;
    this.#state.approvedFrames = {};
    this.#state.thumbnailOperationIds = {};
    this.#state.selectedFrameIndices = [];
    this.#state.focusedFrameIndex = null;
    this.#selectionAnchor = null;
    const drafts: Record<number, FrameAlignment> = {};
    for (const frame of project.frames) {
      if (frame.alignment !== undefined) drafts[frame.index] = frame.alignment;
    }
    this.#state.frameAlignmentDrafts = drafts;
    this.#state.failedFrameAlignmentReplayIndices = new Set();
    this.#state.pendingFrameAlignmentReplayIndices = new Set();
    this.#resetProjectRuntime(project);
  }

  /**
   * First save after an exact pre-project preview is an attachment boundary,
   * not a media/project switch. Preserve registration and user review state
   * while adopting the durable project's receipts and job boundary.
   */
  #attachProjectToPreview(project: ScanProject): void {
    this.#state.activeOperationId = null;
    this.#state.previewRequestFailure = null;
    this.#pendingPreviewFilmProcess = null;
    this.#activePreviewAuthorizationEpoch = null;
    this.#resetProjectRuntime(project);
  }

  #resetProjectRuntime(project: ScanProject): void {
    this.#state.jobId = null;
    this.#state.scanStartPending = false;
    this.#state.filmFeedInterrupted = null;
    this.#jobBoundaryPending = false;
    this.#pendingScanEvents = [];
    this.#invalidateScanAuthorization();
    const receipts: Record<number, ScanReceipt[]> = {};
    for (const frame of project.frames) {
      if (frame.receipts.length > 0) receipts[frame.index] = [...frame.receipts];
    }
    this.#state.frameReceipts = receipts;
  }

  /** Thin forward to project.open; records the active project. */
  async openProject(directory: string): Promise<{ project: ScanProject; directory: string }> {
    if (this.#state.connectionChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the device connection change to finish before opening a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.activeOperationId !== null) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active preview to finish before opening a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.frameAlignmentMutationPending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active frame-alignment change to finish before opening a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scan to finish before opening a project",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before opening a project",
        recoverable: false,
      } satisfies EngineError;
    }
    this.#state.projectChangePending = true;
    this.#notify();
    try {
      const rawResult = await this.transport.sendRequest("project.open", { directory });
      if (
        !isRecord(rawResult) ||
        !isScanProject(rawResult.project) ||
        typeof rawResult.directory !== "string"
      ) {
        throw {
          code: "INTERNAL",
          message: "project.open returned an invalid project",
          recoverable: false,
        } satisfies EngineError;
      }
      const result = { project: rawResult.project, directory: rawResult.directory };
      this.#state.project = result.project;
      this.#resetSessionBinding(result.project);
      return result;
    } finally {
      this.#state.projectChangePending = false;
      this.#notify();
    }
  }

  /** Thin forward to project.list; no state field represents the listing. */
  async listProjects(directory?: string): Promise<{ projects: ProjectSummary[] }> {
    const params: Record<string, unknown> = {};
    if (directory !== undefined) params.directory = directory;
    return (await this.transport.sendRequest("project.list", params)) as {
      projects: ProjectSummary[];
    };
  }

  /**
   * Persists the exact alignment/transform drafts visible for the requested
   * frames before scan.start can resolve the project's per-frame overrides.
   * The server-returned project is adopted after every write, so a malformed
   * or wrong-project response fails closed before any motion-capable request.
   */
  async #persistFrameGeometryBeforeScan(
    frames: number[],
    authorizationEpoch: number,
    projectId: string | null,
  ): Promise<void> {
    const startingProject = this.#state.project;
    if (startingProject === null) return;
    for (const frameIndex of [...new Set(frames)].sort((a, b) => a - b)) {
      const currentProject = this.#state.project;
      if (currentProject === null || currentProject.id !== startingProject.id) {
        throw {
          code: "INVALID_PARAMS",
          message: "the active project changed while frame transforms were being saved",
          recoverable: false,
        } satisfies EngineError;
      }
      const persisted = currentProject.frames.find((frame) => frame.index === frameIndex);
      if (persisted === undefined) continue;
      const desired = this.#state.frameAlignmentDrafts[frameIndex];
      if (frameAlignmentEquals(persisted.alignment, desired)) continue;
      const response = (await this.transport.sendRequest("project.setFrameAlignment", {
        frameIndex,
        alignment: desired ?? null,
      })) as { project?: unknown } | undefined;
      this.#assertScanAuthorizationCurrent(authorizationEpoch, projectId);
      if (response === undefined || !isScanProject(response.project)) {
        throw {
          code: "INTERNAL",
          message: `project.setFrameAlignment returned an invalid project for frame ${frameIndex}`,
          recoverable: false,
        } satisfies EngineError;
      }
      if (
        response.project.id !== startingProject.id ||
        response.project.carrier !== startingProject.carrier ||
        response.project.frameCount !== startingProject.frameCount ||
        response.project.filmProcess !== startingProject.filmProcess ||
        !projectHasExactFrameSet(response.project)
      ) {
        throw {
          code: "INVALID_PARAMS",
          message: "the frame transform response belongs to a different or malformed project",
          recoverable: false,
        } satisfies EngineError;
      }
      const saved = response.project.frames.find((frame) => frame.index === frameIndex);
      if (saved === undefined || !frameAlignmentEquals(saved.alignment, desired)) {
        throw {
          code: "INTERNAL",
          message: `project.setFrameAlignment did not persist frame ${frameIndex}`,
          recoverable: false,
        } satisfies EngineError;
      }
      this.#state.project = response.project;
    }
  }

  /**
   * Forwards to scan.start and records the job. The job record is seeded
   * optimistically (jobState queued, every requested frame waiting),
   * mirroring the engine's own job record (sim.rs maps every requested frame
   * to Waiting at scan.start) BEFORE the wire call: the engine's stdout is a
   * single writer thread fed by producers, so the worker's first
   * scan.jobState/frameState events can be enqueued ahead of the response
   * line, and seeding keeps those events legal transitions. The engine
   * validates before spawning, so scan.* events only exist for accepted
   * requests; a rejected request reverts the seeding (plus the transient
   * notify) before re-throwing.
   */
  async startScan(
    frames: number[],
    recipe: CaptureRecipe,
    processing?: ProcessingRecipe,
    output?: OutputRecipe,
    frameAlignments?: Record<number, FrameAlignment>,
  ): Promise<ScanStartResult> {
    if (this.#state.connectionChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the device connection change to finish before starting a scan",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.filmFeedInterrupted !== null) {
      throw {
        code: "FILM_FEED_INTERRUPTED",
        message:
          "the previous film registration is no longer valid; reinsert the film, acquire a fresh preview, then resume the remaining frames",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.activeOperationId !== null) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active preview to finish before starting a scan",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before starting a scan",
        recoverable: false,
      } satisfies EngineError;
    }
    if (this.#state.frameAlignmentMutationPending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active frame-alignment change to finish before starting a scan",
        recoverable: false,
      } satisfies EngineError;
    }
    if (
      this.#state.scanStartPending ||
      (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState))
    ) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active scan to finish before starting another scan",
        recoverable: false,
      } satisfies EngineError;
    }
    // Recipe mirroring (04-03 Task 2): client-side pre-validation running
    // BEFORE the needsApproval gate and the wire call. Defaults are applied
    // deterministically, B&W forcing mirrors domain.rs
    // CaptureRecipe::effective_for_process, and the active project supplies
    // the filmProcess authority + excluded/override frame sets. A local
    // rejection is EngineError-shaped; if the wire call itself still fails
    // (a case this mirror does not model), the engine's own
    // code/message/recoverable reach the caller byte-for-byte unmodified.
    //
    // multisamplePasses is additionally resolved against the CONNECTED
    // device (multisampleOptionsForDevice/applyRecipeDefaults above): the
    // same guarantee Swift's coerceMultisamplePassesForConnectedDevice
    // gives by construction (its scanMultisamplePasses is proactively kept
    // valid for the connected device at every connect/project boundary
    // before scan.start ever sees it) reached here as a final coercion
    // pass at the one place every scan.start call funnels through,
    // regardless of what the caller's own recipe draft happened to carry.
    const connectedDevice = this.#state.connection.device;
    const multisampleOptions = multisampleOptionsForDevice(connectedDevice);
    const resolved = applyRecipeDefaults(recipe, processing, output, connectedDevice);
    const effectiveProcessing =
      resolved.processing !== undefined
        ? resolveEffectiveProcessing(resolved.processing, resolved.capture.channels)
        : undefined;
    const isBwNegative = effectiveProcessing?.filmProcess === "bwNegative";
    const effectiveCapture: ResolvedCaptureRecipe = isBwNegative
      ? { ...resolved.capture, channels: "rgb" }
      : resolved.capture;
    const project = this.#state.project;
    const frameProcessingOverrides: Record<number, ProcessingRecipe> = {};
    const excludedFrameIndices = new Set<number>();
    if (project !== null) {
      for (const frame of project.frames) {
        if (frame.processingOverride !== undefined) {
          frameProcessingOverrides[frame.index] = frame.processingOverride;
        }
        if (frame.excluded) excludedFrameIndices.add(frame.index);
      }
    }
    const validation = validateRecipe(
      { capture: effectiveCapture, processing: effectiveProcessing, output: resolved.output },
      {
        activeProjectFilmProcess: project?.filmProcess,
        frameProcessingOverrides,
        excludedFrameIndices,
        requestedFrames: frames,
        supportedMultisamplePasses: multisampleOptions,
      },
    );
    if (!validation.valid) {
      throw {
        code: "INVALID_PARAMS",
        message: validation.message,
        recoverable: false,
      } satisfies EngineError;
    }

    // needsApproval gating (04-03 Task 1): every requested frame's current
    // completed-preview thumbnail is inspected before the wire call. Any
    // needsApproval: true frame without a recorded approval under the
    // CURRENT completed-preview operationId blocks the ENTIRE batch locally
    // -- never a silently filtered subset, because starting an approved
    // subset and retrying the omitted frame as a second job would lose the
    // one-traversal transport assumption (T-04.03-03).
    //
    // A thumbnail is only "current" when bound to the CURRENT completed
    // preview's operationId (thumbnailOperationIds, review HIGH). A tile
    // from a superseded preview -- e.g. preview A covered frame 1, preview B
    // covered only frame 2 -- is stale and cannot authorize a scan even when
    // its needsApproval flag reads false: the flag describes an older
    // operator decision, not this preview's. Frames with no thumbnail at all
    // carry no needsApproval claim and pass (PROTOCOL.md's gate is keyed on
    // the flag, not on tile presence).
    const blockingFrames: number[] = [];
    const staleThumbnails: number[] = [];
    const operationId = this.#state.latestCompletedPreviewOperationId;
    for (const frame of frames) {
      const thumbnail = this.#state.thumbnails[frame];
      if (thumbnail === undefined) continue;
      if (operationId === null || this.#state.thumbnailOperationIds[frame] !== operationId) {
        staleThumbnails.push(frame);
        continue;
      }
      if (thumbnail.needsApproval === true) {
        const approved = this.#state.approvedFrames[operationId];
        if (!approved?.includes(frame)) blockingFrames.push(frame);
      }
    }
    if (staleThumbnails.length > 0 || blockingFrames.length > 0) {
      const parts: string[] = [];
      if (blockingFrames.length > 0) {
        parts.push(
          `frame(s) [${blockingFrames.join(", ")}] require operator approval of their completed ` +
            `preview before scanning; approve them via roll.approve and resend the original ` +
            `complete frame list in one scan.start`,
        );
      }
      if (staleThumbnails.length > 0) {
        parts.push(
          `frame(s) [${staleThumbnails.join(", ")}] carry thumbnails from a superseded preview; ` +
            `acquire a fresh preview covering them and resend the original complete frame list`,
        );
      }
      throw {
        code: "INVALID_PARAMS",
        message: `scan.start blocked: ${parts.join("; ")}`,
        recoverable: false,
      } satisfies EngineError;
    }

    // Frame-alignment replay gate (04-03 Task 2): PROTOCOL.md keeps scanning
    // unavailable while a saved offset has not replayed through
    // roll.setSpacingOffset successfully. Any requested frame in the failed
    // set blocks the ENTIRE batch (same structural impossibility as the
    // needsApproval gate -- no partial-subset path exists).
    const replayBlocked = frames.filter((frame) =>
      this.#state.failedFrameAlignmentReplayIndices.has(frame),
    );
    if (replayBlocked.length > 0) {
      throw {
        code: "INVALID_PARAMS",
        message:
          `scan.start blocked: frame alignment replay has not succeeded for frame(s) ` +
          `[${replayBlocked.join(", ")}]; the saved offset must replay through ` +
          `roll.setSpacingOffset before scanning is available`,
        recoverable: false,
      } satisfies EngineError;
    }

    const replayPending = frames.filter((frame) =>
      this.#state.pendingFrameAlignmentReplayIndices.has(frame),
    );
    if (replayPending.length > 0) {
      throw {
        code: "INVALID_PARAMS",
        message:
          `scan.start blocked: saved frame alignment is still being restored for frame(s) ` +
          `[${replayPending.join(", ")}]; wait for the current preview restore to finish`,
        recoverable: false,
      } satisfies EngineError;
    }

    const params: Record<string, unknown> = { frames, recipe: effectiveCapture };
    if (effectiveProcessing !== undefined) params.processing = effectiveProcessing;
    if (resolved.output !== undefined) params.output = resolved.output;
    if (frameAlignments !== undefined) params.frameAlignments = frameAlignments;

    const authorizationEpoch = this.#scanAuthorizationEpoch;
    const authorizationProjectId = this.#state.project?.id ?? null;
    assertJobTransition(null, "queued");
    this.#state.scanStartPending = true;
    this.#state.jobState = "queued";
    this.#state.scanProgress = null;
    this.#state.lastCompletedSummary = null;
    const previousFrameStates = this.#state.frameStates;
    this.#state.frameStates = { ...previousFrameStates };
    for (const frame of frames) {
      this.#state.frameStates[frame] = "waiting";
    }
    this.#notify();

    // Job-boundary window: from here until the response establishes the
    // jobId, scan events are buffered (the engine can enqueue a job's first
    // events ahead of its response line); they are replayed once jobId is
    // set, and only events for THIS job survive the replay. Seed this before
    // the asynchronous geometry persistence so startScan retains its
    // original immediate queued/waiting semantics for subscribers.
    this.#jobBoundaryPending = true;
    try {
      if (this.#state.project !== null) {
        await this.#persistFrameGeometryBeforeScan(
          frames,
          authorizationEpoch,
          authorizationProjectId,
        );
      }
      this.#assertScanAuthorizationCurrent(authorizationEpoch, authorizationProjectId);
      const result = (await this.transport.sendRequest("scan.start", params)) as ScanStartResult;
      this.#state.jobId = result.jobId;
      this.#jobBoundaryPending = false;
      this.#state.scanStartPending = false;
      this.#flushPendingScanEvents();
      this.#notify();
      return result;
    } catch (error) {
      this.#state.jobState = null;
      this.#state.scanStartPending = false;
      this.#state.scanProgress = null;
      this.#state.frameStates = previousFrameStates;
      this.#jobBoundaryPending = false;
      this.#pendingScanEvents = [];
      this.#notify();
      throw error;
    }
  }

  /** Replays buffered scan events now that the current jobId is established. */
  #flushPendingScanEvents(): void {
    const pending = this.#pendingScanEvents;
    this.#pendingScanEvents = [];
    for (const raw of pending) {
      this.#handleEvent(raw);
    }
  }

  /**
   * Forwards to scan.stop VERBATIM -- no client-side mode gating, since
   * PROTOCOL.md documents no mode restriction by device kind.
   */
  async stopJob(jobId: string, mode: StopMode): Promise<ScanStopResult> {
    return (await this.transport.sendRequest("scan.stop", { jobId, mode })) as ScanStopResult;
  }

  /**
   * skipCurrentFrame is a simulator-only primitive (PROTOCOL.md: "Only
   * supported against the simulated backend"). For any other device kind this
   * refuses locally with no wire call, naming the real-hardware equivalent:
   * project.setFrameExcluded on the frame, then scan.stop{afterCurrentFrame},
   * then a fresh scan.start/resume (threat T-04.02-03). NOTE: DeviceInfo.kind
   * is an explicit simulated/real discriminator, so this local refusal
   * remains valid for both current backends.
   */
  async skipCurrentFrame(jobId: string): Promise<{ acknowledged: boolean }> {
    const kind = this.#state.connection.device?.kind ?? null;
    if (kind !== "simulated") {
      throw new Error(
        `scan.skipCurrentFrame is only supported against the simulated backend ` +
          `(connected device kind is ${kind}); on real hardware, exclude the frame via ` +
          `project.setFrameExcluded, then scan.stop{afterCurrentFrame}, then a fresh ` +
          `scan.start/resume with the remaining frames`,
      );
    }
    return (await this.transport.sendRequest("scan.skipCurrentFrame", { jobId })) as {
      acknowledged: boolean;
    };
  }

  /** Thin forward to project.pendingFrames. */
  async pendingFrames(): Promise<PendingFramesResult> {
    if (this.#state.projectChangePending) {
      throw {
        code: "INVALID_PARAMS",
        message: "wait for the active project change to finish before reading pending frames",
        recoverable: false,
      } satisfies EngineError;
    }
    return (await this.transport.sendRequest("project.pendingFrames", {})) as PendingFramesResult;
  }

  /**
   * Resume workflow: project.pendingFrames answers every frame index that is
   * neither excluded nor already carrying a completed receipt, and that exact
   * set is fed into the same scan-start path -- one fresh job over the
   * returned list, never a partial subset.
   */
  async resumeJob(
    recipe: CaptureRecipe,
    processing?: ProcessingRecipe,
    output?: OutputRecipe,
    frameAlignments?: Record<number, FrameAlignment>,
  ): Promise<ScanStartResult> {
    const pending = await this.pendingFrames();
    return this.startScan(pending.frames, recipe, processing, output, frameAlignments);
  }

  #invalidatePreviewRegistration(): void {
    this.#state.thumbnails = {};
    this.#state.thumbnailOperationIds = {};
    this.#state.activeOperationId = null;
    this.#state.latestCompletedPreviewOperationId = null;
    this.#state.approvedFrames = {};
    this.#previewOutcome = null;
    this.#state.previewOutcome = null;
    this.#state.previewError = null;
    this.#state.previewRequestFailure = null;
    this.#state.previewFilmProcess = null;
    this.#state.previewStatusOperationId = null;
    this.#pendingPreviewFilmProcess = null;
    this.#activePreviewAuthorizationEpoch = null;
    this.#state.selectedFrameIndices = [];
    this.#state.focusedFrameIndex = null;
    this.#selectionAnchor = null;
    this.#clearUnsavedPreProjectAlignment();
    this.#invalidateScanAuthorization();
  }

  #clearUnsavedPreProjectAlignment(): void {
    if (this.#state.project !== null) return;
    this.#state.frameAlignmentDrafts = {};
    this.#state.failedFrameAlignmentReplayIndices = new Set();
    this.#state.pendingFrameAlignmentReplayIndices = new Set();
  }

  /**
   * A generic status update cannot prove an asynchronous preview worker has
   * released its physical lane. Retire its registration evidence and epoch,
   * but keep the active operation/button lock until its correlated terminal.
   */
  #invalidateRegistrationPreservingActivePreviewLane(): void {
    this.#state.thumbnails = {};
    this.#state.thumbnailOperationIds = {};
    this.#state.latestCompletedPreviewOperationId = null;
    this.#state.approvedFrames = {};
    this.#state.previewFilmProcess = null;
    this.#state.previewStatusOperationId = null;
    this.#pendingPreviewFilmProcess = null;
    this.#state.selectedFrameIndices = [];
    this.#state.focusedFrameIndex = null;
    this.#selectionAnchor = null;
    this.#clearUnsavedPreProjectAlignment();
    this.#invalidateScanAuthorization();
  }

  #recordFilmFeedInterrupted(error: EngineError): void {
    this.#state.filmFeedInterrupted = error;
    this.#invalidatePreviewRegistration();
    const status = this.#state.connection.status;
    if (status !== null) {
      this.#state.connection = {
        ...this.#state.connection,
        status: {
          ...status,
          mediaLoaded: false,
          frameCount: null,
          filmPresent: false,
        },
      };
    }
  }

  #handleEvent(raw: unknown): void {
    const event = decodeEvent(raw);
    if (event === null) return;
    switch (event.event) {
      case "scanner.status": {
        const payload = event.payload as { status?: unknown; operationId?: unknown };
        if (!isRecord(payload) || !isScannerStatus(payload.status)) return;
        const previous = this.#state.connection.status;
        const status = normalizedScannerStatus(payload.status);
        this.#state.connection = !status.connected
          ? { connected: false, device: null, status }
          : this.#state.connection.device !== null
            ? { ...this.#state.connection, status }
            : { ...this.#state.connection, connected: false, status };
        // Approval-binding invalidation observed through status transitions
        // (roll.approve triggers 4-5): eject (mediaLoaded true -> false),
        // media change (carrier/frameCount change), and disconnect
        // (connected: false) each invalidate the completed-preview token.
        // This event NEVER clears the active-preview tracker -- only a
        // correlated thumbnailsComplete / thumbnailsFailed+thumbnailsComplete
        // sequence does that, so an untagged generic status cannot terminate
        // an active preview.
        const operationId =
          typeof payload.operationId === "string" ? payload.operationId : null;
        const statusBelongsToPreview =
          operationId !== null &&
          (operationId === this.#state.activeOperationId ||
            operationId === this.#state.latestCompletedPreviewOperationId);
        if (statusBelongsToPreview) {
          this.#state.previewStatusOperationId = operationId;
        }
        let registrationChanged = false;
        if (status.connected === false) {
          this.#state.latestCompletedPreviewOperationId = null;
          registrationChanged = true;
        } else if (previous !== null) {
          const ejected = previous.mediaLoaded === true && status.mediaLoaded === false;
          const mediaChanged =
            previous.carrier !== status.carrier ||
            previous.frameCount !== status.frameCount;
          // The real backend emits thumbnailsComplete first and then a status
          // event carrying the same operationId with the newly detected
          // carrier/count. That transition establishes this preview; treating
          // it as foreign media would immediately erase the token we just
          // completed.
          if (ejected || (mediaChanged && !statusBelongsToPreview)) {
            this.#state.latestCompletedPreviewOperationId = null;
            registrationChanged = true;
          }
        }
        if (status.filmPresent === false || registrationChanged) {
          if (this.#state.activeOperationId !== null) {
            this.#invalidateRegistrationPreservingActivePreviewLane();
          } else {
            this.#invalidatePreviewRegistration();
          }
        }
        if (
          status.motionArmed === true &&
          this.#state.previewRequestFailure?.error.code === "HW_MOTION_NOT_ARMED"
        ) {
          this.#state.previewRequestFailure = null;
        }
        this.#notify();
        return;
      }
      case "scanner.thumbnail": {
        const payload = event.payload as {
          frameIndex?: unknown;
          thumbnail?: unknown;
          operationId?: unknown;
        };
        if (!isRecord(payload) || typeof payload.frameIndex !== "number" || !isThumbnail(payload.thumbnail)) {
          return;
        }
        // Fail closed (T-04.03-01): a thumbnail event may only add its tile
        // while a preview is active AND its token matches the store's own
        // active token (this store always sends a fresh operationId per
        // accepted preview). Missing or mismatched tokens are no-ops.
        if (
          this.#state.activeOperationId === null ||
          payload.operationId !== this.#state.activeOperationId ||
          this.#activePreviewAuthorizationEpoch !== this.#scanAuthorizationEpoch
        ) {
          return;
        }
        this.#state.thumbnails = { ...this.#state.thumbnails, [payload.frameIndex]: payload.thumbnail };
        this.#state.thumbnailOperationIds = {
          ...this.#state.thumbnailOperationIds,
          [payload.frameIndex]: payload.operationId,
        };
        this.#notify();
        return;
      }
      case "scanner.thumbnailsFailed": {
        const payload = event.payload as { code?: unknown; message?: unknown; operationId?: unknown };
        if (!isRecord(payload) || typeof payload.code !== "string" || typeof payload.message !== "string") {
          return;
        }
        if (
          this.#state.activeOperationId === null ||
          payload.operationId !== this.#state.activeOperationId ||
          this.#activePreviewAuthorizationEpoch !== this.#scanAuthorizationEpoch
        ) {
          return;
        }
        // A failed preview's terminal diagnosis: the tracker resolves to
        // "failed" when the correlated zero-count completion arrives. The
        // completed-preview token stays null -- a failed preview never sets
        // one (roll.approve trigger 2). The wire's code/message are exposed
        // on state verbatim (previewError) so the contact sheet renders the
        // engine's own diagnosis -- never invented copy -- and subscribers
        // are notified now, not only at the trailing zero-count completion.
        this.#previewOutcome = "failed";
        this.#state.previewOutcome = "failed";
        this.#state.previewError = { code: payload.code, message: payload.message };
        this.#pendingPreviewFilmProcess = null;
        this.#state.previewFilmProcess = null;
        this.#notify();
        return;
      }
      case "scanner.thumbnailsComplete": {
        const payload = event.payload as { count?: unknown; operationId?: unknown };
        if (!isRecord(payload) || typeof payload.count !== "number") return;
        if (
          this.#state.activeOperationId === null ||
          payload.operationId !== this.#state.activeOperationId
        ) {
          // Mismatch or missing token: no-op; the tracker stays "active".
          return;
        }
        // Resolve the preview lane: "succeeded" (this operationId becomes the
        // latest completed preview) UNLESS a preceding correlated
        // thumbnailsFailed already marked it failed -- a zero-count
        // completion preceded by a failure is a FAILURE, not an empty
        // success.
        const previewStillAuthorized =
          this.#activePreviewAuthorizationEpoch === this.#scanAuthorizationEpoch;
        if (this.#previewOutcome !== "failed" && previewStillAuthorized) {
          this.#previewOutcome = "succeeded";
          this.#state.previewOutcome = "succeeded";
          this.#state.latestCompletedPreviewOperationId = payload.operationId;
          if (this.#pendingPreviewFilmProcess?.operationId === payload.operationId) {
            this.#state.previewFilmProcess =
              this.#pendingPreviewFilmProcess.filmProcess;
          }
          this.#pendingPreviewFilmProcess = null;
          this.#state.filmFeedInterrupted = null;
          // A successful preview is the trigger for replaying every saved
          // frame-alignment draft through roll.setSpacingOffset (Task 2);
          // failures land in failedFrameAlignmentReplayIndices and keep
          // those frames excluded from startScan.
          const replayEpoch = this.#alignmentReplayEpoch;
          void this.#replayFrameAlignmentDrafts(payload.operationId, replayEpoch);
        } else if (this.#previewOutcome !== "failed") {
          // A foreign/untagged status changed media identity while this
          // worker was active. Its terminal releases the lane but cannot
          // resurrect registration evidence for the superseded media.
          this.#previewOutcome = null;
          this.#state.previewOutcome = null;
          this.#state.previewError = null;
          this.#state.latestCompletedPreviewOperationId = null;
          this.#state.previewFilmProcess = null;
        }
        this.#state.activeOperationId = null;
        this.#activePreviewAuthorizationEpoch = null;
        this.#pendingPreviewFilmProcess = null;
        this.#notify();
        return;
      }
      case "scan.progress": {
        const payload = event.payload as { jobId?: unknown; jobPercent?: unknown; etaSeconds?: unknown };
        if (
          !isRecord(payload) ||
          typeof payload.jobId !== "string" ||
          typeof payload.jobPercent !== "number" ||
          typeof payload.etaSeconds !== "number"
        ) {
          return;
        }
        if (this.#jobBoundaryPending || this.#state.jobId === null) {
          if (this.#jobBoundaryPending) this.#pendingScanEvents.push(raw);
          return;
        }
        if (payload.jobId !== this.#state.jobId) return;
        this.#state.scanProgress = {
          jobPercent: payload.jobPercent,
          etaSeconds: payload.etaSeconds,
        };
        this.#notify();
        return;
      }
      case "scan.jobState": {
        const payload = event.payload as JobStateEventPayload;
        if (!isRecord(payload) || typeof payload.jobId !== "string" || !isJobState(payload.state)) {
          return;
        }
        // JobId scoping (review HIGH): events are only relevant while a job
        // exists and the ids match (SessionModel's eventIsRelevant). During a
        // scan.start request the event is buffered; otherwise a stale or
        // foreign job's event is dropped, never applied to the wrong job.
        if (this.#jobBoundaryPending || this.#state.jobId === null) {
          if (this.#jobBoundaryPending) this.#pendingScanEvents.push(raw);
          return;
        }
        if (payload.jobId !== this.#state.jobId) return;
        try {
          assertJobTransition(this.#state.jobState, payload.state);
        } catch (error) {
          this.#reportIntegrityError(error);
          return;
        }
        this.#state.jobState = payload.state;
        this.#notify();
        return;
      }
      case "scan.frameState": {
        const payload = event.payload as FrameStateEventPayload;
        if (
          !isRecord(payload) ||
          typeof payload.jobId !== "string" ||
          typeof payload.frameIndex !== "number" ||
          !isFrameState(payload.state) ||
          typeof payload.attempt !== "number"
        ) {
          return;
        }
        if (this.#jobBoundaryPending || this.#state.jobId === null) {
          if (this.#jobBoundaryPending) this.#pendingScanEvents.push(raw);
          return;
        }
        if (payload.jobId !== this.#state.jobId) return;
        const current = this.#state.frameStates[payload.frameIndex] ?? null;
        try {
          assertFrameTransition(current, payload.state);
        } catch (error) {
          this.#reportIntegrityError(error);
          return;
        }
        this.#state.frameStates[payload.frameIndex] = payload.state;
        this.#state.frameAttempts[payload.frameIndex] = payload.attempt;
        // The error is attached to the failing attempt; an attempt without an
        // error clears it (mirrors SessionModel's applyFrameState
        // removeValue(forKey:) -- the retry succeeded, the jam is resolved).
        if (payload.error !== undefined && isEngineError(payload.error)) {
          this.#state.frameErrors[payload.frameIndex] = payload.error;
          if (isFilmFeedInterrupted(payload.error)) {
            this.#recordFilmFeedInterrupted(payload.error);
          }
        } else {
          delete this.#state.frameErrors[payload.frameIndex];
        }
        this.#notify();
        return;
      }
      case "scan.frameCompleted": {
        const payload = event.payload as FrameCompletedEventPayload;
        if (
          !isRecord(payload) ||
          typeof payload.jobId !== "string" ||
          typeof payload.frameIndex !== "number" ||
          !isScanReceipt(payload.receipt)
        ) {
          return;
        }
        if (this.#jobBoundaryPending || this.#state.jobId === null) {
          if (this.#jobBoundaryPending) this.#pendingScanEvents.push(raw);
          return;
        }
        if (payload.jobId !== this.#state.jobId) return;
        // Receipt storage choice: APPEND-LIST keyed by frameIndex. A later
        // job re-scanning the same frame preserves receipt history (each
        // entry records its own jobId/duration), matching ScanReceipt's
        // per-receipt provenance fields; Plan 03 consumers pick the latest.
        const list = this.#state.frameReceipts[payload.frameIndex] ?? [];
        list.push(payload.receipt);
        this.#state.frameReceipts[payload.frameIndex] = list;
        this.#notify();
        return;
      }
      case "scan.completed": {
        const payload = event.payload as ScanCompletedEventPayload;
        if (!isRecord(payload) || typeof payload.jobId !== "string" || !isRecord(payload.summary)) {
          return;
        }
        if (this.#jobBoundaryPending || this.#state.jobId === null) {
          if (this.#jobBoundaryPending) this.#pendingScanEvents.push(raw);
          return;
        }
        if (payload.jobId !== this.#state.jobId) return;
        if (typeof payload.summary.stopped !== "boolean") return;
        // The completion summary is authoritative for the terminal jobState
        // when the job's own terminal scan.jobState event was absent or
        // out-of-order -- but never overwrites an already-terminal jobState
        // (a late/out-of-order summary must not downgrade a reported
        // failure/stop). Resolution rule mirrors SessionModel's
        // ScanCompletionPolicy: stopped summaries resolve to stopped, every
        // other summary to completed (job-level failed only ever arrives as
        // its own scan.jobState{failed} event; per-frame failures live in
        // summary.failed).
        const summary = {
          completed: Array.isArray(payload.summary.completed)
            ? (payload.summary.completed as number[])
            : [],
          failed: Array.isArray(payload.summary.failed) ? (payload.summary.failed as number[]) : [],
          skipped: Array.isArray(payload.summary.skipped)
            ? (payload.summary.skipped as number[])
            : [],
          stopped: payload.summary.stopped,
          ...(isDutyCycleReport(payload.summary.dutyCycle)
            ? { dutyCycle: payload.summary.dutyCycle }
            : {}),
        };
        this.#state.lastCompletedSummary = summary;
        if (this.#state.jobState !== null && !isTerminalJobState(this.#state.jobState)) {
          this.#state.jobState = payload.summary.stopped ? "stopped" : "completed";
        }
        this.#notify();
        return;
      }
      default:
        // Unknown event names are ignored per the forward-compatibility rule.
        return;
    }
  }

  #notify(): void {
    for (const listener of [...this.#listeners]) {
      try {
        listener();
      } catch (error) {
        // A throwing subscriber must not break the dispatch loop; it is
        // re-routed to the integrity channel instead.
        this.#reportIntegrityError(error);
      }
    }
  }

  #reportIntegrityError(error: unknown): void {
    for (const callback of [...this.#integrityCallbacks]) {
      try {
        callback(error);
      } catch {
        // Integrity callbacks must never crash the dispatch loop either.
      }
    }
  }
}
