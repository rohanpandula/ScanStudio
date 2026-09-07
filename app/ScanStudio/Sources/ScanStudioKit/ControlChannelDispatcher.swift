// The transport-agnostic core of the ScanStudio control channel.
//
// Canonical source: `protocol/CONTROL.md` (envelopes and error vocabulary
// come from `ControlWireProtocol.swift`, D-01). This file adds the one
// piece neither of those provide: a decoder from raw request bytes to a
// typed `ControlRequest`, and a `@MainActor` dispatcher that runs every
// request through one shared refusal preamble (hello/schema-version gate,
// confirmation, busy) before routing it onto the exact `SessionModel`
// method the GUI itself calls (D-04). No transport of any kind lives here
// (Phase 2's job) -- `handle(_:)`/`handleLine(_:)` are the only two entry
// points a future transport needs (D-06).
//
// Plan 04 builds this preamble plus the five read-only aggregate commands
// (`status`, `frames.list`, `settings.get`, `outputs.get`, `job.get`) and
// `events.subscribe`. Every other D-05 command is left as a deliberate,
// greppable placeholder that Plans 05 and 06 replace with real routing on
// top of the preamble this file establishes.

import Foundation
import Observation

// MARK: - Decode failure

/// A decode-time refusal that still carries the request id it belongs to
/// (`0` when the line could not even be sniffed for an id) -- the reason
/// `decode(_:)` returns a `Result` rather than throwing a `DecodingError`,
/// which has no notion of "which request this was."
public struct ControlDecodeFailure: Error, Equatable, Sendable {
    public let id: UInt64
    public let error: ControlErrorPayload
}

// MARK: - Typed request

/// One case per D-05 command. Case names are the camelCased command names;
/// `id` and (where the command has params) `params` are always the first
/// associated values, in that order.
public enum ControlRequest: Sendable {
    case hello(id: UInt64, params: ControlHelloParams)
    case status(id: UInt64)
    case scannerList(id: UInt64)
    case scannerRescan(id: UInt64)
    case scannerConnect(id: UInt64, params: ControlScannerConnectParams)
    case scannerDisconnect(id: UInt64)
    case previewAcquire(id: UInt64, params: ControlPreviewAcquireParams)
    case framesList(id: UInt64)
    case framesInclude(id: UInt64, params: ControlFrameSelectionParams)
    case framesExclude(id: UInt64, params: ControlFrameSelectionParams)
    case reviewApprove(id: UInt64, params: ControlReviewApproveParams)
    case settingsGet(id: UInt64)
    case settingsSet(id: UInt64, params: ControlSettingsSetParams)
    case outputsGet(id: UInt64)
    case outputsSet(id: UInt64, params: ControlOutputsSetParams)
    case rollSave(id: UInt64, params: ControlRollSaveParams)
    case rollOpen(id: UInt64, params: ControlRollOpenParams)
    case rollList(id: UInt64)
    case scanStart(id: UInt64, params: ControlScanStartParams)
    case scanStop(id: UInt64, params: ControlScanStopParams)
    case scanResume(id: UInt64, params: ControlScanResumeParams)
    case scannerEject(id: UInt64, params: ControlScannerEjectParams)
    case diagnosticsExport(id: UInt64, params: ControlDiagnosticsExportParams)
    case eventsSubscribe(id: UInt64)
    case jobGet(id: UInt64)
}

extension ControlRequest {
    public var id: UInt64 {
        switch self {
        case .hello(let id, _): id
        case .status(let id): id
        case .scannerList(let id): id
        case .scannerRescan(let id): id
        case .scannerConnect(let id, _): id
        case .scannerDisconnect(let id): id
        case .previewAcquire(let id, _): id
        case .framesList(let id): id
        case .framesInclude(let id, _): id
        case .framesExclude(let id, _): id
        case .reviewApprove(let id, _): id
        case .settingsGet(let id): id
        case .settingsSet(let id, _): id
        case .outputsGet(let id): id
        case .outputsSet(let id, _): id
        case .rollSave(let id, _): id
        case .rollOpen(let id, _): id
        case .rollList(let id): id
        case .scanStart(let id, _): id
        case .scanStop(let id, _): id
        case .scanResume(let id, _): id
        case .scannerEject(let id, _): id
        case .diagnosticsExport(let id, _): id
        case .eventsSubscribe(let id): id
        case .jobGet(let id): id
        }
    }

