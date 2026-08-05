// Typed transcription of the Scan Studio Engine Protocol v1 wire contract.
// Source of truth (read-only): nikon-coolscan4-software-archaeology/app/
// ScanStudio/protocol/PROTOCOL.md. Validators are structural type guards:
// they check shape and return boolean, never stripping, cloning, or
// reconstructing the input, so unknown fields pass through untouched per the
// protocol's forward-compatibility rule.

export interface DeviceInfo {
  deviceId: string;
  model: string;
  kind: "simulated" | "real";
  firmware: string;
  connection: string;
}

export interface ScannerStatus {
  connected: boolean;
  adapter: string | null;
  mediaLoaded: boolean;
  carrier: "roll36" | "strip6" | "mounted" | null;
  frameCount: number | null;
  lamp: "off" | "warming" | "stable";
  transport: "idle" | "busy" | "locked";
  activeJobId: string | null;
  motionArmed?: boolean;
  filmPresent?: boolean | null;
}

export interface CaptureRecipe {
  resolutionDpi?: number;
  bitDepth?: 8 | 16;
  multisamplePasses?: 1 | 2 | 4 | 8 | 16;
  channels?: "rgb" | "rgbi";
}

export interface ProcessingRecipe {
  filmProcess: "positive" | "c41ColorNegative" | "bwNegative" | "kodachrome";
  autofocusEachFrame: boolean;
  autoExposureEachFrame: boolean;
  digitalIceEnabled: boolean;
  digitalIceMode: "legacy" | "hybrid";
  softwareDustRemovalBw?: boolean;
}

export interface ArchiveRecipe {
  enabled?: boolean;
  filenameTemplate: string;
  destination: string;
  fullCapturePackage?: boolean;
}

export interface PositiveRecipe {
  enabled: boolean;
  fileFormat: "tiff" | "jpeg";
  colorProfile: "adobeRgb1998" | "sRgb" | "proPhotoRgb";
  filenameTemplate: string;
  destination: string;
}

export interface PreviewRecipe {
  enabled: boolean;
  fileFormat: "tiff" | "jpeg";
  maxLongEdgePx: number;
  filenameTemplate: string;
  destination: string;
}

export interface OutputRecipe {
  archive: ArchiveRecipe;
  positive: PositiveRecipe;
  preview: PreviewRecipe;
  /** Missing on legacy manifests and interpreted as false. */
  autoCrop?: boolean;
}

export type RotationDegrees = 0 | 90 | 180 | 270;

export interface DerivativeTransform {
  rotationDegrees: RotationDegrees;
  horizontalMirror: boolean;
  verticalMirror: boolean;
}

export interface WrittenOutputs {
  archivePath?: string;
  positivePath?: string;
  previewPath?: string;
  /** Missing on legacy receipts and interpreted as the identity transform. */
  derivativeTransform?: DerivativeTransform;
}

export interface Thumbnail {
  brightness?: number;
  tint?: number;
  imagePath?: string;
  boundaryRows?: [number, number];
  spacingOffset?: number;
  needsApproval?: boolean;
  warnings?: string[];
}

export interface ExposureVector {
  focusPosition: number;
  exposureMultiplier: number;
  redExposureUs: number;
  greenExposureUs: number;
  blueExposureUs: number;
}

export interface ClippingTelemetry {
  fractions: [number, number, number];
  clipLevel: number;
  warningFraction: number;
  warning: boolean;
}

export interface FocusDetailTelemetry {
  method: string;
  verdict: string;
  score: number | null;
  textureSpan: number;
}

export interface TransportSmearAssessment {
  verdict: string;
  startRow: number | null;
  suffixRows: number;
  minimumMatches: number;
  tailMedianRms: number | null;
  tailMinCorr: number | null;
  preTailMedianRms: number | null;
  textureSpan: number | null;
  reason: string;
}

export interface HardwareTelemetry {
  exposure: ExposureVector;
  clipping: ClippingTelemetry;
  focusDetail: FocusDetailTelemetry;
  transportSmear: TransportSmearAssessment;
}

export interface FrameIdleSample {
  frameIndex: number;
  idleMs: number;
}

export interface DutyCycleReport {
  perFrameIdleMs: FrameIdleSample[];
  meanIdleMs: number;
  maxIdleMs: number;
}

