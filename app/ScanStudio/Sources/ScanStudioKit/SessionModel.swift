// @MainActor @Observable session state + user actions (D-04). This is the
// thin, honest projection of engine state the UI binds to directly — it
// owns no scanner logic itself (D-02); every action is a single typed
// request to `EngineClient`, and all state changes beyond a request's own
// result flow in through the subscribed event stream.

import Foundation
import Observation

/// A capability minted by one concrete presentation of a preview action.
///
/// The model consumes the token before checking whether the action is
/// currently admissible. Consequently, neither a delayed replay nor a later
/// status/terminal event can turn the same UI activation into another scanner
/// movement.
public struct PreviewIntentToken: Hashable, Identifiable, Sendable {
    public let id: UUID

    public init() {
        id = UUID()
    }
}

/// The only three user actions allowed to start a preview traversal.
///
/// Keeping these cases distinct prevents a generic "acquire" entry point
/// from silently becoming a replacement or refresh after state changes.
public enum PreviewIntent: Sendable {
    case initial(token: PreviewIntentToken)
    case replaceFilmProcess(token: PreviewIntentToken, filmProcess: FilmProcess)
    case refreshSavedProject(token: PreviewIntentToken)

    fileprivate var token: PreviewIntentToken {
        switch self {
        case .initial(let token),
             .replaceFilmProcess(let token, _),
             .refreshSavedProject(let token):
            token
        }
    }

    fileprivate var kind: PreviewIntentStateMachine.Kind {
        switch self {
        case .initial:
            .initial
        case .replaceFilmProcess:
            .replaceFilmProcess
        case .refreshSavedProject:
            .refreshSavedProject
        }
    }

    fileprivate var operationID: String {
        token.id.uuidString
    }
}

public enum PreviewRequestOutcome: Equatable, Sendable {
    case started
    case rejected
    case failedToStart
}

/// One frame whose current, completed real-device preview needs an operator
/// decision before any fine-scan transport movement.
public struct ManualReviewRequirement: Equatable, Identifiable, Sendable {
    public var id: Int { frameIndex }
    public let frameIndex: Int
    public let warnings: [String]
}

/// The operator's decision for a preview frame whose detected boundary is
/// ambiguous. Decisions are session-local and valid only for the exact
/// completed preview that produced the warning.
public enum ManualReviewDecision: Equatable, Sendable {
    case useFrameAnyway
    case dontScan
}

/// The exact scan request paused at the pre-motion manual-review boundary.
///
/// `frames` is the original complete batch, not only the ambiguous frames.
/// After explicit confirmation, ScanStudio approves `requirements` first and
/// then sends `frames` in one `scan.start`, preserving one continuous
/// transport traversal.
public struct ManualReviewScanRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let frames: [Int]
    public let requirements: [ManualReviewRequirement]
}

/// One-shot authorization boundary immediately above `EngineClient`.
///
/// `activeKind` deliberately outlives the request ACK. Only a typed terminal
/// preview event (or a real failure/media reset) ends the active traversal;
/// an intermediate `scanner.status` transition to idle cannot reopen the
/// command path.
fileprivate struct PreviewIntentStateMachine {
    enum Kind: Equatable {
        case initial
        case replaceFilmProcess
        case refreshSavedProject
    }

    struct Context {
        let hasProject: Bool
        let isAcquiring: Bool
        let hasCompleteRegistration: Bool
    }

    private struct ActiveOperation {
        let id: String
        let kind: Kind
    }

    private var consumedTokens: Set<PreviewIntentToken> = []
    private var activeOperation: ActiveOperation?
    private var latestTerminalOperationID: String?
    private var completedPreProjectPreview = false

    var hasActiveOperation: Bool {
        activeOperation != nil
    }

    mutating func consume(_ intent: PreviewIntent, context: Context) -> Bool {
        // Consume first: an action denied now must not become authorized later
        // merely because completion/status/failure changed session state.
        guard consumedTokens.insert(intent.token).inserted else { return false }
        guard activeOperation == nil, !context.isAcquiring else { return false }

        let isAdmissible = switch intent.kind {
        case .initial:
            !context.hasProject && !completedPreProjectPreview
        case .replaceFilmProcess:
            !context.hasProject
                && completedPreProjectPreview
                && context.hasCompleteRegistration
        case .refreshSavedProject:
            context.hasProject
        }
        guard isAdmissible else { return false }

        activeOperation = ActiveOperation(id: intent.operationID, kind: intent.kind)
        if intent.kind != .refreshSavedProject {
            // An admitted replacement invalidates the old registration before
            // the film moves. A failed replacement therefore requires a new
            // explicit initial-preview intent rather than reviving stale data.
            completedPreProjectPreview = false
        }
        return true
    }

    /// Returns whether this completion belonged to an admitted traversal.
    @discardableResult
    mutating func complete(operationID: String?, hasProject: Bool) -> Bool {
        guard let operationID,
              let activeOperation,
              activeOperation.id == operationID
        else { return false }
        self.activeOperation = nil
        latestTerminalOperationID = operationID
        completedPreProjectPreview =
            !hasProject && activeOperation.kind != .refreshSavedProject
        return true
    }

    /// Ends only the traversal identified by this asynchronous failure.
    /// A delayed failure from an older worker cannot erase a newer operation.
    @discardableResult
    mutating func fail(operationID: String?) -> Bool {
        guard let operationID,
              activeOperation?.id == operationID
        else { return false }
        activeOperation = nil
        latestTerminalOperationID = operationID
        completedPreProjectPreview = false
        return true
    }

    /// A genuine synchronous refusal happens before an engine worker exists.
    /// If a request continuation instead fails only after correlated terminal
    /// events closed it, this ownership check rejects the now-stale catch.
    @discardableResult
    mutating func failSynchronousRequest(operationID: String) -> Bool {
        guard activeOperation?.id == operationID else { return false }
        activeOperation = nil
        completedPreProjectPreview = false
        return true
    }

    func admitsPreviewEvent(operationID: String?) -> Bool {
        guard let operationID else { return false }
        return activeOperation?.id == operationID
    }

    /// A preview worker's post-terminal status is accepted only while it owns
    /// the lane or, once idle, when it belongs to the latest terminal. A stale
    /// A status can therefore never destructively reset a running B.
    func admitsStatusEvent(operationID: String?) -> Bool {
        guard let operationID else {
            return activeOperation == nil
        }
        if let activeOperation {
            return activeOperation.id == operationID
        }
        return latestTerminalOperationID == operationID
    }

    mutating func resetForExplicitMediaChange() {
        activeOperation = nil
        latestTerminalOperationID = nil
        completedPreProjectPreview = false
    }
}

public enum SimulatedFilmCarrier: String, Codable, CaseIterable, Identifiable, Sendable {
    case mounted
    case strip6
    case roll36

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mounted: "Mounted slide"
        case .strip6: "6-frame strip"
        // `roll36` remains the established wire token, but SA-30 capacity
        // is a mechanical holder bound, not a detected exposure count.
        case .roll36: "35 mm roll"
        }
    }

    public var frameCount: Int {
        switch self {
        case .mounted: 1
        case .strip6: 6
        case .roll36: 36
        }
    }
}

/// Uncompressed raster size derived from Nikon's published LS-5000 scan
/// ranges: 3946×5782 pixels for MA-21 mounted media and 3946×5959 pixels for
/// SA-21/SA-30 strip or roll media at the scanner's native 4000 ppi.
public enum ScanSizeEstimator {
    public static func uncompressedBytes(
        carrier: SimulatedFilmCarrier,
        resolutionDpi: Int,
        bitDepth: Int,
        colorChannels: Int
    ) -> Int {
        let nativeWidth = 3_946
        let nativeHeight = carrier == .mounted ? 5_782 : 5_959
        let scale = max(0, Double(resolutionDpi)) / 4_000
        let width = Int((Double(nativeWidth) * scale).rounded())
        let height = Int((Double(nativeHeight) * scale).rounded())
        let bytesPerSample = max(1, bitDepth / 8)
        return width * height * max(1, colorChannels) * bytesPerSample
    }

    /// The archive is always full-fidelity, uncompressed, 3-channel — it has
    /// no format/profile choice to estimate around (REC-02).
    public static func archiveBytesPerFrame(
        carrier: SimulatedFilmCarrier,
        resolutionDpi: Int,
        bitDepth: Int
    ) -> Int {
        uncompressedBytes(carrier: carrier, resolutionDpi: resolutionDpi, bitDepth: bitDepth, colorChannels: 3)
    }

    /// Positive TIFF rendering is fixed at 16-bit; JPEG is fixed at 8-bit.
    /// JPEG uses the same rough compression-ratio estimate the old
    /// `estimatedOutputBytes` used (~0.18 of the uncompressed size).
    public static func positiveBytesPerFrame(
        carrier: SimulatedFilmCarrier,
        resolutionDpi: Int,
        bitDepth _: Int,
        fileFormat: OutputFileFormat
    ) -> Int {
        let uncompressed = uncompressedBytes(
            carrier: carrier,
            resolutionDpi: resolutionDpi,
            bitDepth: fileFormat == .tiff ? 16 : 8,
            colorChannels: 3
        )
        return fileFormat == .jpeg ? Int(Double(uncompressed) * 0.18) : uncompressed
    }

    /// The preview derivative: always 8-bit regardless of the capture's own
    /// bit depth, downsampled to `maxLongEdgePx` (a no-op if the native long
    /// edge is already smaller, or if `maxLongEdgePx` isn't positive).
    public static func previewBytesPerFrame(
        carrier: SimulatedFilmCarrier,
        resolutionDpi: Int,
        maxLongEdgePx: Int,
        fileFormat: OutputFileFormat
    ) -> Int {
        let native = frameDimensions(carrier: carrier, resolutionDpi: resolutionDpi)
        let scaled = downsampleDimensions(width: native.width, height: native.height, maxLongEdgePx: maxLongEdgePx)
        let uncompressed = scaled.width * scaled.height * 3 * 1
        return fileFormat == .jpeg ? Int(Double(uncompressed) * 0.18) : uncompressed
    }

    /// Mirrors the engine's own native-dimension constants (3946×5782 for
    /// mounted media, 3946×5959 for strip/roll media, scaled by
    /// `resolutionDpi / 4000`) so the two languages' *estimates* stay
    /// conceptually consistent. Kept private and separate from
    /// `uncompressedBytes`'s own inline copy of the same formula so that
    /// function's golden values are never at risk of changing if this
    /// helper is ever revisited.
    private static func frameDimensions(carrier: SimulatedFilmCarrier, resolutionDpi: Int) -> (width: Int, height: Int) {
        let nativeWidth = 3_946
        let nativeHeight = carrier == .mounted ? 5_782 : 5_959
        let scale = max(0, Double(resolutionDpi)) / 4_000
        let width = Int((Double(nativeWidth) * scale).rounded())
        let height = Int((Double(nativeHeight) * scale).rounded())
        return (width, height)
    }

    /// Mirrors the engine's `downsample_dimensions`: a no-op whenever the
    /// native long edge already fits within `maxLongEdgePx` (or the cap
    /// isn't positive); otherwise scales both dimensions down, preserving
    /// aspect ratio.
    private static func downsampleDimensions(width: Int, height: Int, maxLongEdgePx: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard maxLongEdgePx > 0, longEdge > maxLongEdgePx else { return (width, height) }
        let scale = Double(maxLongEdgePx) / Double(longEdge)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }
}

@MainActor
@Observable
public final class SessionModel {
    /// Local mirror of the `scan.progress` event payload — a small,
    /// UI-facing type distinct from the wire `ScanProgressPayload`.
    public struct ScanProgress: Equatable, Sendable {
        public let jobId: String
        public let frameIndex: Int
        public let frameOrdinal: Int
        public let totalFrames: Int
        public let pass: Int
        public let totalPasses: Int
        public let framePercent: Double
        public let jobPercent: Double
        public let etaSeconds: Double
    }

    /// Owns the narrow interval between sending `scan.start` and receiving
    /// its response. Scan events are allowed to arrive before that response,
    /// but only while this marker still belongs to the current connection.
    private struct PendingScanStart {
        let id: UUID
        let connectionEpoch: UInt64
    }

    /// Binds the UI-visible manual-review request to the exact completed
    /// preview and connection that produced it.
    private struct PendingManualReviewScanAuthorization {
        let requestId: UUID
        let frames: [Int]
        /// Every flagged frame the bridge must approve before scan.start.
        let requirements: [ManualReviewRequirement]
        /// The subset not already resolved with "Use Frame Anyway" when the
        /// scan was requested. Empty means the contact-sheet decision itself
        /// was the explicit confirmation and no scan-time sheet is needed.
        let confirmationRequirements: [ManualReviewRequirement]
        let previewOperationId: String
        let connectionEpoch: UInt64
    }

    /// Owns the response interval while every flagged frame is explicitly
    /// approved. The epoch prevents an earlier bridge owner's response from
    /// authorizing work in a replacement scanner session.
    private struct PendingManualReviewApproval {
        let id: UUID
        let requestId: UUID
        let previewOperationId: String
        let connectionEpoch: UInt64
    }

    private struct PendingStatusRefresh {
        let id: UUID
        let connectionEpoch: UInt64
    }

    /// Owns one asynchronous adjusted-thumbnail response. Preview identity
    /// and connection epoch prevent a late result from replacing a newer
    /// registration after preview/media reset.
    private struct PendingFrameAlignmentAdjustment {
        let id: UUID
        let frameIndex: Int
        let previewOperationId: String
        let projectId: String?
        let connectionEpoch: UInt64
    }

    /// Owns the sequential replay of project-persisted offsets into one
    /// concrete completed live preview.
    private struct PendingFrameAlignmentRestore {
        let id: UUID
        let previewOperationId: String
        let projectId: String
        let connectionEpoch: UInt64
    }

    private struct PersistedFrameAlignmentTarget: Sendable {
        let frameIndex: Int
        let offsetRows: Int
    }

    private let engineClient: any EngineClientProtocol
    @ObservationIgnored
    private let preferences: UserDefaults
    // Set exactly once (in `init`) and only ever read/cancelled again in
    // `deinit`, which Swift treats as a nonisolated context even on a
    // `@MainActor` class — `nonisolated(unsafe)` is safe here because there
    // is no concurrent mutation, just a single set followed by a single
    // cancel. `@ObservationIgnored` since this is internal plumbing, not
    // UI-observable state.
    @ObservationIgnored
    nonisolated(unsafe) private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var deviceDiscoveryRequestsInFlight = 0
    @ObservationIgnored
    private var previewIntentStateMachine = PreviewIntentStateMachine()
    @ObservationIgnored
    private var diagnosticTimeline: SessionDiagnosticTimeline
    @ObservationIgnored
    private var connectionEpoch: UInt64 = 0
    @ObservationIgnored
    private var pendingScanStart: PendingScanStart?
    @ObservationIgnored
    private var pendingManualReviewScanAuthorization: PendingManualReviewScanAuthorization?
    @ObservationIgnored
    private var pendingManualReviewApproval: PendingManualReviewApproval?
    @ObservationIgnored
    private var pendingStatusRefresh: PendingStatusRefresh?
    @ObservationIgnored
    private var pendingFrameAlignmentAdjustment: PendingFrameAlignmentAdjustment?
    @ObservationIgnored
    private var pendingFrameAlignmentRestore: PendingFrameAlignmentRestore?

    public private(set) var device: DeviceInfo?
    /// The full device list from the engine's last `scanner.list` response
    /// (simulator plus, when a bridge is configured, the real LS-5000) —
    /// what `SessionSidebarView`'s device picker renders. Refreshed once
    /// from `init` and again by `connect(deviceId:)` if still empty.
    public private(set) var availableDevices: [DeviceInfo] = []
    /// Distinguishes an incomplete device list from a completed empty list.
    /// Starts true because `init` immediately schedules the initial refresh.
    public private(set) var isDiscoveringDevices = true
    /// True from the moment a connection action is accepted until its
    /// preflight discovery and `scanner.connect` request have resolved.
    /// Used to replace every connect affordance with one honest progress
    /// state and to reject overlapping button presses.
    public private(set) var isConnectingDevice = false
    public private(set) var isRefreshingScannerStatus = false
    public private(set) var status: ScannerStatus?
    public private(set) var engineVersion: String?
    public private(set) var thumbnails: [Int: Thumbnail] = [:]
    /// Exact operation identity of the latest successfully completed preview.
    /// Manual boundary approval is valid only while this same identity remains
    /// current.
    public private(set) var latestCompletedPreviewOperationId: String?
    /// The full `analyzeFrameDefects` result from the last round trip,
    /// cached per frame index — never refetched on every render. Holds the
    /// defects array plus provenance signals (`simulated`,
    /// `digitalIceEnabled`, `transportSmearFlagged`, `transportSmearReason`);
    /// `digitalIceEnabled` is the authoritative "Digital ICE is off for this
    /// frame" signal, not `defects.isEmpty`.
    public private(set) var frameDefects: [Int: AnalyzeFrameDefectsResult] = [:]
    public internal(set) var jobId: String?
    public private(set) var jobState: JobState?
    public private(set) var progress: ScanProgress?
    public private(set) var frameStates: [Int: FrameState] = [:]
    public private(set) var receipts: [ScanReceipt] = []
    public private(set) var frameErrors: [Int: ErrorPayload] = [:]
    /// A fine-scan request paused before `scan.start` because one or more
    /// current preview boundaries need an explicit operator confirmation.
    public private(set) var pendingManualReviewScan: ManualReviewScanRequest?
    /// Explicit operator choices for ambiguous boundaries in the current
    /// completed preview. Cleared before any replacement preview or scanner
    /// session can become authoritative.
    public private(set) var manualReviewDecisions: [Int: ManualReviewDecision] = [:]
    /// Session-local offsets that exist before Save Roll and mirror the
    /// unapproved draft persisted on a project once one exists.
    public private(set) var frameAlignmentDrafts: [Int: FrameAlignment] = [:]
    /// Observable per-frame activity for alignment controls.
    public private(set) var adjustingFrameAlignmentIndices: Set<Int> = []
    /// True while saved offsets are being replayed into a newly completed
    /// preview. Scan and manual nudge paths remain closed until every response
    /// is bound to that preview and installed.
    public private(set) var isRestoringFrameAlignments = false
    /// Frames whose saved offsets could not be rebound to the current preview.
    /// Scan readiness remains closed until a fresh preview retries the restore
    /// or a successful manual adjustment replaces that saved intent.
    public private(set) var failedFrameAlignmentRestoreIndices: Set<Int> = []
    /// The frame currently awaiting its explicit `roll.approve` response.
    /// Duplicate UI actions remain disabled while this is non-nil.
    public private(set) var approvingFrameIndex: Int?
    public private(set) var frameAttempts: [Int: Int] = [:]
    public private(set) var frameTransportSmearReasons: [Int: String] = [:]
    public private(set) var scanSummary: ScanSummary?
    public private(set) var lastErrorMessage: String?
    /// Calm, actionable copy for the workspace plus a privacy-scrubbed,
    /// user-initiated issue URL. `lastErrorMessage` remains the compatibility
    /// source of truth and the technical detail shown locally.
    public var errorPresentation: ErrorPresentation? {
        guard let lastErrorMessage else { return nil }

        let projectMetadata = project.map(\.rollMetadata)
        let frameMetadata = project?.frames.compactMap(\.metadataOverride) ?? []
        let metadataSets = [rollMetadataDraft] + [projectMetadata].compactMap { $0 } + frameMetadata
        let metadataValues = metadataSets.flatMap { metadata in
            [
                metadata.camera,
                metadata.lens,
                metadata.filmStock,
                metadata.location,
                metadata.photographer,
                metadata.copyright,
                metadata.rollId,
                metadata.notes,
            ].compactMap { $0 } + metadata.keywords
        } + [project?.name].compactMap { $0 }

        let frameOutputPaths = project?.frames.compactMap(\.outputOverride).flatMap {
            [$0.archive.destination, $0.positive.destination, $0.preview.destination]
        } ?? []
        let selectedPaths = [
            saveLocation,
            projectDirectory,
            outputRecipe.archive.destination,
            outputRecipe.positive.destination,
            outputRecipe.preview.destination,
        ].compactMap { $0 }.filter { !$0.isEmpty } + frameOutputPaths

        return ErrorPresentationPolicy.make(
            lastErrorMessage: lastErrorMessage,
            context: ErrorPresentationContext(
                scanStudioVersion: Self.releaseStamp,
                operatingSystemVersion: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
                cpuArchitecture: HostArchitectureProvider.currentHostArchitecture.rawValue,
                scannerFirmware: device?.firmware,
                scannerAdapter: status?.adapter,
                scannerHolder: status?.carrier,
                selectedPaths: selectedPaths,
                filmMetadataValues: metadataValues,
                deviceIdentifiers: (
                    [device?.deviceId].compactMap { $0 }
                        + availableDevices.map(\.deviceId)
                ),
                diagnosticSessionId: diagnosticTimeline.sessionID,
                engineVersion: engineVersion,
                connectionSummary: diagnosticConnectionSummary,
                recentDiagnosticEvents: diagnosticTimeline.summaryLines,
                diagnosticLogRelativePath: diagnosticLogRelativePath,
                diagnosticLogPath: diagnosticLogPath
            )
        )
    }