    /// The exact D-05 wire name -- what a control caller sent as `method`.
    public var methodName: String {
        switch self {
        case .hello: "hello"
        case .status: "status"
        case .scannerList: "scanner.list"
        case .scannerRescan: "scanner.rescan"
        case .scannerConnect: "scanner.connect"
        case .scannerDisconnect: "scanner.disconnect"
        case .previewAcquire: "preview.acquire"
        case .framesList: "frames.list"
        case .framesInclude: "frames.include"
        case .framesExclude: "frames.exclude"
        case .reviewApprove: "review.approve"
        case .settingsGet: "settings.get"
        case .settingsSet: "settings.set"
        case .outputsGet: "outputs.get"
        case .outputsSet: "outputs.set"
        case .rollSave: "roll.save"
        case .rollOpen: "roll.open"
        case .rollList: "roll.list"
        case .scanStart: "scan.start"
        case .scanStop: "scan.stop"
        case .scanResume: "scan.resume"
        case .scannerEject: "scanner.eject"
        case .diagnosticsExport: "diagnostics.export"
        case .eventsSubscribe: "events.subscribe"
        case .jobGet: "job.get"
        }
    }

    /// `true` for exactly the commands that route onto a `SessionModel`
    /// method carrying Plan 03's `mutatingOperationInFlight` flag, plus
    /// `settingsSet`/`outputsSet` (RESEARCH: no busy flag of their own, but
    /// the GUI hides its settings editors while a job is active, so a
    /// control caller must meet the same bar -- Plan 06 implements the
    /// specific check; this flag is what routes them through it).
    public var isMutating: Bool {
        switch self {
        case .scannerList, .scannerRescan, .scannerConnect, .scannerDisconnect,
             .previewAcquire, .framesInclude, .framesExclude, .reviewApprove,
             .settingsSet, .outputsSet, .rollSave, .rollOpen, .rollList,
             .scanStart, .scanStop, .scanResume, .scannerEject:
            true
        case .hello, .status, .framesList, .settingsGet, .outputsGet,
             .diagnosticsExport, .eventsSubscribe, .jobGet:
            false
        }
    }
}

// MARK: - Typed result

/// One case per D-05 result type. `encode(to:)` is hand-written to forward
/// straight to the wrapped payload's own encoding, so the wire shape is the
/// bare result object -- this enum exists only to keep `ControlResponse`
/// typed without a separate `Encodable` eraser type.
public enum ControlResult: Encodable, Equatable, Sendable {
    case empty(ControlEmptyResult)
    case hello(ControlHelloResult)
    case status(ControlStatusResult)
    case framesList(ControlFramesListResult)
    case job(ControlJobResult)
    case settings(ControlSettingsResult)
    case outputs(ControlOutputsResult)
    case scannerList(ControlScannerListResult)
    case rollList(ControlRollListResult)
    case rollSave(ControlRollSaveResult)
    case previewAcquire(ControlPreviewAcquireResult)
    case diagnosticsExport(ControlDiagnosticsExportResult)
    case eventsSubscribe(ControlEventsSubscribeResult)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .empty(let value): try container.encode(value)
        case .hello(let value): try container.encode(value)
        case .status(let value): try container.encode(value)
        case .framesList(let value): try container.encode(value)
        case .job(let value): try container.encode(value)
        case .settings(let value): try container.encode(value)
        case .outputs(let value): try container.encode(value)
        case .scannerList(let value): try container.encode(value)
        case .rollList(let value): try container.encode(value)
        case .rollSave(let value): try container.encode(value)
        case .previewAcquire(let value): try container.encode(value)
        case .diagnosticsExport(let value): try container.encode(value)
        case .eventsSubscribe(let value): try container.encode(value)
        }
    }
}