export interface ExposureAuthority {
  rgbSource: string;
  irSource: string;
  commandedChannelsRaw10ns: { R: number; G: number; B: number; IR: number };
  activeControllerChannelsRaw10ns: { R: number; G: number; B: number; IR: number };
  deviceBoundClampedChannelsRaw10ns: { R?: number; G?: number; B?: number };
  deviceExposureBoundsRaw10ns: [number, number];
}

export interface NikonlookProvenance {
  bundleVersion: string;
  layerAPath: "blind" | "hardwareExposure";
  gains: [number, number, number];
}

export interface AutoCropRoi {
  y1: number;
  y2: number;
  x1: number;
  x2: number;
}

export interface AutoCropOutcome {
  mode: "image";
  applied: boolean;
  roi?: AutoCropRoi;
  sourceWidth: number;
  sourceHeight: number;
  reason?: string;
}

export interface ScanReceipt {
  jobId: string;
  frameIndex: number;
  startedAt: string;
  durationMs: number;
  passes: number;
  resolutionDpi: number;
  bitDepth: number;
  channels: string;
  engineVersion: string;
  deviceId: string;
  simulated: boolean;
  settingsFingerprint: string;
  processing?: ProcessingRecipe;
  output?: OutputRecipe;
  outputs?: WrittenOutputs;
  rgbPath?: string;
  irPath?: string;
  storageTransform?: string;
  meterRgbiPath?: string;
  hardwareTelemetry?: HardwareTelemetry;
  nikonlook?: NikonlookProvenance;
  autoCrop?: AutoCropOutcome;
  exposureAuthority?: ExposureAuthority;
}

export interface FrameAlignment {
  offsetRows: number;
  approved: boolean;
  /** Missing on legacy manifests and interpreted as the identity transform. */
  derivativeTransform?: DerivativeTransform;
}

export type PartialDate =
  | { kind: "exact"; date: string }
  | { kind: "monthOnly"; year: number; month: number }
  | { kind: "yearOnly"; year: number }
  | { kind: "unknown" };

export interface MetadataSet {
  camera?: string;
  lens?: string;
  filmStock?: string;
  process?: "positive" | "c41ColorNegative" | "bwNegative" | "kodachrome";
  iso?: number;
  date?: PartialDate;
  location?: string;
  photographer?: string;
  copyright?: string;
  rollId?: string;
  frameNumber?: number;
  notes?: string;
  keywords: string[];
}

export interface ProjectFrame {
  index: number;
  excluded: boolean;
  captureOverride?: CaptureRecipe;
  processingOverride?: ProcessingRecipe;
  outputOverride?: OutputRecipe;
  alignment?: FrameAlignment;
  metadataOverride?: MetadataSet;
  receipts: ScanReceipt[];
}

export interface ScanProject {
  schemaVersion: 4;
  id: string;
  name: string;
  carrier: "roll36" | "strip6" | "mounted";
  frameCount: number;
  filmProcess: "positive" | "c41ColorNegative" | "bwNegative" | "kodachrome";
  recipes: OutputRecipe;
  rollMetadata: MetadataSet;
  createdAt: string;
  frames: ProjectFrame[];
}

export interface PendingFramesResult {
  frames: number[];
  totalFrames: number;
  completedCount: number;
  excludedCount: number;
}

export interface ProjectSummary {
  id: string;
  name: string;
  carrier: "roll36" | "strip6" | "mounted";
  frameCount: number;
  filmProcess: "positive" | "c41ColorNegative" | "bwNegative" | "kodachrome";
  createdAt: string;
  directory: string;
}

export interface DefectInstance {
  id: number;
  kind: "dust" | "scratch";
  severity: number;
  classification: "willCorrect" | "uncertain";
  centerX: number;
  centerY: number;
  radius: number;
  endX?: number;
  endY?: number;
}

/** project.analyzeFrameDefects response shape (07-02 Task 2). */
export interface AnalyzeFrameDefectsResult {
  frameIndex: number;
  defects: DefectInstance[];
  simulated: boolean;
  digitalIceEnabled: boolean;
  transportSmearFlagged: boolean;
  transportSmearReason: string | null;
}

export interface ExifToolDetection {
  available: boolean;
  path: string | null;
  version: string | null;
}

