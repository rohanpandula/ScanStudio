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
// Plan 04 built this preamble plus the five read-only aggregate commands
// (`status`, `frames.list`, `settings.get`, `outputs.get`, `job.get`) and
// `events.subscribe`; Plans 05 and 06 routed the remaining nineteen D-05
// commands on top of that preamble. Every one of the 25 D-05 commands is
// now routed -- D-05.

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
    case scannerRefresh(id: UInt64)
    case scannerConnect(id: UInt64, params: ControlScannerConnectParams)
    case scannerDisconnect(id: UInt64)
    case previewAcquire(id: UInt64, params: ControlPreviewAcquireParams)
    case framesList(id: UInt64)
    case framesSelect(id: UInt64, params: ControlFramesSelectParams)
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
    case jobGet(id: UInt64, params: ControlJobGetParams)
    /// D-23/HEAD-12: dismisses a pending manual review without starting
    /// motion, without approving anything, and without clearing
    /// `selectedFrameIndices`. No confirmation field: it authorizes no
    /// motion, so `confirmationRefusal(for:)` deliberately has no entry
    /// for it (T-03-44).
    case reviewCancel(id: UInt64)
}

extension ControlRequest {
    public var id: UInt64 {
        switch self {
        case .hello(let id, _): id
        case .status(let id): id
        case .scannerList(let id): id
        case .scannerRescan(let id): id
        case .scannerRefresh(let id): id
        case .scannerConnect(let id, _): id
        case .scannerDisconnect(let id): id
        case .previewAcquire(let id, _): id
        case .framesList(let id): id
        case .framesSelect(let id, _): id
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
        case .jobGet(let id, _): id
        case .reviewCancel(let id): id
        }
    }

    /// The exact D-05 wire name -- what a control caller sent as `method`.
    public var methodName: String {
        switch self {
        case .hello: "hello"
        case .status: "status"
        case .scannerList: "scanner.list"
        case .scannerRescan: "scanner.rescan"
        case .scannerRefresh: "scanner.refresh"
        case .scannerConnect: "scanner.connect"
        case .scannerDisconnect: "scanner.disconnect"
        case .previewAcquire: "preview.acquire"
        case .framesList: "frames.list"
        case .framesSelect: "frames.select"
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
        case .reviewCancel: "review.cancel"
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
        case .scannerList, .scannerRescan, .scannerRefresh, .scannerConnect, .scannerDisconnect,
             .previewAcquire, .framesSelect, .framesInclude, .framesExclude, .reviewApprove,
             .settingsSet, .outputsSet, .rollSave, .rollOpen, .rollList,
             .scanStart, .scanStop, .scanResume, .scannerEject, .reviewCancel:
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
    case scannerRefresh(ControlScannerRefreshResult)
    case scannerConnect(ControlScannerConnectResult)
    case rollList(ControlRollListResult)
    case rollSave(ControlRollSaveResult)
    case previewAcquire(ControlPreviewAcquireResult)
    case diagnosticsExport(ControlDiagnosticsExportResult)
    case eventsSubscribe(ControlEventsSubscribeResult)
    case scanOutcome(ControlScanOutcomeResult)

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
        case .scannerRefresh(let value): try container.encode(value)
        case .scannerConnect(let value): try container.encode(value)
        case .rollList(let value): try container.encode(value)
        case .rollSave(let value): try container.encode(value)
        case .previewAcquire(let value): try container.encode(value)
        case .diagnosticsExport(let value): try container.encode(value)
        case .eventsSubscribe(let value): try container.encode(value)
        case .scanOutcome(let value): try container.encode(value)
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
    /// Subscriptions `subscribeToEvents()` still owns. `onTermination`
    /// removes a subscription's id here so a dropped subscriber's observer
    /// chain stops re-arming instead of running for the process lifetime
    /// (T-01-15).
    private var activeEventSubscriptions: Set<UUID> = []

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
        case "scanner.refresh": return decoded(EmptyParams.self) { id, _ in .scannerRefresh(id: id) }
        case "scanner.connect": return decoded(ControlScannerConnectParams.self) { .scannerConnect(id: $0, params: $1) }
        case "scanner.disconnect": return decoded(EmptyParams.self) { id, _ in .scannerDisconnect(id: id) }
        case "preview.acquire": return decoded(ControlPreviewAcquireParams.self) { .previewAcquire(id: $0, params: $1) }
        case "frames.list": return decoded(EmptyParams.self) { id, _ in .framesList(id: id) }
        case "frames.select": return decoded(ControlFramesSelectParams.self) { .framesSelect(id: $0, params: $1) }
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
        case "job.get": return decoded(ControlJobGetParams.self) { .jobGet(id: $0, params: $1) }
        case "review.cancel": return decoded(EmptyParams.self) { id, _ in .reviewCancel(id: id) }
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
    ///
    /// SAFE-04 (Gap 2 fix): every `.failure` this function (or anything it
    /// calls, including `route(_:)`) produces is recorded on the shared
    /// `SessionModel` via `recordControlRefusal` before returning -- one
    /// choke point rather than a write scattered across every individual
    /// refusal site, so `CONFIRMATION_REQUIRED`, `GATE_REFUSED`,
    /// `CONTROLLER_BUSY`, `INVALID_PARAMS`, `SCHEMA_VERSION_MISMATCH`, and
    /// `HELLO_REQUIRED` all become an `@Observable` write every subscriber's
    /// `control.changed` picks up, not only the refused connection's own
    /// direct RPC response. `handleLine(_:)`'s decode-failure branch is the
    /// other choke point, for the two codes (`UNKNOWN_COMMAND`, and
    /// `INVALID_PARAMS` for a line that never became a typed `ControlRequest`
    /// at all) that never reach this function.
    public func handle(_ request: ControlRequest) async -> ControlResponse {
        let response = await handleAndRoute(request)
        if case .failure(_, let error) = response {
            sessionModel.recordControlRefusal(command: request.methodName, code: error.code, gate: error.gate)
        }
        return response
    }

    private func handleAndRoute(_ request: ControlRequest) async -> ControlResponse {
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
        case .rollSave(let id, let params):
            guard params.motionConfirmed == true else {
                return .failure(id: id, error: ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"roll.save\" requires motionConfirmed: true (it creates the project and starts the scan).",
                    guidance: "Confirm scanner motion is authorized, then resend with motionConfirmed: true."
                ))
            }
        default:
            break
        }
        return nil
    }