// MARK: - Typed response

public enum ControlResponse: Equatable, Sendable {
    case success(id: UInt64, result: ControlResult)
    case failure(id: UInt64, error: ControlErrorPayload)

    public var id: UInt64 {
        switch self {
        case .success(let id, _): id
        case .failure(let id, _): id
        }
    }

    /// `{"id":…,"result":…}` or `{"id":…,"error":…}`, via the encode-direction
    /// envelope mirrors `ControlWireProtocol.swift` declares.
    public func encoded() throws -> Data {
        switch self {
        case .success(let id, let result):
            try JSONEncoder().encode(ControlResponseEnvelope(id: id, result: result))
        case .failure(let id, let error):
            try JSONEncoder().encode(ControlResponseErrorEnvelope(id: id, error: error))
        }
    }
}

// MARK: - Dispatcher

/// Accepts a decoded request and returns an encodable response, plus a
/// separate event/snapshot stream (`subscribeToEvents()`) -- no transport
/// knowledge of any kind (D-06). One instance owns exactly one control
/// connection's `hello` state; a future transport constructs one dispatcher
/// per accepted connection.
@MainActor
public final class ControlChannelDispatcher {
    /// A request line longer than this is refused before any parse is
    /// attempted at all -- a decode-time denial-of-service guard.
    /// `nonisolated` because the pure, static `decode(_:)` below reads it
    /// with no `SessionModel` in scope at all.
    nonisolated public static let maxRequestLineBytes = 1 << 20

    private let sessionModel: SessionModel
    private var greeted = false

    public init(sessionModel: SessionModel) {
        self.sessionModel = sessionModel
    }

    // MARK: Two-phase decode