export interface PreviewMetadataCommandResult {
  available: boolean;
  exiftoolPath: string | null;
  targets: string[];
  arguments: string[];
}

export interface ApplyMetadataResult {
  success: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  targets: string[];
}

export interface EngineError {
  code: string;
  message: string;
  recoverable: boolean;
}

export interface WireRequest {
  id: number;
  method: string;
  params?: unknown;
}

export interface WireResponseSuccess<T = unknown> {
  id: number;
  result: T;
}

export interface WireResponseError {
  id: number;
  error: EngineError;
}

export type WireResponse<T = unknown> = WireResponseSuccess<T> | WireResponseError;

export interface WireEvent<T = unknown> {
  event: string;
  payload: T;
}

export type JobState =
  | "queued"
  | "scanning"
  | "completed"
  | "failed"
  | "stoppingAfterCurrentFrame"
  | "stoppingImmediately"
  | "stopped";

export type FrameState = "waiting" | "active" | "completed" | "failed" | "skipped";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isIn(value: unknown, allowed: readonly unknown[]): boolean {
  return allowed.includes(value);
}

function isStringOrNull(value: unknown): value is string | null {
  return typeof value === "string" || value === null;
}

function isNumberOrNull(value: unknown): value is number | null {
  return typeof value === "number" || value === null;
}

function isBooleanOrNull(value: unknown): value is boolean | null {
  return typeof value === "boolean" || value === null;
}

function isNumberTuple(value: unknown, length: number): boolean {
  return (
    Array.isArray(value) &&
    value.length === length &&
    value.every((entry) => typeof entry === "number")
  );
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((entry) => typeof entry === "string");
}

const CARRIERS = ["roll36", "strip6", "mounted"] as const;
const FILM_PROCESSES = [
  "positive",
  "c41ColorNegative",
  "bwNegative",
  "kodachrome",
] as const;
const LAMP_STATES = ["off", "warming", "stable"] as const;
const TRANSPORT_STATES = ["idle", "busy", "locked"] as const;
const FILE_FORMATS = ["tiff", "jpeg"] as const;
const COLOR_PROFILES = ["adobeRgb1998", "sRgb", "proPhotoRgb"] as const;
const BIT_DEPTHS = [8, 16] as const;
const MULTISAMPLE_PASSES = [1, 2, 4, 8, 16] as const;
const CHANNEL_OPTIONS = ["rgb", "rgbi"] as const;
const DIGITAL_ICE_MODES = ["legacy", "hybrid"] as const;
const DEFECT_KINDS = ["dust", "scratch"] as const;
const DEFECT_CLASSIFICATIONS = ["willCorrect", "uncertain"] as const;
const JOB_STATES = [
  "queued",
  "scanning",
  "completed",
  "failed",
  "stoppingAfterCurrentFrame",
  "stoppingImmediately",
  "stopped",
] as const;
const FRAME_STATES = ["waiting", "active", "completed", "failed", "skipped"] as const;
const ROTATION_DEGREES = [0, 90, 180, 270] as const;
const NIKONLOOK_LAYER_A_PATHS = ["blind", "hardwareExposure"] as const;
const SETTINGS_FINGERPRINT_PATTERN = /^[0-9a-f]{16}$/;

export function isDeviceInfo(value: unknown): value is DeviceInfo {
  if (!isRecord(value)) return false;
  return (
    typeof value.deviceId === "string" &&
    typeof value.model === "string" &&
    isIn(value.kind, ["simulated", "real"] as const) &&
    typeof value.firmware === "string" &&
    typeof value.connection === "string"
  );
}

export function isScannerStatus(value: unknown): value is ScannerStatus {
  if (!isRecord(value)) return false;
  return (
    typeof value.connected === "boolean" &&
    isStringOrNull(value.adapter) &&
    typeof value.mediaLoaded === "boolean" &&
    (value.carrier === null || isIn(value.carrier, CARRIERS)) &&
    isNumberOrNull(value.frameCount) &&
    isIn(value.lamp, LAMP_STATES) &&
    isIn(value.transport, TRANSPORT_STATES) &&
    isStringOrNull(value.activeJobId) &&
    (!("motionArmed" in value) || typeof value.motionArmed === "boolean") &&
    (!("filmPresent" in value) || isBooleanOrNull(value.filmPresent))
  );
}