    /// The packaged `ScanStudioRelease` stamp, falling back to
    /// `CFBundleShortVersionString` for an unstamped dev/source build --
    /// mirrors `ScanStudioApp.installedUpdateVersion()`'s own precedence so
    /// the error report names the exact same build the updater would offer
    /// to replace. `nil` (never a hardcoded placeholder) when neither key is
    /// set, so `ErrorPresentationPolicy` renders the header's honest
    /// "unknown" instead of a fabricated version string.
    private static var releaseStamp: String? {
        if let stamp = Bundle.main.infoDictionary?["ScanStudioRelease"] as? String, !stamp.isEmpty {
            return stamp
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public private(set) var project: ScanProject?
    public private(set) var projectDirectory: String?
    public private(set) var recentProjects: [ProjectSummary] = []
    /// Serializes project create/open requests with frame-alignment work so an
    /// asynchronous response cannot be applied to a different project.
    public private(set) var isChangingProject = false
    public private(set) var isAcquiringThumbnails = false
    /// When the current active operation (a running scan job or a preview
    /// acquisition) began. Powers `SessionSidebarView`'s session-aware
    /// status card "Elapsed" readout while `isJobActive` or
    /// `isAcquiringThumbnails` is true. `nil` between operations; a stale
    /// leftover `Date` from a just-finished operation is inert by
    /// construction since the card only ever reads this while one of
    /// those two flags is true.
    public private(set) var activeOperationStartedAt: Date?
    /// Set by `connect(deviceId:)`/`createProject` whenever
    /// `scanMultisamplePasses` had to be coerced to a value the
    /// connected/newly-created-project's device actually supports (the
    /// owner hit `scan.start`'s `INVALID_PARAMS` twice picking a popup
    /// option the real LS-5000 rejects — verified live 2026-07-25).
    /// `BatchInspectorView` shows this as a subtle inline note next to the
    /// Multi-sampling picker. Transient UI feedback, never persisted;
    /// simply overwritten (including a `nil` clear when no coercion was
    /// needed) by the next call to either of those two methods.
    public private(set) var multisampleCoercionNote: String?
    /// True while the transport is in the refeed-required state: a preview,
    /// synchronous batch refusal, or scan-time fresh-index check proved the
    /// current physical registration cannot be trusted.
    /// Gates `DeviceBarView`'s Eject affordance in exactly that state —
    /// found live 2026-07-26, when the refusal's message said "eject or
    /// refeed" while the app offered no eject affordance anywhere and the
    /// owner had to use the scanner's physical button. Deliberately NOT
    /// set for `FEEDER_PARKED` (an eject against a parked transport is the
    /// accepted-but-inert stall of INCIDENT-20260719-eject-from-park; a
    /// power cycle, not an eject, is the recovery) and deliberately NOT
    /// cleared by `clearMediaState()` (the not-media-loaded status re-emit
    /// that follows a failed preview is exactly the state this flag
    /// describes). Cleared when a new preview starts, on a successful
    /// eject, and on connect/disconnect/engine-termination.
    public private(set) var refeedRequired = false
    /// Per-frame derivative rotation intent, in degrees
    /// (0/90/180/270). Read/written by `rotateFrame(_:by:)`/
    /// `resetFrameOrientation(_:)`; frames absent from this dictionary are
    /// unrotated (0°). The model persists this inside the frame's alignment
    /// geometry before scanning; the engine applies it only to finished
    /// Positive/Preview derivatives and receipts the exact transform.
    public private(set) var frameOrientations: [Int: Int] = [:]
    /// Per-frame horizontal mirror intent. Read/written by
    /// `toggleFrameMirror(_:)`/`setFrameMirror(_:for:)`/`resetFrameMirror(_:)`;
    /// frames absent from this dictionary are unmirrored (`false`). Symmetric
    /// with `frameOrientations`; persisted in the same derivative-only frame
    /// geometry record before scan dispatch.
    public private(set) var frameMirrors: [Int: Bool] = [:]
    /// Per-frame top-to-bottom flip intent. Kept independent
    /// from `frameMirrors` so either axis can be toggled or reset without
    /// changing the other.
    public private(set) var frameVerticalMirrors: [Int: Bool] = [:]
    public var scanResolutionDpi = 4_000
    public var scanBitDepth = 16
    public var scanMultisamplePasses = 2
    public var scanChannels = "rgbi"
    public var scanFilmProcess: FilmProcess = .c41ColorNegative
    /// Process used by the currently previewed real film. A project created
    /// from that registration must preserve this choice unless the operator
    /// deliberately runs a new preview.
    public private(set) var previewFilmProcess: FilmProcess?
    private var pendingPreviewFilmProcess: FilmProcess?
    public var autofocusEachFrame = true
    public var autoExposureEachFrame = true
    public var digitalIceEnabled = true
    public var digitalIceMode: DigitalIceMode = .legacy
    public var softwareDustRemovalBw = false

    /// A real, always-writable-on-this-Mac fallback destination for when no
    /// project is open yet.
    private static func defaultOutputDestination(subfolder: String) -> String {
        "\(NSHomeDirectory())/ScanStudio Projects/_Unfiled/\(subfolder)"
    }

    // MARK: - Output recipes (REC-01/02/03)
    //
    // Three independent state groups instead of one blended output recipe:
    // editing Positive's file format or Preview's size never touches any
    // Archive field, because they are simply different `@Observable`
    // properties, not different cases of one shared enum.

    /// Retaining the master TIFF is an independent output choice. Its
    /// full-fidelity format/profile remain deliberately non-configurable.
    public var masterTIFFEnabled = true
    public var archiveFilenameTemplate = FilenameTemplate.defaultTemplate
    public var archiveDestination = SessionModel.defaultOutputDestination(subfolder: "Archive")
    public var fullCapturePackageEnabled = true
    public var positiveEnabled = true
    public var positiveFileFormat: OutputFileFormat = .tiff
    public var positiveColorProfile: OutputColorProfile = .adobeRgb1998
    public var positiveFilenameTemplate = FilenameTemplate.defaultTemplate
    public var positiveDestination = SessionModel.defaultOutputDestination(subfolder: "Positive")
    public var previewEnabled = true
    public var previewFileFormat: OutputFileFormat = .jpeg
    /// A zero cap is an existing engine-supported full-resolution export.
    public var previewMaxLongEdgePx = 0
    /// Non-destructive scan-time auto-crop of derived outputs (positive and
    /// preview) to each frame's own detected film ROI. The retained master
    /// TIFF is never cropped, and every frame's receipt records the decision,
    /// so the choice is reversible by re-rendering. Off by default.
    public var autoCropEnabled = false
    public var previewFilenameTemplate = FilenameTemplate.defaultTemplate
    public var previewDestination = SessionModel.defaultOutputDestination(subfolder: "Preview")
    /// User-facing output organization. The legacy per-output destination
    /// fields above remain the wire/project representation; these derive
    /// them from one chosen base directory without changing old projects.
    public var saveLocation = ""
    public var saveEachOutputInOwnFolder = true
    public var masterFolderName = "Master TIFF"
    public var positiveTiffFolderName = "Positive TIFF"
    public var positiveJPEGFolderName = "Positive JPEG"
    public var saveFilenameTemplateAsDefault = false
    /// Ephemeral UI choice: a user can intentionally switch away from a
    /// curated stock before they have typed their own name. The project
    /// stores the resulting metadata, not this presentation state.
    public var isCustomFilmStockSelected = false

    /// Per-user only, deliberately not included in `ScanProject`.
    public private(set) var recentGearHistory = RecentGearHistory()
    private static let recentGearHistoryKey = "ScanStudio.recentGearHistory.v1"
    private static let filenameTemplateDefaultKey = "ScanStudio.filenameTemplateDefault.v1"

    // MARK: - Roll metadata (META-01/02) + ExifTool (META-03) + resume (PERSIST-02)

    /// Always-current roll-wide metadata draft the roll-metadata UI binds
    /// directly to. No separate "seed from project" step is needed since
    /// `MetadataSet()`'s default init is already the correct empty starting
    /// point; `createProject`/`openProject` re-sync this from
    /// `project?.rollMetadata` whenever a project loads, exactly the same
    /// shape `applyRecipes` already uses for the three output-recipe state
    /// groups above.
    public var rollMetadataDraft = MetadataSet()

    /// The last `exiftool.detect` result, if one has been requested yet.
    public private(set) var exifToolDetection: ExifToolDetection?
    /// The last `previewMetadataCommand` result for whichever single frame
    /// is currently being inspected. Only ever one frame's preview is shown
    /// at a time, so a cached dictionary keyed by frame index (like
    /// `frameDefects`) would be needless; callers clear/replace this
    /// between frames.
    public private(set) var metadataPreview: PreviewMetadataCommandResult?

    /// The engine's authoritative resume set from the last
    /// `project.pendingFrames` round trip.
    public private(set) var pendingFrames: [Int] = []
    public var pendingFrameCount: Int { pendingFrames.count }
    /// How many frames already carry a receipt, from that same
    /// `project.pendingFrames` round trip (`PendingFramesResult.completedCount`)
    /// — the one signal that distinguishes a fresh, never-scanned project
    /// from a genuinely partial one. See `ResumeBatchPolicy` below for why
    /// this can never be derived from `pendingFrameCount` alone.
    public private(set) var completedFrameCount: Int = 0
    /// Every frame whose completion is backed by a receipt, whether that
    /// receipt came from the project snapshot or arrived live in this
    /// session. Unlike `frameStates`, this durable set is never cleared just
    /// to display a fresh re-scan attempt.
    private var durableCompletedFrameIndices: Set<Int> = []

    /// Selection is a user choice, deliberately separate from engine frame
    /// states so completed/failed overlays never change the next batch.
    public private(set) var selectedFrameIndices: Set<Int> = []
    /// The last frame a *plain* (non-Shift) click landed on — the anchor a
    /// Shift-click range-select extends from. Reset alongside
    /// `selectedFrameIndices` whenever media changes (`clearMediaState`), so
    /// a stale anchor from a previous carrier/project can never leak into a
    /// new one.
    public private(set) var selectionAnchorFrameIndex: Int?
    /// The one frame targeted by edit commands. This is deliberately
    /// independent from scan selection: six frames can remain checked while
    /// rotation or flipping changes only the focused frame.
    public private(set) var focusedFrameIndex: Int?
    private var bufferedJobEvents: [String: [EngineEvent]] = [:]

    /// Which frame's detail workspace is open, if any — pure UI navigation
    /// state consumed by Plan 04-04's per-frame detail view, not read
    /// anywhere in this plan's own tasks.
    public private(set) var detailFrameIndex: Int? = nil

    public var receiptCount: Int { receipts.count }
    public var thumbnailCount: Int { thumbnails.count }
    public var selectedFrameCount: Int { selectedFrameIndices.count }
    public var selectedFrames: [Int] { selectedFrameIndices.sorted() }
    /// Every frame index the active project currently marks `excluded`,
    /// re-derived from `project` on every access rather than cached — always
    /// consistent with whatever `setFrameExcluded` last wrote.
    public var excludedFrameIndices: Set<Int> {
        Set((project?.frames ?? []).filter { $0.excluded }.map { $0.index })
    }
    public func isFrameExcluded(_ frameIndex: Int) -> Bool {
        excludedFrameIndices.contains(frameIndex)
    }
    public var loadedCarrier: SimulatedFilmCarrier? {
        status?.carrier.flatMap(SimulatedFilmCarrier.init(rawValue:))
    }
    /// A saved project may only scan the exact frame registration established
    /// by the current successful preview. This protects an older 36-frame
    /// project from silently targeting a newly detected 39-frame roll.
    public var projectMediaMismatch: Bool {
        guard let project,
              status?.mediaLoaded == true,
              let previewedCarrier = loadedCarrier,
              let previewedFrameCount = status?.frameCount
        else { return false }
        return !ProjectMediaCompatibilityPolicy.matches(
            projectCarrier: project.carrier,
            projectFrameCount: project.frameCount,
            previewedCarrier: previewedCarrier,
            previewedFrameCount: previewedFrameCount
        )
    }
    public var carrierDisplayName: String {
        loadedCarrier?.displayName ?? "Film loaded"
    }
    public var captureRecipe: CaptureRecipe {
        CaptureRecipe(
            resolutionDpi: scanResolutionDpi,
            bitDepth: scanBitDepth,
            multisamplePasses: scanMultisamplePasses,
            channels: scanChannels
        )
    }
    public var processingRecipe: ProcessingRecipe {
        ProcessingRecipe(
            filmProcess: scanFilmProcess,
            autofocusEachFrame: autofocusEachFrame,
            autoExposureEachFrame: autoExposureEachFrame,
            digitalIceEnabled: digitalIceEnabled && scanChannels == "rgbi" && scanFilmProcess != .bwNegative,
            digitalIceMode: digitalIceMode,
            softwareDustRemovalBw: softwareDustRemovalBw && scanFilmProcess == .bwNegative
        )
    }
    public var outputRecipe: OutputRecipe {
        let masterDestination = OutputDestination.destination(
            base: saveLocation,
            subfolder: saveEachOutputInOwnFolder ? masterFolderName : nil,
            fallback: archiveDestination
        )
        let positiveDestination = OutputDestination.destination(
            base: saveLocation,
            subfolder: saveEachOutputInOwnFolder ? positiveTiffFolderName : nil,
            fallback: self.positiveDestination
        )
        let jpegDestination = OutputDestination.destination(
            base: saveLocation,
            subfolder: saveEachOutputInOwnFolder ? positiveJPEGFolderName : nil,
            fallback: previewDestination
        )
        return OutputRecipe(
            archive: ArchiveRecipe(
                enabled: masterTIFFEnabled,
                filenameTemplate: OutputNamingTemplate.template(
                    archiveFilenameTemplate,
                    roleSuffix: "Master",
                    separateFolders: saveEachOutputInOwnFolder
                ),
                destination: masterDestination,
                fullCapturePackage: masterTIFFEnabled && fullCapturePackageEnabled
            ),
            positive: PositiveRecipe(
                enabled: positiveEnabled,
                fileFormat: positiveFileFormat,
                colorProfile: positiveColorProfile,
                filenameTemplate: OutputNamingTemplate.template(
                    positiveFilenameTemplate,
                    roleSuffix: "Positive",
                    separateFolders: saveEachOutputInOwnFolder
                ),
                destination: positiveDestination
            ),
            preview: PreviewRecipe(
                enabled: previewEnabled,
                fileFormat: previewFileFormat,
                maxLongEdgePx: previewMaxLongEdgePx,
                filenameTemplate: OutputNamingTemplate.template(
                    previewFilenameTemplate,
                    roleSuffix: "Positive",
                    separateFolders: saveEachOutputInOwnFolder
                ),
                destination: jpegDestination
            ),
            autoCrop: autoCropEnabled
        )
    }

    public var scanRecipePreset: ScanRecipePreset {
        let values = ScanRecipeValues(
            resolutionDpi: scanResolutionDpi,
            bitDepth: scanBitDepth,
            multisamplePasses: scanMultisamplePasses,
            channels: scanChannels,
            autofocus: autofocusEachFrame,
            autoExposure: autoExposureEachFrame,
            digitalIce: digitalIceEnabled,
            digitalIceMode: digitalIceMode,
            softwareDustRemovalBw: softwareDustRemovalBw,
            positiveTiff: positiveEnabled,
            positiveJPEG: previewEnabled,
            positiveFileFormat: positiveFileFormat,
            previewFileFormat: previewFileFormat,
            positiveColorProfile: positiveColorProfile,
            previewMaxLongEdgePx: previewMaxLongEdgePx
        )
        return ScanRecipePolicy.preset(
            matching: values,
            filmProcess: scanFilmProcess,
            supportedMultisamplePasses: MultisamplePassPolicy.supportedOptions(for: device)
        )
    }

    public func applyScanRecipePreset(_ preset: ScanRecipePreset) {
        guard let values = ScanRecipePolicy.values(
            for: preset,
            filmProcess: scanFilmProcess,
            supportedMultisamplePasses: MultisamplePassPolicy.supportedOptions(for: device)
        ) else { return }
        scanResolutionDpi = values.resolutionDpi
        scanBitDepth = values.bitDepth
        scanMultisamplePasses = values.multisamplePasses
        scanChannels = values.channels
        autofocusEachFrame = values.autofocus
        autoExposureEachFrame = values.autoExposure
        digitalIceEnabled = values.digitalIce
        digitalIceMode = values.digitalIceMode
        softwareDustRemovalBw = values.softwareDustRemovalBw
        positiveEnabled = values.positiveTiff
        previewEnabled = values.positiveJPEG
        positiveFileFormat = values.positiveFileFormat
        previewFileFormat = values.previewFileFormat
        positiveColorProfile = values.positiveColorProfile
        previewMaxLongEdgePx = values.previewMaxLongEdgePx
    }

    /// True whenever a job exists and hasn't reached a terminal state.
    /// This is what `SessionSidebarView` binds Eject's `.disabled` to
    /// (D-11 — UI side is by construction).
    public var isJobActive: Bool {
        guard let jobState else { return false }
        return !jobState.isTerminal
    }

    public var hardwareMotionReadiness: HardwareMotionReadiness {
        HardwareMotionReadiness.evaluate(
            isRealDevice: device?.kind == "real",
            motionArmed: status?.motionArmed
        )
    }

    /// Whether the current film has one complete, internally consistent
    /// preview registration. This is deliberately the same evidence the
    /// center Save Roll gate trusts: media status, exact 1...N thumbnails,
    /// the authoritative status count, and a process committed only by the
    /// terminal completion event.
    public var hasCompletePreviewRegistration: Bool {
        guard !isRestoringFrameAlignments,
              failedFrameAlignmentRestoreIndices.isEmpty
        else {
            return false
        }
        return PreviewRegistrationPolicy.isComplete(
            mediaLoaded: status?.mediaLoaded == true,
            previewFrameIndices: thumbnails.keys,
            statusFrameCount: status?.frameCount,
            committedFilmProcess: previewFilmProcess
        )
    }

    /// Allows ordinary frame detail only for a current, complete preview, but
    /// preserves the one recovery route when an alignment failure itself is
    /// what makes `hasCompletePreviewRegistration` false. A failed frame from
    /// another index, a partial tile stream, or preview evidence cleared by a
    /// session reset never opens detail through this exception.
    public func canPresentFrameDetail(_ frameIndex: Int) -> Bool {
        guard !isRestoringFrameAlignments,
              latestCompletedPreviewOperationId != nil,
              thumbnails[frameIndex] != nil,
              validFrameIndices.contains(frameIndex),
              PreviewRegistrationPolicy.isComplete(
                  mediaLoaded: status?.mediaLoaded == true,
                  previewFrameIndices: thumbnails.keys,
                  statusFrameCount: status?.frameCount,
                  committedFilmProcess: previewFilmProcess
              )
        else {
            return false
        }
        return failedFrameAlignmentRestoreIndices.isEmpty
            || failedFrameAlignmentRestoreIndices.contains(frameIndex)
    }

    /// The shared readiness decision used by every scan-start path and both
    /// scan controls. A preview is required as well as media presence: a
    /// carrier alone does not establish usable frame registration.
    public func scanReadiness(for requestedFrames: [Int]) -> ScanReadinessPolicy.Decision {
        let validTargets = Set(validFrameIndices)
        let hasValidTarget = ScanReadinessPolicy.allTargetsAreStructurallyValid(
            requestedFrames,
            validFrameIndices: validTargets,
            excludedFrameIndices: excludedFrameIndices
        )
        return ScanReadinessPolicy.evaluate(.init(
            isConnected: status?.connected == true,
            hasPreviewedMedia:
                status?.mediaLoaded == true
                    && !thumbnails.isEmpty
                    && failedFrameAlignmentRestoreIndices.isEmpty,
            hasOpenProject: project != nil,
            hardwareMotionReadiness: hardwareMotionReadiness,
            projectMatchesPreviewedMedia: !projectMediaMismatch,
            fineScanUnsupported: device?.kind == "real" && scanFilmProcess == .bwNegative,
            hasValidTarget: hasValidTarget,
            hasTargetPreviews: ScanReadinessPolicy.allTargetPreviewsAreAvailable(
                requestedFrames,
                previewedFrameIndices: Set(thumbnails.keys)
            ),
            transportIsIdle: status?.transport == "idle",
            isAcquiringPreviews: isAcquiringThumbnails,
            hasActiveJob: isJobActive,
            isAdjustingFrameAlignment: pendingFrameAlignmentAdjustment != nil
        ))
    }

    public init(
        engineClient: any EngineClientProtocol,
        preferences: UserDefaults = .standard,
        diagnosticsDirectory: URL? = nil
    ) {
        self.engineClient = engineClient
        self.preferences = preferences
        self.diagnosticTimeline = SessionDiagnosticTimeline(
            sessionID: UUID().uuidString.lowercased(),
            directory: diagnosticsDirectory
        )
        if let data = preferences.data(forKey: Self.recentGearHistoryKey),
           let history = try? JSONDecoder().decode(RecentGearHistory.self, from: data) {
            recentGearHistory = history
        }
        if let savedTemplate = preferences.string(forKey: Self.filenameTemplateDefaultKey),
           !savedTemplate.isEmpty {
            archiveFilenameTemplate = savedTemplate
            positiveFilenameTemplate = savedTemplate
            previewFilenameTemplate = savedTemplate
        }
        recordDiagnostic(event: "session.started")
        self.eventTask = Task { [weak self] in
            for await event in engineClient.events {
                self?.handle(event: event)
            }
        }
        Task { [weak self] in
            await self?.refreshAvailableDevices()
        }
    }

    deinit {
        eventTask?.cancel()
    }

    // MARK: - Session controls

    /// Refreshes `availableDevices` from `scanner.list` so the sidebar's
    /// device picker has real devices to render before the user takes any
    /// action. Called once from `init` (fire-and-forget); also called by
    /// `connect(deviceId:)` if `availableDevices` is still empty when a
    /// specific device is requested.
    public func refreshAvailableDevices() async {
        deviceDiscoveryRequestsInFlight += 1
        isDiscoveringDevices = true
        defer {
            deviceDiscoveryRequestsInFlight -= 1
            isDiscoveringDevices = deviceDiscoveryRequestsInFlight > 0
        }
        do {
            let listResult: ScannerListResult = try await engineClient.request(
                "scanner.list", params: EmptyParams()
            )
            availableDevices = listResult.devices
            recordDiagnostic(
                event: "device.discovery.succeeded",
                fields: ["count": String(listResult.devices.count)]
            )
        } catch is CancellationError {
            // Cancellation is lifecycle, not a user-facing discovery error.
            recordDiagnostic(event: "device.discovery.cancelled")
        } catch {
            recordOperationFailure(error, operation: "device.discovery")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Re-checks the engine's current scanner status without moving film or
    /// changing hardware authorization. A response may update this model only
    /// while the same connected session that requested it still owns the UI.
    public func refreshScannerStatus() async {
        guard diagnosticUIConnected, pendingStatusRefresh == nil else { return }
        let marker = PendingStatusRefresh(
            id: UUID(),
            connectionEpoch: connectionEpoch
        )
        pendingStatusRefresh = marker
        isRefreshingScannerStatus = true
        defer {
            if pendingStatusRefresh?.id == marker.id {
                pendingStatusRefresh = nil
                isRefreshingScannerStatus = false
            }
        }

        do {
            let refreshed: ScannerStatus = try await engineClient.request(
                "scanner.status",
                params: EmptyParams()
            )
            guard pendingStatusRefresh?.id == marker.id,
                  connectionEpoch == marker.connectionEpoch,
                  diagnosticUIConnected
            else {
                return
            }
            guard refreshed.connected else {
                invalidateConnection(
                    source: "scanner.status",
                    uiConnectedBefore: true
                )
                return
            }
            let reconciled = refreshed.invalidatingPreviewWhenFilmIsAbsent()
            status = reconciled
            recordDiagnostic(
                event: "scanner.status",
                fields: Self.scannerStatusDiagnosticFields(reconciled)
            )
            if !reconciled.mediaLoaded || reconciled.filmPresent == false {
                clearMediaState(
                    preservingPreviewAuthorization: true,
                    preservingActiveJob: refeedRequired
                )
            }
            if !refeedRequired {
                lastErrorMessage = nil
            }
        } catch {
            guard pendingStatusRefresh?.id == marker.id,
                  connectionEpoch == marker.connectionEpoch
            else {
                return
            }
            recordOperationFailure(error, operation: "scanner.status")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Connects to a specific device by id. A nil target fails closed unless
    /// discovery finds exactly one device; engine result ordering is never
    /// treated as permission to choose between real hardware and simulator.
    public func connect(deviceId: String? = nil) async {
        guard !Task.isCancelled, !isConnectingDevice else { return }
        isConnectingDevice = true
        defer { isConnectingDevice = false }
        lastErrorMessage = nil
        do {
            let targetDeviceId: String
            if let deviceId {
                if availableDevices.isEmpty {
                    await refreshAvailableDevices()
                }
                try Task.checkCancellation()
                guard availableDevices.contains(where: { $0.deviceId == deviceId }) else {
                    lastErrorMessage = "The engine has no device with id \"\(deviceId)\"."
                    return
                }
                targetDeviceId = deviceId
            } else {
                if availableDevices.isEmpty {
                    await refreshAvailableDevices()
                }
                try Task.checkCancellation()
                guard let resolvedDeviceId = DeviceSelectionPolicy.resolveNilTarget(
                    devices: availableDevices
                ) else {
                    lastErrorMessage = availableDevices.isEmpty
                        ? "No scanner is available. Refresh the device list and try again."
                        : "Choose a scanner from Connect…; ScanStudio will not guess between real hardware and the simulator."
                    return
                }
                targetDeviceId = resolvedDeviceId
            }
            let timeScale = ProcessInfo.processInfo.environment["SCANSTUDIO_TIMESCALE"]
                .flatMap(Double.init) ?? 1.0
            let options = ConnectOptions(timeScale: timeScale, faultInjection: "none")
            let params = ConnectParams(deviceId: targetDeviceId, options: options)
            recordDiagnostic(
                event: "device.connect.requested",
                fields: [
                    "kind": availableDevices.first {
                        $0.deviceId == targetDeviceId
                    }?.kind ?? "unknown",
                    "uiConnectedBefore": String(diagnosticUIConnected),
                ]
            )
            let result: ConnectResult = try await engineClient.request("scanner.connect", params: params)
            // Once the engine reports success, that connection is
            // authoritative even if the calling UI task was cancelled while
            // awaiting it. Discarding the result here would leave the engine
            // connected while this session falsely rendered as offline.
            advanceConnectionEpoch()
            device = result.device
            status = result.status
            refeedRequired = false
            engineVersion = await engineClient.engineVersion
            coerceMultisamplePassesForConnectedDevice()
            recordDiagnostic(
                event: "device.connect.succeeded",
                fields: [
                    "connected": String(result.status.connected),
                    "kind": result.device.kind,
                    "mediaLoaded": String(result.status.mediaLoaded),
                    "transport": result.status.transport,
                ]
            )
        } catch is CancellationError {
            // A cancelled connect should silently restore the idle affordance.
            recordDiagnostic(event: "device.connect.cancelled")
        } catch {
            recordOperationFailure(error, operation: "device.connect")
            lastErrorMessage = Self.describe(error)
        }
    }

    public func disconnect() async {
        lastErrorMessage = nil
        recordDiagnostic(
            event: "device.disconnect.requested",
            fields: ["uiConnectedBefore": String(diagnosticUIConnected)]
        )
        do {
            let _: EmptyResult = try await engineClient.request("scanner.disconnect", params: EmptyParams())
            advanceConnectionEpoch()
            device = nil
            status = nil
            multisampleCoercionNote = nil
            refeedRequired = false
            clearMediaState()
            recordDiagnostic(event: "device.disconnect.succeeded")
        } catch {
            recordOperationFailure(error, operation: "device.disconnect")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Coerces `scanMultisamplePasses` to a value the currently-connected
    /// device (`self.device`, already refreshed by the caller) actually
    /// accepts, recording a `multisampleCoercionNote` when a coercion
    /// happened (or clearing it when the current value was already
    /// valid). Shared by `connect(deviceId:)` (a device just connected)
    /// and `createProject` (a fresh project should never inherit a
    /// leftover unsupported value — see that method's own call site
    /// comment).
    private func coerceMultisamplePassesForConnectedDevice() {
        let supported = MultisamplePassPolicy.supportedOptions(for: device)
        let coerced = MultisamplePassPolicy.coerce(scanMultisamplePasses, into: supported)
        guard coerced != scanMultisamplePasses else {
            multisampleCoercionNote = nil
            return
        }
        multisampleCoercionNote = "Multi-sampling adjusted to \(MultisamplePassPolicy.label(for: coerced)) — "
            + "\(device?.model ?? "this device") only supports \(MultisamplePassPolicy.optionsDescription(supported))."
        scanMultisamplePasses = coerced
    }

    /// Loads a simulated carrier. Previewing remains an explicit next action
    /// after a roll project exists, matching the real scanner's honest flow.
    public func loadCarrier(_ carrier: SimulatedFilmCarrier) async {
        lastErrorMessage = nil
        do {
            let params = LoadMediaParams(carrier: carrier.rawValue)
            let newStatus: ScannerStatus = try await engineClient.request("sim.loadMedia", params: params)
            status = newStatus
            clearMediaState()
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    public func loadRoll() async {
        await loadCarrier(.roll36)
    }

    /// Consumes one typed, presentation-scoped preview intent and, only when
    /// admitted, sends exactly one hardware request.
    ///
    /// There is intentionally no untyped acquisition escape hatch. Callers
    /// must identify whether this is an initial preview, a confirmed process
    /// replacement, or a saved-project refresh, and must carry the stable
    /// token owned by that concrete UI presentation.
    @discardableResult
    public func requestPreview(_ intent: PreviewIntent) async -> PreviewRequestOutcome {
        let context = PreviewIntentStateMachine.Context(
            hasProject: project != nil,
            isAcquiring: isAcquiringThumbnails,
            hasCompleteRegistration: hasCompletePreviewRegistration
        )
        guard previewIntentStateMachine.consume(intent, context: context) else {
            return .rejected
        }
        guard hardwareMotionReadiness.allowsMotion else {
            _ = previewIntentStateMachine.failSynchronousRequest(
                operationID: intent.operationID
            )
            lastErrorMessage = hardwareMotionReadiness.guidance
            return .rejected
        }
        // Only an admitted traversal that passed its synchronous movement
        // preflight replaces the current preview evidence. A rejected
        // "Preview Again" must leave its still-visible Review buttons and
        // choices usable rather than orphaning them before any motion began.
        clearPendingManualReviewScan()
        manualReviewDecisions.removeAll()
        clearFrameAlignmentSessionState()
        latestCompletedPreviewOperationId = nil

        lastErrorMessage = nil
        // A fresh preview attempt supersedes the previous refeed verdict;
        // if this one also refuses, `scanner.thumbnailsFailed` re-sets it.
        refeedRequired = false
        thumbnails = [:]
        isAcquiringThumbnails = true
        activeOperationStartedAt = Date()

        let process: FilmProcess
        switch intent {
        case .initial:
            process = PreviewProcessLifecyclePolicy.requestProcess(
                projectProcess: nil,
                selectedProcess: scanFilmProcess
            )
        case .replaceFilmProcess(_, let replacement):
            previewFilmProcess = nil
            pendingPreviewFilmProcess = nil
            scanFilmProcess = replacement
            if replacement == .bwNegative {
                scanChannels = "rgb"
                digitalIceEnabled = false
            }
            process = replacement
        case .refreshSavedProject:
            process = PreviewProcessLifecyclePolicy.requestProcess(
                projectProcess: project?.filmProcess,
                selectedProcess: scanFilmProcess
            )
        }

        recordDiagnostic(
            event: "preview.requested",
            fields: [
                "kind": String(describing: intent.kind),
                "process": process.rawValue,
                "uiConnected": String(diagnosticUIConnected),
            ]
        )
        do {
            let params = AcquireThumbnailsParams(
                frames: nil,
                filmProcess: process,
                operationId: intent.operationID
            )
            pendingPreviewFilmProcess = process
            let _: AcquireThumbnailsAck = try await engineClient.request(
                "scanner.acquireThumbnails", params: params
            )
            recordDiagnostic(
                event: "preview.accepted",
                fields: ["uiConnected": String(diagnosticUIConnected)]
            )
            return .started
        } catch {
            guard previewIntentStateMachine.failSynchronousRequest(
                operationID: intent.operationID
            ) else {
                // The request continuation can fail after correlated terminal
                // events closed this operation and a replacement acquired the
                // lane. A stale catch may report its own call as failed, but
                // it no longer owns any shared preview or error state.
                return .failedToStart
            }
            isAcquiringThumbnails = false
            activeOperationStartedAt = nil
            pendingPreviewFilmProcess = nil
            latestCompletedPreviewOperationId = nil
            recordOperationFailure(error, operation: "preview")
            lastErrorMessage = Self.describe(error)
            return .failedToStart
        }
    }

    /// Starts a batch for the selected frames using the editable capture
    /// recipe currently shown in the Batch Settings inspector.
    public func startMockScan() async {
        _ = await startScanOrRequestManualReview(frames: selectedFrames)
    }

    /// Scans exactly one frame regardless of the grid's current selection —
    /// serves both "retry a completed/failed frame" (`ThumbnailGridView`'s
    /// per-frame retry action) and "Scan Frame NN" (Plan 04-04's detail-view
    /// CTA); the operation on the wire is identical either way.
    public func scanSingleFrame(_ frameIndex: Int) async {
        _ = await startScanOrRequestManualReview(frames: [frameIndex])
    }

    /// Legacy fallback for a manual-review refusal that escaped the preview
    /// preflight (for example, an older engine that omitted thumbnail
    /// evidence). Never launches a second real-scanner traversal: once a job
    /// has ended, the reviewed transport registration must be re-established
    /// with a fresh preview before another fine scan.
    public func approveAndRetryFrame(_ frameIndex: Int) async {
        guard frameErrors[frameIndex]?.code == FrameFailureLabel.manualReviewCode else {
            return
        }
        lastErrorMessage =
            "This scan already ended, so retrying from here could start a second film traversal. "
            + "Acquire a fresh preview, confirm any flagged frame there, then start the batch again."
    }

    /// Cancels the UI-visible pre-scan review without approving or moving the
    /// scanner. An approval already in flight owns the boundary until its
    /// response returns; the sheet disables dismissal during that interval.
    public func cancelPendingManualReviewScan() {
        guard pendingManualReviewApproval == nil else { return }
        clearPendingManualReviewScan()
    }

    /// Approves every flagged boundary from the exact current preview, then
    /// starts the original complete frame list once. Any approval failure,
    /// preview replacement, disconnect, or readiness change fails closed
    /// before `scan.start`.
    public func approvePendingManualReviewAndStart() async {
        guard pendingManualReviewApproval == nil,
              pendingScanStart == nil,
              let authorization = pendingManualReviewScanAuthorization,
              !authorization.confirmationRequirements.isEmpty,
              pendingManualReviewScan?.id == authorization.requestId
        else {
            return
        }
        _ = await approveManualReviewAndStart(authorization)
    }

    /// Executes one already-authorized manual-review path. The authorization
    /// may come from the scan-time sheet or from contact-sheet decisions that
    /// resolved every flagged frame before Scan was pressed.
    @discardableResult
    private func approveManualReviewAndStart(
        _ authorization: PendingManualReviewScanAuthorization
    ) async -> Bool {
        guard pendingManualReviewApproval == nil,
              pendingScanStart == nil,
              pendingManualReviewScanAuthorization?.requestId
                == authorization.requestId
        else {
            return false
        }
        guard manualReviewAuthorizationIsCurrent(authorization) else {
            clearPendingManualReviewScan()
            lastErrorMessage =
                "That review no longer matches the current scanner preview. Acquire a fresh preview before scanning."
            return false
        }

        lastErrorMessage = nil
        let readinessBeforeApproval = scanReadiness(for: authorization.frames)
        guard readinessBeforeApproval.isReady else {
            lastErrorMessage = readinessBeforeApproval.reason
            return false
        }

        let marker = PendingManualReviewApproval(
            id: UUID(),
            requestId: authorization.requestId,
            previewOperationId: authorization.previewOperationId,
            connectionEpoch: authorization.connectionEpoch
        )
        pendingManualReviewApproval = marker
        defer {
            if pendingManualReviewApproval?.id == marker.id {
                pendingManualReviewApproval = nil
                approvingFrameIndex = nil
            }
        }

        for requirement in authorization.requirements {
            approvingFrameIndex = requirement.frameIndex
            do {
                let params = RollApproveParams(
                    frameIndex: requirement.frameIndex,
                    operationId: marker.previewOperationId
                )
                let _: EmptyResult = try await engineClient.request(
                    "roll.approve",
                    params: params
                )
            } catch {
                guard manualReviewApprovalIsCurrent(marker) else {
                    return false
                }
                recordOperationFailure(error, operation: "roll.approve")
                lastErrorMessage = Self.describe(error)
                if authorization.confirmationRequirements.isEmpty {
                    clearPendingManualReviewScan(
                        requestId: authorization.requestId
                    )
                }
                return false
            }
            guard manualReviewApprovalIsCurrent(marker) else {
                return false
            }
        }

        for requirement in authorization.requirements {
            manualReviewDecisions[requirement.frameIndex] = .useFrameAnyway
        }

        let readinessAfterApproval = scanReadiness(for: authorization.frames)
        guard readinessAfterApproval.isReady else {
            lastErrorMessage = readinessAfterApproval.reason
            if authorization.confirmationRequirements.isEmpty {
                clearPendingManualReviewScan(
                    requestId: authorization.requestId
                )
            }
            return false
        }

        do {
            guard let result = try await dispatchScanStart(
                frames: authorization.frames
            ) else {
                return false
            }
            // A successful response means the engine accepted this exact,
            // already-approved full batch. Adopt it unconditionally, just as
            // the ordinary scan-start path does. A late status/media event
            // may have cleared the UI review marker while the request was in
            // flight; returning here would orphan a physically running job
            // and hide its stop controls.
            clearPendingManualReviewScan(requestId: marker.requestId)
            beginJob(id: result.jobId, frames: authorization.frames)
            return true
        } catch {
            guard manualReviewApprovalIsCurrent(marker) else {
                return false
            }
            recordOperationFailure(error, operation: "scan.start")
            lastErrorMessage = Self.describe(error)
            noteRefeedRequired(from: error)
            if authorization.confirmationRequirements.isEmpty {
                clearPendingManualReviewScan(
                    requestId: authorization.requestId
                )
            }
            return false
        }
    }

    /// Shared final boundary for every UI path capable of issuing
    /// `scan.start`. Preview evidence is checked here, in the model, so a
    /// forgotten or delayed UI confirmation cannot bypass it.
    @discardableResult
    private func startScanOrRequestManualReview(frames: [Int]) async -> Bool {
        lastErrorMessage = nil
        guard pendingManualReviewApproval == nil else { return false }
        guard pendingScanStart == nil else {
            lastErrorMessage = "A scan is already starting."
            return false
        }

        let readiness = scanReadiness(for: frames)
        guard readiness.isReady else {
            lastErrorMessage = readiness.reason
            return false
        }

        let requirements: [ManualReviewRequirement] = frames.compactMap { frameIndex in
            guard let thumbnail = thumbnails[frameIndex],
                  thumbnail.needsApproval
            else {
                return nil
            }
            return ManualReviewRequirement(
                frameIndex: frameIndex,
                warnings: thumbnail.warnings
            )
        }

        if !requirements.isEmpty {
            guard let previewOperationId = latestCompletedPreviewOperationId else {
                clearPendingManualReviewScan()
                lastErrorMessage =
                    "The flagged frame is not bound to a completed preview. "
                    + "Acquire a fresh preview before scanning."
                return false
            }

            let confirmationRequirements = requirements.filter {
                manualReviewDecisions[$0.frameIndex] != .useFrameAnyway
            }

            if let current = pendingManualReviewScanAuthorization,
               current.frames == frames,
               current.requirements == requirements,
               current.confirmationRequirements == confirmationRequirements,
               current.previewOperationId == previewOperationId,
               current.connectionEpoch == connectionEpoch
            {
                return false
            }

            let request = ManualReviewScanRequest(
                id: UUID(),
                frames: frames,
                requirements: confirmationRequirements
            )
            pendingManualReviewScan = confirmationRequirements.isEmpty
                ? nil
                : request
            pendingManualReviewScanAuthorization =
                PendingManualReviewScanAuthorization(
                    requestId: request.id,
                    frames: request.frames,
                    requirements: requirements,
                    confirmationRequirements: confirmationRequirements,
                    previewOperationId: previewOperationId,
                    connectionEpoch: connectionEpoch
                )
            recordDiagnostic(
                event: "scan.manualReview.required",
                fields: [
                    "frames": confirmationRequirements.map {
                        String($0.frameIndex)
                    }.joined(separator: ","),
                    "alreadyResolvedFrameCount":
                        String(requirements.count - confirmationRequirements.count),
                    "requestedFrameCount": String(frames.count),
                ]
            )
            if confirmationRequirements.isEmpty,
               let authorization = pendingManualReviewScanAuthorization
            {
                return await approveManualReviewAndStart(authorization)
            }
            return false
        }

        clearPendingManualReviewScan()
        do {
            guard let result = try await dispatchScanStart(frames: frames) else {
                return false
            }
            beginJob(id: result.jobId, frames: frames)
            return true
        } catch {
            recordOperationFailure(error, operation: "scan.start")
            lastErrorMessage = Self.describe(error)
            noteRefeedRequired(from: error)
            return false
        }
    }

    private func manualReviewAuthorizationIsCurrent(
        _ authorization: PendingManualReviewScanAuthorization
    ) -> Bool {
        let presentationIsCurrent: Bool
        if authorization.confirmationRequirements.isEmpty {
            presentationIsCurrent =
                pendingManualReviewScan == nil
                && authorization.requirements.allSatisfy {
                    manualReviewDecisions[$0.frameIndex] == .useFrameAnyway
                }
        } else {
            presentationIsCurrent =
                pendingManualReviewScan?.id == authorization.requestId
                && pendingManualReviewScan?.requirements
                    == authorization.confirmationRequirements
        }

        return pendingManualReviewScanAuthorization?.requestId
            == authorization.requestId
            && presentationIsCurrent
            && connectionEpoch == authorization.connectionEpoch
            && diagnosticUIConnected
            && latestCompletedPreviewOperationId
                == authorization.previewOperationId
            && authorization.requirements
                == authorization.frames.compactMap {
                    frameIndex -> ManualReviewRequirement? in
                    guard let thumbnail = thumbnails[frameIndex],
                          thumbnail.needsApproval
                    else {
                        return nil
                    }
                    return ManualReviewRequirement(
                        frameIndex: frameIndex,
                        warnings: thumbnail.warnings
                    )
                }
    }

    private func manualReviewApprovalIsCurrent(
        _ marker: PendingManualReviewApproval
    ) -> Bool {
        guard pendingManualReviewApproval?.id == marker.id,
              let authorization = pendingManualReviewScanAuthorization,
              authorization.requestId == marker.requestId,
              marker.previewOperationId == authorization.previewOperationId,
              marker.connectionEpoch == authorization.connectionEpoch
        else {
            return false
        }
        return manualReviewAuthorizationIsCurrent(authorization)
    }

    private func clearPendingManualReviewScan(requestId: UUID? = nil) {
        if let requestId,
           pendingManualReviewScanAuthorization?.requestId != requestId
        {
            return
        }
        pendingManualReviewScan = nil
        pendingManualReviewScanAuthorization = nil
    }

    public func stopAfterCurrentFrame() async {
        lastErrorMessage = nil
        guard let jobId else { return }
        do {
            let params = ScanStopParams(jobId: jobId, mode: "afterCurrentFrame")
            let _: ScanStopResult = try await engineClient.request("scan.stop", params: params)
        } catch {
            recordOperationFailure(error, operation: "scan.stop")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Requests an immediate stop for the current scan. The engine remains
    /// authoritative about whether a job can still be stopped.
    public func stopImmediately() async {
        lastErrorMessage = nil
        guard let jobId else { return }
        do {
            let params = ScanStopParams(jobId: jobId, mode: "immediate")
            let _: ScanStopResult = try await engineClient.request("scan.stop", params: params)
        } catch {
            recordOperationFailure(error, operation: "scan.stop")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Lets a running batch abandon its currently-active frame (marked
    /// `skipped`, no receipt written for it) and continue to its next frame,
    /// rather than pausing/halting the whole batch like `scan.stop` does.
    public func skipCurrentFrame() async {
        lastErrorMessage = nil
        guard let jobId else { return }
        do {
            let params = ScanSkipCurrentFrameParams(jobId: jobId)
            let _: ScanSkipCurrentFrameResult = try await engineClient.request("scan.skipCurrentFrame", params: params)
        } catch {
            recordOperationFailure(error, operation: "scan.skip")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Success here means the engine's backend confirmed the film is out
    /// (BRIDGE.md `device.eject`: `{}` is confirmed-ejected only; a stall
    /// or no-capability report arrives as a typed error and lands in the
    /// banner via `describe`). Never retried from the app — the incident
    /// contract puts retry decisions with the operator at the machine.
    public func eject() async {
        lastErrorMessage = nil
        guard hardwareMotionReadiness.allowsMotion else {
            lastErrorMessage = hardwareMotionReadiness.guidance
            return
        }
        do {
            let _: EmptyResult = try await engineClient.request("scanner.eject", params: EmptyParams())
            refeedRequired = false
            clearMediaState()
        } catch {
            recordOperationFailure(error, operation: "device.eject")
            lastErrorMessage = Self.describe(error)
        }
    }

    /// REC-03: sets current values for all three outputs at once. This does
    /// not lock or otherwise distinguish them from manual edits — every
    /// field remains a plain `@Observable var`, immediately editable
    /// afterward.
    public func applyArchivePositivePreviewPreset() {
        positiveEnabled = true
        previewEnabled = true
        let base = projectDirectory ?? "\(NSHomeDirectory())/ScanStudio Projects/_Unfiled"
        archiveDestination = "\(base)/Archive"
        positiveDestination = "\(base)/Positive"
        previewDestination = "\(base)/Preview"
    }

    /// Commits gear only at an explicit field completion/selection boundary,
    /// never on each keystroke. The current roll metadata remains independent
    /// and still persists through `setRollMetadata`.
    public func rememberCurrentGear() {
        recentGearHistory.remember(
            camera: rollMetadataDraft.camera,
            lens: rollMetadataDraft.lens
        )
        persistRecentGearHistory()
    }

    public func removeRecentCamera(_ camera: String) {
        recentGearHistory.removeCamera(camera)
        persistRecentGearHistory()
    }

    public func removeRecentLens(_ lens: String) {
        recentGearHistory.removeLens(lens)
        persistRecentGearHistory()
    }

    /// Use only for blank roll metadata. Opening a project with recorded gear
    /// must never be changed by a per-user preference.
    @discardableResult
    public func prefillBlankRollMetadataFromRecentGear() -> Bool {
        guard rollMetadataDraft.camera == nil, rollMetadataDraft.lens == nil,
              let last = recentGearHistory.lastUsed else { return false }
        rollMetadataDraft = MetadataSet(
            camera: last.camera.isEmpty ? nil : last.camera,
            lens: last.lens.isEmpty ? nil : last.lens,
            filmStock: rollMetadataDraft.filmStock,
            process: rollMetadataDraft.process,
            iso: rollMetadataDraft.iso,
            date: rollMetadataDraft.date,
            location: rollMetadataDraft.location,
            photographer: rollMetadataDraft.photographer,
            copyright: rollMetadataDraft.copyright,
            rollId: rollMetadataDraft.rollId,
            frameNumber: rollMetadataDraft.frameNumber,
            notes: rollMetadataDraft.notes,
            keywords: rollMetadataDraft.keywords
        )
        return true
    }

    public func saveCurrentFilenameTemplateAsUserDefault() {
        let template = archiveFilenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return }
        preferences.set(template, forKey: Self.filenameTemplateDefaultKey)
    }

    public func setSharedFilenameTemplate(_ template: String) {
        archiveFilenameTemplate = template
        positiveFilenameTemplate = template
        previewFilenameTemplate = template
        if saveFilenameTemplateAsDefault {
            saveCurrentFilenameTemplateAsUserDefault()
        }
    }

    /// Applies the UI's invariant before a recipe reaches the engine: every
    /// scan retains at least one user-visible output. Turning off the master
    /// also turns off its dependent capture package.
    public func setMasterTIFFEnabled(_ enabled: Bool) {
        guard OutputRetentionPolicy.allowsChange(
            .archive,
            to: enabled,
            archiveEnabled: masterTIFFEnabled,
            positiveEnabled: positiveEnabled,
            previewEnabled: previewEnabled
        ) else { return }
        masterTIFFEnabled = enabled
        if !enabled { fullCapturePackageEnabled = false }
    }

    public func setPositiveEnabled(_ enabled: Bool) {
        guard OutputRetentionPolicy.allowsChange(
            .positive,
            to: enabled,
            archiveEnabled: masterTIFFEnabled,
            positiveEnabled: positiveEnabled,
            previewEnabled: previewEnabled
        ) else { return }
        positiveEnabled = enabled
    }

    public func setPreviewEnabled(_ enabled: Bool) {
        guard OutputRetentionPolicy.allowsChange(
            .preview,
            to: enabled,
            archiveEnabled: masterTIFFEnabled,
            positiveEnabled: positiveEnabled,
            previewEnabled: previewEnabled
        ) else { return }
        previewEnabled = enabled
    }

    /// Auto-crop shapes derived outputs; it never retains or discards one,
    /// so it is exempt from `OutputRetentionPolicy` by construction.
    public func setAutoCropEnabled(_ enabled: Bool) {
        autoCropEnabled = enabled
    }

    public func beginCustomFilmStock() {
        isCustomFilmStockSelected = true
        if FilmStock.matching(metadataName: rollMetadataDraft.filmStock) != nil {
            let clearedStock: String? = nil
            rollMetadataDraft = replacingRollMetadata(filmStock: clearedStock)
        }
    }

    public func applyCustomFilmProcess(_ process: FilmProcess) {
        rollMetadataDraft = replacingRollMetadata(process: process)
        guard previewFilmProcess == nil, project == nil else { return }
        scanFilmProcess = process
        canonicalizeFilmProcessDisplayState()
    }

    /// A stock selection is an explicit operator choice. It records the
    /// stock, its box speed, and its documented process in roll metadata.
    /// A previewed/saved project keeps its established capture process; the
    /// user must deliberately re-preview to change that physical assumption.
    public func applyFilmStock(_ stock: FilmStock?) {
        guard let stock else { return }
        isCustomFilmStockSelected = false
        rollMetadataDraft = MetadataSet(
            camera: rollMetadataDraft.camera,
            lens: rollMetadataDraft.lens,
            filmStock: stock.displayName,
            process: stock.process,
            iso: stock.boxSpeedIso,
            date: rollMetadataDraft.date,
            location: rollMetadataDraft.location,
            photographer: rollMetadataDraft.photographer,
            copyright: rollMetadataDraft.copyright,
            rollId: rollMetadataDraft.rollId,
            frameNumber: rollMetadataDraft.frameNumber,
            notes: rollMetadataDraft.notes,
            keywords: rollMetadataDraft.keywords
        )
        guard previewFilmProcess == nil, project == nil else { return }
        scanFilmProcess = stock.process
        canonicalizeFilmProcessDisplayState()
    }

    private func replacingRollMetadata(
        filmStock: String?? = nil,
        process: FilmProcess?? = nil
    ) -> MetadataSet {
        MetadataSet(
            camera: rollMetadataDraft.camera, lens: rollMetadataDraft.lens,
            filmStock: filmStock ?? rollMetadataDraft.filmStock,
            process: process ?? rollMetadataDraft.process, iso: rollMetadataDraft.iso,
            date: rollMetadataDraft.date, location: rollMetadataDraft.location,
            photographer: rollMetadataDraft.photographer, copyright: rollMetadataDraft.copyright,
            rollId: rollMetadataDraft.rollId, frameNumber: rollMetadataDraft.frameNumber,
            notes: rollMetadataDraft.notes, keywords: rollMetadataDraft.keywords
        )
    }

    private func persistRecentGearHistory() {
        guard let data = try? JSONEncoder().encode(recentGearHistory) else { return }
        preferences.set(data, forKey: Self.recentGearHistoryKey)
    }

    // MARK: - Project management

    /// Creates a new project manifest in the engine's default projects
    /// location. `directory` is always omitted (nil) — the UI never
    /// overrides the default location in this phase.
    public func createProject(name: String, carrier: SimulatedFilmCarrier, frameCount: Int, filmProcess: FilmProcess) async {
        guard beginProjectLifecycleChange() else { return }
        defer { isChangingProject = false }
        lastErrorMessage = nil
        // Save Roll attaches the preview already on screen to its first
        // project. Keep that preview's scan choices across this one boundary;
        // switching from one existing project to another still clears them.
        let preProjectSelection = project == nil
            ? selectedFrameIndices
            : []
        let preProjectSelectionAnchor = project == nil
            ? selectionAnchorFrameIndex
            : nil
        let preProjectFocus = project == nil ? focusedFrameIndex : nil
        let preProjectOrientations = project == nil ? frameOrientations : [:]
        let preProjectHorizontalMirrors = project == nil ? frameMirrors : [:]
        let preProjectVerticalMirrors = project == nil ? frameVerticalMirrors : [:]
        // Batch Settings is intentionally editable before Save Roll. Capture
        // those choices before awaiting the engine: the fresh manifest owns
        // its project-rooted destinations, but its all-enabled recipe defaults
        // must never silently replace an explicit TIFF-only (or other)
        // selection the user already made in this session.
        let draftOutput = outputRecipe
        let draftOutputOrganization = (
            separateFolders: saveEachOutputInOwnFolder,
            masterFolder: masterFolderName,
            positiveFolder: positiveTiffFolderName,
            jpegFolder: positiveJPEGFolderName
        )
        do {
            let params = ProjectCreateParams(
                name: name,
                carrier: carrier,
                frameCount: frameCount,
                filmProcess: filmProcess
            )
            let result: ProjectCreateResult = try await engineClient.request("project.create", params: params)
            resetProjectScopedScanState()
            project = result.project
            restoreProjectProgress(from: result.project.frames)
            let projectFrameIndices = Set(result.project.frames.map(\.index))
            selectedFrameIndices = preProjectSelection
                .intersection(projectFrameIndices)
            selectionAnchorFrameIndex = preProjectSelectionAnchor.flatMap {
                projectFrameIndices.contains($0) ? $0 : nil
            }
            focusedFrameIndex = preProjectFocus.flatMap {
                projectFrameIndices.contains($0) ? $0 : nil
            }
            frameOrientations = preProjectOrientations.filter {
                projectFrameIndices.contains($0.key)
            }
            frameMirrors = preProjectHorizontalMirrors.filter {
                projectFrameIndices.contains($0.key)
            }
            frameVerticalMirrors = preProjectVerticalMirrors.filter {
                projectFrameIndices.contains($0.key)
            }
            scanFilmProcess = result.project.filmProcess
            canonicalizeFilmProcessDisplayState()
            rollMetadataDraft = result.project.rollMetadata
            isCustomFilmStockSelected = false
            projectDirectory = result.directory
            // Keep the engine-created, project-rooted destinations
            // authoritative, then restore the pre-Save output choices
            // captured above. Only the per-user naming default is seeded
            // separately; opening a project still uses its saved recipe
            // unchanged.
            applyRecipes(result.project.recipes)
            if draftOutput.archive.enabled
                || draftOutput.positive.enabled
                || draftOutput.preview.enabled {
                masterTIFFEnabled = draftOutput.archive.enabled
                fullCapturePackageEnabled = draftOutput.archive.enabled
                    && draftOutput.archive.fullCapturePackage
                positiveEnabled = draftOutput.positive.enabled
                positiveFileFormat = draftOutput.positive.fileFormat
                positiveColorProfile = draftOutput.positive.colorProfile
                previewEnabled = draftOutput.preview.enabled
                previewFileFormat = draftOutput.preview.fileFormat
                previewMaxLongEdgePx = draftOutput.preview.maxLongEdgePx
                autoCropEnabled = draftOutput.autoCrop
                saveEachOutputInOwnFolder = draftOutputOrganization.separateFolders
                masterFolderName = draftOutputOrganization.masterFolder
                positiveTiffFolderName = draftOutputOrganization.positiveFolder
                positiveJPEGFolderName = draftOutputOrganization.jpegFolder
            }
            let template = preferences.string(forKey: Self.filenameTemplateDefaultKey)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? FilenameTemplate.defaultTemplate
            archiveFilenameTemplate = template
            positiveFilenameTemplate = template
            previewFilenameTemplate = template
            if prefillBlankRollMetadataFromRecentGear() {
                await setRollMetadata(rollMetadataDraft)
            }
            // A fresh project must never carry a leftover unsupported
            // multisample value (e.g. this class's own `= 2` startup
            // default, or whatever an earlier project/device session left
            // behind) when a device is already connected — see
            // `coerceMultisamplePassesForConnectedDevice`'s own doc
            // comment. `ScanProject` has no capture-recipe field of its
            // own (only `OutputRecipe` is project-level; capture/
            // processing recipes live purely in this session's own
            // `scan*` properties), so this is the only seeding this value
            // ever gets from project creation.
            if device != nil {
                coerceMultisamplePassesForConnectedDevice()
            }
            await persistFrameAlignmentDrafts()
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// The pre-project contact sheet's primary action: attach the completed
    /// preview to a new roll project, then continue the exact frame selection
    /// into the ordinary review/scan gate. A flagged boundary intentionally
    /// returns with `pendingManualReviewScan` rather than moving film; the
    /// user's confirmation resumes this same frame list exactly once.
    @discardableResult
    public func saveRollAndScanSelectedFrames(
        name: String,
        carrier: SimulatedFilmCarrier,
        frameCount: Int,
        filmProcess: FilmProcess
    ) async -> Bool {
        lastErrorMessage = nil
        guard project == nil else {
            lastErrorMessage =
                "This roll is already saved. Use Scan to start the selected frames."
            return false
        }

        let requestedFrames = selectedFrames
        guard !requestedFrames.isEmpty else {
            lastErrorMessage = "Select at least one frame before saving and scanning."
            return false
        }

        await createProject(
            name: name,
            carrier: carrier,
            frameCount: frameCount,
            filmProcess: filmProcess
        )
        guard project != nil, lastErrorMessage == nil else { return false }

        let started = await startScanOrRequestManualReview(
            frames: requestedFrames
        )
        return started || pendingManualReviewScan?.frames == requestedFrames
    }

    /// Moves contact-sheet crop and presentation geometry chosen before Save
    /// Roll into the newly created project. Crop drafts remain unapproved;
    /// explicit rotation/flips become derivative-authoritative at this
    /// Save Roll boundary.
    private func persistFrameAlignmentDrafts() async {
        guard let project else { return }
        let targets = project.frames.compactMap { frame in
            frame.alignment == desiredFrameGeometry(
                for: frame.index,
                persistedFrame: frame
            ) ? nil : frame.index
        }.sorted()
        for (position, frameIndex) in targets.enumerated() {
            guard let currentProject = self.project,
                  let persistedFrame = currentProject.frames.first(
                    where: { $0.index == frameIndex }
                  )
            else { continue }
            let desired = desiredFrameGeometry(
                for: frameIndex,
                persistedFrame: persistedFrame
            )
            guard persistedFrame.alignment != desired else { continue }
            let params = SetFrameAlignmentParams(
                frameIndex: frameIndex,
                alignment: desired
            )
            do {
                let result: SetFrameResult = try await engineClient.request(
                    "project.setFrameAlignment",
                    params: params
                )
                guard self.project?.id == project.id,
                      result.project.id == project.id
                else {
                    throw EngineRequestError(
                        code: "ALIGNMENT_PROJECT_CHANGED",
                        message:
                            "the draft alignment response belongs to a different project",
                        recoverable: true
                    )
                }
                self.project = result.project
                failedFrameAlignmentRestoreIndices.remove(frameIndex)
            } catch {
                let unresolved = Set(
                    targets[position...]
                )
                failedFrameAlignmentRestoreIndices.formUnion(unresolved)
                recordOperationFailure(
                    error,
                    operation: "frame.alignment.migrate"
                )
                lastErrorMessage =
                    "The project was created, but the crop/rotation settings for frame "
                    + "\(frameIndex) could not be saved: \(Self.describe(error)). "
                    + frameAlignmentRestoreRecoveryGuidance()
                return
            }
        }
    }

    /// Opens an existing project manifest from `directory`.
    public func openProject(directory: String) async {
        guard beginProjectLifecycleChange() else { return }
        defer { isChangingProject = false }
        lastErrorMessage = nil
        do {
            let params = ProjectOpenParams(directory: directory)
            let result: ProjectOpenResult = try await engineClient.request("project.open", params: params)
            // A preview completed before this manifest was opened was not
            // registered against the opened project's process or saved
            // offsets. Require an explicit saved-project refresh so neither
            // matching frame counts nor pre-project drafts can authorize a
            // scan with inert alignment state.
            invalidatePreviewRegistrationForProjectOpen()
            resetProjectScopedScanState()
            project = result.project
            restoreProjectProgress(from: result.project.frames)
            scanFilmProcess = result.project.filmProcess
            canonicalizeFilmProcessDisplayState()
            rollMetadataDraft = result.project.rollMetadata
            isCustomFilmStockSelected = false
            projectDirectory = result.directory
            applyRecipes(result.project.recipes)
            restoreDerivativeTransforms(from: result.project.frames)
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    private func invalidatePreviewRegistrationForProjectOpen() {
        previewIntentStateMachine.resetForExplicitMediaChange()
        previewFilmProcess = nil
        pendingPreviewFilmProcess = nil
        thumbnails = [:]
        latestCompletedPreviewOperationId = nil
        clearPendingManualReviewScan()
        manualReviewDecisions.removeAll()
        clearFrameAlignmentSessionState()
        selectedFrameIndices.removeAll()
        selectionAnchorFrameIndex = nil
        focusedFrameIndex = nil
        detailFrameIndex = nil
        frameOrientations.removeAll()
        frameMirrors.removeAll()
        frameVerticalMirrors.removeAll()
        isAcquiringThumbnails = false
        activeOperationStartedAt = nil
    }

    private func beginProjectLifecycleChange() -> Bool {
        guard !isChangingProject else {
            lastErrorMessage =
                "Another project action is still in progress. Wait for it to finish and try again."
            return false
        }
        guard pendingScanStart == nil, jobId == nil, !isJobActive else {
            lastErrorMessage =
                "A scan is still in progress. Wait for it to finish or stop it before changing projects."
            return false
        }
        guard pendingFrameAlignmentAdjustment == nil,
              pendingFrameAlignmentRestore == nil,
              !isRestoringFrameAlignments
        else {
            lastErrorMessage =
                "A frame alignment is still in progress. Wait for it to finish before changing projects."
            return false
        }
        isChangingProject = true
        return true
    }

    /// Refreshes the recent-projects listing from the engine's default
    /// projects root. An empty list on success is still a valid,
    /// displayable state.
    public func refreshRecentProjects() async {
        lastErrorMessage = nil
        do {
            let params = ProjectListParams(directory: nil)
            let result: ProjectListResult = try await engineClient.request("project.list", params: params)
            recentProjects = result.projects
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Marks (or unmarks) one frame excluded from future scan jobs.
    /// Every dependent computed property (`excludedFrameIndices`,
    /// `isFrameExcluded`) re-derives from the fresh `project` this sets.
    public func setFrameExcluded(_ frameIndex: Int, excluded: Bool) async {
        lastErrorMessage = nil
        do {
            let params = SetFrameExcludedParams(frameIndex: frameIndex, excluded: excluded)
            let result: SetFrameResult = try await engineClient.request("project.setFrameExcluded", params: params)
            project = result.project
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Sets (`capture` populated) or clears (`capture: nil`, reverting to
    /// the roll-wide default) one frame's independent capture override.
    public func setFrameCaptureOverride(_ frameIndex: Int, to capture: CaptureRecipe?) async {
        lastErrorMessage = nil
        do {
            let params = SetFrameCaptureOverrideParams(frameIndex: frameIndex, capture: capture)
            let result: SetFrameResult = try await engineClient.request("project.setFrameCaptureOverride", params: params)
            project = result.project
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Sets or clears one frame's independent processing override (film
    /// process, autofocus/auto-exposure, Digital ICE).
    public func setFrameProcessingOverride(_ frameIndex: Int, to processing: ProcessingRecipe?) async {
        lastErrorMessage = nil
        do {
            let params = SetFrameProcessingOverrideParams(frameIndex: frameIndex, processing: processing)
            let result: SetFrameResult = try await engineClient.request("project.setFrameProcessingOverride", params: params)
            project = result.project
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Sets or clears one frame's independent output override (archive/
    /// positive/preview).
    public func setFrameOutputOverride(_ frameIndex: Int, to output: OutputRecipe?) async {
        lastErrorMessage = nil
        do {
            let params = SetFrameOutputOverrideParams(frameIndex: frameIndex, output: output)
            let result: SetFrameResult = try await engineClient.request("project.setFrameOutputOverride", params: params)
            project = result.project
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Sets the roll-wide default metadata every frame without its own
    /// override inherits.
    public func setRollMetadata(_ metadata: MetadataSet) async {
        lastErrorMessage = nil
        do {
            let params = SetRollMetadataParams(metadata: metadata)
            let result: SetFrameResult = try await engineClient.request("project.setRollMetadata", params: params)
            project = result.project
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Sets (`metadata` populated) or clears (`metadata: nil`, reverting to
    /// roll-wide inheritance) one frame's independent metadata override.
    public func setFrameMetadataOverride(_ frameIndex: Int, to metadata: MetadataSet?) async {
        lastErrorMessage = nil
        do {
            let params = SetFrameMetadataOverrideParams(frameIndex: frameIndex, metadata: metadata)
            let result: SetFrameResult = try await engineClient.request("project.setFrameMetadataOverride", params: params)
            project = result.project
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Fetches (or re-fetches, for the "Re-analyze" action) this frame's
    /// synthetic defect set from the engine, resolved against this frame's own
    /// capture/processing override if one exists (engine-side, per
    /// PROTOCOL.md). Always performs a real round trip and overwrites the
    /// cache entry -- deterministic generation means an unchanged-recipe
    /// re-fetch legitimately returns byte-identical data (SIM-03), the same
    /// idempotent-but-real precedent `acquireThumbnails`'s "Refresh previews"
    /// already established.
    public func analyzeFrameDefects(_ frameIndex: Int) async {
        lastErrorMessage = nil
        do {
            let params = AnalyzeFrameDefectsParams(frameIndex: frameIndex, capture: captureRecipe, processing: processingRecipe)
            let result: AnalyzeFrameDefectsResult = try await engineClient.request("project.analyzeFrameDefects", params: params)
            frameDefects[frameIndex] = result
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Probes the engine's host for a usable ExifTool binary.
    public func detectExifTool() async {
        lastErrorMessage = nil
        do {
            let result: ExifToolDetection = try await engineClient.request("exiftool.detect", params: EmptyParams())
            exifToolDetection = result
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Fetches a dry-run preview of the ExifTool invocation
    /// `applyMetadata(_:)` would actually run for this frame.
    public func previewMetadataCommand(_ frameIndex: Int) async {
        lastErrorMessage = nil
        do {
            let params = PreviewMetadataCommandParams(frameIndex: frameIndex)
            let result: PreviewMetadataCommandResult = try await engineClient.request("project.previewMetadataCommand", params: params)
            metadataPreview = result
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Runs ExifTool against this frame's scanned outputs for real. Returns
    /// the one-shot result directly rather than storing it on
    /// `SessionModel` — the caller displays a success/failure banner rather
    /// than persistent state — and returns `nil` on failure (with
    /// `lastErrorMessage` set, same as every other action here).
    public func applyMetadata(_ frameIndex: Int) async -> ApplyMetadataResult? {
        lastErrorMessage = nil
        do {
            let params = ApplyMetadataParams(frameIndex: frameIndex)
            let result: ApplyMetadataResult = try await engineClient.request("project.applyMetadata", params: params)
            return result
        } catch {
            lastErrorMessage = Self.describe(error)
            return nil
        }
    }

    /// Refreshes `pendingFrames` from the engine's own authoritative
    /// `project.pendingFrames` answer.
    public func refreshPendingFrames() async {
        // The endpoint is project-scoped. A carrier status update must never
        // turn into a user-visible PROJECT_NOT_FOUND while the Save Roll gate
        // is intentionally on screen.
        guard project != nil else {
            pendingFrames = []
            completedFrameCount = 0
            return
        }
        lastErrorMessage = nil
        do {
            let result: PendingFramesResult = try await engineClient.request("project.pendingFrames", params: EmptyParams())
            pendingFrames = result.frames
            completedFrameCount = result.completedCount
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Resumes a partially-completed project using exactly the engine's own
    /// pending-frame list — never a stale cached copy, and never
    /// `selectedFrameIndices` (a client-side, ephemeral selection).
    /// `refreshPendingFrames()` is always re-queried immediately before
    /// acting on it, since the whole point is authoritative-from-the-engine
    /// state; `selectedFrameIndices` is only set FROM the resumed list
    /// afterward, purely so the rest of the selection-driven UI stays
    /// visually consistent with what's actually running.
    public func resumeBatch() async {
        guard project != nil else {
            lastErrorMessage = ScanReadinessPolicy.Decision.projectRequired.reason
            return
        }
        await refreshPendingFrames()
        guard !pendingFrames.isEmpty else {
            lastErrorMessage = "Nothing to resume — every frame is already complete or excluded."
            return
        }
        selectedFrameIndices = Set(pendingFrames)
        _ = await startScanOrRequestManualReview(frames: pendingFrames)
    }

    /// Seeds the three output-recipe state groups from a just-created or
    /// just-opened project's persisted recipes, so the Batch Settings
    /// inspector reflects that project's own archive/positive/preview
    /// choices rather than whatever was left over from a previous project
    /// (or this class's fresh-launch defaults).
    private func applyRecipes(_ recipes: OutputRecipe) {
        // This organization UI is intentionally per-session rather than a
        // hidden fourth project recipe. Clear it before loading every
        // project so project A's chosen base can never redirect project B.
        saveLocation = ""
        saveEachOutputInOwnFolder = true
        masterFolderName = "Master TIFF"
        positiveTiffFolderName = "Positive TIFF"
        positiveJPEGFolderName = "Positive JPEG"
        archiveFilenameTemplate = recipes.archive.filenameTemplate
        archiveDestination = recipes.archive.destination
        masterTIFFEnabled = recipes.archive.enabled
        fullCapturePackageEnabled = recipes.archive.enabled && recipes.archive.fullCapturePackage
        positiveEnabled = recipes.positive.enabled
        positiveFileFormat = recipes.positive.fileFormat
        positiveColorProfile = recipes.positive.colorProfile
        positiveFilenameTemplate = recipes.positive.filenameTemplate
        positiveDestination = recipes.positive.destination
        previewEnabled = recipes.preview.enabled
        previewFileFormat = recipes.preview.fileFormat
        previewMaxLongEdgePx = recipes.preview.maxLongEdgePx
        previewFilenameTemplate = recipes.preview.filenameTemplate
        previewDestination = recipes.preview.destination
        autoCropEnabled = recipes.autoCrop
    }

    private func canonicalizeFilmProcessDisplayState() {
        guard scanFilmProcess == .bwNegative else { return }
        scanChannels = "rgb"
        digitalIceEnabled = false
    }

    /// Clears state whose meaning belongs to the previously active project.
    ///
    /// Preview imagery and unsaved frame-alignment drafts deliberately remain:
    /// `createProject` is the Save Roll transition that attaches those drafts
    /// to a manifest. Job receipts, summaries, selection, analysis, and
    /// metadata preview must never cross that boundary.
    private func resetProjectScopedScanState() {
        jobId = nil
        jobState = nil
        progress = nil
        frameStates = [:]
        receipts = []
        frameErrors.removeAll()
        frameAttempts.removeAll()
        frameTransportSmearReasons.removeAll()
        scanSummary = nil
        pendingFrames = []
        completedFrameCount = 0
        durableCompletedFrameIndices.removeAll()
        metadataPreview = nil
        frameDefects.removeAll()
        selectedFrameIndices.removeAll()
        selectionAnchorFrameIndex = nil
        focusedFrameIndex = nil
        detailFrameIndex = nil
        frameOrientations.removeAll()
        frameMirrors.removeAll()
        frameVerticalMirrors.removeAll()
        bufferedJobEvents.removeAll()
    }

    /// Restores durable completion and resume state from a project's receipts.
    /// `additionallyCompleted` carries receipts observed live by this session
    /// before the immutable `ScanProject` value has been refreshed.
    private func restoreProjectProgress(
        from frames: [ProjectFrame],
        additionallyCompleted: Set<Int> = []
    ) {
        let validIndices = Set(frames.map(\.index))
        let persistedCompleted = Set(
            frames.filter { !$0.receipts.isEmpty }.map(\.index)
        )
        let completed = persistedCompleted
            .union(durableCompletedFrameIndices.intersection(validIndices))
            .union(additionallyCompleted.intersection(validIndices))
        durableCompletedFrameIndices = completed
        frameStates = Dictionary(
            uniqueKeysWithValues: completed.map { ($0, FrameState.completed) }
        )
        pendingFrames = frames
            .filter { !$0.excluded && !completed.contains($0.index) }
            .map(\.index)
        completedFrameCount = completed.count
    }

    // MARK: - Frame alignment

    private func beginPersistedFrameAlignmentRestore(
        previewOperationId: String,
        previewFrameCount: Int
    ) {
        guard let project else {
            finishCompletedPreview(frameCount: previewFrameCount)
            return
        }
        restoreDerivativeTransforms(from: project.frames)
        let targets = project.frames.compactMap { frame -> PersistedFrameAlignmentTarget? in
            guard let alignment = frame.alignment,
                  alignment.offsetRows != 0
            else {
                return nil
            }
            return PersistedFrameAlignmentTarget(
                frameIndex: frame.index,
                offsetRows: alignment.offsetRows
            )
        }.sorted { $0.frameIndex < $1.frameIndex }
        guard !targets.isEmpty else {
            finishCompletedPreview(frameCount: previewFrameCount)
            return
        }

        let marker = PendingFrameAlignmentRestore(
            id: UUID(),
            previewOperationId: previewOperationId,
            projectId: project.id,
            connectionEpoch: connectionEpoch
        )
        pendingFrameAlignmentRestore = marker
        isRestoringFrameAlignments = true
        // Keep preview acquisition logically active until every saved offset
        // has a bridge-confirmed replacement tile. Scan readiness and another
        // preview request therefore remain closed during the restore.
        isAcquiringThumbnails = true

        Task { [weak self] in
            await self?.restorePersistedFrameAlignments(
                targets,
                marker: marker,
                previewFrameCount: previewFrameCount
            )
        }
    }

    private func restorePersistedFrameAlignments(
        _ targets: [PersistedFrameAlignmentTarget],
        marker: PendingFrameAlignmentRestore,
        previewFrameCount: Int
    ) async {
        for (position, target) in targets.enumerated() {
            guard frameAlignmentRestoreIsCurrent(marker) else {
                abandonFrameAlignmentRestoreIfOwned(marker)
                return
            }
            let unresolvedFrameIndices = Set(
                targets[position...].map(\.frameIndex)
            )
            guard frameAlignmentOffsetBounds(for: target.frameIndex)
                .contains(target.offsetRows)
            else {
                failFrameAlignmentRestore(
                    marker,
                    unresolvedFrameIndices: unresolvedFrameIndices,
                    message:
                        "The saved alignment for frame \(target.frameIndex) "
                        + "is outside this scanner's supported range."
                )
                return
            }
            do {
                let params = RollSetSpacingOffsetParams(
                    frameIndex: target.frameIndex,
                    offsetRows: target.offsetRows,
                    operationId: marker.previewOperationId
                )
                let result: RollSetSpacingOffsetResult = try await engineClient.request(
                    "roll.setSpacingOffset",
                    params: params
                )
                guard frameAlignmentRestoreIsCurrent(marker) else {
                    abandonFrameAlignmentRestoreIfOwned(marker)
                    return
                }
                guard result.thumbnail.spacingOffset == target.offsetRows else {
                    failFrameAlignmentRestore(
                        marker,
                        unresolvedFrameIndices: unresolvedFrameIndices,
                        message:
                            "The saved alignment for frame \(target.frameIndex) "
                            + "was not confirmed by the current preview. Preview the film again."
                    )
                    return
                }
                thumbnails[target.frameIndex] = result.thumbnail
                frameAlignmentDrafts[target.frameIndex] = FrameAlignment(
                    offsetRows: target.offsetRows,
                    approved: false,
                    derivativeTransform: derivativeTransform(
                        for: target.frameIndex
                    )
                )
                failedFrameAlignmentRestoreIndices.remove(target.frameIndex)
                manualReviewDecisions.removeValue(forKey: target.frameIndex)
            } catch {
                guard frameAlignmentRestoreIsCurrent(marker) else {
                    abandonFrameAlignmentRestoreIfOwned(marker)
                    return
                }
                recordOperationFailure(error, operation: "frame.alignment.restore")
                failFrameAlignmentRestore(
                    marker,
                    unresolvedFrameIndices: unresolvedFrameIndices,
                    message:
                        "Could not restore the saved alignment for frame "
                        + "\(target.frameIndex): \(Self.describe(error))"
                )
                return
            }
        }

        guard frameAlignmentRestoreIsCurrent(marker) else {
            abandonFrameAlignmentRestoreIfOwned(marker)
            return
        }
        pendingFrameAlignmentRestore = nil
        isRestoringFrameAlignments = false
        finishCompletedPreview(frameCount: previewFrameCount)
    }

    private func frameAlignmentRestoreIsCurrent(
        _ marker: PendingFrameAlignmentRestore
    ) -> Bool {
        pendingFrameAlignmentRestore?.id == marker.id
            && connectionEpoch == marker.connectionEpoch
            && latestCompletedPreviewOperationId == marker.previewOperationId
            && project?.id == marker.projectId
    }

    /// A reset path normally clears the marker before a late response
    /// returns. If another piece of state invalidates the marker first,
    /// release only the busy state still owned by this restore so the
    /// contact sheet cannot remain stuck in an acquiring state.
    private func abandonFrameAlignmentRestoreIfOwned(
        _ marker: PendingFrameAlignmentRestore
    ) {
        guard pendingFrameAlignmentRestore?.id == marker.id else { return }
        pendingFrameAlignmentRestore = nil
        isRestoringFrameAlignments = false
        isAcquiringThumbnails = false
        activeOperationStartedAt = nil
    }

    private func failFrameAlignmentRestore(
        _ marker: PendingFrameAlignmentRestore,
        unresolvedFrameIndices: Set<Int>,
        message: String
    ) {
        guard frameAlignmentRestoreIsCurrent(marker) else {
            abandonFrameAlignmentRestoreIfOwned(marker)
            return
        }
        pendingFrameAlignmentRestore = nil
        isRestoringFrameAlignments = false
        isAcquiringThumbnails = false
        activeOperationStartedAt = nil
        failedFrameAlignmentRestoreIndices.formUnion(unresolvedFrameIndices)
        lastErrorMessage =
            message + " " + frameAlignmentRestoreRecoveryGuidance()
    }

    private func frameAlignmentRestoreRecoveryGuidance() -> String {
        let frames = failedFrameAlignmentRestoreIndices.sorted()
        let label = frames.count == 1 ? "frame" : "frames"
        let values = frames.map(String.init).joined(separator: ", ")
        return "Saved alignment still needs attention for \(label) \(values). "
            + "Adjust those frames or preview the film again before scanning."
    }

    private func finishCompletedPreview(frameCount: Int) {
        isAcquiringThumbnails = false
        activeOperationStartedAt = nil
        recordDiagnostic(
            event: "preview.completed",
            fields: ["frameCount": String(frameCount)]
        )
    }

    /// Current native-row offset for the contact-sheet control. Only evidence
    /// applied to this live preview session is authoritative: a persisted
    /// project value must never masquerade as active before the bridge returns
    /// its adjusted replacement thumbnail.
    public func alignmentOffset(for frameIndex: Int) -> Int {
        frameAlignmentDrafts[frameIndex]?.offsetRows
            ?? thumbnails[frameIndex]?.spacingOffset
            ?? 0
    }

    public func isAdjustingFrameAlignment(_ frameIndex: Int) -> Bool {
        adjustingFrameAlignmentIndices.contains(frameIndex)
    }

    /// Positive deltas are native +rows (the preview image moves left);
    /// negative deltas are native -rows (the preview image moves right).
    public func canNudgeFrameAlignment(_ frameIndex: Int, by delta: Int) -> Bool {
        guard delta != 0,
              !isChangingProject,
              !isRestoringFrameAlignments,
              pendingScanStart == nil,
              !isJobActive,
              pendingFrameAlignmentAdjustment == nil,
              latestCompletedPreviewOperationId != nil,
              thumbnails[frameIndex] != nil,
              validFrameIndices.contains(frameIndex)
        else {
            return false
        }
        let (target, overflow) = alignmentOffset(for: frameIndex)
            .addingReportingOverflow(delta)
        guard !overflow else { return false }
        return frameAlignmentOffsetBounds(for: frameIndex).contains(target)
    }

    private func frameAlignmentOffsetBounds(
        for frameIndex: Int
    ) -> ClosedRange<Int> {
        frameIndex == 1 ? 0...144 : -144...144
    }

    /// Requests and installs one bridge-regenerated adjusted tile. The
    /// operator's old Review decision is invalid once the boundary changes.
    public func nudgeFrameAlignment(frameIndex: Int, by delta: Int) async {
        guard canNudgeFrameAlignment(frameIndex, by: delta),
              let previewOperationId = latestCompletedPreviewOperationId
        else {
            return
        }
        let targetOffset = alignmentOffset(for: frameIndex) + delta
        let marker = PendingFrameAlignmentAdjustment(
            id: UUID(),
            frameIndex: frameIndex,
            previewOperationId: previewOperationId,
            projectId: project?.id,
            connectionEpoch: connectionEpoch
        )
        pendingFrameAlignmentAdjustment = marker
        adjustingFrameAlignmentIndices.insert(frameIndex)
        lastErrorMessage = nil
        defer {
            if pendingFrameAlignmentAdjustment?.id == marker.id {
                pendingFrameAlignmentAdjustment = nil
                adjustingFrameAlignmentIndices.remove(frameIndex)
            }
        }

        var installedLiveAlignment = false
        do {
            let params = RollSetSpacingOffsetParams(
                frameIndex: frameIndex,
                offsetRows: targetOffset,
                operationId: previewOperationId
            )
            let result: RollSetSpacingOffsetResult = try await engineClient.request(
                "roll.setSpacingOffset",
                params: params
            )
            guard frameAlignmentAdjustmentIsCurrent(marker) else { return }

            thumbnails[frameIndex] = result.thumbnail
            let appliedOffset = result.thumbnail.spacingOffset ?? targetOffset
            frameAlignmentDrafts[frameIndex] = FrameAlignment(
                offsetRows: appliedOffset,
                approved: false,
                derivativeTransform: derivativeTransform(for: frameIndex)
            )
            installedLiveAlignment = true
            manualReviewDecisions.removeValue(forKey: frameIndex)
            clearPendingManualReviewScan()
            if project != nil {
                let persistenceParams = SetFrameAlignmentParams(
                    frameIndex: frameIndex,
                    alignment: FrameAlignment(
                        offsetRows: appliedOffset,
                        approved: false,
                        derivativeTransform: derivativeTransform(
                            for: frameIndex
                        )
                    )
                )
                let persistenceResult: SetFrameResult = try await engineClient.request(
                    "project.setFrameAlignment",
                    params: persistenceParams
                )
                guard frameAlignmentAdjustmentIsCurrent(marker) else { return }
                guard persistenceResult.project.id == marker.projectId else {
                    throw EngineRequestError(
                        code: "ALIGNMENT_PROJECT_CHANGED",
                        message:
                            "the alignment response belongs to a different project",
                        recoverable: true
                    )
                }
                project = persistenceResult.project
            }
            failedFrameAlignmentRestoreIndices.remove(frameIndex)
            if !failedFrameAlignmentRestoreIndices.isEmpty {
                lastErrorMessage = frameAlignmentRestoreRecoveryGuidance()
            }
        } catch {
            guard frameAlignmentAdjustmentIsCurrent(marker) else { return }
            recordOperationFailure(error, operation: "frame.alignment")
            if installedLiveAlignment, marker.projectId != nil {
                failedFrameAlignmentRestoreIndices.insert(frameIndex)
                lastErrorMessage =
                    "The adjusted preview for frame \(frameIndex) is live, "
                    + "but its alignment could not be saved: \(Self.describe(error)). "
                    + frameAlignmentRestoreRecoveryGuidance()
            } else {
                lastErrorMessage = Self.describe(error)
            }
        }
    }

    /// Retries a failed restore or manifest write without requiring the
    /// operator to alter the chosen offset. If the current tile already
    /// carries that offset, only project persistence is retried; otherwise
    /// the saved target is rebound to this exact preview first.
    public func retryFrameAlignment(frameIndex: Int) async {
        guard failedFrameAlignmentRestoreIndices.contains(frameIndex),
              !isChangingProject,
              !isRestoringFrameAlignments,
              pendingScanStart == nil,
              !isJobActive,
              pendingFrameAlignmentAdjustment == nil
        else {
            return
        }
        guard let previewOperationId = latestCompletedPreviewOperationId,
              let project,
              thumbnails[frameIndex] != nil,
              validFrameIndices.contains(frameIndex)
        else {
            lastErrorMessage =
                "Preview this project again before retrying the alignment for frame \(frameIndex)."
            return
        }
        let savedAlignment = frameAlignmentDrafts[frameIndex]
            ?? project.frames.first(where: { $0.index == frameIndex })?.alignment
        guard let savedAlignment,
              frameAlignmentOffsetBounds(for: frameIndex)
                .contains(savedAlignment.offsetRows)
        else {
            lastErrorMessage =
                "The saved alignment for frame \(frameIndex) cannot be retried because it is missing or outside this scanner's supported range."
            return
        }

        let targetAlignment = FrameAlignment(
            offsetRows: savedAlignment.offsetRows,
            approved: false,
            derivativeTransform: derivativeTransform(for: frameIndex)
        )
        let marker = PendingFrameAlignmentAdjustment(
            id: UUID(),
            frameIndex: frameIndex,
            previewOperationId: previewOperationId,
            projectId: project.id,
            connectionEpoch: connectionEpoch
        )
        pendingFrameAlignmentAdjustment = marker
        adjustingFrameAlignmentIndices.insert(frameIndex)
        lastErrorMessage = nil
        defer {
            if pendingFrameAlignmentAdjustment?.id == marker.id {
                pendingFrameAlignmentAdjustment = nil
                adjustingFrameAlignmentIndices.remove(frameIndex)
            }
        }

        do {
            if thumbnails[frameIndex]?.spacingOffset != targetAlignment.offsetRows {
                let params = RollSetSpacingOffsetParams(
                    frameIndex: frameIndex,
                    offsetRows: targetAlignment.offsetRows,
                    operationId: previewOperationId
                )
                let result: RollSetSpacingOffsetResult = try await engineClient.request(
                    "roll.setSpacingOffset",
                    params: params
                )
                guard frameAlignmentAdjustmentIsCurrent(marker) else { return }
                guard result.thumbnail.spacingOffset == targetAlignment.offsetRows else {
                    throw EngineRequestError(
                        code: "ALIGNMENT_RETRY_NOT_CONFIRMED",
                        message:
                            "the adjusted tile did not confirm the saved row offset",
                        recoverable: true
                    )
                }
                thumbnails[frameIndex] = result.thumbnail
                manualReviewDecisions.removeValue(forKey: frameIndex)
                clearPendingManualReviewScan()
            }
            frameAlignmentDrafts[frameIndex] = targetAlignment

            let persistenceParams = SetFrameAlignmentParams(
                frameIndex: frameIndex,
                alignment: targetAlignment
            )
            let persistenceResult: SetFrameResult = try await engineClient.request(
                "project.setFrameAlignment",
                params: persistenceParams
            )
            guard frameAlignmentAdjustmentIsCurrent(marker) else { return }
            guard persistenceResult.project.id == marker.projectId else {
                throw EngineRequestError(
                    code: "ALIGNMENT_PROJECT_CHANGED",
                    message: "the alignment response belongs to a different project",
                    recoverable: true
                )
            }
            self.project = persistenceResult.project
            failedFrameAlignmentRestoreIndices.remove(frameIndex)
            lastErrorMessage = failedFrameAlignmentRestoreIndices.isEmpty
                ? nil
                : frameAlignmentRestoreRecoveryGuidance()
        } catch {
            guard frameAlignmentAdjustmentIsCurrent(marker) else { return }
            failedFrameAlignmentRestoreIndices.insert(frameIndex)
            recordOperationFailure(error, operation: "frame.alignment.retry")
            lastErrorMessage =
                "Could not retry the alignment for frame \(frameIndex): "
                + "\(Self.describe(error)). "
                + frameAlignmentRestoreRecoveryGuidance()
        }
    }

    private func frameAlignmentAdjustmentIsCurrent(
        _ marker: PendingFrameAlignmentAdjustment
    ) -> Bool {
        pendingFrameAlignmentAdjustment?.id == marker.id
            && connectionEpoch == marker.connectionEpoch
            && latestCompletedPreviewOperationId == marker.previewOperationId
            && project?.id == marker.projectId
            && thumbnails[marker.frameIndex] != nil
    }

    private func clearFrameAlignmentSessionState() {
        let wasRestoring =
            pendingFrameAlignmentRestore != nil || isRestoringFrameAlignments
        pendingFrameAlignmentAdjustment = nil
        pendingFrameAlignmentRestore = nil
        frameAlignmentDrafts.removeAll()
        adjustingFrameAlignmentIndices.removeAll()
        isRestoringFrameAlignments = false
        failedFrameAlignmentRestoreIndices.removeAll()
        if wasRestoring {
            isAcquiringThumbnails = false
            activeOperationStartedAt = nil
        }
    }

    // MARK: - Frame selection

    /// Records the user's resolution of one ambiguous preview boundary.
    /// "Use anyway" includes the frame; "Don't scan" removes it from the
    /// current batch. This is local decision state only: the bridge's
    /// preview-bound `roll.approve` still runs immediately before the one
    /// authorized `scan.start`.
    @discardableResult
    public func decideManualReview(
        _ decision: ManualReviewDecision,
        for frameIndex: Int,
        previewOperationId: String
    ) -> Bool {
        guard latestCompletedPreviewOperationId == previewOperationId,
              thumbnails[frameIndex]?.needsApproval == true,
              validFrameIndices.contains(frameIndex)
        else {
            return false
        }
        manualReviewDecisions[frameIndex] = decision
        switch decision {
        case .useFrameAnyway:
            selectedFrameIndices.insert(frameIndex)
        case .dontScan:
            selectedFrameIndices.remove(frameIndex)
        }
        clearPendingManualReviewScan()
        return true
    }

    public func manualReviewDecision(
        for frameIndex: Int
    ) -> ManualReviewDecision? {
        manualReviewDecisions[frameIndex]
    }

    public func toggleFrameSelection(_ frameIndex: Int) {
        guard validFrameIndices.contains(frameIndex) else { return }
        if selectedFrameIndices.contains(frameIndex) {
            selectedFrameIndices.remove(frameIndex)
        } else {
            if manualReviewDecisions[frameIndex] == .dontScan {
                manualReviewDecisions.removeValue(forKey: frameIndex)
            }
            selectedFrameIndices.insert(frameIndex)
        }
    }

    /// The single entry point `ThumbnailGridView`'s tile taps call for both
    /// plain and Shift-modified clicks (SwiftUI has no built-in
    /// modifier-aware tap gesture, so the tile itself reads
    /// `NSEvent.modifierFlags` at tap time and reports the result here). A
    /// plain click keeps the pre-existing toggle-single-frame behavior and
    /// moves the range anchor to `frameIndex`. A Shift-click never toggles:
    /// it *adds* the inclusive range between the current anchor and
    /// `frameIndex` to the selection — standard Finder-style range-select —
    /// and leaves the anchor exactly where it was, so a second Shift-click
    /// elsewhere still extends from the original anchor rather than the
    /// frame the previous Shift-click landed on. The very first click of a
    /// session (anchor still `nil`) always sets the anchor, even if it
    /// happens to arrive with Shift held, since there is no prior anchor to
    /// preserve in that case.
    public func selectFrame(_ frameIndex: Int, extendingSelectionIfShiftHeld shiftHeld: Bool) {
        guard validFrameIndices.contains(frameIndex) else { return }
        if shiftHeld, let anchor = selectionAnchorFrameIndex {
            let reviewSkippedFrames = Set(
                manualReviewDecisions.compactMap { frameIndex, decision in
                    decision == .dontScan ? frameIndex : nil
                }
            )
            selectedFrameIndices.formUnion(
                Set(
                    FrameRangeSelection.inclusiveRange(
                        anchor: anchor,
                        clicked: frameIndex
                    )
                ).subtracting(reviewSkippedFrames)
            )
        } else {
            toggleFrameSelection(frameIndex)
            selectionAnchorFrameIndex = frameIndex
        }
    }

    /// Excluded frames are never included in "Select All" — a user must
    /// deliberately `toggleFrameSelection` an excluded frame to select it
    /// (e.g. in order to Include it again via the toolbar).
    public func selectAllFrames() {
        let reviewSkippedFrames = Set(
            manualReviewDecisions.compactMap { frameIndex, decision in
                decision == .dontScan ? frameIndex : nil
            }
        )
        selectedFrameIndices = Set(validFrameIndices)
            .subtracting(excludedFrameIndices)
            .subtracting(reviewSkippedFrames)
        if focusedFrameIndex == nil
            || !validFrameIndices.contains(focusedFrameIndex ?? -1)
        {
            focusedFrameIndex = selectedFrameIndices.min()
        }
    }

    public func clearFrameSelection() {
        selectedFrameIndices.removeAll()
    }

    /// Inverting flips every non-excluded frame's selection state; an
    /// already-selected excluded frame stays selected (inversion never
    /// silently drops a frame the user explicitly selected).
    public func invertFrameSelection() {
        let reviewSkippedFrames = Set(
            manualReviewDecisions.compactMap { frameIndex, decision in
                decision == .dontScan ? frameIndex : nil
            }
        )
        selectedFrameIndices = Set(validFrameIndices)
            .subtracting(excludedFrameIndices)
            .subtracting(reviewSkippedFrames)
            .symmetricDifference(selectedFrameIndices)
    }

    // MARK: - Frame edit focus

    /// Focuses one frame for rotate/flip commands without changing which
    /// frames are selected for scanning.
    public func focusFrame(_ frameIndex: Int) {
        guard validFrameIndices.contains(frameIndex) else { return }
        focusedFrameIndex = frameIndex
    }

    /// The explicit focus wins. A sole selected frame remains a useful
    /// fallback for keyboard commands in older/session-restored UI states.
    public var frameTransformTargetIndex: Int? {
        if let focusedFrameIndex,
           validFrameIndices.contains(focusedFrameIndex) {
            return focusedFrameIndex
        }
        guard selectedFrameIndices.count == 1,
              let soleSelection = selectedFrameIndices.first,
              validFrameIndices.contains(soleSelection)
        else {
            return nil
        }
        return soleSelection
    }

    // MARK: - Frame detail navigation

    public func openFrameDetail(_ frameIndex: Int) {
        focusFrame(frameIndex)
        detailFrameIndex = frameIndex
    }

    public func closeFrameDetail() {
        detailFrameIndex = nil
    }

    // MARK: - Error banner

    /// Manually dismisses the current error banner without waiting for the
    /// next action's own auto-clear. Every action already clears
    /// `lastErrorMessage` at its own start (see e.g. `connect`/
    /// `requestPreview`/`startMockScan` above), so a genuinely new
    /// failure always replaces this immediately regardless of whether it
    /// was dismissed early. UI-only: dismissing never retries or cancels
    /// anything in flight.
    public func dismissLastError() {
        lastErrorMessage = nil
    }

    // MARK: - Frame derivative transform

    /// One UI/model contract for every rotation and flip affordance. The
    /// value becomes false as soon as scan startup owns the request and stays
    /// false until the resulting job reaches a terminal state.
    public var frameTransformsAreEditable: Bool {
        pendingScanStart == nil && !isJobActive
    }

    public func rotateFrame(_ frameIndex: Int, by degrees: Int) {
        guard frameTransformsAreEditable else { return }
        let current = frameOrientations[frameIndex] ?? 0
        let normalized = FrameOrientation.normalized(current + degrees)
        guard normalized.isMultiple(of: 90) else { return }
        if normalized == 0 {
            frameOrientations.removeValue(forKey: frameIndex)
        } else {
            frameOrientations[frameIndex] = normalized
        }
    }

    @discardableResult
    public func rotateFocusedFrame(by degrees: Int) -> Bool {
        guard frameTransformsAreEditable,
              let frameIndex = frameTransformTargetIndex
        else { return false }
        rotateFrame(frameIndex, by: degrees)
        return true
    }

    /// One tested dispatch point for the app-wide Photo menu and its
    /// keyboard shortcuts. Keeping this in the model means the global
    /// commands and the on-screen menus cannot drift into different focus
    /// or selection behavior.
    @discardableResult
    public func performFrameTransformCommand(
        _ command: FrameTransformCommand
    ) -> Bool {
        guard let frameIndex = frameTransformTargetIndex else { return false }
        return performFrameTransformCommand(command, for: frameIndex)
    }

    /// Applies a transform to the frame focused in the active app window.
    /// The explicit target prevents a command from one window mutating the
    /// frame focused in another window that shares this session model.
    @discardableResult
    public func performFrameTransformCommand(
        _ command: FrameTransformCommand,
        for frameIndex: Int
    ) -> Bool {
        guard frameTransformsAreEditable,
              validFrameIndices.contains(frameIndex)
        else { return false }
        switch command {
        case .rotateLeft:
            rotateFrame(frameIndex, by: -90)
        case .rotateRight:
            rotateFrame(frameIndex, by: 90)
        case .flipLeftToRight:
            toggleFrameMirror(frameIndex)
        case .flipTopToBottom:
            toggleFrameVerticalMirror(frameIndex)
        }
        return true
    }

    public func resetFrameOrientation(_ frameIndex: Int) {
        guard frameTransformsAreEditable else { return }
        frameOrientations.removeValue(forKey: frameIndex)
    }

    public func frameOrientation(_ frameIndex: Int) -> Int {
        frameOrientations[frameIndex] ?? 0
    }

    // MARK: - Frame horizontal/vertical mirror

    public func toggleFrameMirror(_ frameIndex: Int) {
        setFrameMirror(!frameMirror(frameIndex), for: frameIndex)
    }

    public func setFrameMirror(_ mirrored: Bool, for frameIndex: Int) {
        guard frameTransformsAreEditable else { return }
        if mirrored {
            frameMirrors[frameIndex] = true
        } else {
            frameMirrors.removeValue(forKey: frameIndex)
        }
    }

    public func resetFrameMirror(_ frameIndex: Int) {
        guard frameTransformsAreEditable else { return }
        frameMirrors.removeValue(forKey: frameIndex)
    }

    public func frameMirror(_ frameIndex: Int) -> Bool {
        frameMirrors[frameIndex] ?? false
    }

    public func toggleFrameVerticalMirror(_ frameIndex: Int) {
        setFrameVerticalMirror(!frameVerticalMirror(frameIndex), for: frameIndex)
    }

    public func setFrameVerticalMirror(_ mirrored: Bool, for frameIndex: Int) {
        guard frameTransformsAreEditable else { return }
        if mirrored {
            frameVerticalMirrors[frameIndex] = true
        } else {
            frameVerticalMirrors.removeValue(forKey: frameIndex)
        }
    }

    public func frameVerticalMirror(_ frameIndex: Int) -> Bool {
        frameVerticalMirrors[frameIndex] ?? false
    }

    public func resetFrameMirrors(_ frameIndex: Int) {
        guard frameTransformsAreEditable else { return }
        frameMirrors.removeValue(forKey: frameIndex)
        frameVerticalMirrors.removeValue(forKey: frameIndex)
    }

    private func derivativeTransform(for frameIndex: Int) -> DerivativeTransform {
        DerivativeTransform(
            rotationDegrees: FrameOrientation.normalized(
                frameOrientation(frameIndex)
            ),
            horizontalMirror: frameMirror(frameIndex),
            verticalMirror: frameVerticalMirror(frameIndex)
        )
    }

    private func restoreDerivativeTransforms(from frames: [ProjectFrame]) {
        frameOrientations.removeAll()
        frameMirrors.removeAll()
        frameVerticalMirrors.removeAll()
        for frame in frames {
            guard let transform = frame.alignment?.derivativeTransform else {
                continue
            }
            let rotation = FrameOrientation.normalized(
                transform.rotationDegrees
            )
            if rotation != 0 {
                frameOrientations[frame.index] = rotation
            }
            if transform.horizontalMirror {
                frameMirrors[frame.index] = true
            }
            if transform.verticalMirror {
                frameVerticalMirrors[frame.index] = true
            }
        }
    }

    private func desiredFrameGeometry(
        for frameIndex: Int,
        persistedFrame: ProjectFrame
    ) -> FrameAlignment? {
        let base = frameAlignmentDrafts[frameIndex]
            ?? persistedFrame.alignment
        let transform = derivativeTransform(for: frameIndex)
        guard base != nil || transform != .identity else { return nil }
        return FrameAlignment(
            offsetRows: base?.offsetRows ?? 0,
            approved: base?.approved ?? false,
            derivativeTransform: transform
        )
    }

    // MARK: - Event subscription
    //
    // Consuming-side half of D-14's unknown-event tolerance: every case not
    // recognized here falls through to `default` and is silently ignored,
    // complementing EngineClient's own decode-layer tolerance.

    /// Internal for focused reducer tests; production delivery comes only
    /// from the engine event stream above.
    func handle(event: EngineEvent) {
        switch event.name {
        case "scanner.status":
            decodeAndApply(event, as: ScannerStatusPayload.self) {
                guard self.previewIntentStateMachine.admitsStatusEvent(
                    operationID: $0.operationId
                ) else { return }
                let reconciled = $0.status.invalidatingPreviewWhenFilmIsAbsent()
                self.recordDiagnostic(
                    event: "scanner.status",
                    fields: Self.scannerStatusDiagnosticFields(reconciled)
                )
                if !reconciled.connected {
                    self.invalidateConnection(
                        source: "scanner.status",
                        uiConnectedBefore: self.diagnosticUIConnected
                    )
                    return
                }
                self.status = reconciled
                if !reconciled.mediaLoaded || reconciled.filmPresent == false {
                    self.clearMediaState(
                        preservingPreviewAuthorization: true,
                        preservingActiveJob: self.refeedRequired
                    )
                }
            }
        case "scanner.thumbnail":
            decodeAndApply(event, as: ThumbnailPayload.self) {
                guard self.previewIntentStateMachine.admitsPreviewEvent(
                    operationID: $0.operationId
                ) else { return }
                // A real backend has no load-media call (see
                // `ScanPanelView.canAcquireThumbnails`'s own doc comment):
                // it only proves `mediaLoaded` (and refreshes `frameCount`)
                // via a `scanner.status` re-emit *after* the whole
                // `roll.preview` stream finishes (real_backend.rs's
                // `acquire_thumbnails` calls `status()` exactly once, from
                // its `roll.previewComplete`/`previewError`/timeout
                // branches) — every individual `scanner.thumbnail` event
                // for a real device therefore arrives while
                // `status?.mediaLoaded`/`status?.frameCount` are still
                // stale. `ThumbnailAdmissionPolicy` admits on
                // `isAcquiringThumbnails` as well (true for exactly that
                // same streaming window on both backends), allowing the
                // bridge's bounded real preview to establish a count even
                // before any project exists. The simulator's own path — status
                // already carries `mediaLoaded`/`frameCount` before
                // `requestPreview(_:)` even runs — is unchanged.
                guard ThumbnailAdmissionPolicy.shouldAdmit(
                    frameIndex: $0.frameIndex,
                    mediaLoaded: self.status?.mediaLoaded == true,
                    isAcquiringThumbnails: self.isAcquiringThumbnails,
                    statusFrameCount: self.status?.frameCount,
                    projectFrameCount: self.project?.frameCount
                ) else { return }
                self.thumbnails[$0.frameIndex] = $0.thumbnail
            }
        case "scanner.thumbnailsComplete":
            decodeAndApply(event, as: ThumbnailsCompletePayload.self) {
                guard let operationId = $0.operationId else { return }
                guard self.previewIntentStateMachine.complete(
                    operationID: operationId,
                    hasProject: self.project != nil
                ) else { return }
                self.latestCompletedPreviewOperationId = operationId
                // A manual-review refusal belongs to the preview under which
                // it was raised. Once a replacement preview is authoritative,
                // discard that stale approval path; the failed tile remains
                // available as an ordinary retry.
                self.frameErrors = self.frameErrors.filter {
                    $0.value.code != FrameFailureLabel.manualReviewCode
                }
                self.previewFilmProcess = PreviewProcessLifecyclePolicy.commitAfterCompletion(
                    pending: self.pendingPreviewFilmProcess
                )
                self.pendingPreviewFilmProcess =
                    PreviewProcessLifecyclePolicy.clearAfterFailureOrMediaReset()
                self.beginPersistedFrameAlignmentRestore(
                    previewOperationId: operationId,
                    previewFrameCount: $0.count
                )
            }
        case "scanner.thumbnailsFailed":
            // Previously dropped by `default:` — live 2026-07-26 a
            // whole-roll preview refused with REFEED_REQUIRED ("eject or
            // refeed the strip") and the typed reason never reached any
            // app state. The engine forwards the bridge's own error code
            // verbatim here (real_backend.rs `roll.previewError` arm), so
            // this is the typed signal, not string matching.
            decodeAndApply(event, as: ThumbnailsFailedPayload.self) {
                guard self.previewIntentStateMachine.fail(
                    operationID: $0.operationId
                ) else { return }
                self.latestCompletedPreviewOperationId = nil
                self.isAcquiringThumbnails = false
                self.activeOperationStartedAt = nil
                self.pendingPreviewFilmProcess = nil
                self.lastErrorMessage = "\($0.code): \($0.message)"
                let wasConnected = self.diagnosticUIConnected
                self.recordDiagnostic(
                    event: "preview.failed",
                    fields: [
                        "code": $0.code,
                        "uiConnectedBefore": String(wasConnected),
                    ]
                )
                if $0.code == "NOT_CONNECTED" {
                    self.invalidateConnection(
                        source: "preview",
                        uiConnectedBefore: wasConnected
                    )
                }
                // FEEDER_PARKED intentionally does not light the eject
                // affordance: eject against a parked transport is the
                // accepted-but-inert stall (INCIDENT-20260719); recovery
                // there is a power cycle, not an eject.
                if $0.code == "REFEED_REQUIRED" {
                    self.refeedRequired = true
                }
            }
        case "scan.jobState":
            decodeAndApply(event, as: JobStatePayload.self) { self.applyJobState($0, source: event) }
        case "scan.progress":
            decodeAndApply(event, as: ScanProgressPayload.self) { self.applyProgress($0, source: event) }
        case "scan.frameState":
            decodeAndApply(event, as: FrameStatePayload.self) { self.applyFrameState($0, source: event) }
        case "scan.frameCompleted":
            decodeAndApply(event, as: FrameCompletedPayload.self) { self.applyReceipt($0, source: event) }
        case "scan.completed":
            decodeAndApply(event, as: ScanCompletedPayload.self) { self.applyCompleted($0, source: event) }
        case "engine.terminated":
            handleUnexpectedEngineTermination()
        default:
            break
        }
    }

    private var validFrameIndices: [Int] {
        guard let frameCount = status?.frameCount, frameCount > 0 else { return [] }
        let previewedIndices = Array(1...frameCount)
        guard let project else { return previewedIndices }
        let projectIndices = Set(project.frames.map(\.index))
        return previewedIndices.filter(projectIndices.contains)
    }

    private func clearMediaState(
        preservingPreviewAuthorization: Bool = false,
        preservingActiveJob: Bool = false
    ) {
        let sessionCompletedFrames = Set(
            frameStates.compactMap { index, state in
                state == .completed ? index : nil
            }
        )
        let preserveActivePreview =
            preservingPreviewAuthorization
                && previewIntentStateMachine.hasActiveOperation
        if !preserveActivePreview {
            previewIntentStateMachine.resetForExplicitMediaChange()
        }
        isCustomFilmStockSelected = false
        previewFilmProcess = nil
        if !preserveActivePreview {
            pendingPreviewFilmProcess = nil
        }
        thumbnails = [:]
        latestCompletedPreviewOperationId = nil
        clearPendingManualReviewScan()
        manualReviewDecisions.removeAll()
        clearFrameAlignmentSessionState()
        selectedFrameIndices.removeAll()
        selectionAnchorFrameIndex = nil
        focusedFrameIndex = nil
        detailFrameIndex = nil
        if !preservingActiveJob {
            jobId = nil
            jobState = nil
            progress = nil
            frameStates = [:]
            receipts = []
            frameErrors.removeAll()
            frameAttempts.removeAll()
            frameTransportSmearReasons.removeAll()
            scanSummary = nil
        }
        if !preserveActivePreview {
            isAcquiringThumbnails = false
            activeOperationStartedAt = nil
        }
        frameOrientations.removeAll()
        frameMirrors.removeAll()
        frameVerticalMirrors.removeAll()
        if !preservingActiveJob {
            bufferedJobEvents.removeAll()
            if let project {
                restoreProjectProgress(
                    from: project.frames,
                    additionallyCompleted: sessionCompletedFrames
                )
            } else {
                pendingFrames = []
                completedFrameCount = 0
            }
        }
    }

    private func handleUnexpectedEngineTermination() {
        let wasConnected = diagnosticUIConnected
        advanceConnectionEpoch()
        device = nil
        status = nil
        refeedRequired = false
        clearMediaState()
        recordDiagnostic(
            event: "engine.terminated",
            fields: ["uiConnectedBefore": String(wasConnected)]
        )
        lastErrorMessage = "The scanner engine stopped unexpectedly. Reopen ScanStudio to reconnect."
    }

    /// Internal for lifecycle tests that verify a bridge-reused job id cannot
    /// consume terminal events buffered for a prior connection.
    func beginJob(id: String, frames: [Int] = []) {
        let previouslyCompleted = Set(
            frameStates.compactMap { index, state in
                state == .completed ? index : nil
            }
        ).subtracting(frames)
        clearPendingManualReviewScan()
        jobId = id
        jobState = .queued
        progress = nil
        if let project {
            restoreProjectProgress(
                from: project.frames,
                additionallyCompleted: previouslyCompleted
            )
            for frameIndex in frames {
                frameStates.removeValue(forKey: frameIndex)
            }
        } else {
            frameStates = [:]
            pendingFrames = []
            completedFrameCount = 0
        }
        receipts = []
        frameErrors.removeAll()
        frameAttempts.removeAll()
        frameTransportSmearReasons.removeAll()
        scanSummary = nil
        activeOperationStartedAt = Date()
        let pending = bufferedJobEvents.removeValue(forKey: id) ?? []
        for event in pending { handle(event: event) }
        // Old unknown-job events can never become relevant after a start.
        bufferedJobEvents.removeAll()
    }

    private func eventIsRelevant(_ eventJobId: String, source: EngineEvent) -> Bool {
        if eventJobId == jobId { return true }
        if jobId == nil,
           let pendingScanStart,
           pendingScanStart.connectionEpoch == connectionEpoch {
            bufferedJobEvents[eventJobId, default: []].append(source)
        }
        return false
    }

    /// Sends one scan-start request and accepts its response only if the
    /// connection that authorized it still owns the session. Events may race
    /// ahead of the response and are buffered during this exact interval;
    /// outside it, unknown-job events are dropped.
    func dispatchScanStart(frames: [Int]) async throws -> ScanStartResult? {
        guard pendingScanStart == nil else {
            recordDiagnostic(
                event: "scan.start.ignored",
                fields: ["reason": "requestAlreadyInFlight"]
            )
            return nil
        }

        let marker = PendingScanStart(
            id: UUID(),
            connectionEpoch: connectionEpoch
        )
        pendingScanStart = marker
        defer {
            if pendingScanStart?.id == marker.id {
                pendingScanStart = nil
            }
        }

        guard try await persistFrameGeometryBeforeScan(
            frames: frames,
            scanStartMarker: marker
        ), scanStartRequestIsCurrent(marker, frames: frames) else {
            bufferedJobEvents.removeAll()
            recordDiagnostic(
                event: "scan.start.discarded",
                fields: ["reason": "authorizationChangedBeforeRequest"]
            )
            return nil
        }

        let params = ScanStartParams(
            frames: frames,
            recipe: captureRecipe,
            processing: processingRecipe,
            output: outputRecipe
        )
        let result: ScanStartResult
        do {
            result = try await engineClient.request("scan.start", params: params)
        } catch {
            if pendingScanStart?.id == marker.id {
                bufferedJobEvents.removeAll()
            }
            throw error
        }

        guard pendingScanStart?.id == marker.id,
              connectionEpoch == marker.connectionEpoch,
              diagnosticUIConnected
        else {
            bufferedJobEvents.removeAll()
            recordDiagnostic(
                event: "scan.start.discarded",
                fields: ["reason": "connectionChangedBeforeResponse"]
            )
            return nil
        }
        return result
    }

    /// Makes the active manifest authoritative for the exact crop/rotation/
    /// flip geometry visible in the UI before the engine is allowed to
    /// resolve its per-frame overrides. A bounded convergence check handles
    /// a last-moment edit during an awaited manifest write without ever
    /// starting with stale geometry.
    private func persistFrameGeometryBeforeScan(
        frames: [Int],
        scanStartMarker: PendingScanStart
    ) async throws -> Bool {
        guard let project else { return true }
        let requested = Set(frames)
        for _ in 0..<3 {
            var wroteAny = false
            for frameIndex in requested.sorted() {
                guard let currentProject = self.project,
                      currentProject.id == project.id,
                      let persistedFrame = currentProject.frames.first(
                        where: { $0.index == frameIndex }
                      )
                else {
                    throw EngineRequestError(
                        code: "TRANSFORM_PROJECT_CHANGED",
                        message:
                            "the frame transform no longer belongs to the active project",
                        recoverable: true
                    )
                }
                let desired = desiredFrameGeometry(
                    for: frameIndex,
                    persistedFrame: persistedFrame
                )
                guard persistedFrame.alignment != desired else { continue }
                wroteAny = true
                let result: SetFrameResult = try await engineClient.request(
                    "project.setFrameAlignment",
                    params: SetFrameAlignmentParams(
                        frameIndex: frameIndex,
                        alignment: desired
                    )
                )
                guard scanStartRequestIsCurrent(
                    scanStartMarker,
                    frames: frames
                ) else {
                    return false
                }
                guard result.project.id == project.id else {
                    throw EngineRequestError(
                        code: "TRANSFORM_PROJECT_CHANGED",
                        message:
                            "the frame transform response belongs to a different project",
                        recoverable: true
                    )
                }
                self.project = result.project
            }

            guard let currentProject = self.project,
                  currentProject.id == project.id
            else {
                throw EngineRequestError(
                    code: "TRANSFORM_PROJECT_CHANGED",
                    message: "the active project changed before scan start",
                    recoverable: true
                )
            }
            let converged = requested.allSatisfy { frameIndex in
                guard let persistedFrame = currentProject.frames.first(
                    where: { $0.index == frameIndex }
                ) else { return false }
                return persistedFrame.alignment == desiredFrameGeometry(
                    for: frameIndex,
                    persistedFrame: persistedFrame
                )
            }
            if converged { return true }
            if !wroteAny { break }
        }
        throw EngineRequestError(
            code: "TRANSFORM_CHANGED_DURING_SAVE",
            message:
                "rotation or flip settings changed while the roll was being saved; review them and start the scan again",
            recoverable: true
        )
    }

    /// Revalidates the exact owner and all motion preconditions at every
    /// suspension point between accepting a Scan action and sending the
    /// motion-capable `scan.start` request. A reconnect retires the marker
    /// even when a previous manifest write later resumes successfully.
    private func scanStartRequestIsCurrent(
        _ marker: PendingScanStart,
        frames: [Int]
    ) -> Bool {
        guard let pendingScanStart,
              pendingScanStart.id == marker.id,
              pendingScanStart.connectionEpoch == marker.connectionEpoch,
              connectionEpoch == marker.connectionEpoch,
              diagnosticUIConnected
        else {
            return false
        }
        return scanReadiness(for: frames).isReady
    }

    private func applyJobState(_ payload: JobStatePayload, source: EngineEvent) {
        guard eventIsRelevant(payload.jobId, source: source) else { return }
        guard let current = jobState else { jobState = payload.state; return }
        guard SessionEventPolicy.allowsJobTransition(from: current, to: payload.state) else { return }
        jobState = payload.state
    }

    private func applyProgress(_ payload: ScanProgressPayload, source: EngineEvent) {
        guard eventIsRelevant(payload.jobId, source: source) else { return }
        if let current = progress, payload.jobPercent < current.jobPercent { return }
        progress = ScanProgress(jobId: payload.jobId, frameIndex: payload.frameIndex, frameOrdinal: payload.frameOrdinal, totalFrames: payload.totalFrames, pass: payload.pass, totalPasses: payload.totalPasses, framePercent: payload.framePercent, jobPercent: payload.jobPercent, etaSeconds: payload.etaSeconds)
    }

    private func applyFrameState(_ payload: FrameStatePayload, source: EngineEvent) {
        guard eventIsRelevant(payload.jobId, source: source) else { return }
        let current = frameStates[payload.frameIndex]
        let allowed: Bool = {
            guard let current else { return true }
            return SessionEventPolicy.allowsFrameTransition(from: current, to: payload.state)
        }()
        guard allowed else { return }
        frameStates[payload.frameIndex] = payload.state
        frameAttempts[payload.frameIndex] = payload.attempt
        if let error = payload.error {
            let isFilmFeedInterrupted = FilmTransportFailurePolicy.isFilmFeedInterrupted(
                errorCode: error.code,
                message: error.message
            )
            let duplicateBatchFeedDiagnostic = isFilmFeedInterrupted
                && frameErrors.values.contains {
                    FilmTransportFailurePolicy.isFilmFeedInterrupted(
                        errorCode: $0.code,
                        message: $0.message
                    )
                }
            frameErrors[payload.frameIndex] = error
            let diagnosticCode = Self.diagnosticErrorCode(
                code: error.code,
                message: error.message
            )
            let wasConnected = diagnosticUIConnected
            if !duplicateBatchFeedDiagnostic {
                recordDiagnostic(
                    event: "scan.frame.failed",
                    fields: [
                        "attempt": String(payload.attempt),
                        "code": diagnosticCode,
                        "frameIndex": String(payload.frameIndex),
                        "uiConnectedBefore": String(wasConnected),
                    ]
                )
            }
            if diagnosticCode == "NOT_CONNECTED" {
                lastErrorMessage = "\(error.code): \(error.message)"
                invalidateConnection(
                    source: "scan.frame",
                    uiConnectedBefore: wasConnected,
                    preservingActiveJob: true
                )
            }
        } else {
            frameErrors.removeValue(forKey: payload.frameIndex)
        }
    }

    private func applyReceipt(_ payload: FrameCompletedPayload, source: EngineEvent) {
        guard eventIsRelevant(payload.jobId, source: source), !receipts.contains(where: { $0.id == payload.receipt.id }) else { return }
        receipts.append(payload.receipt)
        durableCompletedFrameIndices.insert(payload.frameIndex)
        frameStates[payload.frameIndex] = .completed
        pendingFrames.removeAll { $0 == payload.frameIndex }
        completedFrameCount = Set(
            frameStates.compactMap { index, state in
                state == .completed ? index : nil
            }
        ).count
        if let smear = payload.receipt.hardwareTelemetry?.transportSmear, smear.verdict != "clean" {
            frameTransportSmearReasons[payload.frameIndex] = smear.reason
        } else {
            frameTransportSmearReasons.removeValue(forKey: payload.frameIndex)
        }
    }

    private func applyCompleted(_ payload: ScanCompletedPayload, source: EngineEvent) {
        guard eventIsRelevant(payload.jobId, source: source) else { return }
        let transportFailure = payload.summary.failed
            .compactMap { frameErrors[$0] }
            .first {
                FilmTransportFailurePolicy.requiresPhysicalRefeed(
                    errorCode: $0.code,
                    message: $0.message
                )
            }
        scanSummary = payload.summary
        // A re-scan is allowed to replace a persisted frame's live display
        // state with waiting/active/failed while the attempt is in flight.
        // If that attempt stops or fails before a new receipt arrives, the
        // older manifest receipt is still durable truth. Restore only those
        // persisted completions here; never synthesize completion for a
        // previously-pending frame that failed in this job.
        if let project {
            for frameIndex in durableCompletedFrameIndices {
                frameStates[frameIndex] = .completed
            }
            let completed = Set(
                frameStates.compactMap { index, state in
                    state == .completed ? index : nil
                }
            )
            pendingFrames = project.frames
                .filter { !$0.excluded && !completed.contains($0.index) }
                .map(\.index)
            completedFrameCount = completed.count
        }
        if payload.summary.stopped {
            selectedFrameIndices.subtract(payload.summary.completed)
        }
        // Force a terminal jobState from the authoritative completion summary
        // when the terminal `scan.jobState` was absent/out of order (a session
        // otherwise stuck "SCANNING"); an existing terminal state is preserved,
        // never overridden. See `ScanCompletionPolicy`.
        jobState = ScanCompletionPolicy.resolveJobState(current: jobState, summary: payload.summary)
        if let transportFailure {
            requirePhysicalRefeed(
                errorCode: transportFailure.code,
                message: transportFailure.message,
                preservingActiveJob: true
            )
        }
        jobId = nil
    }

    private func decodeAndApply<Payload: Decodable>(
        _ event: EngineEvent,
        as payloadType: Payload.Type,
        apply: (Payload) -> Void
    ) {
        guard let envelope = try? JSONDecoder().decode(EventEnvelope<Payload>.self, from: event.rawLine) else {
            return
        }
        apply(envelope.payload)
    }

    /// `scan.start` can refuse synchronously with the bridge's
    /// REFEED_REQUIRED (a whole-batch precondition failure — BRIDGE.md's
    /// `scan.start` notable errors). Unlike the preview path there is no
    /// typed event: the engine folds the bridge code into the thrown
    /// error's message using its own fixed format ("bridge error
    /// REFEED_REQUIRED: …", `real_backend.rs::map_bridge_error`), so this
    /// checks for that engine-formatted name — the wire contract as it
    /// exists today — not for human prose. Internal for focused tests,
    /// same as `handle(event:)`.
    func noteRefeedRequired(from error: Error) {
        guard let requestError = error as? EngineRequestError else { return }
        if requestError.message.contains("REFEED_REQUIRED") {
            requirePhysicalRefeed(
                errorCode: requestError.code,
                message: requestError.message,
                preservingActiveJob: false
            )
        }
    }

    /// Records the operator-facing recovery reason and invalidates every
    /// preview-bound coordinate before another Capture can be attempted.
    /// Terminal scan failures preserve their job evidence; synchronous
    /// refusals have no accepted job to retain.
    private func requirePhysicalRefeed(
        errorCode: String,
        message: String,
        preservingActiveJob: Bool
    ) {
        lastErrorMessage = "\(errorCode): \(message)"
        refeedRequired = true
        clearMediaState(preservingActiveJob: preservingActiveJob)
    }

    private var diagnosticUIConnected: Bool {
        device != nil && status?.connected == true
    }

    private var diagnosticConnectionSummary: String {
        [
            "uiConnected=\(diagnosticUIConnected)",
            "deviceKind=\(device?.kind ?? "none")",
            "previewActive=\(isAcquiringThumbnails)",
            "scanActive=\(isJobActive)",
            "transport=\(status?.transport ?? "unknown")",
        ].joined(separator: "; ")
    }

    private var diagnosticLogRelativePath: String? {
        guard let logURL = diagnosticTimeline.logURL else { return nil }
        return "~/.scanstudio/diagnostics/\(logURL.lastPathComponent)"
    }

    /// The true absolute path to the durable diagnostics log, for the
    /// local-only technical details view (T-ERR-02). Never surfaced in the
    /// public issue draft -- see `diagnosticLogRelativePath` for that form.
    private var diagnosticLogPath: String? {
        diagnosticTimeline.logURL?.path
    }

    /// Builds "Save Diagnostic Bundle..."'s zip bytes (T-ERR-04): the
    /// session's diagnostics.jsonl, the current generated report text, and
    /// -- when the session had a roll preview whose image path is still
    /// readable -- that preview raster. The raster comes only from
    /// already-decoded `Thumbnail.imagePath` state; this never opens a new
    /// engine/bridge round trip to locate it.
    public func makeDiagnosticBundleData() -> Data {
        let reportText = errorPresentation?.technicalDetails
            ?? lastErrorMessage
            ?? "No error was active when this bundle was saved."
        let (raster, unavailableReason) = DiagnosticBundleRasterPolicy.resolve(
            thumbnails: thumbnails,
            readFile: { FileManager.default.contents(atPath: $0) }
        )
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: diagnosticsJSONLData(),
            reportText: reportText,
            previewRaster: raster,
            unavailableRasterReason: unavailableReason
        )
        return StoredZipWriter.write(entries)
    }

    /// Re-derives diagnostics.jsonl's exact bytes from the in-memory
    /// timeline -- identical in shape to what `SessionDiagnosticTimeline`
    /// persists to disk -- so the bundle never depends on a prior disk write
    /// having succeeded (a memory-only timeline in tests still bundles).
    private func diagnosticsJSONLData() -> Data {
        var data = Data()
        let encoder = JSONEncoder()
        for entry in diagnosticTimeline.entries {
            guard let encoded = try? encoder.encode(entry) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        return data
    }

    private func recordDiagnostic(
        event: String,
        fields: [String: String] = [:]
    ) {
        // Every current call site hands this plain String fields, but the
        // timeline itself stores the generic `DiagnosticFieldValue` shape
        // (SessionDiagnosticTimeline.swift) so future instrumentation can
        // record numbers/bools/nested objects straight into
        // `diagnosticTimeline.record` without a report-side change.
        diagnosticTimeline.record(event: event, fields: fields.mapValues { .string($0) })
    }

    /// A scanner operation can prove that the bridge has no live device
    /// owner even while the app still holds an older successful connection
    /// result. That refusal is authoritative: clear the stale READY state and
    /// require an explicit reconnect. Never auto-open the bridge or replay a
    /// motion command from here.
    private func recordOperationFailure(_ error: Error, operation: String) {
        let wasConnected = diagnosticUIConnected
        let code = Self.diagnosticErrorCode(error)
        recordDiagnostic(
            event: "\(operation).failed",
            fields: [
                "code": code,
                "uiConnectedBefore": String(wasConnected),
            ]
        )
        if code == "NOT_CONNECTED" {
            invalidateConnection(
                source: operation,
                uiConnectedBefore: wasConnected
            )
        }
    }

    private func invalidateConnection(
        source: String,
        uiConnectedBefore: Bool,
        preservingActiveJob: Bool = false
    ) {
        let hadConnectionState =
            device != nil
            || status != nil
            || isAcquiringThumbnails
        guard hadConnectionState else { return }
        if lastErrorMessage?.range(
            of: #"(?<![A-Z0-9_])NOT_CONNECTED(?![A-Z0-9_])"#,
            options: .regularExpression
        ) == nil {
            let previousDetail = lastErrorMessage.map {
                "\nPrevious error: \($0)"
            } ?? ""
            lastErrorMessage =
                "NOT_CONNECTED: The scanner session was lost; reconnect required."
                + previousDetail
        }
        advanceConnectionEpoch()
        device = nil
        status = nil
        multisampleCoercionNote = nil
        refeedRequired = false
        clearMediaState(preservingActiveJob: preservingActiveJob)
        recordDiagnostic(
            event: "connection.invalidated",
            fields: [
                "reason": "NOT_CONNECTED",
                "source": source,
                "uiConnectedBefore": String(uiConnectedBefore),
            ]
        )
    }

    /// Invalidates all request/event races tied to the previous logical
    /// bridge owner. This is local bookkeeping only: it never opens a device,
    /// retries motion, or sends a scanner command.
    private func advanceConnectionEpoch() {
        connectionEpoch &+= 1
        latestCompletedPreviewOperationId = nil
        pendingScanStart = nil
        clearPendingManualReviewScan()
        manualReviewDecisions.removeAll()
        clearFrameAlignmentSessionState()
        pendingManualReviewApproval = nil
        approvingFrameIndex = nil
        pendingStatusRefresh = nil
        isRefreshingScannerStatus = false
        bufferedJobEvents.removeAll()
    }

    private static func diagnosticErrorCode(_ error: Error) -> String {
        guard let requestError = error as? EngineRequestError else {
            return "LOCAL_ERROR"
        }
        return diagnosticErrorCode(
            code: requestError.code,
            message: requestError.message
        )
    }

    private static func diagnosticErrorCode(
        code: String,
        message: String
    ) -> String {
        if FilmTransportFailurePolicy.isFilmFeedInterrupted(
            errorCode: code,
            message: message
        ) {
            return "FILM_FEED_INTERRUPTED"
        }
        if FilmTransportFailurePolicy.requiresPhysicalRefeed(
            errorCode: code,
            message: message
        ) {
            return "REFEED_REQUIRED"
        }
        if code == "NOT_CONNECTED"
            || message.range(
                of: #"(?<![A-Z0-9_])NOT_CONNECTED(?![A-Z0-9_])"#,
                options: .regularExpression
            ) != nil {
            return "NOT_CONNECTED"
        }
        return code
    }

    private static func scannerStatusDiagnosticFields(
        _ status: ScannerStatus
    ) -> [String: String] {
        [
            "connected": String(status.connected),
            "filmPresent": status.filmPresent.map(String.init) ?? "unknown",
            "mediaLoaded": String(status.mediaLoaded),
            "transport": status.transport,
        ]
    }

    private static func describe(_ error: Error) -> String {
        if let requestError = error as? EngineRequestError {
            return "\(requestError.code): \(requestError.message)"
        }
        if let locateError = error as? EngineLocator.LocateError {
            return locateError.message
        }
        if let compatibilityError = error as? EngineCompatibilityError {
            return compatibilityError.reason
        }
        return String(describing: error)
    }
}

enum SessionEventPolicy {
    static func allowsJobTransition(from current: JobState, to next: JobState) -> Bool {
        if current == next { return true }
        switch current {
        case .queued:
            return next == .scanning || next == .stopped
        case .scanning:
            return next.isTerminal || next == .stoppingAfterCurrentFrame || next == .stoppingImmediately
        case .stoppingAfterCurrentFrame, .stoppingImmediately:
            return next.isTerminal
        case .completed, .failed, .stopped:
            return false
        }
    }

    static func allowsFrameTransition(from current: FrameState, to next: FrameState) -> Bool {
        if current == next { return true }
        switch current {
        case .waiting: return next == .active || next == .completed || next == .failed || next == .skipped
        case .active: return next == .completed || next == .failed || next == .skipped
        case .failed: return next == .active
        case .completed, .skipped: return false
        }
    }
}

/// The terminal `JobState` a `scan.completed` summary authoritatively implies
/// for a job whose own terminal `scan.jobState` event was absent or arrived
/// out of order — the fix for a session stuck "SCANNING" because the completion
/// summary landed but no terminal job-state transition ever did. Extracted as a
/// pure function (mirroring `SessionEventPolicy` above) so the resolution rule
/// is directly testable without a live `EngineClient`.
///
/// `stopped` summaries resolve to `.stopped`; every other summary resolves to
/// `.completed` — a job that ran to its natural end is completed at the job
/// level even when some of its frames failed (the engine's own precedent, per
/// PROTOCOL.md's `scan.completed`/`JobState` contract and `sim.rs`: per-frame
/// failures live in `summary.failed`, while the job-level `.failed` state only
/// ever arrives as its own `scan.jobState{failed}` event from the scan.error/
/// silence paths, never from the summary). An existing terminal state is always
/// preserved: a late or out-of-order summary must never downgrade a
/// `scan.jobState{failed}`/`{stopped}` the engine already reported.
enum ScanCompletionPolicy {
    static func resolveJobState(current: JobState?, summary: ScanSummary) -> JobState {
        if let current, current.isTerminal { return current }
        return summary.stopped ? .stopped : .completed
    }
}

/// Whether an incoming `scanner.thumbnail` event should be stored, given the
/// two staleness-prone signals available in `SessionModel.handle(event:)`.
/// Extracted as a pure function (mirroring `SessionEventPolicy` above) so the
/// real-backend fix — admit on `isAcquiringThumbnails`, not only
/// `mediaLoaded`, and fall back to the project's own frame count when the
/// engine's own `status.frameCount` isn't current yet — is directly
/// testable without a live `EngineClient`. See the `"scanner.thumbnail"`
/// case's own comment for why both fallbacks are necessary for a real
/// device.
enum ThumbnailAdmissionPolicy {
    /// The LS-5000 adapter family's documented physical slot ceiling
    /// (BRIDGE.md's `Capabilities.adapterFrameCapacity`). The engine exposes
    /// its trusted holder classification through `ScannerStatus.carrier`, but
    /// not the raw capacity itself, so this remains a documented constant
    /// rather than a live value. No real detected frame index can ever
    /// legitimately exceed this, no matter how stale or absent
    /// `statusFrameCount`/`projectFrameCount` are — it is the one bound
    /// spoof/decode-garbage indices still have to clear.
    static let maximumPhysicalFrameIndex = 40

    static func shouldAdmit(
        frameIndex: Int,
        mediaLoaded: Bool,
        isAcquiringThumbnails: Bool,
        statusFrameCount: Int?,
        projectFrameCount: Int?
    ) -> Bool {
        guard mediaLoaded || isAcquiringThumbnails else { return false }
        // A real preview establishes the actual count. While its stream is
        // active, neither a pre-preview status nor a project exists yet, so
        // accept only the scanner family's mechanical upper bound; these are
        // thumbnail events the bridge itself actually discovered, not scan
        // targets inferred from holder capacity.
        if isAcquiringThumbnails {
            return (1...maximumPhysicalFrameIndex).contains(frameIndex)
        }
        let nominalCeiling = max(statusFrameCount ?? 0, projectFrameCount ?? 0)
        guard nominalCeiling > 0 else { return false }
        // After acquisition settles, a late/straggler event must match the
        // authoritative preview status or saved project; do not extend the
        // list merely because the holder could physically accept more film.
        let frameCeiling = min(nominalCeiling, maximumPhysicalFrameIndex)
        return (1...frameCeiling).contains(frameIndex)
    }
}

/// The multisample-pass options a Scan Settings picker should offer, given
/// which device (if any) is connected — and the coercion rule for when a
/// previously-chosen value stops being one of them. A real LS-5000 only
/// accepts the device's own bridge-reported set (BRIDGE.md's
/// `Capabilities.supportedMultisamplePasses`, always `[4]` today per that
/// field's own doc comment); offering the simulator's fuller `[1, 2, 4, 8,
/// 16]` range to a connected real device let the owner pick 2x/8x/16x and
/// get an `INVALID_PARAMS` rejection back from `scan.start` (verified live
/// 2026-07-25, `real_backend.rs`'s `scan_start`: "multisamplePasses must be
/// one of {:?} for this device"). `DeviceInfo.supportedMultisamplePasses`
/// (added to `WireProtocol.swift`) is preferred the moment a future engine
/// build actually sends it; until then, `realDeviceFallback` matches
/// today's real, documented, engine-enforced behavior exactly.
public enum MultisamplePassPolicy {
    /// The simulator's own fuller, historical range — unchanged.
    public static let simulatedOptions = [1, 2, 4, 8, 16]
    /// Matches `real_backend.rs`'s `derive_supported_multisample_passes` /
    /// BRIDGE.md's documented `supportedMultisamplePasses` today: always
    /// `[4]` for the LS-5000.
    public static let realDeviceFallback = [4]

    /// The options a picker should offer for `device` (`nil` — no device
    /// connected yet — gets the fuller simulator-shaped range, matching
    /// this picker's own pre-existing behavior before any device
    /// connects).
    public static func supportedOptions(for device: DeviceInfo?) -> [Int] {
        guard let device else { return simulatedOptions }
        if let supported = device.supportedMultisamplePasses, !supported.isEmpty {
            return supported.sorted()
        }
        return device.kind == "real" ? realDeviceFallback : simulatedOptions
    }

    /// The value a recipe should carry given `options`: `current` unchanged
    /// if it's still supported, otherwise coerced to the closest allowed
    /// value (nearest by absolute difference; ties break toward the lower
    /// value) rather than always snapping to the first/lowest entry, so a
    /// hypothetical future `[4, 8]`-only device coerces a stored `6` to `4`
    /// and a stored `9` to `8`, never both to the same value. An empty
    /// `options` list is a no-op (returns `current` unchanged) rather than
    /// crashing or fabricating a value with no basis.
    public static func coerce(_ current: Int, into options: [Int]) -> Int {
        guard !options.isEmpty else { return current }
        if options.contains(current) { return current }
        return options.min { lhs, rhs in
            let distanceLhs = abs(lhs - current)
            let distanceRhs = abs(rhs - current)
            return distanceLhs == distanceRhs ? lhs < rhs : distanceLhs < distanceRhs
        } ?? current
    }

    public static func label(for passes: Int) -> String {
        passes == 1 ? "Off" : "\(passes)×"
    }

    public static func optionsDescription(_ options: [Int]) -> String {
        options.map(label(for:)).joined(separator: ", ")
    }
}

/// What the sidebar's session-aware status card should show right now.
/// Extracted as a pure function (mirroring `ThumbnailAdmissionPolicy`
/// above) so both "which shape to show" and each displayed number are
/// tested logic rather than inline SwiftUI computed properties. It uses
/// receipts as completed-work evidence and reports remaining work only when
/// the engine supplies a total. An absent real-hardware total stays unknown;
/// neither the selected frame count nor the holder's capacity is substituted.
public enum SessionActivitySummary: Equatable, Sendable {
    case idle
    case scanning(completed: Int, remaining: Int?, lastCompletedFrame: Int?)
    case loadingPreviews(completed: Int, remaining: Int?, lastLoadedFrame: Int?)

    public static func current(
        isJobActive: Bool,
        isAcquiringThumbnails: Bool,
        receiptCount: Int,
        lastCompletedFrame: Int?,
        progressTotalFrames: Int?,
        thumbnailCount: Int,
        lastLoadedFrame: Int?,
        statusFrameCount: Int?
    ) -> SessionActivitySummary {
        if isJobActive {
            return .scanning(
                completed: receiptCount,
                remaining: progressTotalFrames.map {
                    max($0 - receiptCount, 0)
                },
                lastCompletedFrame: lastCompletedFrame
            )
        }
        if isAcquiringThumbnails {
            // A real preview has no total until its terminal status. Do not
            // invent the SA-30 holder's capacity as an exposure count.
            let total = statusFrameCount.flatMap { $0 > 0 ? $0 : nil }
            return .loadingPreviews(
                completed: thumbnailCount,
                remaining: total.map { max($0 - thumbnailCount, 0) },
                lastLoadedFrame: lastLoadedFrame
            )
        }
        return .idle
    }
}

/// Pure degrees-of-rotation arithmetic for `SessionModel.rotateFrame`:
/// always normalizes into the range `0..<360` regardless of how far
/// positive or negative `degrees` runs (Swift's `%` can return a negative
/// result for a negative dividend, so a plain `% 360` alone is not
/// sufficient for a counter-clockwise rotation).
///
/// `public` (with `ResumeBatchPolicy`'s precedent): the `ScanStudio`
/// executable target's tiles read `accessibilityText(_:)` across the module
/// boundary to announce the selected derivative rotation honestly to VoiceOver.
public enum FrameOrientation {
    static func normalized(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    /// Honest VoiceOver text for a derivative rotation — `nil` for an
    /// unrotated frame, so callers append nothing rather than announce a
    /// pointless "rotated 0 degrees".
    public static func accessibilityText(_ degrees: Int) -> String? {
        let normalized = normalized(degrees)
        guard normalized != 0 else { return nil }
        return "rotated \(normalized) degrees"
    }

    /// The contact sheet's outer card must participate in a quarter-turn;
    /// `rotationEffect` changes pixels but not SwiftUI layout bounds.
    public static func displayAspectRatio(_ degrees: Int) -> Double {
        swapsLayoutAxes(degrees) ? 2.0 / 3.0 : 3.0 / 2.0
    }

    /// A quarter-turn also swaps the bitmap's proposed layout dimensions
    /// before SwiftUI paints the rotation.
    public static func swapsLayoutAxes(_ degrees: Int) -> Bool {
        !normalized(degrees).isMultiple(of: 180)
    }
}

/// App-wide commands that change only the currently focused photo. Scan
/// selection is deliberately not part of this type.
public enum FrameTransformCommand: Sendable {
    case rotateLeft
    case rotateRight
    case flipLeftToRight
    case flipTopToBottom
}

/// Whether the "Resume Batch" action should be offered, given the engine's
/// own authoritative completed/pending counts from the last
/// `project.pendingFrames` round trip (`PendingFramesResult.completedCount`
/// and `.frames.count` — the exact same manifest-derived response
/// `SessionModel.completedFrameCount`/`.pendingFrameCount` are sourced
/// from). `public`: `ScanPanelView` (the `ScanStudio` executable target)
/// calls this directly across the module boundary via a plain `import
/// ScanStudioKit`, the same precedent `ProjectCarrierRules` below already
/// established.
///
/// A fresh project (zero receipts, i.e. `completedCount == 0`) must never
/// read as resumable, no matter how its pending count compares to anything
/// else. Comparing `pendingCount` against a *different* frame-count signal
/// (`ScannerStatus.frameCount`, the physically-detected frame count from
/// the last preview pass) is exactly the bug verified live on 2026-07-25: a
/// brand-new project with a nominal 36-frame roll had all 36 frames
/// pending (zero receipts yet — none scanned), while the same physical
/// roll's preview detected 39 frames. "36 pending < 39 detected" read as
/// "partial roll" under the old `ScanPanelView.showResumeBatch` check, even
/// though not a single frame had ever been scanned. Resuming is only
/// meaningful once at least one frame has actually completed *and* at
/// least one still needs to run — both counts belong to the project's own
/// manifest, never to `status.frameCount`.
public enum ResumeBatchPolicy {
    public static func shouldShowResumeBatch(completedCount: Int, pendingCount: Int) -> Bool {
        completedCount > 0 && pendingCount > 0
    }
}

/// Whether the per-frame auto-crop affordance should be offered. This is
/// scan-time engine crop *information* surfaced for inspection — never an
/// instant client-side crop action — so it is only meaningful for a single,
/// real-preview-backed frame the operator is actually looking at: offered only
/// when exactly one frame is selected and that frame carries a real `imagePath`
/// preview (a bridge-written tile, per PROTOCOL.md's `Thumbnail` one-of
/// contract), never for a simulator-shaped brightness/tint thumbnail with no
/// real image to crop against. `public`: the `ScanStudio` executable target's
/// detail workspace reads this across the module boundary via a plain `import
/// ScanStudioKit`, the same precedent `ResumeBatchPolicy` above established.
public enum AutoCropAffordance {
    public static func isOffered(selectedFrameIndices: Set<Int>, thumbnails: [Int: Thumbnail]) -> Bool {
        guard selectedFrameIndices.count == 1, let frameIndex = selectedFrameIndices.first else { return false }
        return thumbnails[frameIndex]?.imagePath != nil
    }
}

/// The contiguous, inclusive frame-index range a Shift-click range-select
/// should add to the current selection — order-independent, since the
/// anchor (the last frame a plain click landed on) may sit above or below
/// the just-clicked frame in the grid.
enum FrameRangeSelection {
    static func inclusiveRange(anchor: Int, clicked: Int) -> ClosedRange<Int> {
        min(anchor, clicked)...max(anchor, clicked)
    }
}

/// Centralizes carrier-to-frame-count rules so they live in one pure,
/// tested place rather than duplicated inline in UI code: the legacy
/// `roll36` wire token means SA-30 roll film, whose preview-established
/// count may be 1-40; strip6 is 1-6; mounted is exactly 1. Holder capacity
/// is not an exposure count.
///
/// `public`: the `ScanStudio` executable target's project-launcher UI
/// (02-03) calls these directly across the module boundary via a plain
/// `import ScanStudioKit`, not `@testable import`.
public enum ProjectCarrierRules {
    public static func isFrameCountFixed(_ carrier: SimulatedFilmCarrier) -> Bool {
        switch carrier {
        case .mounted: return true
        case .roll36, .strip6: return false
        }
    }

    public static func validFrameCountRange(_ carrier: SimulatedFilmCarrier) -> ClosedRange<Int> {
        switch carrier {
        case .roll36: return 1...40
        case .strip6: return 1...6
        case .mounted: return 1...1
        }
    }

    public static func defaultFrameCount(_ carrier: SimulatedFilmCarrier) -> Int {
        // A manual, unknown SA-30 choice may start at the familiar 36, but
        // that is never used as a real scanner's detected frame count.
        carrier == .roll36 ? 36 : validFrameCountRange(carrier).upperBound
    }
}

/// A successful preview establishes both the physical holder and the exact
/// frame registration. A project is safe to use only when both facts agree;
/// equal counts alone do not make (for example) a strip and an SA-30 roll
/// interchangeable.
public enum ProjectMediaCompatibilityPolicy {
    public static func matches(
        projectCarrier: SimulatedFilmCarrier,
        projectFrameCount: Int,
        previewedCarrier: SimulatedFilmCarrier,
        previewedFrameCount: Int
    ) -> Bool {
        projectCarrier == previewedCarrier && projectFrameCount == previewedFrameCount
    }
}