    /// Sniffs `{id, method}` first, then decodes the same bytes a second
    /// time into the concrete `Params` type `method` selects. Returning a
    /// `Result` (rather than throwing) keeps the id attached to a decode
    /// failure, which a thrown `DecodingError` has no way to carry.
    public nonisolated static func decode(_ line: Data) -> Result<ControlRequest, ControlDecodeFailure> {
        guard line.count <= maxRequestLineBytes else {
            return .failure(ControlDecodeFailure(
                id: 0,
                error: ControlErrorPayload(
                    .invalidParams,
                    message: "Request line of \(line.count) bytes exceeds the \(maxRequestLineBytes)-byte limit."
                )
            ))
        }
        guard let sniff = try? JSONDecoder().decode(ControlMethodSniff.self, from: line) else {
            return .failure(ControlDecodeFailure(
                id: 0,
                error: ControlErrorPayload(
                    .invalidParams,
                    message: "Request line is not a valid {id, method, params} envelope."
                )
            ))
        }

        func decoded<Params: Decodable>(
            _: Params.Type,
            _ build: (UInt64, Params) -> ControlRequest
        ) -> Result<ControlRequest, ControlDecodeFailure> {
            guard let envelope = try? JSONDecoder().decode(DecodedRequestEnvelope<Params>.self, from: line) else {
                return .failure(ControlDecodeFailure(
                    id: sniff.id,
                    error: ControlErrorPayload(
                        .invalidParams,
                        message: "Could not decode params for \"\(sniff.method)\"."
                    )
                ))
            }
            return .success(build(envelope.id, envelope.params))
        }

        switch sniff.method {
        case "hello": return decoded(ControlHelloParams.self) { .hello(id: $0, params: $1) }
        case "status": return decoded(EmptyParams.self) { id, _ in .status(id: id) }
        case "scanner.list": return decoded(EmptyParams.self) { id, _ in .scannerList(id: id) }
        case "scanner.rescan": return decoded(EmptyParams.self) { id, _ in .scannerRescan(id: id) }
        case "scanner.connect": return decoded(ControlScannerConnectParams.self) { .scannerConnect(id: $0, params: $1) }
        case "scanner.disconnect": return decoded(EmptyParams.self) { id, _ in .scannerDisconnect(id: id) }
        case "preview.acquire": return decoded(ControlPreviewAcquireParams.self) { .previewAcquire(id: $0, params: $1) }
        case "frames.list": return decoded(EmptyParams.self) { id, _ in .framesList(id: id) }
        case "frames.include": return decoded(ControlFrameSelectionParams.self) { .framesInclude(id: $0, params: $1) }
        case "frames.exclude": return decoded(ControlFrameSelectionParams.self) { .framesExclude(id: $0, params: $1) }
        case "review.approve": return decoded(ControlReviewApproveParams.self) { .reviewApprove(id: $0, params: $1) }
        case "settings.get": return decoded(EmptyParams.self) { id, _ in .settingsGet(id: id) }
        case "settings.set": return decoded(ControlSettingsSetParams.self) { .settingsSet(id: $0, params: $1) }
        case "outputs.get": return decoded(EmptyParams.self) { id, _ in .outputsGet(id: id) }
        case "outputs.set": return decoded(ControlOutputsSetParams.self) { .outputsSet(id: $0, params: $1) }
        case "roll.save": return decoded(ControlRollSaveParams.self) { .rollSave(id: $0, params: $1) }
        case "roll.open": return decoded(ControlRollOpenParams.self) { .rollOpen(id: $0, params: $1) }
        case "roll.list": return decoded(EmptyParams.self) { id, _ in .rollList(id: id) }
        case "scan.start": return decoded(ControlScanStartParams.self) { .scanStart(id: $0, params: $1) }
        case "scan.stop": return decoded(ControlScanStopParams.self) { .scanStop(id: $0, params: $1) }
        case "scan.resume": return decoded(ControlScanResumeParams.self) { .scanResume(id: $0, params: $1) }
        case "scanner.eject": return decoded(ControlScannerEjectParams.self) { .scannerEject(id: $0, params: $1) }
        case "diagnostics.export": return decoded(ControlDiagnosticsExportParams.self) { .diagnosticsExport(id: $0, params: $1) }
        case "events.subscribe": return decoded(EmptyParams.self) { id, _ in .eventsSubscribe(id: id) }
        case "job.get": return decoded(EmptyParams.self) { id, _ in .jobGet(id: id) }
        default:
            return .failure(ControlDecodeFailure(
                id: sniff.id,
                error: ControlErrorPayload(.unknownCommand, message: "Unknown control command \"\(sniff.method)\".")
            ))
        }
    }

    // MARK: Typed core

    /// The refusal preamble every request passes through, in this exact
    /// order -- each step returns before the next runs: hello/greeted,
    /// schema version, confirmation, busy, route. D-09: a refusal is
    /// returned once; nothing here waits, repeats, or re-issues anything.
    public func handle(_ request: ControlRequest) async -> ControlResponse {
        if case .hello(let id, let params) = request {
            return handleHello(id: id, params: params)
        }
        guard greeted else {
            return .failure(id: request.id, error: ControlErrorPayload(
                .helloRequired,
                message: "\"\(request.methodName)\" was refused: send \"hello\" first."
            ))
        }
        if let refusal = confirmationRefusal(for: request) {
            return refusal
        }
        if request.isMutating, let inFlight = sessionModel.mutatingOperationInFlight {
            return .failure(id: request.id, error: ControlErrorPayload(
                .controllerBusy,
                message: "\"\(request.methodName)\" was refused: \"\(inFlight)\" is already in flight.",
                guidance: inFlight
            ))
        }
        return await route(request)
    }