export function isCaptureRecipe(value: unknown): value is CaptureRecipe {
  if (!isRecord(value)) return false;
  return (
    (!("resolutionDpi" in value) || typeof value.resolutionDpi === "number") &&
    (!("bitDepth" in value) || isIn(value.bitDepth, BIT_DEPTHS)) &&
    (!("multisamplePasses" in value) || isIn(value.multisamplePasses, MULTISAMPLE_PASSES)) &&
    (!("channels" in value) || isIn(value.channels, CHANNEL_OPTIONS))
  );
}

export function isProcessingRecipe(value: unknown): value is ProcessingRecipe {
  if (!isRecord(value)) return false;
  return (
    isIn(value.filmProcess, FILM_PROCESSES) &&
    typeof value.autofocusEachFrame === "boolean" &&
    typeof value.autoExposureEachFrame === "boolean" &&
    typeof value.digitalIceEnabled === "boolean" &&
    isIn(value.digitalIceMode, DIGITAL_ICE_MODES) &&
    (!("softwareDustRemovalBw" in value) || typeof value.softwareDustRemovalBw === "boolean")
  );
}

export function isArchiveRecipe(value: unknown): value is ArchiveRecipe {
  if (!isRecord(value)) return false;
  return (
    (!("enabled" in value) || typeof value.enabled === "boolean") &&
    typeof value.filenameTemplate === "string" &&
    typeof value.destination === "string" &&
    (!("fullCapturePackage" in value) || typeof value.fullCapturePackage === "boolean")
  );
}

export function isPositiveRecipe(value: unknown): value is PositiveRecipe {
  if (!isRecord(value)) return false;
  return (
    typeof value.enabled === "boolean" &&
    isIn(value.fileFormat, FILE_FORMATS) &&
    isIn(value.colorProfile, COLOR_PROFILES) &&
    typeof value.filenameTemplate === "string" &&
    typeof value.destination === "string"
  );
}

export function isPreviewRecipe(value: unknown): value is PreviewRecipe {
  if (!isRecord(value)) return false;
  return (
    typeof value.enabled === "boolean" &&
    isIn(value.fileFormat, FILE_FORMATS) &&
    typeof value.maxLongEdgePx === "number" &&
    typeof value.filenameTemplate === "string" &&
    typeof value.destination === "string"
  );
}

export function isOutputRecipe(value: unknown): value is OutputRecipe {
  if (!isRecord(value)) return false;
  return (
    isArchiveRecipe(value.archive) &&
    isPositiveRecipe(value.positive) &&
    isPreviewRecipe(value.preview) &&
    (!("autoCrop" in value) || typeof value.autoCrop === "boolean")
  );
}

export function isDerivativeTransform(value: unknown): value is DerivativeTransform {
  if (!isRecord(value)) return false;
  return (
    isIn(value.rotationDegrees, ROTATION_DEGREES) &&
    typeof value.horizontalMirror === "boolean" &&
    typeof value.verticalMirror === "boolean"
  );
}

export function isWrittenOutputs(value: unknown): value is WrittenOutputs {
  if (!isRecord(value)) return false;
  return (
    (!("archivePath" in value) || typeof value.archivePath === "string") &&
    (!("positivePath" in value) || typeof value.positivePath === "string") &&
    (!("previewPath" in value) || typeof value.previewPath === "string") &&
    (!("derivativeTransform" in value) || isDerivativeTransform(value.derivativeTransform))
  );
}

export function isThumbnail(value: unknown): value is Thumbnail {
  if (!isRecord(value)) return false;
  return (
    (!("brightness" in value) || typeof value.brightness === "number") &&
    (!("tint" in value) || typeof value.tint === "number") &&
    (!("imagePath" in value) || typeof value.imagePath === "string") &&
    (!("boundaryRows" in value) || isNumberTuple(value.boundaryRows, 2)) &&
    (!("spacingOffset" in value) || typeof value.spacingOffset === "number") &&
    (!("needsApproval" in value) || typeof value.needsApproval === "boolean") &&
    (!("warnings" in value) || isStringArray(value.warnings))
  );
}