    /// The routing switch. Only `.hello` is handled ahead of this function;
    /// every other one of the 25 D-05 commands has a real routing arm here.
    private func route(_ request: ControlRequest) async -> ControlResponse {
        switch request {
        case .hello:
            preconditionFailure("`.hello` is intercepted in handle(_:) before reaching route(_:).")
        case .status(let id):
            return .success(id: id, result: .status(buildStatusResult()))
        case .scannerList(let id):
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.refreshAvailableDevices(rescan: false)
            return scannerListResponse(id: id, errorMessageBefore: errorMessageBefore)
        case .scannerRescan(let id):
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.refreshAvailableDevices(rescan: true)
            return scannerListResponse(id: id, errorMessageBefore: errorMessageBefore)
        case .scannerRefresh(let id):
            // D-11: a live, non-motion status re-read through the exact
            // method `HardwareMotionReadinessView`'s own refresh button
            // calls -- no second status path. `refreshScannerStatus()`
            // already handles a lost session via `invalidateConnection`
            // (SessionModel.swift), so a `nil` `scanner` here is an honest
            // "the refresh found nothing," not a decode gap.
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.refreshScannerStatus()
            return scannerRefreshResponse(id: id, errorMessageBefore: errorMessageBefore)
        case .scannerConnect(let id, let params):
            // A `nil` `deviceId` is legitimate: it means "let
            // `DeviceSelectionPolicy` resolve the target", the same as the
            // GUI's own no-argument connect.
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.connect(deviceId: params.deviceId)
            switch outcome(id: id, errorMessageBefore: errorMessageBefore) {
            case .success:
                // D-16: `alreadyConnected` reflects this exact connect's
                // own outcome (`SessionModel.connect` clears it at the top
                // of every call), never a stale value from an earlier one.
                return .success(id: id, result: .scannerConnect(
                    ControlScannerConnectResult(alreadyConnected: sessionModel.lastConnectAlreadyConnected)
                ))
            case .failure(let failureId, let error):
                return .failure(id: failureId, error: error)
            }
        case .scannerDisconnect(let id):
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.disconnect()
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .previewAcquire(let id, let params):
            // The confirmation check already ran in the preamble above, so
            // `filmLoadedConfirmed == true` is guaranteed here. This is the
            // GUI's own gate (`ScanPanelView.canAcquireThumbnails`'s motion
            // component) mirrored directly.
            guard sessionModel.hardwareMotionReadiness.allowsMotion else {
                return .failure(id: id, error: gateRefusal(motionReadiness: sessionModel.hardwareMotionReadiness)
                    ?? ControlErrorPayload(.gateRefused, message: "Hardware motion is not ready.", gate: .hardwareMotion))
            }
            let token = PreviewIntentToken()
            let intent: PreviewIntent
            switch params.intent ?? "initial" {
            case "initial":
                intent = .initial(token: token)
            case "refreshSavedProject":
                intent = .refreshSavedProject(token: token)
            case "replaceFilmProcess":
                guard let filmProcess = params.filmProcess else {
                    return .failure(id: id, error: ControlErrorPayload(
                        .invalidParams,
                        message: "\"preview.acquire\" with intent \"replaceFilmProcess\" requires filmProcess."
                    ))
                }
                intent = .replaceFilmProcess(token: token, filmProcess: filmProcess)
            default:
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "Unknown preview.acquire intent \"\(params.intent ?? "initial")\"."
                ))
            }
            // A `.rejected`/`.failedToStart` outcome is still a *success*
            // response here: the request was accepted and answered
            // definitively, and the caller reads `outcome` to see which of
            // the three occurred. The one place in this phase where a
            // non-`.started` `PreviewRequestOutcome` is not a failure
            // response.
            let requestOutcome = await sessionModel.requestPreview(intent)
            return .success(id: id, result: .previewAcquire(ControlPreviewAcquireResult(
                outcome: String(describing: requestOutcome),
                intentToken: token.id.uuidString
            )))
        case .framesList(let id):
            return .success(id: id, result: .framesList(buildFramesListResult()))
        case .framesSelect(let id, let params):
            // CR-02: unblocks the cold-start `connect -> preview -> save`
            // flow for a caller with no GUI ever driven -- see
            // `SessionModel.setFrameSelection(_:)`'s own doc comment. Shape
            // first (exactly one of the three), then the two typed
            // refusals a caller can hit, then apply.
            let chosen = [params.indices != nil, params.all == true, params.none == true].filter { $0 }.count
            guard chosen == 1 else {
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "\"frames.select\" requires exactly one of indices, all, or none."
                ))
            }
            if let refusal = jobActiveBusyRefusal(method: "frames.select") {
                return .failure(id: id, error: refusal)
            }
            // D-23/HEAD-12 (CF-12, the 2026-09-07 batch abort): lifting the
            // blanket "a project already exists" refusal in favor of
            // project-aware validation -- a project-mode caller could
            // otherwise never re-select frames after a failed batch
            // without `frames.include`/`frames.exclude`'s one-at-a-time
            // shape. `ScanReadinessPolicy.allTargetsAreStructurallyValid`
            // remains the independent second layer refusing a scan whose
            // target set contains an excluded frame (T-03-45): neither
            // layer substitutes for the other.
            if let project = sessionModel.project {
                let excludedSet = sessionModel.excludedFrameIndices
                func isCompleted(_ index: Int) -> Bool {
                    sessionModel.frameStates[index] == .completed
                        || project.frames.first { $0.index == index }?.receipts.isEmpty == false
                }
                if let indices = params.indices {
                    let projectIndices = Set(project.frames.map(\.index))
                    let offending = indices.filter {
                        !projectIndices.contains($0) || excludedSet.contains($0) || isCompleted($0)
                    }
                    guard offending.isEmpty else {
                        return .failure(id: id, error: ControlErrorPayload(
                            .invalidParams,
                            message: "\"frames.select\" refuses out-of-range, excluded, or already-completed indices: \(offending.sorted())."
                        ))
                    }
                    guard sessionModel.setFrameSelection(indices) else {
                        return .failure(id: id, error: ControlErrorPayload(
                            .invalidParams,
                            message: "\"frames.select\" could not apply the requested selection."
                        ))
                    }
                } else if params.all == true {
                    // Every project frame that is neither excluded nor
                    // already completed -- re-selecting durable work or an
                    // operator-excluded frame into the next scan is never
                    // what --all means.
                    let targets = project.frames.map(\.index).filter {
                        !excludedSet.contains($0) && !isCompleted($0)
                    }
                    guard sessionModel.setFrameSelection(targets) else {
                        return .failure(id: id, error: ControlErrorPayload(
                            .invalidParams,
                            message: "\"frames.select\" could not apply --all."
                        ))
                    }
                } else {
                    sessionModel.clearFrameSelection()
                }
                return .success(id: id, result: .empty(ControlEmptyResult()))
            }
            // Pre-project path (CR-02), unchanged: validated against the
            // previewed frame count, since no project exists yet.
            if let indices = params.indices {
                if let error = validatedFrameSelectionIndices(indices, method: "frames.select") {
                    return .failure(id: id, error: error)
                }
                guard sessionModel.setFrameSelection(indices) else {
                    return .failure(id: id, error: ControlErrorPayload(
                        .invalidParams,
                        message: "\"frames.select\" could not apply the requested selection."
                    ))
                }
            } else if params.all == true {
                sessionModel.selectAllFrames()
            } else {
                sessionModel.clearFrameSelection()
            }
            return .success(id: id, result: .empty(ControlEmptyResult()))
        case .framesInclude(let id, let params):
            if let error = validatedFrameIndex(params.frameIndex, method: request.methodName) {
                return .failure(id: id, error: error)
            }
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.setFrameExcluded(params.frameIndex, excluded: false)
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .framesExclude(let id, let params):
            if let error = validatedFrameIndex(params.frameIndex, method: request.methodName) {
                return .failure(id: id, error: error)
            }
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.setFrameExcluded(params.frameIndex, excluded: true)
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .reviewApprove(let id, _):
            // Confirmation already checked in the preamble above.
            // `approvePendingManualReviewAndStart()` returns silently (no
            // `lastErrorMessage`) when nothing is pending -- pre-checking
            // here is RESEARCH Pitfall 1's silent-no-op-to-typed-refusal
            // translation, so "approved" can never be confused with "there
            // was nothing to approve".
            guard sessionModel.pendingManualReviewScan != nil else {
                return .failure(id: id, error: ControlErrorPayload(
                    .gateRefused,
                    message: "\"review.approve\" was refused: no manual review is awaiting approval.",
                    guidance: "There is no pending manual review to approve.",
                    gate: .manualReviewPending
                ))
            }
            // Attended-scan-recovery approval (`approveEveryFrameAndScan()`,
            // the path behind `ContentView.swift:571`) is deliberately NOT
            // routed here. It approves every frame against a different
            // confirmation contract and needs its own D-05 command name --
            // Phase 2 / CLI-05 work. Do not add it to this arm.
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.approvePendingManualReviewAndStart()
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .settingsGet(let id):
            return .success(id: id, result: .settings(ControlSettingsResult(
                capture: sessionModel.captureRecipe,
                processing: sessionModel.processingRecipe
            )))
        case .settingsSet(let id, let params):
            if let refusal = jobActiveBusyRefusal(method: "settings.set") {
                return .failure(id: id, error: refusal)
            }
            // No individual settings field is written from the dispatcher --
            // this is the one D-04 fallback entry point Plan 03 added.
            sessionModel.applySettingsRecipes(capture: params.capture, processing: params.processing)
            return .success(id: id, result: .empty(ControlEmptyResult()))
        case .outputsGet(let id):
            return .success(id: id, result: .outputs(ControlOutputsResult(outputs: sessionModel.outputRecipe)))
        case .outputsSet(let id, let params):
            if let refusal = jobActiveBusyRefusal(method: "outputs.set") {
                return .failure(id: id, error: refusal)
            }
            // Delegates to the same private `applyRecipes(_:)` path
            // `openProject(directory:)` already uses -- no individual output
            // field is written from the dispatcher.
            sessionModel.applyOutputRecipe(params.outputs)
            return .success(id: id, result: .empty(ControlEmptyResult()))
        case .rollSave(let id, let params):
            // `saveRollAndScanSelectedFrames` sets `lastErrorMessage` on
            // both its synchronous refusal branches (`project != nil`,
            // `selectedFrames.isEmpty`) before its own busy flag would even
            // apply, so the shared `outcome` helper still produces a typed
            // refusal carrying the model's own explanation for either one.
            let errorMessageBefore = sessionModel.lastErrorMessage
            let saved = await sessionModel.saveRollAndScanSelectedFrames(name: params.name, carrier: params.carrier, frameCount: params.frameCount, filmProcess: params.filmProcess)
            guard saved else {
                return outcome(id: id, errorMessageBefore: errorMessageBefore)
            }
            // `ScanProject` has no `directory` field -- the resolved
            // directory lives on `SessionModel.projectDirectory`, a
            // separate property `createProject`/`openProject` both set.
            //
            // D-13/HEAD-07: `saveRollAndScanSelectedFrames`'s own `return
            // started || pendingManualReviewScan?.frames == requestedFrames`
            // line is why a bare `true` here cannot tell "the scan started"
            // apart from "a flagged frame paused it at the boundary-review
            // gate" -- reading `pendingManualReviewScan` back out (mirroring
            // that same equality the model used internally) recovers the
            // distinction. `"failed"` therefore never comes from this
            // branch at all: it is reserved for a save that created the
            // project and then failed to start scanning for a reason that
            // is neither an outright refusal (already handled by
            // `outcome(id:errorMessageBefore:)` above) nor a pending review
            // -- not reachable from today's `SessionModel`, but D-13's own
            // three-value contract gives a future such case somewhere
            // honest to report it.
            let isPendingReview = sessionModel.pendingManualReviewScan?.frames == sessionModel.selectedFrames
            return .success(id: id, result: .rollSave(ControlRollSaveResult(
                saved: true,
                projectName: sessionModel.project?.name,
                projectDirectory: sessionModel.projectDirectory,
                outcome: isPendingReview ? "manualReviewPending" : "started"
            )))
        case .rollOpen(let id, let params):
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.openProject(directory: params.directory)
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .rollList(let id):
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.refreshRecentProjects()
            switch outcome(id: id, errorMessageBefore: errorMessageBefore) {
            case .success:
                return .success(id: id, result: .rollList(ControlRollListResult(
                    projects: sessionModel.recentProjects.map(Self.mapProjectSummary)
                )))
            case .failure(let failureId, let error):
                return .failure(id: failureId, error: error)
            }
        case .scanStart(let id, _):
            // Confirmation already checked in the preamble. This is
            // verbatim the expression `ScanPanelView.swift` computes for
            // its own Scan button's `.disabled` binding.
            let decision = sessionModel.scanReadiness(for: sessionModel.selectedFrames)
            if let refusal = gateRefusal(scanReadiness: decision) {
                return .failure(id: id, error: refusal)
            }
            let errorMessageBefore = sessionModel.lastErrorMessage
            let requestedFrames = sessionModel.selectedFrames
            // RESEARCH Pitfall 4: `startMockScan()` is the real GUI Scan
            // button entry point for both real and simulated devices. Route
            // here and nowhere else -- a second "real" scan-start method
            // would duplicate its manual-review branching, exactly what
            // D-04 forbids.
            await sessionModel.startMockScan()
            return scanOutcomeResponse(id: id, errorMessageBefore: errorMessageBefore, requestedFrames: requestedFrames)
        case .scanStop(let id, let params):
            let mode: String
            switch params.mode ?? "afterCurrentFrame" {
            case "afterCurrentFrame", "immediate":
                mode = params.mode ?? "afterCurrentFrame"
            default:
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "Unknown scan.stop mode \"\(params.mode ?? "")\"."
                ))
            }
            // `stopAfterCurrentFrame()`/`stopImmediately()` both return
            // silently from a `guard let jobId` when no job is active (a
            // data precondition, not a reentrancy guard) -- pre-checking
            // here is RESEARCH Pitfall 1's silent-no-op-to-typed-refusal
            // translation, so "nothing to stop" is never indistinguishable
            // from "stopped".
            guard sessionModel.jobId != nil else {
                return .failure(id: id, error: ControlErrorPayload(
                    .gateRefused,
                    message: "\"scan.stop\" was refused: no job is active.",
                    guidance: "There is no active job to stop."
                ))
            }
            let errorMessageBefore = sessionModel.lastErrorMessage
            if mode == "immediate" {
                await sessionModel.stopImmediately()
            } else {
                await sessionModel.stopAfterCurrentFrame()
            }
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .scanResume(let id, _):
            // D-22/HEAD-12 (CF-12/CF-13, the 2026-09-07 batch abort): reads
            // the engine's authoritative pendingFrames before evaluating
            // readiness, not the cache -- excluding a frame after a failed
            // batch must never brick Resume until something else happens to
            // refresh it. `resumeBatch()` below performs its own second
            // refresh and re-verification (T-03-53): this pre-check exists
            // to give the caller a typed refusal, not to be the gate.
            await sessionModel.refreshPendingFrames()
            // Confirmation already checked. Mirrors `ScanPanelView.swift`'s
            // own Resume Batch `.disabled` binding.
            let decision = sessionModel.scanReadiness(for: sessionModel.pendingFrames)
            if let refusal = gateRefusal(scanReadiness: decision) {
                return .failure(id: id, error: refusal)
            }
            // `resumeBatch()`'s own guard additionally reads three
            // `private var` flags (`pendingScanStart`,
            // `pendingManualReviewApproval`, `pendingAttendedScanApproval`)
            // this dispatcher cannot see and must not attempt to read
            // (RESEARCH: architecturally invisible outside
            // SessionModel.swift) -- this pre-check plus that inner guard
            // is the complete story; a silent no-op from the inner guard is
            // reported as success, and the caller can distinguish it via
            // `job.get`.
            let errorMessageBefore = sessionModel.lastErrorMessage
            // Captured before the call: `resumeBatch()` sets
            // `selectedFrameIndices = Set(pendingFrames)` itself, so this
            // is the frame set the operator's resume actually targets.
            let requestedFrames = sessionModel.pendingFrames
            await sessionModel.resumeBatch()
            return scanOutcomeResponse(id: id, errorMessageBefore: errorMessageBefore, requestedFrames: requestedFrames)
        case .scannerEject(let id, _):
            // The confirmation check already ran in the preamble above.
            guard sessionModel.hardwareMotionReadiness.allowsMotion else {
                return .failure(id: id, error: gateRefusal(motionReadiness: sessionModel.hardwareMotionReadiness)
                    ?? ControlErrorPayload(.gateRefused, message: "Hardware motion is not ready.", gate: .hardwareMotion))
            }
            // CR-02: the GUI's Eject button is only ever rendered when
            // `DeviceBarView.canOfferEject` is true -- the identical
            // `DeviceBarEjectPolicy.canOffer` call below, fed the same
            // isConnected/transportIsIdle/isJobActive/mediaLoaded/
            // filmPresent/refeedRequired inputs `DeviceBarView` reads off
            // `SessionModel`. Previously this arm (and `eject()` itself)
            // checked only `hardwareMotionReadiness.allowsMotion`, so a
            // caller could eject while disconnected, mid-job, or mid-
            // transport-activity -- states the GUI never even offers the
            // button for.
            guard DeviceBarEjectPolicy.canOffer(
                isConnected: sessionModel.status?.connected == true,
                transportIsIdle: (sessionModel.status?.transport ?? "idle") == "idle" && !sessionModel.isAcquiringThumbnails,
                isJobActive: sessionModel.isJobActive,
                mediaLoaded: sessionModel.status?.mediaLoaded == true,
                filmPresent: sessionModel.status?.filmPresent,
                refeedRequired: sessionModel.refeedRequired,
                lastErrorMessage: sessionModel.lastErrorMessage
            ) else {
                return .failure(id: id, error: ControlErrorPayload(
                    .gateRefused,
                    message: "\"scanner.eject\" was refused: the scanner must be connected, idle, and not mid-job, with film to release.",
                    guidance: "Connect the scanner and wait for the current job or transport activity to finish before ejecting."
                ))
            }
            // `SessionModel.eject()` re-checks `hardwareMotionReadiness` and
            // this identical `DeviceBarEjectPolicy.canOffer` gate internally
            // -- this is D-08's defence in depth, not redundancy: this
            // pre-check gives the caller a typed refusal, and the model's
            // own guard is what makes the gate impossible to bypass from
            // any caller, including a future one that forgets to pre-check
            // here.
            let errorMessageBefore = sessionModel.lastErrorMessage
            await sessionModel.eject()
            return outcome(id: id, errorMessageBefore: errorMessageBefore)
        case .diagnosticsExport(let id, let params):
            // T-01-20: `params.directory` is a caller-controlled write
            // destination crossing a trust boundary -- this is the only
            // filesystem-write primitive the Phase 1 channel exposes.
            // Every condition below is checked before any write, and the
            // filename itself is dispatcher-generated, never caller-
            // supplied, so a caller can never choose what gets overwritten.
            guard params.directory.hasPrefix("/") else {
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "\"diagnostics.export\" directory \"\(params.directory)\" must be an absolute path."
                ))
            }
            guard !params.directory.split(separator: "/").contains("..") else {
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "\"diagnostics.export\" directory \"\(params.directory)\" must not contain \"..\" path components."
                ))
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: params.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "\"diagnostics.export\" directory \"\(params.directory)\" does not exist."
                ))
            }
            // Film bytes require exact per-export consent, and the control
            // channel has no consent affordance in Phase 1 -- always
            // `previewConsent: nil` (T-01-05).
            let entries = sessionModel.diagnosticBundleEntryNames(previewConsent: nil)
            let data = sessionModel.makeDiagnosticBundleData(previewConsent: nil)
            let url = URL(fileURLWithPath: params.directory)
                .appendingPathComponent(Self.diagnosticBundleFilename())
            do {
                try DiagnosticBundleFileWriter.write(data, to: url)
            } catch {
                return .failure(id: id, error: ControlErrorPayload(
                    .invalidParams,
                    message: "\"diagnostics.export\" failed: \(error.localizedDescription)"
                ))
            }
            return .success(id: id, result: .diagnosticsExport(ControlDiagnosticsExportResult(
                path: url.path,
                entries: entries
            )))
        case .eventsSubscribe(let id):
            return .success(id: id, result: .eventsSubscribe(ControlEventsSubscribeResult(
                subscribed: true,
                snapshot: buildStatusResult()
            )))
        case .jobGet(let id, let params):
            // D-19/HEAD-12 (the 2026-09-07 batch abort): no jobId keeps the
            // historical "the job this session is currently tracking"
            // behavior byte-for-byte. A jobId matching the live job is the
            // identical answer under a different name. Only a jobId this
            // process genuinely never tracked (neither live nor in the last
            // `SessionModel.maximumTerminalJobHistory` archived jobs) is
            // `JOB_NOT_FOUND` -- a job that finished seconds ago must not
            // read as unknown.
            guard let requestedJobId = params.jobId else {
                return .success(id: id, result: .job(buildJobResult()))
            }
            if let liveJobId = sessionModel.jobId, liveJobId == requestedJobId {
                return .success(id: id, result: .job(buildJobResult()))
            }
            if let archived = sessionModel.terminalJob(id: requestedJobId) {
                return .success(id: id, result: .job(buildJobResult(from: archived)))
            }
            return .failure(id: id, error: ControlErrorPayload(
                code: "JOB_NOT_FOUND",
                message: "No job with id \"\(requestedJobId)\" is tracked by this host.",
                recoverable: false
            ))
        case .reviewCancel(let id):
            // D-23/HEAD-12 (CF-10/CF-11, the 2026-09-07 batch abort):
            // mirrors `.reviewApprove`'s own silent-no-op-to-typed-refusal
            // translation (RESEARCH Pitfall 1) -- `cancelPendingManualReviewScan()`
            // returns silently when nothing is pending, so pre-checking
            // here means "cancelled" can never be confused with "there was
            // nothing to cancel". Routes only to that one method: no
            // confirmation, no approval path, no selection mutation (T-03-44).
            guard sessionModel.pendingManualReviewScan != nil else {
                return .failure(id: id, error: ControlErrorPayload(
                    .gateRefused,
                    message: "\"review.cancel\" was refused: no manual review is awaiting approval.",
                    guidance: "There is no pending manual review to cancel.",
                    gate: .manualReviewPending
                ))
            }
            sessionModel.cancelPendingManualReviewScan()
            return .success(id: id, result: .empty(ControlEmptyResult()))
        }
    }

    // MARK: Device discovery (scanner.list / scanner.rescan)

    /// Shared by `.scannerList`/`.scannerRescan` after each has already
    /// called its own literal `refreshAvailableDevices(rescan:)` -- the two
    /// commands share one method call and differ only in that argument
    /// (mirroring the GUI exactly, D-04); this only wraps the outcome.
    private func scannerListResponse(id: UInt64, errorMessageBefore: String?) -> ControlResponse {
        switch outcome(id: id, errorMessageBefore: errorMessageBefore) {
        case .success:
            return .success(id: id, result: .scannerList(
                ControlScannerListResult(devices: sessionModel.availableDevices)
            ))
        case .failure(let failureId, let error):
            return .failure(id: failureId, error: error)
        }
    }

    /// Shared by `.scannerRefresh` after it has already called
    /// `refreshScannerStatus()` -- same success/failure split as
    /// `scannerListResponse` above, wrapping the model's post-refresh
    /// `status` (D-11) instead of `availableDevices`.
    private func scannerRefreshResponse(id: UInt64, errorMessageBefore: String?) -> ControlResponse {
        switch outcome(id: id, errorMessageBefore: errorMessageBefore) {
        case .success:
            return .success(id: id, result: .scannerRefresh(
                ControlScannerRefreshResult(scanner: sessionModel.status)
            ))
        case .failure(let failureId, let error):
            return .failure(id: failureId, error: error)
        }
    }

    // MARK: Outcome translation (shared by every mutating arm, Plans 05/06)

    /// Turns "what happened during the routed call" into a typed response.
    /// Compares `sessionModel.lastErrorMessage` against the value captured
    /// immediately before the call -- never inferred from a return value or
    /// an unchanged state (RESEARCH Pitfall 1: pre-check, then call, then
    /// compare). Unchanged means success; a new, non-nil message means the
    /// call reported a failure through the model's existing
    /// `lastErrorMessage`/`Self.describe` path.
    ///
    /// A message with a leading `"CODE: "` engine-shaped prefix (the exact
    /// form `SessionModel.describe` writes for an `EngineRequestError`)
    /// recovers that code verbatim per D-03. Anything else is an app-level
    /// precondition refusal (for example "This roll is already saved.")
    /// reported as `GATE_REFUSED` with no `gate` -- a present `gate` names
    /// one of the four physical gates (`ControlGate`); an absent `gate`
    /// means an app-level precondition. Plan 06 and Phase 2 keep this rule.
    ///
    /// `recoverable` is now the engine's own flag, read off
    /// `sessionModel.lastEngineError` (OUT-03) -- the code-match guard below
    /// is what stops a stale retained payload from being misattributed to a
    /// textually similar later failure.
    private func outcome(id: UInt64, errorMessageBefore: String?) -> ControlResponse {
        guard let message = sessionModel.lastErrorMessage, message != errorMessageBefore else {
            return .success(id: id, result: .empty(ControlEmptyResult()))
        }
        if let prefix = Self.parseEngineCodePrefix(message) {
            let recoverable = sessionModel.lastEngineError?.code == prefix.code
                ? sessionModel.lastEngineError?.recoverable ?? false
                : false
            return .failure(id: id, error: ControlErrorPayload(
                code: prefix.code, message: prefix.remainder, recoverable: recoverable
            ))
        }
        return .failure(id: id, error: ControlErrorPayload(.gateRefused, message: message, guidance: message))
    }

    /// D-23/HEAD-12: shared by `.scanStart`/`.scanResume` after each has
    /// already called the exact `SessionModel` method the GUI's own
    /// Scan/Resume button calls. `outcome(id:errorMessageBefore:)`'s
    /// `.success` covers both "the scan actually started" and "a flagged
    /// boundary paused it for review" -- reading `pendingManualReviewScan`
    /// back out (mirroring `roll.save`'s own D-13 precedent exactly)
    /// recovers the distinction a bare success cannot. `requestedFrames`
    /// is the frame set captured *before* the call, since `resumeBatch()`
    /// mutates `selectedFrameIndices` itself. Never `"failed"`: a failure
    /// is the `.failure` branch below, not a success carrying one.
    private func scanOutcomeResponse(
        id: UInt64, errorMessageBefore: String?, requestedFrames: [Int]
    ) -> ControlResponse {
        switch outcome(id: id, errorMessageBefore: errorMessageBefore) {
        case .success:
            let isPendingReview = sessionModel.pendingManualReviewScan?.frames == requestedFrames
            return .success(id: id, result: .scanOutcome(ControlScanOutcomeResult(
                outcome: isPendingReview ? "manualReviewPending" : "started"
            )))
        case .failure(let failureId, let error):
            return .failure(id: failureId, error: error)
        }
    }

    /// Recovers a leading `[A-Z][A-Z0-9_]*` run followed by `": "` -- the
    /// exact shape `SessionModel.describe(_:)` writes for an
    /// `EngineRequestError` (`"\(code): \(message)"`, see
    /// `WireProtocol.swift`). `nonisolated`, like `decode(_:)` above: a pure
    /// string parse with no `SessionModel` in scope. Not `private` so a unit
    /// test can exercise the parse directly, independent of driving
    /// `SessionModel` into a failure state.
    nonisolated static func parseEngineCodePrefix(_ message: String) -> (code: String, remainder: String)? {
        guard let colonRange = message.range(of: ": ") else { return nil }
        let candidate = message[message.startIndex..<colonRange.lowerBound]
        guard let first = candidate.first, first.isUppercase, first.isLetter,
              candidate.allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber || $0 == "_" })
        else {
            return nil
        }
        return (String(candidate), String(message[colonRange.upperBound...]))
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

    // MARK: Frame selection validation (frames.select / frames.include / frames.exclude)

    /// CR-02: `frames.select`'s `indices` arm has no project to validate
    /// membership against (that's the whole point of this command -- it
    /// exists to run *before* one exists), so it validates against the
    /// *previewed* frame count instead, mirroring `SessionModel
    /// .setFrameSelection(_:)`'s own check. Returns the same `INVALID_PARAMS`
    /// shape `validatedFrameIndex` below returns for the post-project case,
    /// naming every offending index at once rather than only the first.
    private func validatedFrameSelectionIndices(_ indices: [Int], method: String) -> ControlErrorPayload? {
        guard let frameCount = sessionModel.status?.frameCount, frameCount > 0 else {
            return ControlErrorPayload(
                .invalidParams,
                message: "\"\(method)\" requires a completed preview before frames can be selected."
            )
        }
        let validRange = 1...frameCount
        let outOfRange = indices.filter { !validRange.contains($0) }
        guard outOfRange.isEmpty else {
            return ControlErrorPayload(
                .invalidParams,
                message: "\"\(method)\" indices \(outOfRange) are outside the previewed frame range 1...\(frameCount)."
            )
        }
        return nil
    }

    /// D-04: `frames.include`/`frames.exclude` share one frame-index check
    /// -- no project open, or an index that is not one of the open
    /// project's actual frame indices, is `INVALID_PARAMS` before either
    /// arm ever calls `setFrameExcluded(_:excluded:)`.
    ///
    /// This checks membership in `project.frames`, not a `0..<count`
    /// range: frame indices in this codebase are the frame's own 1-based
    /// `.index` field, confirmed by every existing project fixture (for
    /// example `AttendedScanRecoveryTests.swift`'s
    /// `frames: (1...2).map { ProjectFrame(index: $0, ...) }` for a
    /// 2-frame project) -- a zero-based array-position range would silently
    /// accept `frameIndex: 0`, which no project ever has.
    private func validatedFrameIndex(_ frameIndex: Int, method: String) -> ControlErrorPayload? {
        guard let project = sessionModel.project else {
            return ControlErrorPayload(.invalidParams, message: "\"\(method)\" requires an open project.")
        }
        let validIndices = project.frames.map(\.index).sorted()
        guard validIndices.contains(frameIndex) else {
            return ControlErrorPayload(
                .invalidParams,
                message: "\"\(method)\" frameIndex \(frameIndex) is not a valid frame index for the open project (valid indices: \(validIndices))."
            )
        }
        return nil
    }

    // MARK: Job-active busy guard (settings.set / outputs.set / frames.select)

    /// `applySettingsRecipes(capture:processing:)`/`applyOutputRecipe(_:)`/
    /// `frames.select`'s selection mutators are all synchronous and hold no
    /// busy flag of their own, so the preamble's `mutatingOperationInFlight`
    /// check in `handle(_:)` cannot see a running job for any of them.
    /// Mirrors `BatchInspectorView.swift` lines 42-47, where `setupInspector`
    /// (the settings editors) is rendered only while `!sessionModel
    /// .isJobActive` and is `.disabled(sessionModel.isResumingBatch)` when
    /// it is rendered -- a control caller must meet the same bar the GUI
    /// enforces by not rendering the control at all. `frames.select` reuses
    /// this exact rule (CR-02): a caller must not be able to replace the
    /// selection while a job is active or a resume is in flight, mirroring
    /// how the GUI's own thumbnail grid selection is unavailable then too.
    private func jobActiveBusyRefusal(method: String) -> ControlErrorPayload? {
        guard sessionModel.isJobActive || sessionModel.isResumingBatch else { return nil }
        let inFlight = sessionModel.jobId ?? "a resume in progress"
        return ControlErrorPayload(
            .controllerBusy,
            message: "\"\(method)\" was refused: \(inFlight) is active.",
            guidance: inFlight
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
            // D-15: the only wire-visible proof a preview finished, before
            // a project exists. Same source `frames.list`'s own
            // pre-project branch and every preview-completion gate in this
            // file already read.
            previewComplete: sessionModel.latestCompletedPreviewOperationId != nil,
            // D-17: reading sessionModel.progress here (not only in
            // buildJobResult() below) is what makes withObservationTracking
            // re-emit control.changed on a progress-only update, and what
            // gives JobWaiter's stderr progress sink something to read
            // without a second job.get request.
            progress: sessionModel.progress.map(Self.mapScanProgress),
            refeedRequired: sessionModel.refeedRequired,
            hardwareMotionReadiness: String(describing: motion),
            motionAllowed: motion.allowsMotion,
            motionGuidance: motion.guidance,
            mutatingOperationInFlight: sessionModel.mutatingOperationInFlight,
            selectedFrames: sessionModel.selectedFrames,
            scanReadiness: String(describing: readiness),
            scanReadinessReason: readiness.reason,
            lastErrorMessage: sessionModel.lastErrorMessage,
            lastControlRefusal: sessionModel.lastControlRefusal,
            manualReviewPending: buildManualReviewPending(),
            pendingFrames: sessionModel.pendingFrames
        )
    }

    /// D-13/HEAD-07: `nil` when nothing is pending. Built from
    /// `pendingManualReviewScan?.requirements` -- each requirement's own
    /// `warnings` *is* D-12's boundary evidence (`Thumbnail.warnings`,
    /// carried through unchanged), so `reason` is simply its first entry,
    /// or the literal `"boundaryAmbiguous"` when a requirement carries none
    /// (never an empty string, never an invented sentence).
    /// `contentConfidence` is `1 - blankConfidence` of the same
    /// `BlankFrameHint.Score` `frames.list` would report for that index, or
    /// `nil` when no hint exists (T-03-31: absence stays absence). Because
    /// this lives inside `buildStatusResult()` -- the same aggregate
    /// `subscribeToEvents()` observes -- a pending review reaches `status`,
    /// `control.snapshot`, and `control.changed` from this one source, with
    /// no separate event wiring (T-03-34).
    private func buildManualReviewPending() -> ControlManualReviewPending? {
        guard let requirements = sessionModel.pendingManualReviewScan?.requirements,
              !requirements.isEmpty
        else { return nil }
        let frames = requirements.map { requirement -> ControlManualReviewFrame in
            ControlManualReviewFrame(
                index: requirement.frameIndex,
                reason: requirement.warnings.first ?? "boundaryAmbiguous",
                evidence: requirement.warnings,
                contentConfidence: sessionModel.blankFrameHints[requirement.frameIndex].map { 1 - $0.blankConfidence }
            )
        }
        return ControlManualReviewPending(frames: frames)
    }

    /// One `ControlFrameSummary` per frame -- with a project open, one per
    /// `project.frames` entry (as before); with none open, one per
    /// **previewed thumbnail** (D-12/HEAD-06), sorted ascending. This is the
    /// pre-project gap D-12 closes: previously, no project meant an empty
    /// optional-chained frames array with nothing to fall back to, silently
    /// defaulting to an empty result before any project existed, so a
    /// script had no way to see which frames were leader before it could
    /// even call `roll.save`. Nothing can be *excluded* before a project
    /// exists -- there is no manifest to hold an exclusion -- so `excluded`
    /// is always `false` in the pre-project branch; that is a real fact
    /// about this state, not a third state invented to fill the field.
    private func buildFramesListResult() -> ControlFramesListResult {
        let frames: [ControlFrameSummary]
        if let project = sessionModel.project {
            frames = project.frames.map { frame in
                buildFrameSummary(index: frame.index, excluded: sessionModel.excludedFrameIndices.contains(frame.index))
            }
        } else {
            frames = sessionModel.thumbnails.keys.sorted().map { index in
                buildFrameSummary(index: index, excluded: false)
            }
        }
        return ControlFramesListResult(frames: frames, selectedFrames: sessionModel.selectedFrames)
    }

    /// Shared by both `buildFramesListResult()` branches so the hint/review
    /// fields are computed identically whether or not a project exists yet.
    /// `errorCode` copies only the bare failure code string; T-01-05 forbids
    /// copying any richer hardware-diagnostic payload alongside it.
    private func buildFrameSummary(index: Int, excluded: Bool) -> ControlFrameSummary {
        let hint = sessionModel.blankFrameHints[index]
        let thumbnail = sessionModel.thumbnails[index]
        return ControlFrameSummary(
            index: index,
            excluded: excluded,
            selected: sessionModel.selectedFrameIndices.contains(index),
            hasThumbnail: thumbnail != nil,
            state: sessionModel.frameStates[index]?.rawValue,
            manualReviewDecision: sessionModel.manualReviewDecisions[index].map(Self.manualReviewDecisionName),
            errorCode: sessionModel.frameErrors[index]?.code,
            errorMessage: sessionModel.frameErrors[index]?.message,
            blankConfidence: hint?.blankConfidence,
            thumbnailStddev: hint?.thumbnailStddev,
            thumbnailMean: hint?.thumbnailMean,
            endBonus: hint?.endBonus,
            runBonus: hint?.runBonus,
            needsApproval: thumbnail?.needsApproval ?? false,
            reviewEvidence: thumbnail?.warnings ?? []
        )
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
        let frameErrorMessages = Dictionary(
            uniqueKeysWithValues: sessionModel.frameErrors.map { (String($0.key), $0.value.message) }
        )
        return ControlJobResult(
            jobId: sessionModel.jobId,
            jobState: sessionModel.jobState,
            progress: sessionModel.progress.map(Self.mapScanProgress),
            completedFrameCount: sessionModel.completedFrameCount,
            pendingFrameCount: sessionModel.pendingFrameCount,
            receiptCount: sessionModel.receipts.count,
            frameErrorCodes: frameErrorCodes,
            frameErrorMessages: frameErrorMessages
            // finishedAt/notAttemptedFrames stay at their nil/[] defaults:
            // by the time jobId is non-nil again for a *different* job,
            // applyCompleted has already archived and cleared the
            // previous one (SessionModel never holds a live jobId whose
            // jobState is already terminal).
        )
    }

    /// D-19/HEAD-12: the `.jobGet` arm's "found in the ring" branch --
    /// `TerminalJobRecord` already carries exactly what `ControlJobResult`
    /// exposes for a finished job (T-03-46: no `details`/`evidence`).
    private func buildJobResult(from record: TerminalJobRecord) -> ControlJobResult {
        ControlJobResult(
            jobId: record.jobId,
            jobState: record.jobState,
            progress: nil,
            completedFrameCount: record.completedFrameCount,
            pendingFrameCount: record.pendingFrameCount,
            receiptCount: record.receiptCount,
            frameErrorCodes: Dictionary(
                uniqueKeysWithValues: record.frameErrorCodes.map { (String($0.key), $0.value) }
            ),
            frameErrorMessages: Dictionary(
                uniqueKeysWithValues: record.frameErrorMessages.map { (String($0.key), $0.value) }
            ),
            finishedAt: record.finishedAt,
            notAttemptedFrames: record.notAttemptedFrames
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

    /// `WireProtocol.swift`'s `ProjectSummary` (`SessionModel.recentProjects`'
    /// element type) is `Decodable`-only, missing the `Encodable`/`Equatable`
    /// directions the wire needs -- mirrors it field-for-field into
    /// `ControlProjectSummary` rather than retrofitting cross-module
    /// conformances onto a type owned by `WireProtocol.swift`.
    private static func mapProjectSummary(_ summary: ProjectSummary) -> ControlProjectSummary {
        ControlProjectSummary(
            id: summary.id,
            name: summary.name,
            carrier: summary.carrier,
            frameCount: summary.frameCount,
            filmProcess: summary.filmProcess,
            createdAt: summary.createdAt,
            directory: summary.directory
        )
    }

    // MARK: Diagnostics export (diagnostics.export)

    /// Mirrors `ContentView.swift`'s own `saveDiagnosticBundle()` filename
    /// scheme (`"ScanStudio-Diagnostics-\(timestamp).zip"`) verbatim, so a
    /// bundle written by the control channel is indistinguishable from one
    /// the GUI would have written for the same moment. The filename is
    /// always generated here, never taken from the request (T-01-20).
    private static func diagnosticBundleFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "ScanStudio-Diagnostics-\(timestamp).zip"
    }

    // MARK: Event stream
    //
    // Phase 1 scope: this is the in-process snapshot-plus-change contract
    // only. Transport fan-out, per-event filtering, and the full
    // per-property event vocabulary are CTRL-04, Phase 2's job.

    /// Each element is an encoded `control.snapshot`/`control.changed`
    /// event. The first element yielded is always the current snapshot,
    /// before any state change; every element after that is a fresh
    /// snapshot following a `SessionModel` change. This deliberately never
    /// reads the engine client's own unsolicited-event stream --
    /// `SessionModel.init` already owns that stream's one consumer, and a
    /// second reader would race it rather than mirror it.
    public func subscribeToEvents() -> AsyncStream<Data> {
        let subscriptionId = UUID()
        activeEventSubscriptions.insert(subscriptionId)
        return AsyncStream { continuation in
            if let data = Self.encodedEvent(name: Self.snapshotEventName, snapshot: buildStatusResult()) {
                continuation.yield(data)
            }
            armEventObservation(subscriptionId: subscriptionId, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.activeEventSubscriptions.remove(subscriptionId)
                }
            }
        }
    }

    private static let snapshotEventName = "control.snapshot"
    private static let changedEventName = "control.changed"

    /// Recursive re-arm, copied from `AppDelegate.bindJobActivity`'s
    /// `withObservationTracking { } onChange: { }` shape
    /// (`ScanStudioApp.swift`): the tracked read is `buildStatusResult()`,
    /// the exact same aggregate `.status` answers, so the observed property
    /// set and the reported snapshot never drift apart. `onChange` runs on
    /// an arbitrary, non-isolated context, hence the `Task { @MainActor }`
    /// hop before touching `self` or yielding again.
    private func armEventObservation(subscriptionId: UUID, continuation: AsyncStream<Data>.Continuation) {
        guard activeEventSubscriptions.contains(subscriptionId) else { return }
        withObservationTracking {
            _ = buildStatusResult()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeEventSubscriptions.contains(subscriptionId) else { return }
                if let data = Self.encodedEvent(name: Self.changedEventName, snapshot: self.buildStatusResult()) {
                    continuation.yield(data)
                }
                self.armEventObservation(subscriptionId: subscriptionId, continuation: continuation)
            }
        }
    }

    private static func encodedEvent(name: String, snapshot: ControlStatusResult) -> Data? {
        try? JSONEncoder().encode(ControlEventEnvelope(event: name, payload: snapshot))
    }

    // MARK: Line-based entry point

    /// Composes `decode` and `handle` and encodes the result -- the single
    /// call a future transport makes per request line. Never throws, never
    /// crashes: an encode failure falls back to a hand-built minimal
    /// `INVALID_PARAMS` line.
    ///
    /// SAFE-04 (Gap 2 fix): a decode-time refusal (`UNKNOWN_COMMAND`, or
    /// `INVALID_PARAMS` for an oversized/malformed line or an undecodable
    /// params shape) never becomes a typed `ControlRequest`, so it can
    /// never reach `handle(_:)`'s own recording choke point -- this is the
    /// second, and only other, place a refusal is recorded. The command
    /// name is recovered by re-sniffing the same line once more (best
    /// effort: `nil` for a line too malformed to carry a `method` at all,
    /// for example an oversized line or invalid JSON).
    public func handleLine(_ line: Data) async -> Data {
        let response: ControlResponse
        switch Self.decode(line) {
        case .success(let request):
            response = await handle(request)
        case .failure(let failure):
            response = .failure(id: failure.id, error: failure.error)
            let recoveredMethod = try? JSONDecoder().decode(ControlMethodSniff.self, from: line).method
            sessionModel.recordControlRefusal(command: recoveredMethod, code: failure.error.code, gate: failure.error.gate)
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