    /// A second `hello` on an already-greeted dispatcher is idempotent: it
    /// re-validates and returns the same result, rather than being refused
    /// by the `greeted` check above (which only applies to non-hello
    /// requests).
    private func handleHello(id: UInt64, params: ControlHelloParams) -> ControlResponse {
        guard params.schemaVersion == ControlSchema.version else {
            return .failure(id: id, error: ControlErrorPayload(
                .schemaVersionMismatch,
                message: "Client requested schema version \(params.schemaVersion); this app speaks schema version \(ControlSchema.version)."
            ))
        }
        greeted = true
        return .success(id: id, result: .hello(ControlHelloResult(
            schemaVersion: ControlSchema.version,
            appName: "ScanStudio"
        )))
    }

    /// D-08: a motion-capable command missing its confirmation flag is
    /// refused before any `SessionModel` call. `nil` and `false` are both
    /// unconfirmed -- only an explicit `true` clears this check.
    /// `review.approve` is included because it routes to
    /// `approvePendingManualReviewAndStart()`, which starts a scan; the
    /// method name alone does not advertise that.
    private func confirmationRefusal(for request: ControlRequest) -> ControlResponse? {
        switch request {
        case .previewAcquire(let id, let params):
            guard params.filmLoadedConfirmed == true else {
                return .failure(id: id, error: ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"preview.acquire\" requires filmLoadedConfirmed: true.",
                    guidance: "Confirm film is physically loaded, then resend with filmLoadedConfirmed: true."
                ))
            }
        case .scanStart(let id, let params):
            guard params.motionConfirmed == true else {
                return .failure(id: id, error: ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"scan.start\" requires motionConfirmed: true.",
                    guidance: "Confirm scanner motion is authorized, then resend with motionConfirmed: true."
                ))
            }
        case .scanResume(let id, let params):
            guard params.motionConfirmed == true else {
                return .failure(id: id, error: ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"scan.resume\" requires motionConfirmed: true.",
                    guidance: "Confirm scanner motion is authorized, then resend with motionConfirmed: true."
                ))
            }
        case .scannerEject(let id, let params):
            guard params.motionConfirmed == true else {
                return .failure(id: id, error: ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"scanner.eject\" requires motionConfirmed: true.",
                    guidance: "Confirm scanner motion is authorized, then resend with motionConfirmed: true."
                ))
            }
        case .reviewApprove(let id, let params):
            guard params.motionConfirmed == true else {
                return .failure(id: id, error: ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"review.approve\" requires motionConfirmed: true (it may start a scan).",
                    guidance: "Confirm scanner motion is authorized, then resend with motionConfirmed: true."
                ))
            }
        default:
            break
        }
        return nil
    }

    /// The routing switch. Only `.hello` is handled ahead of this function;
    /// every other case here is a deliberate placeholder until Tasks 2/3 of
    /// this plan and Plans 05/06 replace it with real routing.
    private func route(_ request: ControlRequest) async -> ControlResponse {
        switch request {
        case .hello:
            preconditionFailure("`.hello` is intercepted in handle(_:) before reaching route(_:).")
        case .status(let id):
            return .success(id: id, result: .status(buildStatusResult()))
        case .scannerList:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scannerRescan:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scannerConnect:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scannerDisconnect:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .previewAcquire:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .framesList(let id):
            return .success(id: id, result: .framesList(buildFramesListResult()))
        case .framesInclude:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .framesExclude:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .reviewApprove:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .settingsGet(let id):
            return .success(id: id, result: .settings(ControlSettingsResult(
                capture: sessionModel.captureRecipe,
                processing: sessionModel.processingRecipe
            )))
        case .settingsSet:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .outputsGet(let id):
            return .success(id: id, result: .outputs(ControlOutputsResult(outputs: sessionModel.outputRecipe)))
        case .outputsSet:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .rollSave:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .rollOpen:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .rollList:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scanStart:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scanStop:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scanResume:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .scannerEject:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .diagnosticsExport:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .eventsSubscribe:
            // Plan 05/06 replaces this arm
            return placeholder(request)
        case .jobGet(let id):
            return .success(id: id, result: .job(buildJobResult()))
        }
    }

    private func placeholder(_ request: ControlRequest) -> ControlResponse {
        .failure(id: request.id, error: ControlErrorPayload(
            .unknownCommand,
            message: "\"\(request.methodName)\" is not yet routed by this dispatcher build."
        ))
    }

    // MARK: GATE_REFUSED normalization

    /// Normalizes three of the four `GATE_REFUSED` sources RESEARCH
    /// Pitfall 8 lists (the fourth, live hardware motion, is
    /// `gateRefusal(motionReadiness:)` below): a non-ready scan-readiness
    /// decision, the transport's bare refeed-required flag (it carries no
    /// reason string of its own), and a scan paused on manual-boundary
    /// review. Plans 05/06 call this before routing a scan-adjacent
    /// mutating command; every value here is read verbatim from whatever
    /// `SessionModel` already reports, never re-derived.
    func gateRefusal(scanReadiness decision: ScanReadinessPolicy.Decision?) -> ControlErrorPayload? {
        if let decision, !decision.isReady {
            return ControlErrorPayload(
                .gateRefused,
                message: "Scan readiness refused (\(String(describing: decision))): \(decision.reason ?? "not ready").",
                guidance: decision.reason,
                gate: .scanReadiness
            )
        }
        if sessionModel.refeedRequired {
            return ControlErrorPayload(
                .gateRefused,
                message: "The transport needs a refeed before this command can proceed.",
                guidance: "Reload the film from the app, or resolve the refeed, then send the command again.",
                gate: .refeedRequired
            )
        }
        if sessionModel.pendingManualReviewScan != nil {
            return ControlErrorPayload(
                .gateRefused,
                message: "A scan is paused awaiting manual review of one or more frame boundaries.",
                guidance: "Resolve the pending manual review (for example review.approve) before scanning again.",
                gate: .manualReviewPending
            )
        }
        return nil
    }

    /// The fourth `GATE_REFUSED` source: live hardware motion readiness.
    func gateRefusal(motionReadiness readiness: HardwareMotionReadiness) -> ControlErrorPayload? {
        guard !readiness.allowsMotion else { return nil }
        return ControlErrorPayload(
            .gateRefused,
            message: "Hardware motion is not ready (\(String(describing: readiness))): \(readiness.guidance)",
            guidance: readiness.guidance,
            gate: .hardwareMotion
        )
    }

    // MARK: Read-only aggregates
    //
    // CTRL-03: no builder in this section may contain `await` or reach
    // `sessionModel`'s engine boundary -- every field comes from a
    // `SessionModel` public property. This is what makes a repeated
    // read-only call provably inert: it never reconnects, never re-arms
    // discovery, and never changes scanner or engine state.

    /// Built from `SessionModel` public state only; also the exact tracked
    /// read `subscribeToEvents()` observes (Task 3), so the set of
    /// properties this snapshot reports is exactly the set whose change
    /// wakes a subscriber -- one aggregate, no separate list to keep in
    /// sync. `hardwareMotionReadiness`/`scanReadiness` cross the wire as
    /// their case names (via `String(describing:)`, the same conversion
    /// for both) rather than leaking either enum itself.
    private func buildStatusResult() -> ControlStatusResult {
        let motion = sessionModel.hardwareMotionReadiness
        let readiness = sessionModel.scanReadiness(for: sessionModel.selectedFrames)
        return ControlStatusResult(
            device: sessionModel.device,
            scanner: sessionModel.status,
            projectName: sessionModel.project?.name,
            projectDirectory: sessionModel.projectDirectory,
            jobId: sessionModel.jobId,
            jobState: sessionModel.jobState,
            refeedRequired: sessionModel.refeedRequired,
            hardwareMotionReadiness: String(describing: motion),
            motionAllowed: motion.allowsMotion,
            motionGuidance: motion.guidance,
            mutatingOperationInFlight: sessionModel.mutatingOperationInFlight,
            selectedFrames: sessionModel.selectedFrames,
            scanReadiness: String(describing: readiness),
            scanReadinessReason: readiness.reason,
            lastErrorMessage: sessionModel.lastErrorMessage
        )
    }

    /// One `ControlFrameSummary` per frame of the open project -- an empty
    /// array when no project is open (a legitimate readable state, never an
    /// error). `errorCode` copies only the bare failure code string; T-01-05
    /// forbids copying any richer hardware-diagnostic payload alongside it.
    private func buildFramesListResult() -> ControlFramesListResult {
        let frames = (sessionModel.project?.frames ?? []).map { frame -> ControlFrameSummary in
            let index = frame.index
            return ControlFrameSummary(
                index: index,
                excluded: sessionModel.excludedFrameIndices.contains(index),
                selected: sessionModel.selectedFrameIndices.contains(index),
                hasThumbnail: sessionModel.thumbnails[index] != nil,
                state: sessionModel.frameStates[index]?.rawValue,
                manualReviewDecision: sessionModel.manualReviewDecisions[index].map(Self.manualReviewDecisionName),
                errorCode: sessionModel.frameErrors[index]?.code
            )
        }
        return ControlFramesListResult(frames: frames, selectedFrames: sessionModel.selectedFrames)
    }

    private static func manualReviewDecisionName(_ decision: ManualReviewDecision) -> String {
        switch decision {
        case .useFrameAnyway: "useFrameAnyway"
        case .dontScan: "dontScan"
        }
    }

    /// `receiptCount` rather than the receipts themselves: a receipt carries
    /// output file paths, and `job.get` is a status call, not an export.
    private func buildJobResult() -> ControlJobResult {
        let frameErrorCodes = Dictionary(
            uniqueKeysWithValues: sessionModel.frameErrors.map { (String($0.key), $0.value.code) }
        )
        return ControlJobResult(
            jobId: sessionModel.jobId,
            jobState: sessionModel.jobState,
            progress: sessionModel.progress.map(Self.mapScanProgress),
            completedFrameCount: sessionModel.completedFrameCount,
            pendingFrameCount: sessionModel.pendingFrameCount,
            receiptCount: sessionModel.receipts.count,
            frameErrorCodes: frameErrorCodes
        )
    }

    private static func mapScanProgress(_ progress: SessionModel.ScanProgress) -> ControlScanProgress {
        ControlScanProgress(
            jobId: progress.jobId,
            frameIndex: progress.frameIndex,
            frameOrdinal: progress.frameOrdinal,
            totalFrames: progress.totalFrames,
            pass: progress.pass,
            totalPasses: progress.totalPasses,
            framePercent: progress.framePercent,
            jobPercent: progress.jobPercent,
            etaSeconds: progress.etaSeconds
        )
    }

    // MARK: Line-based entry point

    /// Composes `decode` and `handle` and encodes the result -- the single
    /// call a future transport makes per request line. Never throws, never
    /// crashes: an encode failure falls back to a hand-built minimal
    /// `INVALID_PARAMS` line.
    public func handleLine(_ line: Data) async -> Data {
        let response: ControlResponse
        switch Self.decode(line) {
        case .success(let request):
            response = await handle(request)
        case .failure(let failure):
            response = .failure(id: failure.id, error: failure.error)
        }
        if let data = try? response.encoded() {
            return data
        }
        return Self.fallbackInvalidParamsLine(id: response.id)
    }

    private static func fallbackInvalidParamsLine(id: UInt64) -> Data {
        Data(
            #"{"id":\#(id),"error":{"code":"INVALID_PARAMS","message":"Failed to encode the response.","recoverable":false}}"#
                .utf8
        )
    }
}