export function isExposureVector(value: unknown): value is ExposureVector {
  if (!isRecord(value)) return false;
  return (
    typeof value.focusPosition === "number" &&
    typeof value.exposureMultiplier === "number" &&
    typeof value.redExposureUs === "number" &&
    typeof value.greenExposureUs === "number" &&
    typeof value.blueExposureUs === "number"
  );
}

export function isClippingTelemetry(value: unknown): value is ClippingTelemetry {
  if (!isRecord(value)) return false;
  return (
    isNumberTuple(value.fractions, 3) &&
    typeof value.clipLevel === "number" &&
    typeof value.warningFraction === "number" &&
    typeof value.warning === "boolean"
  );
}

export function isFocusDetailTelemetry(value: unknown): value is FocusDetailTelemetry {
  if (!isRecord(value)) return false;
  return (
    typeof value.method === "string" &&
    typeof value.verdict === "string" &&
    isNumberOrNull(value.score) &&
    typeof value.textureSpan === "number"
  );
}

export function isTransportSmearAssessment(value: unknown): value is TransportSmearAssessment {
  if (!isRecord(value)) return false;
  return (
    typeof value.verdict === "string" &&
    isNumberOrNull(value.startRow) &&
    typeof value.suffixRows === "number" &&
    typeof value.minimumMatches === "number" &&
    isNumberOrNull(value.tailMedianRms) &&
    isNumberOrNull(value.tailMinCorr) &&
    isNumberOrNull(value.preTailMedianRms) &&
    isNumberOrNull(value.textureSpan) &&
    typeof value.reason === "string"
  );
}

export function isHardwareTelemetry(value: unknown): value is HardwareTelemetry {
  if (!isRecord(value)) return false;
  return (
    isExposureVector(value.exposure) &&
    isClippingTelemetry(value.clipping) &&
    isFocusDetailTelemetry(value.focusDetail) &&
    isTransportSmearAssessment(value.transportSmear)
  );
}

export function isFrameIdleSample(value: unknown): value is FrameIdleSample {
  if (!isRecord(value)) return false;
  return typeof value.frameIndex === "number" && typeof value.idleMs === "number";
}

export function isDutyCycleReport(value: unknown): value is DutyCycleReport {
  if (!isRecord(value)) return false;
  return (
    Array.isArray(value.perFrameIdleMs) &&
    value.perFrameIdleMs.every(isFrameIdleSample) &&
    typeof value.meanIdleMs === "number" &&
    typeof value.maxIdleMs === "number"
  );
}

function isChannelLevelsRaw10ns(value: unknown): boolean {
  if (!isRecord(value)) return false;
  return (
    typeof value.R === "number" &&
    typeof value.G === "number" &&
    typeof value.B === "number" &&
    typeof value.IR === "number"
  );
}

function isClampedChannelLevelsRaw10ns(value: unknown): boolean {
  if (!isRecord(value)) return false;
  return (
    (!("R" in value) || typeof value.R === "number") &&
    (!("G" in value) || typeof value.G === "number") &&
    (!("B" in value) || typeof value.B === "number")
  );
}

export function isExposureAuthority(value: unknown): value is ExposureAuthority {
  if (!isRecord(value)) return false;
  return (
    typeof value.rgbSource === "string" &&
    typeof value.irSource === "string" &&
    isChannelLevelsRaw10ns(value.commandedChannelsRaw10ns) &&
    isChannelLevelsRaw10ns(value.activeControllerChannelsRaw10ns) &&
    isClampedChannelLevelsRaw10ns(value.deviceBoundClampedChannelsRaw10ns) &&
    isNumberTuple(value.deviceExposureBoundsRaw10ns, 2)
  );
}

export function isNikonlookProvenance(value: unknown): value is NikonlookProvenance {
  if (!isRecord(value)) return false;
  return (
    typeof value.bundleVersion === "string" &&
    isIn(value.layerAPath, NIKONLOOK_LAYER_A_PATHS) &&
    isNumberTuple(value.gains, 3)
  );
}

export function isAutoCropRoi(value: unknown): value is AutoCropRoi {
  if (!isRecord(value)) return false;
  return (
    typeof value.y1 === "number" &&
    typeof value.y2 === "number" &&
    typeof value.x1 === "number" &&
    typeof value.x2 === "number"
  );
}

export function isAutoCropOutcome(value: unknown): value is AutoCropOutcome {
  if (!isRecord(value)) return false;
  return (
    value.mode === "image" &&
    typeof value.applied === "boolean" &&
    (!("roi" in value) || isAutoCropRoi(value.roi)) &&
    typeof value.sourceWidth === "number" &&
    typeof value.sourceHeight === "number" &&
    (!("reason" in value) || typeof value.reason === "string")
  );
}

export function isScanReceipt(value: unknown): value is ScanReceipt {
  if (!isRecord(value)) return false;
  return (
    typeof value.jobId === "string" &&
    typeof value.frameIndex === "number" &&
    typeof value.startedAt === "string" &&
    typeof value.durationMs === "number" &&
    typeof value.passes === "number" &&
    typeof value.resolutionDpi === "number" &&
    typeof value.bitDepth === "number" &&
    typeof value.channels === "string" &&
    typeof value.engineVersion === "string" &&
    typeof value.deviceId === "string" &&
    typeof value.simulated === "boolean" &&
    typeof value.settingsFingerprint === "string" &&
    SETTINGS_FINGERPRINT_PATTERN.test(value.settingsFingerprint) &&
    (!("processing" in value) || isProcessingRecipe(value.processing)) &&
    (!("output" in value) || isOutputRecipe(value.output)) &&
    (!("outputs" in value) || isWrittenOutputs(value.outputs)) &&
    (!("rgbPath" in value) || typeof value.rgbPath === "string") &&
    (!("irPath" in value) || typeof value.irPath === "string") &&
    (!("storageTransform" in value) || typeof value.storageTransform === "string") &&
    (!("meterRgbiPath" in value) || typeof value.meterRgbiPath === "string") &&
    (!("hardwareTelemetry" in value) || isHardwareTelemetry(value.hardwareTelemetry)) &&
    (!("nikonlook" in value) || isNikonlookProvenance(value.nikonlook)) &&
    (!("autoCrop" in value) || isAutoCropOutcome(value.autoCrop)) &&
    (!("exposureAuthority" in value) || isExposureAuthority(value.exposureAuthority))
  );
}

export function isFrameAlignment(value: unknown): value is FrameAlignment {
  if (!isRecord(value)) return false;
  return (
    typeof value.offsetRows === "number" &&
    typeof value.approved === "boolean" &&
    (!("derivativeTransform" in value) || isDerivativeTransform(value.derivativeTransform))
  );
}

export function isPartialDate(value: unknown): value is PartialDate {
  if (!isRecord(value)) return false;
  switch (value.kind) {
    case "exact":
      return typeof value.date === "string";
    case "monthOnly":
      return typeof value.year === "number" && typeof value.month === "number";
    case "yearOnly":
      return typeof value.year === "number";
    case "unknown":
      return true;
    default:
      return false;
  }
}

export function isMetadataSet(value: unknown): value is MetadataSet {
  if (!isRecord(value)) return false;
  return (
    (!("camera" in value) || typeof value.camera === "string") &&
    (!("lens" in value) || typeof value.lens === "string") &&
    (!("filmStock" in value) || typeof value.filmStock === "string") &&
    (!("process" in value) || isIn(value.process, FILM_PROCESSES)) &&
    (!("iso" in value) || typeof value.iso === "number") &&
    (!("date" in value) || isPartialDate(value.date)) &&
    (!("location" in value) || typeof value.location === "string") &&
    (!("photographer" in value) || typeof value.photographer === "string") &&
    (!("copyright" in value) || typeof value.copyright === "string") &&
    (!("rollId" in value) || typeof value.rollId === "string") &&
    (!("frameNumber" in value) || typeof value.frameNumber === "number") &&
    (!("notes" in value) || typeof value.notes === "string") &&
    isStringArray(value.keywords)
  );
}

export function isProjectFrame(value: unknown): value is ProjectFrame {
  if (!isRecord(value)) return false;
  return (
    typeof value.index === "number" &&
    typeof value.excluded === "boolean" &&
    (!("captureOverride" in value) || isCaptureRecipe(value.captureOverride)) &&
    (!("processingOverride" in value) || isProcessingRecipe(value.processingOverride)) &&
    (!("outputOverride" in value) || isOutputRecipe(value.outputOverride)) &&
    (!("alignment" in value) || isFrameAlignment(value.alignment)) &&
    (!("metadataOverride" in value) || isMetadataSet(value.metadataOverride)) &&
    Array.isArray(value.receipts) &&
    value.receipts.every(isScanReceipt)
  );
}

export function isScanProject(value: unknown): value is ScanProject {
  if (!isRecord(value)) return false;
  return (
    value.schemaVersion === 4 &&
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    isIn(value.carrier, CARRIERS) &&
    typeof value.frameCount === "number" &&
    isIn(value.filmProcess, FILM_PROCESSES) &&
    isOutputRecipe(value.recipes) &&
    isMetadataSet(value.rollMetadata) &&
    typeof value.createdAt === "string" &&
    Array.isArray(value.frames) &&
    value.frames.every(isProjectFrame)
  );
}

export function isPendingFramesResult(value: unknown): value is PendingFramesResult {
  if (!isRecord(value)) return false;
  return (
    Array.isArray(value.frames) &&
    value.frames.every((entry) => typeof entry === "number") &&
    typeof value.totalFrames === "number" &&
    typeof value.completedCount === "number" &&
    typeof value.excludedCount === "number"
  );
}

export function isProjectSummary(value: unknown): value is ProjectSummary {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    isIn(value.carrier, CARRIERS) &&
    typeof value.frameCount === "number" &&
    isIn(value.filmProcess, FILM_PROCESSES) &&
    typeof value.createdAt === "string" &&
    typeof value.directory === "string"
  );
}

export function isDefectInstance(value: unknown): value is DefectInstance {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === "number" &&
    isIn(value.kind, DEFECT_KINDS) &&
    typeof value.severity === "number" &&
    isIn(value.classification, DEFECT_CLASSIFICATIONS) &&
    typeof value.centerX === "number" &&
    typeof value.centerY === "number" &&
    typeof value.radius === "number" &&
    (!("endX" in value) || typeof value.endX === "number") &&
    (!("endY" in value) || typeof value.endY === "number")
  );
}

export function isExifToolDetection(value: unknown): value is ExifToolDetection {
  if (!isRecord(value)) return false;
  return (
    typeof value.available === "boolean" &&
    isStringOrNull(value.path) &&
    isStringOrNull(value.version)
  );
}

export function isPreviewMetadataCommandResult(
  value: unknown,
): value is PreviewMetadataCommandResult {
  if (!isRecord(value)) return false;
  return (
    typeof value.available === "boolean" &&
    isStringOrNull(value.exiftoolPath) &&
    isStringArray(value.targets) &&
    isStringArray(value.arguments)
  );
}

export function isApplyMetadataResult(value: unknown): value is ApplyMetadataResult {
  if (!isRecord(value)) return false;
  return (
    typeof value.success === "boolean" &&
    typeof value.exitCode === "number" &&
    typeof value.stdout === "string" &&
    typeof value.stderr === "string" &&
    isStringArray(value.targets)
  );
}

export function isEngineError(value: unknown): value is EngineError {
  if (!isRecord(value)) return false;
  return (
    typeof value.code === "string" &&
    typeof value.message === "string" &&
    typeof value.recoverable === "boolean"
  );
}

export function isWireRequest(value: unknown): value is WireRequest {
  if (!isRecord(value)) return false;
  return typeof value.id === "number" && typeof value.method === "string";
}

export function isWireResponseSuccess(value: unknown): value is WireResponseSuccess {
  if (!isRecord(value)) return false;
  return typeof value.id === "number" && "result" in value;
}

export function isWireResponseError(value: unknown): value is WireResponseError {
  if (!isRecord(value)) return false;
  return typeof value.id === "number" && isEngineError(value.error);
}

export function isWireResponse(value: unknown): value is WireResponse {
  return isWireResponseSuccess(value) || isWireResponseError(value);
}

export function isWireEvent(value: unknown): value is WireEvent {
  if (!isRecord(value)) return false;
  return typeof value.event === "string" && "payload" in value;
}

export function isJobState(value: unknown): value is JobState {
  return isIn(value, JOB_STATES);
}

export function isFrameState(value: unknown): value is FrameState {
  return isIn(value, FRAME_STATES);
}
