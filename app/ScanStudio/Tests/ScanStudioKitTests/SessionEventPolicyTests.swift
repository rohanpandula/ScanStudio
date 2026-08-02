import Foundation
import Testing

@testable import ScanStudioKit

private enum ProjectFlowStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private struct EventEnvelopeFixture<Payload: Encodable>: Encodable {
    let event: String
    let payload: Payload
}

private struct FrameCompletedPayloadFixture: Encodable {
    let jobId: String
    let frameIndex: Int
    let receipt: ScanReceipt
}

private actor ProjectFlowEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "project-flow-stub"
    private let project: ScanProject

    init(project: ScanProject) {
        self.project = project
        self.events = AsyncStream { _ in }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        let value: any Sendable
        switch method {
        case "scanner.list": value = ScannerListResult(devices: [])
        case "project.create": value = ProjectCreateResult(project: project, directory: "/tmp/positive-roll")
        case "project.open": value = ProjectOpenResult(project: project, directory: "/tmp/positive-roll")
        case "sim.loadMedia":
            value = ScannerStatus(
                connected: true,
                adapter: "SA-21 (simulated)",
                mediaLoaded: true,
                carrier: "strip6",
                frameCount: 6,
                lamp: "stable",
                transport: "idle",
                activeJobId: nil
            )
        default: throw ProjectFlowStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw ProjectFlowStubError.unexpectedResultType
        }
        return result
    }
}

private actor SequencedProjectFlowEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "sequenced-project-flow-stub"
    private var projects: [ScanProject]

    init(projects: [ScanProject]) {
        self.projects = projects
        self.events = AsyncStream { _ in }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        let value: any Sendable
        switch method {
        case "scanner.list":
            value = ScannerListResult(devices: [])
        case "project.create":
            guard !projects.isEmpty else {
                throw ProjectFlowStubError.unexpectedMethod(
                    "project.create with an exhausted fixture queue"
                )
            }
            let project = projects.removeFirst()
            value = ProjectCreateResult(
                project: project,
                directory: "/tmp/\(project.id)"
            )
        case "project.open":
            guard !projects.isEmpty else {
                throw ProjectFlowStubError.unexpectedMethod(
                    "project.open with an exhausted fixture queue"
                )
            }
            let project = projects.removeFirst()
            value = ProjectOpenResult(
                project: project,
                directory: "/tmp/\(project.id)"
            )
        case "project.analyzeFrameDefects":
            value = AnalyzeFrameDefectsResult(
                frameIndex: 2,
                defects: [],
                simulated: true,
                digitalIceEnabled: true,
                transportSmearFlagged: false,
                transportSmearReason: nil
            )
        case "project.previewMetadataCommand":
            value = PreviewMetadataCommandResult(
                available: true,
                exiftoolPath: "/usr/bin/exiftool",
                targets: ["/tmp/first-project/Preview_0002.jpg"],
                arguments: ["-Title=First Project"]
            )
        case "sim.loadMedia":
            value = ScannerStatus(
                connected: true,
                adapter: "SA-21 (simulated)",
                mediaLoaded: true,
                carrier: "strip6",
                frameCount: 6,
                lamp: "stable",
                transport: "idle",
                activeJobId: nil
            )
        default:
            throw ProjectFlowStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw ProjectFlowStubError.unexpectedResultType
        }
        return result
    }
}

/// A test-only engine boundary whose preview ACK is deliberately held until
/// the test releases it. This lets the tests prove SessionModel installs its
/// pending film process before awaiting the request, rather than merely
/// asserting the standalone policy functions.
private actor ControllablePreviewEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "preview-lifecycle-stub"

    private let eventContinuation: AsyncStream<EngineEvent>.Continuation
    private let failAcquireSynchronously: Bool
    private var requestedFilmProcess: FilmProcess?
    private var requestedOperationID: String?
    private var acquireStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var acquireAckContinuation: CheckedContinuation<Void, Never>?

    init(failAcquireSynchronously: Bool = false) {
        let (events, continuation) = AsyncStream<EngineEvent>.makeStream()
        self.events = events
        self.eventContinuation = continuation
        self.failAcquireSynchronously = failAcquireSynchronously
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        switch method {
        case "scanner.list":
            return try cast(ScannerListResult(devices: []), as: Result.self)
        case "scanner.acquireThumbnails":
            let data = try JSONEncoder().encode(params)
            let decoded = try JSONDecoder()
                .decode(AcquireThumbnailsParams.self, from: data)
            requestedFilmProcess = decoded.filmProcess
            requestedOperationID = decoded.operationId
            let waiters = acquireStartedWaiters
            acquireStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if failAcquireSynchronously {
                throw EngineRequestError(
                    code: "INVALID_PARAMS",
                    message: "preview request refused synchronously",
                    recoverable: false
                )
            }
            await withCheckedContinuation { continuation in
                acquireAckContinuation = continuation
            }
            return try cast(AcquireThumbnailsAck(accepted: true, frames: []), as: Result.self)
        default:
            throw ProjectFlowStubError.unexpectedMethod(method)
        }
    }

    func waitForAcquireRequest() async {
        if requestedFilmProcess != nil || failAcquireSynchronously {
            return
        }
        await withCheckedContinuation { acquireStartedWaiters.append($0) }
    }

    func capturedFilmProcess() -> FilmProcess? { requestedFilmProcess }
    func capturedOperationID() -> String? { requestedOperationID }

    func emit(_ name: String, payloadJSON: String) {
        eventContinuation.yield(EngineEvent(name: name, rawLine: Data(payloadJSON.utf8)))
    }

    func resumeAcquireAck() {
        acquireAckContinuation?.resume()
        acquireAckContinuation = nil
    }

    private func cast<Result: Decodable & Sendable>(
        _ value: some Sendable,
        as _: Result.Type
    ) throws -> Result {
        guard let result = value as? Result else {
            throw ProjectFlowStubError.unexpectedResultType
        }
        return result
    }
}

/// Counts every preview request while ACKing immediately. Terminal preview
/// evidence is driven directly through `SessionModel.handle(event:)`, which
/// makes duplicate-request tests deterministic without a live engine, timer,
/// SwiftUI render loop, or hardware.
private actor CountingPreviewEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "preview-request-count-stub"

    private let project: ScanProject?
    private var previewProcesses: [FilmProcess?] = []
    private var previewOperationIDs: [String?] = []
    private var previewFailuresRemaining: Int

    init(project: ScanProject? = nil, previewFailuresRemaining: Int = 0) {
        self.project = project
        self.previewFailuresRemaining = previewFailuresRemaining
        self.events = AsyncStream { _ in }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        switch method {
        case "scanner.list":
            return try cast(ScannerListResult(devices: []), as: Result.self)
        case "scanner.acquireThumbnails":
            let data = try JSONEncoder().encode(params)
            let decoded = try JSONDecoder()
                .decode(AcquireThumbnailsParams.self, from: data)
            previewProcesses.append(decoded.filmProcess)
            previewOperationIDs.append(decoded.operationId)
            if previewFailuresRemaining > 0 {
                previewFailuresRemaining -= 1
                throw EngineRequestError(
                    code: "INVALID_PARAMS",
                    message: "preview request refused synchronously",
                    recoverable: false
                )
            }
            return try cast(
                AcquireThumbnailsAck(accepted: true, frames: []),
                as: Result.self
            )
        case "project.create":
            guard let project else {
                throw ProjectFlowStubError.unexpectedMethod(method)
            }
            return try cast(
                ProjectCreateResult(project: project, directory: "/tmp/preview-loop-project"),
                as: Result.self
            )
        default:
            throw ProjectFlowStubError.unexpectedMethod(method)
        }
    }

    func previewRequestCount() -> Int { previewProcesses.count }

    func capturedPreviewProcesses() -> [FilmProcess?] { previewProcesses }
    func capturedPreviewOperationIDs() -> [String?] { previewOperationIDs }

    private func cast<Result: Decodable & Sendable>(
        _ value: some Sendable,
        as _: Result.Type
    ) throws -> Result {
        guard let result = value as? Result else {
            throw ProjectFlowStubError.unexpectedResultType
        }
        return result
    }
}

/// Holds only the first preview request, while ACKing later requests
/// immediately. The held request can then fail after its correlated terminal
/// events have already closed A and a replacement B owns the preview lane.
private actor LateFailurePreviewEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "late-preview-failure-stub"

    private var previewOperationIDs: [String] = []
    private var firstAcquireContinuation: CheckedContinuation<Void, Error>?
    private var requestCountWaiter:
        (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init() {
        events = AsyncStream { _ in }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        switch method {
        case "scanner.list":
            return try cast(ScannerListResult(devices: []), as: Result.self)
        case "scanner.acquireThumbnails":
            let data = try JSONEncoder().encode(params)
            let decoded = try JSONDecoder()
                .decode(AcquireThumbnailsParams.self, from: data)
            guard let operationID = decoded.operationId else {
                throw ProjectFlowStubError.unexpectedMethod(
                    "preview request omitted operationId"
                )
            }
            previewOperationIDs.append(operationID)
            if let waiter = requestCountWaiter,
               previewOperationIDs.count >= waiter.count
            {
                requestCountWaiter = nil
                waiter.continuation.resume()
            }

            if previewOperationIDs.count == 1 {
                try await withCheckedThrowingContinuation { continuation in
                    firstAcquireContinuation = continuation
                }
            }
            return try cast(
                AcquireThumbnailsAck(accepted: true, frames: []),
                as: Result.self
            )
        default:
            throw ProjectFlowStubError.unexpectedMethod(method)
        }
    }

    func waitForPreviewRequestCount(_ count: Int) async {
        guard previewOperationIDs.count < count else { return }
        await withCheckedContinuation {
            requestCountWaiter = (count, $0)
        }
    }

    func previewRequestCount() -> Int {
        previewOperationIDs.count
    }

    func failFirstAcquire() {
        firstAcquireContinuation?.resume(throwing: EngineRequestError(
            code: "STALE_REQUEST_FAILURE",
            message: "preview A failed after its terminal events",
            recoverable: false
        ))
        firstAcquireContinuation = nil
    }

    private func cast<Result: Decodable & Sendable>(
        _ value: some Sendable,
        as _: Result.Type
    ) throws -> Result {
        guard let result = value as? Result else {
            throw ProjectFlowStubError.unexpectedResultType
        }
        return result
    }
}

@Suite("Session event ordering")
struct SessionEventPolicyTests {
    @Test("a completed pre-project preview is stable across passive ticks and a replayed initial intent")
    @MainActor
    func completedPreProjectPreviewRejectsReplayedInitialIntent() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let initialToken = PreviewIntentToken()
        let initialIntent = PreviewIntent.initial(token: initialToken)

        #expect(await model.requestPreview(initialIntent) == .started)
        #expect(await client.previewRequestCount() == 1)
        establishCompletedPreview(
            frameCount: 6,
            operationID: initialToken.id.uuidString,
            on: model
        )
        #expect(completePreviewRegistration(on: model))

        // Model the non-actions observed during the live gap: repeated status
        // reconciliation, view-derived policy reads, task scheduling/focus
        // opportunities, and elapsed-time-like yields. None is authorization
        // to move the film.
        for _ in 0..<25 {
            applyLoadedStatus(frameCount: 6, on: model)
            #expect(completePreviewRegistration(on: model))
            await Task.yield()
        }
        #expect(await client.previewRequestCount() == 1)

        // Even if a delayed replay of the original center action reaches
        // the model after completion, it must be idempotent and preserve the
        // established registration.
        #expect(await model.requestPreview(initialIntent) == .rejected)
        #expect(await client.previewRequestCount() == 1)
        #expect(model.thumbnails.count == 6)
        #expect(model.previewFilmProcess == .c41ColorNegative)
        #expect(completePreviewRegistration(on: model))

        // A delayed terminal failure from an older command is not an active
        // traversal and therefore cannot reopen the initial-preview path.
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(initialToken.id.uuidString)","code":"STALE","message":"delayed old failure"}}"#.utf8
            )
        ))

        // Even a freshly minted *initial* action cannot replace a successful
        // registration. That requires the separately confirmed replacement
        // intent.
        #expect(
            await model.requestPreview(.initial(token: PreviewIntentToken()))
                == .rejected
        )
        #expect(await client.previewRequestCount() == 1)
    }

    @Test("completion closes the duplicate window before authoritative status arrives")
    @MainActor
    func completionBeforeStatusRejectsDuplicateGenericAcquire() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let initialToken = PreviewIntentToken()
        let initialIntent = PreviewIntent.initial(token: initialToken)

        #expect(await model.requestPreview(initialIntent) == .started)
        applyPreviewFramesAndCompletion(
            frameCount: 6,
            operationID: initialToken.id.uuidString,
            on: model
        )

        // This is the real backend's event order: completion commits the
        // process and clears the in-flight flag immediately before the
        // authoritative status carrying mediaLoaded/frameCount arrives.
        #expect(await client.previewRequestCount() == 1)
        #expect(model.previewFilmProcess == .c41ColorNegative)
        #expect(model.isAcquiringThumbnails == false)
        #expect(completePreviewRegistration(on: model) == false)

        #expect(await model.requestPreview(initialIntent) == .rejected)
        #expect(
            await model.requestPreview(.initial(token: PreviewIntentToken()))
                == .rejected
        )

        #expect(await client.previewRequestCount() == 1)
        #expect(model.thumbnails.count == 6)
        #expect(model.previewFilmProcess == .c41ColorNegative)
    }

    @Test("the confirmed re-preview action authorizes exactly one replacement request")
    @MainActor
    func explicitRePreviewAuthorizesExactlyOneRequest() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let initialToken = PreviewIntentToken()
        let initialIntent = PreviewIntent.initial(token: initialToken)

        #expect(await model.requestPreview(initialIntent) == .started)
        establishCompletedPreview(
            frameCount: 6,
            operationID: initialToken.id.uuidString,
            on: model
        )
        #expect(await client.previewRequestCount() == 1)
        #expect(completePreviewRegistration(on: model))

        let replacementIntent = PreviewIntent.replaceFilmProcess(
            token: PreviewIntentToken(),
            filmProcess: .positive
        )
        #expect(await model.requestPreview(replacementIntent) == .started)

        #expect(await client.previewRequestCount() == 2)
        #expect(await client.capturedPreviewProcesses() == [.c41ColorNegative, .positive])
        #expect(model.isAcquiringThumbnails)
        #expect(model.thumbnails.isEmpty)
        #expect(model.previewFilmProcess == nil)

        // A second activation while the authorized replacement is already in
        // flight must not turn one confirmation into two hardware requests.
        #expect(await model.requestPreview(replacementIntent) == .rejected)
        #expect(await client.previewRequestCount() == 2)
    }

    @Test("a confirmed re-preview intent cannot replay after its replacement completes")
    @MainActor
    func completedRePreviewRejectsReplayOfSameConfirmation() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)

        let initialToken = PreviewIntentToken()
        #expect(
            await model.requestPreview(.initial(token: initialToken))
                == .started
        )
        establishCompletedPreview(
            frameCount: 6,
            operationID: initialToken.id.uuidString,
            on: model
        )
        let replacementToken = PreviewIntentToken()
        let replacementIntent = PreviewIntent.replaceFilmProcess(
            token: replacementToken,
            filmProcess: .positive
        )
        #expect(await model.requestPreview(replacementIntent) == .started)
        #expect(await client.previewRequestCount() == 2)
        establishCompletedPreview(
            frameCount: 6,
            operationID: replacementToken.id.uuidString,
            on: model
        )
        #expect(model.previewFilmProcess == .positive)
        #expect(completePreviewRegistration(on: model))

        // Models a delayed replay of the already-consumed confirmation after
        // the replacement has fully completed, not merely a double-click
        // while the transport is still busy.
        #expect(await model.requestPreview(replacementIntent) == .rejected)

        #expect(await client.previewRequestCount() == 2)
        #expect(model.thumbnails.count == 6)
        #expect(model.previewFilmProcess == .positive)

        // Reopening and reconfirming is a genuinely new explicit action. Its
        // fresh token authorizes one replacement and only one.
        let freshReplacement = PreviewIntent.replaceFilmProcess(
            token: PreviewIntentToken(),
            filmProcess: .bwNegative
        )
        #expect(await model.requestPreview(freshReplacement) == .started)
        #expect(await model.requestPreview(freshReplacement) == .rejected)
        #expect(await client.previewRequestCount() == 3)
    }

    @Test("a saved project's explicit refresh previews action remains available")
    @MainActor
    func savedProjectCanExplicitlyRefreshCompletedPreview() async {
        let project = previewLoopTestProject()
        let client = CountingPreviewEngineStub(project: project)
        let model = SessionModel(engineClient: client)
        await model.createProject(
            name: project.name,
            carrier: project.carrier,
            frameCount: project.frameCount,
            filmProcess: project.filmProcess
        )
        #expect(model.project?.id == project.id)

        let firstRefreshToken = PreviewIntentToken()
        #expect(
            await model.requestPreview(
                .refreshSavedProject(token: firstRefreshToken)
            ) == .started
        )
        establishCompletedPreview(
            frameCount: 1,
            operationID: firstRefreshToken.id.uuidString,
            on: model
        )
        #expect(await client.previewRequestCount() == 1)
        #expect(completePreviewRegistration(on: model))

        #expect(
            await model.requestPreview(
                .refreshSavedProject(token: PreviewIntentToken())
            ) == .started
        )
        #expect(await client.previewRequestCount() == 2)
    }

    @Test("a saved-project refresh intent cannot replay after refresh completion")
    @MainActor
    func completedSavedProjectRefreshRejectsReplayOfSameAction() async {
        let project = previewLoopTestProject()
        let client = CountingPreviewEngineStub(project: project)
        let model = SessionModel(engineClient: client)
        await model.createProject(
            name: project.name,
            carrier: project.carrier,
            frameCount: project.frameCount,
            filmProcess: project.filmProcess
        )

        let firstRefreshToken = PreviewIntentToken()
        #expect(
            await model.requestPreview(
                .refreshSavedProject(token: firstRefreshToken)
            ) == .started
        )
        establishCompletedPreview(
            frameCount: 1,
            operationID: firstRefreshToken.id.uuidString,
            on: model
        )
        #expect(await client.previewRequestCount() == 1)

        let refreshToken = PreviewIntentToken()
        let refreshIntent = PreviewIntent.refreshSavedProject(
            token: refreshToken
        )
        #expect(await model.requestPreview(refreshIntent) == .started)
        #expect(await client.previewRequestCount() == 2)
        establishCompletedPreview(
            frameCount: 1,
            operationID: refreshToken.id.uuidString,
            on: model
        )
        #expect(completePreviewRegistration(on: model))

        // Models replay of the same saved-project Refresh action after its
        // first refresh has returned to the idle contact-sheet state.
        #expect(await model.requestPreview(refreshIntent) == .rejected)

        #expect(await client.previewRequestCount() == 2)
        #expect(model.thumbnails.count == 1)

        let freshRefresh = PreviewIntent.refreshSavedProject(
            token: PreviewIntentToken()
        )
        #expect(await model.requestPreview(freshRefresh) == .started)
        #expect(await model.requestPreview(freshRefresh) == .rejected)
        #expect(await client.previewRequestCount() == 3)
    }

    @Test("a failed preview's trailing completion cannot terminate its replacement")
    @MainActor
    func trailingCompletionIsCorrelatedToThePreviewThatEmittedIt() async {
        let project = previewLoopTestProject()
        let client = CountingPreviewEngineStub(project: project)
        let model = SessionModel(engineClient: client)
        await model.createProject(
            name: project.name,
            carrier: project.carrier,
            frameCount: project.frameCount,
            filmProcess: project.filmProcess
        )

        let tokenA = PreviewIntentToken()
        #expect(
            await model.requestPreview(.refreshSavedProject(token: tokenA))
                == .started
        )
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(tokenA.id.uuidString)","code":"INVALID_PARAMS","message":"preview A failed"}}"#.utf8
            )
        ))

        let tokenB = PreviewIntentToken()
        #expect(
            await model.requestPreview(.refreshSavedProject(token: tokenB))
                == .started
        )
        #expect(await client.previewRequestCount() == 2)
        #expect(
            await client.capturedPreviewOperationIDs()
                == [tokenA.id.uuidString, tokenB.id.uuidString]
        )
        #expect(model.isAcquiringThumbnails)

        // The real backend emits thumbnailsFailed and then a closing
        // thumbnailsComplete for the same worker. A's trailing completion
        // must not clear B's active/pending state.
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(tokenA.id.uuidString)","count":0}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(tokenA.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails)

        model.handle(event: EngineEvent(
            name: "scanner.thumbnail",
            rawLine: Data(
                #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(tokenA.id.uuidString)","frameIndex":1,"thumbnail":{"brightness":0.5,"tint":0.0}}}"#.utf8
            )
        ))
        #expect(model.thumbnails.isEmpty)

        let tokenC = PreviewIntentToken()
        #expect(
            await model.requestPreview(.refreshSavedProject(token: tokenC))
                == .rejected
        )
        #expect(await client.previewRequestCount() == 2)

        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(tokenB.id.uuidString)","count":1}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails == false)

        // Once B's own terminal arrives, a newly confirmed refresh is
        // accepted, proving terminal correlation does not deadlock the path.
        #expect(
            await model.requestPreview(
                .refreshSavedProject(token: PreviewIntentToken())
            ) == .started
        )
        #expect(await client.previewRequestCount() == 3)
    }

    @Test("a late synchronous failure cannot clear or overwrite its replacement")
    @MainActor
    func lateSynchronousFailureCannotClearReplacement() async {
        let client = LateFailurePreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let tokenA = PreviewIntentToken()
        let requestA = Task { @MainActor in
            await model.requestPreview(.initial(token: tokenA))
        }
        await client.waitForPreviewRequestCount(1)

        // A's correlated worker events can legitimately arrive before its
        // request continuation resumes.
        applyPreviewFramesAndCompletion(
            frameCount: 1,
            operationID: tokenA.id.uuidString,
            on: model
        )
        applyLoadedStatus(
            frameCount: 1,
            operationID: tokenA.id.uuidString,
            on: model
        )
        #expect(completePreviewRegistration(on: model))

        let tokenB = PreviewIntentToken()
        #expect(
            await model.requestPreview(.replaceFilmProcess(
                token: tokenB,
                filmProcess: .bwNegative
            )) == .started
        )
        #expect(await client.previewRequestCount() == 2)
        #expect(model.isAcquiringThumbnails)
        #expect(model.lastErrorMessage == nil)

        await client.failFirstAcquire()
        #expect(await requestA.value == .failedToStart)

        // A no longer owns the preview lane. Its late catch must not clear
        // B's busy/pending state or surface A's stale error.
        #expect(model.isAcquiringThumbnails)
        #expect(model.lastErrorMessage == nil)
        let tokenC = PreviewIntentToken()
        #expect(
            await model.requestPreview(.replaceFilmProcess(
                token: tokenC,
                filmProcess: .positive
            )) == .rejected
        )
        #expect(await client.previewRequestCount() == 2)

        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(tokenB.id.uuidString)","count":1}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails == false)
        #expect(model.previewFilmProcess == .bwNegative)
    }

    @Test("failure and media reset require a fresh explicit preview intent")
    @MainActor
    func failureAndMediaResetNeverRearmConsumedIntent() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let failedToken = PreviewIntentToken()
        let failedIntent = PreviewIntent.initial(token: failedToken)

        #expect(await model.requestPreview(failedIntent) == .started)
        #expect(await client.previewRequestCount() == 1)
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(failedToken.id.uuidString)","code":"INVALID_PARAMS","message":"preview failed"}}"#.utf8
            )
        ))

        // Failure ends the traversal but cannot mint or rearm authorization.
        #expect(await model.requestPreview(failedIntent) == .rejected)
        #expect(await client.previewRequestCount() == 1)

        let afterFailureToken = PreviewIntentToken()
        let afterFailure = PreviewIntent.initial(token: afterFailureToken)
        #expect(await model.requestPreview(afterFailure) == .started)
        #expect(await client.previewRequestCount() == 2)

        // Neither an untagged status nor failed A's slow post-terminal status
        // may clear the active B lane or manufacture authorization for C.
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(failedToken.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails)

        #expect(await model.requestPreview(afterFailure) == .rejected)
        #expect(
            await model.requestPreview(.initial(token: PreviewIntentToken()))
                == .rejected
        )
        #expect(await client.previewRequestCount() == 2)

        applyPreviewFramesAndCompletion(
            frameCount: 1,
            operationID: afterFailureToken.id.uuidString,
            on: model
        )
        #expect(model.isAcquiringThumbnails == false)

        // B's own correlated post-terminal no-media status is authoritative.
        // With no active worker left, it clears B's completed registration and
        // a separately confirmed C can start exactly once.
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(afterFailureToken.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
        let afterMediaReset = PreviewIntent.initial(
            token: PreviewIntentToken()
        )
        #expect(await model.requestPreview(afterMediaReset) == .started)
        #expect(await model.requestPreview(afterMediaReset) == .rejected)
        #expect(await client.previewRequestCount() == 3)
    }

    @Test("a matching media reset waits for its preview worker's terminal")
    @MainActor
    func mediaResetCannotReopenLaneBeforeTrailingTerminal() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let tokenA = PreviewIntentToken()

        #expect(
            await model.requestPreview(.initial(token: tokenA)) == .started
        )
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(tokenA.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails)

        let prematureToken = PreviewIntentToken()
        #expect(
            await model.requestPreview(.initial(token: prematureToken))
                == .rejected
        )
        #expect(await client.previewRequestCount() == 1)

        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(tokenA.id.uuidString)","count":0}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(tokenA.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
        #expect(model.isAcquiringThumbnails == false)

        // The token denied during A remains consumed, while reopening the
        // confirmation after A's correlated close is accepted without a
        // deadlock.
        #expect(
            await model.requestPreview(.initial(token: prematureToken))
                == .rejected
        )
        let freshToken = PreviewIntentToken()
        #expect(
            await model.requestPreview(.initial(token: freshToken)) == .started
        )
        #expect(await client.previewRequestCount() == 2)
    }

    @Test("synchronous refusal does not auto-rearm the failed presentation token")
    @MainActor
    func synchronousFailureRequiresSeparatelyMintedPresentationToken() async {
        let client = CountingPreviewEngineStub(previewFailuresRemaining: 1)
        let model = SessionModel(engineClient: client)
        let failedPresentationToken = PreviewIntentToken()
        let failedIntent = PreviewIntent.initial(token: failedPresentationToken)

        #expect(await model.requestPreview(failedIntent) == .failedToStart)
        #expect(await client.previewRequestCount() == 1)

        // Rendering the same action again, or replaying its delayed closure,
        // still carries the consumed presentation token.
        #expect(await model.requestPreview(failedIntent) == .rejected)
        #expect(await client.previewRequestCount() == 1)

        // Only the parent opening a distinct confirmation presentation mints
        // a different token. That new explicit confirmation starts once.
        let reopenedPresentationToken = PreviewIntentToken()
        #expect(reopenedPresentationToken != failedPresentationToken)
        let reopenedIntent = PreviewIntent.initial(
            token: reopenedPresentationToken
        )
        #expect(await model.requestPreview(reopenedIntent) == .started)
        #expect(await model.requestPreview(reopenedIntent) == .rejected)
        #expect(await client.previewRequestCount() == 2)
    }

    @Test("an intent rejected before completion stays consumed after completion and status")
    @MainActor
    func stateChangesCannotAuthorizePreviouslyRejectedIntent() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let initialToken = PreviewIntentToken()
        let initial = PreviewIntent.initial(token: initialToken)
        let prematureReplacement = PreviewIntent.replaceFilmProcess(
            token: PreviewIntentToken(),
            filmProcess: .positive
        )

        #expect(await model.requestPreview(initial) == .started)
        #expect(await model.requestPreview(prematureReplacement) == .rejected)
        applyPreviewFramesAndCompletion(
            frameCount: 6,
            operationID: initialToken.id.uuidString,
            on: model
        )
        applyLoadedStatus(
            frameCount: 6,
            operationID: initialToken.id.uuidString,
            on: model
        )
        #expect(completePreviewRegistration(on: model))

        // Completion and authoritative status make a *new* replacement
        // admissible, but never resurrect the already-denied token.
        #expect(await model.requestPreview(prematureReplacement) == .rejected)
        #expect(await client.previewRequestCount() == 1)
        #expect(
            await model.requestPreview(.replaceFilmProcess(
                token: PreviewIntentToken(),
                filmProcess: .positive
            )) == .started
        )
        #expect(await client.previewRequestCount() == 2)
    }

    @Test("an intermediate busy-to-idle status cannot reopen an active traversal")
    @MainActor
    func statusIdleDoesNotEndPreviewAuthorizationLifetime() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let activeToken = PreviewIntentToken()
        let activeIntent = PreviewIntent.initial(token: activeToken)

        #expect(await model.requestPreview(activeIntent) == .started)
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(activeToken.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":true,"carrier":null,"frameCount":6,"lamp":"stable","transport":"busy","activeJobId":null}}}"#.utf8
            )
        ))
        applyLoadedStatus(
            frameCount: 6,
            operationID: activeToken.id.uuidString,
            on: model
        )
        #expect(model.isAcquiringThumbnails)

        // Status is descriptive only. It cannot settle the UI-facing preview
        // flag or end the one-shot authorization without a matching terminal.
        #expect(await model.requestPreview(activeIntent) == .rejected)
        #expect(
            await model.requestPreview(.initial(token: PreviewIntentToken()))
                == .rejected
        )
        #expect(await client.previewRequestCount() == 1)

        applyPreviewFramesAndCompletion(
            frameCount: 6,
            operationID: activeToken.id.uuidString,
            on: model
        )
        #expect(model.previewFilmProcess == .c41ColorNegative)
    }

    @Test("preview completion commits the pending process even when it arrives before the held ACK")
    @MainActor
    func previewCompletionBeforeAckCommitsTheRequestedFilmProcess() async {
        let client = ControllablePreviewEngineStub()
        let model = SessionModel(engineClient: client)
        model.scanFilmProcess = .bwNegative

        let previewToken = PreviewIntentToken()
        let operation = Task {
            await model.requestPreview(.initial(token: previewToken))
        }
        await client.waitForAcquireRequest()
        #expect(await client.capturedFilmProcess() == .bwNegative)
        #expect(
            await client.capturedOperationID() == previewToken.id.uuidString
        )
        #expect(model.isAcquiringThumbnails)

        await client.emit(
            "scanner.thumbnailsComplete",
            payloadJSON: #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(previewToken.id.uuidString)","count":1}}"#
        )
        for _ in 0..<30 where model.previewFilmProcess == nil { await Task.yield() }
        #expect(model.previewFilmProcess == .bwNegative)
        #expect(model.isAcquiringThumbnails == false)

        await client.resumeAcquireAck()
        _ = await operation.value
    }

    @MainActor
    private func establishCompletedPreview(
        frameCount: Int,
        operationID: String,
        on model: SessionModel
    ) {
        applyPreviewFramesAndCompletion(
            frameCount: frameCount,
            operationID: operationID,
            on: model
        )
        applyLoadedStatus(
            frameCount: frameCount,
            operationID: operationID,
            on: model
        )
    }

    @MainActor
    private func applyPreviewFramesAndCompletion(
        frameCount: Int,
        operationID: String,
        on model: SessionModel
    ) {
        for frameIndex in 1...frameCount {
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(operationID)","frameIndex":\#(frameIndex),"thumbnail":{"brightness":0.5,"tint":0.0}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(operationID)","count":\#(frameCount)}}"#.utf8
            )
        ))
    }

    @MainActor
    private func applyLoadedStatus(
        frameCount: Int,
        operationID: String? = nil,
        on model: SessionModel
    ) {
        let operationField = operationID.map {
            "\"operationId\":\"\($0)\","
        } ?? ""
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{\#(operationField)"status":{"connected":true,"adapter":null,"mediaLoaded":true,"carrier":null,"frameCount":\#(frameCount),"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
            )
        ))
    }

    @MainActor
    private func completePreviewRegistration(on model: SessionModel) -> Bool {
        PreviewRegistrationPolicy.isComplete(
            mediaLoaded: model.status?.mediaLoaded == true,
            previewFrameIndices: model.thumbnails.keys,
            statusFrameCount: model.status?.frameCount,
            committedFilmProcess: model.previewFilmProcess
        )
    }

    private func previewLoopTestProject() -> ScanProject {
        ScanProject(
            schemaVersion: 1,
            id: "preview-loop-project",
            name: "Preview loop project",
            carrier: .mounted,
            frameCount: 1,
            filmProcess: .c41ColorNegative,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(
                    filenameTemplate: "Archive_####",
                    destination: "/tmp/preview-loop-project/Archive"
                ),
                positive: PositiveRecipe(
                    enabled: true,
                    fileFormat: .tiff,
                    colorProfile: .adobeRgb1998,
                    filenameTemplate: "Positive_####",
                    destination: "/tmp/preview-loop-project/Positive"
                ),
                preview: PreviewRecipe(
                    enabled: true,
                    fileFormat: .jpeg,
                    maxLongEdgePx: 1_024,
                    filenameTemplate: "Preview_####",
                    destination: "/tmp/preview-loop-project/Preview"
                )
            ),
            rollMetadata: MetadataSet(),
            createdAt: "2026-07-27T21:36:49Z",
            frames: [ProjectFrame(index: 1, excluded: false, receipts: [])]
        )
    }

    private func projectLifecycleFixture(
        id: String,
        completedFrames: Set<Int>
    ) throws -> ScanProject {
        let frames = try (1...6).map { frameIndex in
            ProjectFrame(
                index: frameIndex,
                excluded: false,
                receipts: completedFrames.contains(frameIndex)
                    ? [try fixtureReceipt(
                        jobId: "persisted-\(id)",
                        frameIndex: frameIndex
                    )]
                    : []
            )
        }
        return ScanProject(
            schemaVersion: 1,
            id: id,
            name: id,
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(
                    filenameTemplate: "Archive_####",
                    destination: "/tmp/\(id)/Archive"
                ),
                positive: PositiveRecipe(
                    enabled: true,
                    fileFormat: .tiff,
                    colorProfile: .adobeRgb1998,
                    filenameTemplate: "Positive_####",
                    destination: "/tmp/\(id)/Positive"
                ),
                preview: PreviewRecipe(
                    enabled: true,
                    fileFormat: .jpeg,
                    maxLongEdgePx: 1_024,
                    filenameTemplate: "Preview_####",
                    destination: "/tmp/\(id)/Preview"
                )
            ),
            rollMetadata: MetadataSet(),
            createdAt: "2026-07-29T00:00:00Z",
            frames: frames
        )
    }

    private func fixtureReceipt(
        jobId: String,
        frameIndex: Int
    ) throws -> ScanReceipt {
        try JSONDecoder().decode(
            ScanReceipt.self,
            from: Data(
                """
                {
                  "jobId":"\(jobId)",
                  "frameIndex":\(frameIndex),
                  "startedAt":"2026-07-29T00:00:00Z",
                  "durationMs":100,
                  "passes":1,
                  "resolutionDpi":4000,
                  "bitDepth":16,
                  "channels":"rgb",
                  "engineVersion":"0.1.0",
                  "deviceId":"sim-ls5000-0",
                  "simulated":true,
                  "settingsFingerprint":"fixture-\(frameIndex)"
                }
                """.utf8
            )
        )
    }

    private func completedFrameEvent(
        jobId: String,
        frameIndex: Int
    ) throws -> EngineEvent {
        let receipt = try fixtureReceipt(jobId: jobId, frameIndex: frameIndex)
        let payload = FrameCompletedPayloadFixture(
            jobId: jobId,
            frameIndex: frameIndex,
            receipt: receipt
        )
        return EngineEvent(
            name: "scan.frameCompleted",
            rawLine: try JSONEncoder().encode(
                EventEnvelopeFixture(
                    event: "scan.frameCompleted",
                    payload: payload
                )
            )
        )
    }

    @Test("project changes clear the previous selection and last-batch state while new jobs retain other persisted completions")
    @MainActor
    func projectChangesIsolateSessionStateAndJobsPreservePriorReceipts() async throws {
        let first = try projectLifecycleFixture(
            id: "first-project",
            completedFrames: [4]
        )
        let second = try projectLifecycleFixture(
            id: "second-project",
            completedFrames: []
        )
        let model = SessionModel(
            engineClient: SequencedProjectFlowEngineStub(
                projects: [first, second]
            )
        )

        await model.loadCarrier(.strip6)
        await model.createProject(
            name: first.name,
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )
        #expect(model.pendingFrames == [1, 2, 3, 5, 6])
        #expect(model.completedFrameCount == 1)
        model.toggleFrameSelection(2)
        model.beginJob(id: "live-job", frames: [2])

        #expect(model.frameStates[4] == .completed)
        #expect(model.frameStates[2] == nil)
        #expect(model.pendingFrames == [1, 2, 3, 5, 6])
        #expect(model.completedFrameCount == 1)

        model.handle(
            event: try completedFrameEvent(jobId: "live-job", frameIndex: 2)
        )
        #expect(model.pendingFrames == [1, 3, 5, 6])
        #expect(model.completedFrameCount == 2)
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"live-job","summary":{"completed":[2],"failed":[],"skipped":[],"stopped":false}}}"#.utf8
            )
        ))
        #expect(model.receiptCount == 1)
        #expect(model.scanSummary != nil)
        #expect(model.frameStates[4] == .completed)

        await model.createProject(
            name: second.name,
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )

        #expect(model.project?.id == second.id)
        #expect(model.selectedFrameIndices.isEmpty)
        #expect(model.receipts.isEmpty)
        #expect(model.scanSummary == nil)
        #expect(model.frameStates.isEmpty)
        #expect(model.pendingFrames == [1, 2, 3, 4, 5, 6])
        #expect(model.completedFrameCount == 0)
    }

    @Test("opening another project clears every project-scoped audit surface before restoring its receipts")
    @MainActor
    func openProjectClearsAllProjectScopedAuditState() async throws {
        let first = try projectLifecycleFixture(
            id: "first-project",
            completedFrames: [4]
        )
        let second = try projectLifecycleFixture(
            id: "second-project",
            completedFrames: [6]
        )
        let model = SessionModel(
            engineClient: SequencedProjectFlowEngineStub(
                projects: [first, second]
            )
        )

        await model.loadCarrier(.strip6)
        await model.createProject(
            name: first.name,
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )
        model.toggleFrameSelection(2)
        model.openFrameDetail(2)
        await model.analyzeFrameDefects(2)
        await model.previewMetadataCommand(2)
        model.beginJob(id: "first-live-job", frames: [2])
        model.handle(event: EngineEvent(
            name: "scan.progress",
            rawLine: Data(
                #"{"event":"scan.progress","payload":{"jobId":"first-live-job","frameIndex":2,"frameOrdinal":1,"totalFrames":1,"pass":1,"totalPasses":1,"framePercent":50,"jobPercent":50,"etaSeconds":1}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"first-live-job","frameIndex":2,"state":"failed","attempt":1,"error":{"code":"FEED_JAM","message":"fixture failure","recoverable":true}}}"#.utf8
            )
        ))
        model.handle(
            event: try completedFrameEvent(
                jobId: "first-live-job",
                frameIndex: 2
            )
        )
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"first-live-job","summary":{"completed":[2],"failed":[],"skipped":[],"stopped":false}}}"#.utf8
            )
        ))
        await model.scanSingleFrame(99)

        #expect(model.selectedFrameIndices == [2])
        #expect(!model.receipts.isEmpty)
        #expect(model.jobState != nil)
        #expect(model.progress != nil)
        #expect(model.scanSummary != nil)
        #expect(!model.frameErrors.isEmpty)
        #expect(model.lastErrorMessage != nil)
        #expect(model.frameDefects[2] != nil)
        #expect(model.metadataPreview != nil)
        #expect(model.detailFrameIndex == 2)

        await model.openProject(directory: "/tmp/second-project")

        #expect(model.project?.id == second.id)
        #expect(model.selectedFrameIndices.isEmpty)
        #expect(model.receipts.isEmpty)
        #expect(model.jobId == nil)
        #expect(model.jobState == nil)
        #expect(model.progress == nil)
        #expect(model.scanSummary == nil)
        #expect(model.frameErrors.isEmpty)
        #expect(model.lastErrorMessage == nil)
        #expect(model.errorPresentation == nil)
        #expect(model.frameDefects.isEmpty)
        #expect(model.metadataPreview == nil)
        #expect(model.detailFrameIndex == nil)
        #expect(model.frameStates == [6: .completed])
        #expect(model.pendingFrames == [1, 2, 3, 4, 5])
        #expect(model.completedFrameCount == 1)
    }

    @Test("loading a carrier after reopening a partial project preserves durable completion and exposes resume immediately")
    @MainActor
    func mediaLoadPreservesReopenedProjectProgress() async throws {
        let partial = try projectLifecycleFixture(
            id: "partial-project",
            completedFrames: [4, 5, 6]
        )
        let model = SessionModel(
            engineClient: ProjectFlowEngineStub(project: partial)
        )

        await model.openProject(directory: "/tmp/partial-project")
        #expect(model.pendingFrames == [1, 2, 3])
        #expect(model.completedFrameCount == 3)
        #expect(
            ResumeBatchPolicy.shouldShowResumeBatch(
                completedCount: model.completedFrameCount,
                pendingCount: model.pendingFrameCount
            )
        )

        await model.loadCarrier(.strip6)

        #expect(model.frameStates[4] == .completed)
        #expect(model.frameStates[5] == .completed)
        #expect(model.frameStates[6] == .completed)
        #expect(model.pendingFrames == [1, 2, 3])
        #expect(model.completedFrameCount == 3)
    }

    @Test("project lifecycle changes are rejected until an active scan reaches its terminal completion")
    @MainActor
    func projectChangesAreBlockedDuringActiveScan() async throws {
        let first = try projectLifecycleFixture(
            id: "first-project",
            completedFrames: [4]
        )
        let second = try projectLifecycleFixture(
            id: "second-project",
            completedFrames: []
        )
        let model = SessionModel(
            engineClient: SequencedProjectFlowEngineStub(
                projects: [first, second]
            )
        )

        await model.createProject(
            name: first.name,
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )
        model.beginJob(id: "active-job", frames: [2])

        await model.openProject(directory: "/tmp/second-project")

        #expect(model.project?.id == first.id)
        #expect(model.jobId == "active-job")
        #expect(model.isJobActive)
        #expect(
            model.lastErrorMessage
                == "A scan is still in progress. Wait for it to finish or stop it before changing projects."
        )

        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"active-job","summary":{"completed":[],"failed":[],"skipped":[],"stopped":true}}}"#.utf8
            )
        ))
        await model.openProject(directory: "/tmp/second-project")

        #expect(model.project?.id == second.id)
        #expect(model.jobId == nil)
    }

    @Test(
        "a completed frame stays durably completed when its re-scan stops or fails before a replacement receipt",
        arguments: [
            (failed: false, stopped: true),
            (failed: true, stopped: false),
        ]
    )
    @MainActor
    func rescanWithoutReceiptPreservesDurableCompletion(
        failed: Bool,
        stopped: Bool
    ) async throws {
        let partial = try projectLifecycleFixture(
            id: "partial-project",
            completedFrames: [4]
        )
        let model = SessionModel(
            engineClient: ProjectFlowEngineStub(project: partial)
        )

        await model.openProject(directory: "/tmp/partial-project")
        model.beginJob(id: "rescan-job", frames: [4])
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"rescan-job","frameIndex":4,"state":"active","attempt":1}}"#.utf8
            )
        ))
        if failed {
            model.handle(event: EngineEvent(
                name: "scan.frameState",
                rawLine: Data(
                    #"{"event":"scan.frameState","payload":{"jobId":"rescan-job","frameIndex":4,"state":"failed","attempt":1,"error":{"code":"CAPTURE_FAILED","message":"fixture failure","recoverable":true}}}"#.utf8
                )
            ))
        }

        #expect(model.frameStates[4] == (failed ? .failed : .active))
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                """
                {"event":"scan.completed","payload":{"jobId":"rescan-job","summary":{"completed":[],"failed":\(failed ? "[4]" : "[]"),"skipped":[],"stopped":\(stopped)}}}
                """.utf8
            )
        ))

        #expect(model.frameStates[4] == .completed)
        #expect(model.completedFrameCount == 1)
        #expect(!model.pendingFrames.contains(4))
        #expect(model.receipts.isEmpty)
    }

    @Test(
        "a receipt earned live this session stays durable when the same frame's next attempt stops or fails",
        arguments: [
            (failed: false, stopped: true),
            (failed: true, stopped: false),
        ]
    )
    @MainActor
    func liveReceiptSurvivesLaterRescanWithoutReceipt(
        failed: Bool,
        stopped: Bool
    ) async throws {
        let fresh = try projectLifecycleFixture(
            id: "fresh-project",
            completedFrames: []
        )
        let model = SessionModel(
            engineClient: ProjectFlowEngineStub(project: fresh)
        )

        await model.openProject(directory: "/tmp/fresh-project")
        model.beginJob(id: "first-job", frames: [4])
        model.handle(
            event: try completedFrameEvent(jobId: "first-job", frameIndex: 4)
        )
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"first-job","summary":{"completed":[4],"failed":[],"skipped":[],"stopped":false}}}"#.utf8
            )
        ))
        #expect(model.frameStates[4] == .completed)
        #expect(model.completedFrameCount == 1)

        model.beginJob(id: "rescan-job", frames: [4])
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"rescan-job","frameIndex":4,"state":"active","attempt":1}}"#.utf8
            )
        ))
        if failed {
            model.handle(event: EngineEvent(
                name: "scan.frameState",
                rawLine: Data(
                    #"{"event":"scan.frameState","payload":{"jobId":"rescan-job","frameIndex":4,"state":"failed","attempt":1,"error":{"code":"CAPTURE_FAILED","message":"fixture failure","recoverable":true}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                """
                {"event":"scan.completed","payload":{"jobId":"rescan-job","summary":{"completed":[],"failed":\(failed ? "[4]" : "[]"),"skipped":[],"stopped":\(stopped)}}}
                """.utf8
            )
        ))

        #expect(model.frameStates[4] == .completed)
        #expect(model.completedFrameCount == 1)
        #expect(!model.pendingFrames.contains(4))
        #expect(model.receiptCount == 0)
    }

    @Test("a synchronous preview request failure never establishes a film process")
    @MainActor
    func synchronousPreviewFailureClearsPendingProcess() async {
        let client = ControllablePreviewEngineStub(failAcquireSynchronously: true)
        let model = SessionModel(engineClient: client)
        model.scanFilmProcess = .bwNegative

        #expect(
            await model.requestPreview(.initial(token: PreviewIntentToken()))
                == .failedToStart
        )

        #expect(await client.capturedFilmProcess() == .bwNegative)
        #expect(model.previewFilmProcess == nil)
        #expect(model.isAcquiringThumbnails == false)
        #expect(model.lastErrorMessage?.contains("INVALID_PARAMS") == true)
    }

    @Test("failed preview and media clear cannot establish a preview film process")
    @MainActor
    func previewFailureAndMediaClearLeaveNoEstablishedProcess() async {
        let failedClient = ControllablePreviewEngineStub()
        let failedModel = SessionModel(engineClient: failedClient)
        failedModel.scanFilmProcess = .bwNegative
        let failedToken = PreviewIntentToken()
        let failedOperation = Task {
            await failedModel.requestPreview(
                .initial(token: failedToken)
            )
        }
        await failedClient.waitForAcquireRequest()
        await failedClient.emit(
            "scanner.thumbnailsFailed",
            payloadJSON: #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(failedToken.id.uuidString)","code":"INVALID_PARAMS","message":"preview failed"}}"#
        )
        for _ in 0..<30 where failedModel.isAcquiringThumbnails { await Task.yield() }
        #expect(failedModel.previewFilmProcess == nil)
        #expect(failedModel.isAcquiringThumbnails == false)
        await failedClient.resumeAcquireAck()
        _ = await failedOperation.value

        let mediaClient = ControllablePreviewEngineStub()
        let mediaModel = SessionModel(engineClient: mediaClient)
        mediaModel.scanFilmProcess = .bwNegative
        let mediaToken = PreviewIntentToken()
        let mediaOperation = Task {
            await mediaModel.requestPreview(
                .initial(token: mediaToken)
            )
        }
        await mediaClient.waitForAcquireRequest()
        await mediaClient.emit(
            "scanner.status",
            payloadJSON: #"{"event":"scanner.status","payload":{"operationId":"\#(mediaToken.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#
        )
        for _ in 0..<30 where mediaModel.status == nil { await Task.yield() }
        #expect(mediaModel.previewFilmProcess == nil)
        #expect(mediaModel.isAcquiringThumbnails)
        await mediaClient.emit(
            "scanner.thumbnailsFailed",
            payloadJSON: #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(mediaToken.id.uuidString)","code":"NO_MEDIA","message":"media reset during preview"}}"#
        )
        for _ in 0..<30 where mediaModel.isAcquiringThumbnails { await Task.yield() }
        #expect(mediaModel.isAcquiringThumbnails == false)
        await mediaClient.resumeAcquireAck()
        _ = await mediaOperation.value
    }

    @Test("terminal job events cannot be overwritten by delayed earlier events")
    func terminalJobStateIsMonotonic() {
        #expect(SessionEventPolicy.allowsJobTransition(from: .queued, to: .scanning))
        #expect(SessionEventPolicy.allowsJobTransition(from: .queued, to: .stopped))
        #expect(!SessionEventPolicy.allowsJobTransition(from: .queued, to: .completed))
        #expect(!SessionEventPolicy.allowsJobTransition(from: .queued, to: .stoppingImmediately))
        #expect(SessionEventPolicy.allowsJobTransition(from: .scanning, to: .completed))
        #expect(!SessionEventPolicy.allowsJobTransition(from: .completed, to: .scanning))
        #expect(!SessionEventPolicy.allowsJobTransition(from: .stopped, to: .queued))
    }

    @Test("terminal frame events cannot be overwritten by delayed earlier events")
    func terminalFrameStateIsMonotonic() {
        #expect(SessionEventPolicy.allowsFrameTransition(from: .waiting, to: .active))
        #expect(SessionEventPolicy.allowsFrameTransition(from: .active, to: .completed))
        #expect(SessionEventPolicy.allowsFrameTransition(from: .failed, to: .active))
        #expect(!SessionEventPolicy.allowsFrameTransition(from: .completed, to: .active))
        #expect(!SessionEventPolicy.allowsFrameTransition(from: .failed, to: .waiting))
    }

    @Test("compatibility failures are typed and preserve their explanation")
    func compatibilityErrorIsTyped() {
        let error = EngineCompatibilityError(reason: "Protocol version mismatch")
        #expect(error.reason == "Protocol version mismatch")
    }

    @Test("an immediate stop request uses the protocol's immediate mode")
    func immediateStopRequestEncoding() throws {
        let request = RequestEnvelope(
            id: 42,
            method: "scan.stop",
            params: ScanStopParams(jobId: "job-42", mode: "immediate")
        )
        let decoded = try JSONDecoder().decode(
            DecodedRequestEnvelope<ScanStopParams>.self,
            from: JSONEncoder().encode(request)
        )

        #expect(decoded.method == "scan.stop")
        #expect(decoded.params.jobId == "job-42")
        #expect(decoded.params.mode == "immediate")
    }

    @Test("an unexpected engine exit clears unsafe session state and is visible")
    @MainActor
    func unexpectedEngineExitIsVisible() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)

        let busyStatus = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30 (simulated)","mediaLoaded":true,"carrier":"roll36","frameCount":36,"lamp":"stable","transport":"busy","activeJobId":"job-1"}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: busyStatus))

        let token = PreviewIntentToken()
        #expect(await model.requestPreview(.initial(token: token)) == .started)
        let thumbnail = Data(
            #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":{"brightness":0.5,"tint":0.0}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.thumbnail", rawLine: thumbnail))
        #expect(model.status?.transport == "busy")
        #expect(model.thumbnails[1] != nil)

        model.handle(event: EngineEvent(name: "engine.terminated", rawLine: Data()))

        #expect(model.status == nil)
        #expect(model.thumbnails.isEmpty)
        #expect(model.lastErrorMessage?.contains("stopped unexpectedly") == true)
    }

    @Test("a media-clear status event closes stale frame detail")
    @MainActor
    func mediaClearClosesFrameDetail() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.openFrameDetail(4)

        let notLoaded = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: notLoaded))

        #expect(model.detailFrameIndex == nil)
        await client.terminate()
    }

    @Test("creating or opening a positive roll updates the processing recipe")
    @MainActor
    func projectFilmProcessSynchronizesSessionProcessing() async {
        let project = ScanProject(
            schemaVersion: 1,
            id: "positive-roll",
            name: "Positive roll",
            carrier: .mounted,
            frameCount: 1,
            filmProcess: .positive,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/tmp/archive"),
                positive: PositiveRecipe(enabled: true, fileFormat: .tiff, colorProfile: .adobeRgb1998, filenameTemplate: "Positive_####", destination: "/tmp/positive"),
                preview: PreviewRecipe(enabled: true, fileFormat: .jpeg, maxLongEdgePx: 1024, filenameTemplate: "Preview_####", destination: "/tmp/preview")
            ),
            rollMetadata: MetadataSet(),
            createdAt: "2026-07-26T00:00:00Z",
            frames: [ProjectFrame(index: 1, excluded: false, receipts: [])]
        )
        let model = SessionModel(engineClient: ProjectFlowEngineStub(project: project))
        model.scanFilmProcess = .c41ColorNegative

        await model.createProject(name: "Positive roll", carrier: .mounted, frameCount: 1, filmProcess: .positive)
        #expect(model.scanFilmProcess == .positive)

        model.scanFilmProcess = .c41ColorNegative
        await model.openProject(directory: "/tmp/positive-roll")
        #expect(model.scanFilmProcess == .positive)
    }

    @Test("a saved naming default survives new-project creation while an opened recipe remains authoritative")
    @MainActor
    func namingDefaultOnlySeedsNewProjects() async throws {
        let suite = "ScanStudioKitTests.naming.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = ScanProject(
            schemaVersion: 1, id: "roll", name: "Roll", carrier: .mounted, frameCount: 1,
            filmProcess: .positive,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/tmp/archive"),
                positive: PositiveRecipe(enabled: true, fileFormat: .jpeg, colorProfile: .sRgb, filenameTemplate: "Positive_####", destination: "/tmp/positive"),
                preview: PreviewRecipe(enabled: true, fileFormat: .tiff, maxLongEdgePx: 1024, filenameTemplate: "Preview_####", destination: "/tmp/preview")
            ), rollMetadata: MetadataSet(), createdAt: "2026-07-26T00:00:00Z",
            frames: [ProjectFrame(index: 1, excluded: false, receipts: [])]
        )
        let fresh = SessionModel(engineClient: ProjectFlowEngineStub(project: project), preferences: preferences)
        await fresh.createProject(name: "Fresh roll", carrier: .mounted, frameCount: 1, filmProcess: .positive)
        #expect(fresh.archiveFilenameTemplate == FilenameTemplate.defaultTemplate)
        #expect(fresh.outputRecipe.archive.destination == "/tmp/archive")
        #expect(!fresh.outputRecipe.archive.destination.contains("_Unfiled"))
        let first = SessionModel(engineClient: ProjectFlowEngineStub(project: project), preferences: preferences)
        first.archiveFilenameTemplate = "$FilmStock-$Camera-$Frame"
        first.saveCurrentFilenameTemplateAsUserDefault()

        let model = SessionModel(engineClient: ProjectFlowEngineStub(project: project), preferences: preferences)
        await model.createProject(name: "New roll", carrier: .mounted, frameCount: 1, filmProcess: .positive)
        #expect(model.archiveFilenameTemplate == "$FilmStock-$Camera-$Frame")
        #expect(model.outputRecipe.archive.filenameTemplate.contains("$FilmStock-$Camera-$Frame"))

        await model.openProject(directory: "/tmp/positive-roll")
        #expect(model.archiveFilenameTemplate == "Archive_####")
        #expect(model.positiveFileFormat == .jpeg)
        #expect(model.outputRecipe.positive.fileFormat == .jpeg)
        #expect(model.previewFileFormat == .tiff)
        #expect(model.outputRecipe.preview.fileFormat == .tiff)
        model.applyScanRecipePreset(.masterTiffJpeg)
        #expect(model.positiveFileFormat == .tiff)
        #expect(model.previewFileFormat == .jpeg)
    }

    @Test("custom stock transition makes B&W capture safe")
    @MainActor
    func customStockBwSynchronizesCaptureState() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.applyFilmStock(FilmStock.matching(metadataName: "Kodak Gold 200"))
        model.beginCustomFilmStock()
        #expect(model.isCustomFilmStockSelected)
        #expect(model.rollMetadataDraft.filmStock == nil)
        model.applyCustomFilmProcess(.bwNegative)
        #expect(model.rollMetadataDraft.process == .bwNegative)
        #expect(model.scanFilmProcess == .bwNegative)
        #expect(model.scanChannels == "rgb")
        #expect(!model.digitalIceEnabled)
        await client.terminate()
    }

    @Test("a REFEED_REQUIRED preview failure surfaces typed and arms the eject affordance")
    @MainActor
    func refeedRequiredPreviewFailureArmsEject() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let token = PreviewIntentToken()
        #expect(await model.requestPreview(.initial(token: token)) == .started)

        let failed = Data(
            #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(token.id.uuidString)","code":"REFEED_REQUIRED","message":"transport read was not one uniform traversal; eject or refeed the strip and run the preview again"}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.thumbnailsFailed", rawLine: failed))

        #expect(model.refeedRequired)
        #expect(model.isAcquiringThumbnails == false)
        #expect(model.lastErrorMessage?.contains("REFEED_REQUIRED") == true)
        #expect(model.lastErrorMessage?.contains("eject or refeed") == true)

        // The engine re-emits a not-media-loaded status right after a failed
        // preview (real_backend.rs previewError arm) — the media-state clear
        // that triggers must NOT erase the refeed verdict it accompanies.
        let notLoaded = Data(
            #"{"event":"scanner.status","payload":{"operationId":"\#(token.id.uuidString)","status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: notLoaded))
        #expect(model.refeedRequired)
    }

    @Test("a FEEDER_PARKED preview failure surfaces typed but does NOT arm eject")
    @MainActor
    func feederParkedPreviewFailureDoesNotArmEject() async {
        let client = CountingPreviewEngineStub()
        let model = SessionModel(engineClient: client)
        let token = PreviewIntentToken()
        #expect(await model.requestPreview(.initial(token: token)) == .started)

        // INCIDENT-20260719: eject against a parked transport is the
        // accepted-but-inert stall; recovery is a power cycle, so offering
        // the eject affordance here would invite exactly that stall.
        let parked = Data(
            #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(token.id.uuidString)","code":"FEEDER_PARKED","message":"transport parked at end-stop; power cycle required before further motion"}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.thumbnailsFailed", rawLine: parked))

        #expect(model.refeedRequired == false)
        #expect(model.lastErrorMessage?.contains("FEEDER_PARKED") == true)
    }

    @Test("a synchronous scan.start REFEED_REQUIRED refusal arms the eject affordance")
    @MainActor
    func synchronousScanStartRefusalArmsEject() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        model.noteRefeedRequired(from: EngineRequestError(
            code: "internal",
            message: "bridge error REFEED_REQUIRED: scan_many's fresh index read failed from the parked transport",
            recoverable: false
        ))
        #expect(model.refeedRequired)
        await client.terminate()
    }

    @Test("an unrelated engine error never arms the eject affordance")
    @MainActor
    func unrelatedErrorDoesNotArmEject() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        model.noteRefeedRequired(from: EngineRequestError(
            code: "invalidParams",
            message: "multisamplePasses must be one of [4]",
            recoverable: false
        ))
        #expect(model.refeedRequired == false)
        await client.terminate()
    }

    @Test("all supported simulated carriers expose their correct frame counts")
    func simulatedCarrierFrameCounts() {
        #expect(SimulatedFilmCarrier.mounted.rawValue == "mounted")
        #expect(SimulatedFilmCarrier.mounted.frameCount == 1)
        #expect(SimulatedFilmCarrier.strip6.rawValue == "strip6")
        #expect(SimulatedFilmCarrier.strip6.frameCount == 6)
        #expect(SimulatedFilmCarrier.roll36.rawValue == "roll36")
        #expect(SimulatedFilmCarrier.roll36.frameCount == 36)
    }

    @Test("editable batch settings become the exact engine capture recipe")
    @MainActor
    func editableSettingsBuildCaptureRecipe() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.scanResolutionDpi = 2_000
        model.scanBitDepth = 8
        model.scanMultisamplePasses = 4
        model.scanChannels = "rgb"

        #expect(model.captureRecipe == CaptureRecipe(
            resolutionDpi: 2_000,
            bitDepth: 8,
            multisamplePasses: 4,
            channels: "rgb"
        ))
        await client.terminate()
    }

    @Test("4000 ppi 16-bit RGB TIFF estimates use the LS-5000 scan area")
    func fullResolutionTiffSizeUsesScannerGeometry() {
        #expect(ScanSizeEstimator.uncompressedBytes(
            carrier: .mounted,
            resolutionDpi: 4_000,
            bitDepth: 16,
            colorChannels: 3
        ) == 136_894_632)
        #expect(ScanSizeEstimator.uncompressedBytes(
            carrier: .roll36,
            resolutionDpi: 4_000,
            bitDepth: 16,
            colorChannels: 3
        ) == 141_085_284)
        #expect(ScanSizeEstimator.positiveBytesPerFrame(
            carrier: .roll36,
            resolutionDpi: 4_000,
            bitDepth: 16,
            fileFormat: .jpeg
        ) == Int(Double(ScanSizeEstimator.uncompressedBytes(
            carrier: .roll36,
            resolutionDpi: 4_000,
            bitDepth: 8,
            colorChannels: 3
        )) * 0.18))
        #expect(ScanSizeEstimator.positiveBytesPerFrame(
            carrier: .roll36, resolutionDpi: 4_000, bitDepth: 8, fileFormat: .tiff
        ) == ScanSizeEstimator.uncompressedBytes(
            carrier: .roll36, resolutionDpi: 4_000, bitDepth: 16, colorChannels: 3
        ))
        // A cap far larger than the native long edge makes downsampling a
        // no-op; preview is always treated as 8-bit regardless of the
        // capture's own bit depth.
        #expect(ScanSizeEstimator.previewBytesPerFrame(
            carrier: .roll36,
            resolutionDpi: 4_000,
            maxLongEdgePx: 999_999,
            fileFormat: .tiff
        ) == ScanSizeEstimator.uncompressedBytes(
            carrier: .roll36,
            resolutionDpi: 4_000,
            bitDepth: 8,
            colorChannels: 3
        ))
        #expect(ScanSizeEstimator.previewBytesPerFrame(
            carrier: .roll36,
            resolutionDpi: 4_000,
            maxLongEdgePx: 1_024,
            fileFormat: .tiff
        ) < ScanSizeEstimator.previewBytesPerFrame(
            carrier: .roll36,
            resolutionDpi: 4_000,
            maxLongEdgePx: 999_999,
            fileFormat: .tiff
        ))
    }

    @Test("the Archive + Positive + Preview preset enables both derivatives without locking any field")
    @MainActor
    func presetEnablesDerivativesWithoutLockingFields() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.positiveEnabled = false
        model.previewEnabled = false

        model.applyArchivePositivePreviewPreset()

        #expect(model.positiveEnabled == true)
        #expect(model.previewEnabled == true)

        // Every field stays individually editable immediately afterward —
        // the preset is a one-time assignment, not a lock.
        model.positiveEnabled = false
        #expect(model.positiveEnabled == false)
        await client.terminate()
    }

    @Test("processing and save choices become engine job recipes")
    @MainActor
    func editableProcessingAndOutputRecipes() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.scanFilmProcess = .c41ColorNegative
        model.autofocusEachFrame = false
        model.autoExposureEachFrame = true
        model.digitalIceEnabled = true
        model.digitalIceMode = .hybrid
        model.archiveFilenameTemplate = "Archive_####"
        model.archiveDestination = "/Scans/Archive"
        model.positiveEnabled = true
        model.positiveFileFormat = .tiff
        model.positiveColorProfile = .proPhotoRgb
        model.positiveFilenameTemplate = "Positive_####"
        model.positiveDestination = "/Scans/Positive"
        model.previewEnabled = false
        model.previewFileFormat = .jpeg
        model.previewMaxLongEdgePx = 1_024
        model.previewFilenameTemplate = "Preview_####"
        model.previewDestination = "/Scans/Preview"

        #expect(model.processingRecipe == ProcessingRecipe(
            filmProcess: .c41ColorNegative,
            autofocusEachFrame: false,
            autoExposureEachFrame: true,
            digitalIceEnabled: true,
            digitalIceMode: .hybrid
        ))
        #expect(model.outputRecipe == OutputRecipe(
            archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/Scans/Archive"),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .proPhotoRgb,
                filenameTemplate: "Positive_####",
                destination: "/Scans/Positive"
            ),
            preview: PreviewRecipe(
                enabled: false,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/Scans/Preview"
            )
        ))
        await client.terminate()
    }

    @Test("the auto-crop toggle flows into the roll-wide output recipe")
    @MainActor
    func autoCropToggleFlowsIntoOutputRecipe() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        #expect(!model.outputRecipe.autoCrop, "auto-crop is off by default")

        model.setAutoCropEnabled(true)
        #expect(model.outputRecipe.autoCrop)

        model.setAutoCropEnabled(false)
        #expect(!model.outputRecipe.autoCrop)
        await client.terminate()
    }

    @Test("scan.frameState stores per-frame attempt and error")
    @MainActor
    func frameStateStoresAttemptAndError() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"

        let frameState = Data(
            #"{"event":"scan.frameState","payload":{"jobId":"job-1","frameIndex":3,"state":"failed","attempt":2,"error":{"code":"FEED_JAM","message":"jam","recoverable":true}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scan.frameState", rawLine: frameState))

        #expect(model.frameAttempts[3] == 2)
        #expect(model.frameErrors[3]?.code == "FEED_JAM")
        #expect(model.frameErrors[3]?.recoverable == true)
        await client.terminate()
    }

    @Test("a later scan.frameState with error null clears the previous error")
    @MainActor
    func frameStateClearsErrorOnRetry() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"

        let failure = Data(
            #"{"event":"scan.frameState","payload":{"jobId":"job-1","frameIndex":3,"state":"failed","attempt":2,"error":{"code":"FEED_JAM","message":"jam","recoverable":true}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scan.frameState", rawLine: failure))
        #expect(model.frameErrors[3] != nil)

        let retry = Data(
            #"{"event":"scan.frameState","payload":{"jobId":"job-1","frameIndex":3,"state":"active","attempt":3,"error":null}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scan.frameState", rawLine: retry))

        #expect(model.frameAttempts[3] == 3)
        #expect(model.frameErrors[3] == nil)
        await client.terminate()
    }

    @Test("thumbnail admission: mediaLoaded alone is sufficient — the simulator's own path (status already carries mediaLoaded/frameCount before acquireThumbnails runs)")
    func thumbnailAdmissionMediaLoadedPath() {
        #expect(ThumbnailAdmissionPolicy.shouldAdmit(
            frameIndex: 1,
            mediaLoaded: true,
            isAcquiringThumbnails: false,
            statusFrameCount: 36,
            projectFrameCount: nil
        ))
    }

    @Test("thumbnail admission: a real preview can begin before a project or count exists")
    func thumbnailAdmissionRealBackendPath() {
        for frameIndex in [1, 39, 40] {
            #expect(ThumbnailAdmissionPolicy.shouldAdmit(
                frameIndex: frameIndex,
                mediaLoaded: false,
                isAcquiringThumbnails: true,
                statusFrameCount: nil,
                projectFrameCount: nil
            ))
        }
    }

    @Test("thumbnail admission: neither mediaLoaded nor isAcquiringThumbnails rejects the event")
    func thumbnailAdmissionRejectsWithNeitherSignal() {
        #expect(!ThumbnailAdmissionPolicy.shouldAdmit(
            frameIndex: 1,
            mediaLoaded: false,
            isAcquiringThumbnails: false,
            statusFrameCount: 36,
            projectFrameCount: 36
        ))
    }

    // MARK: - ThumbnailAdmissionPolicy ceiling fix (root cause: a real
    // roll that physically holds more frames than the open project's own
    // nominal count — 39 detected vs. a 36-nominal project — kept losing
    // tiles 37-39 during acquisition, since `statusFrameCount` stays `nil`
    // for a real backend's entire streaming window and the old ceiling
    // was always `statusFrameCount ?? projectFrameCount ?? 0`, i.e. always
    // 36 here. Verified live 2026-07-25.)

    @Test("thumbnail admission: a real frame beyond a 36-nominal project's own count is admitted while actively acquiring (the exact 39-frame-roll-on-a-36-nominal-project bug, verified live 2026-07-25)")
    func thumbnailAdmissionAdmitsRealFrameBeyondNominalCeilingWhileAcquiring() {
        for frameIndex in 37...39 {
            #expect(ThumbnailAdmissionPolicy.shouldAdmit(
                frameIndex: frameIndex,
                mediaLoaded: false,
                isAcquiringThumbnails: true,
                statusFrameCount: nil,
                projectFrameCount: 36
            ), "frame \(frameIndex) should be admitted while acquiring")
        }
    }

    @Test("thumbnail admission: an absurd index beyond the device family's physical slot capacity is rejected even while acquiring")
    func thumbnailAdmissionRejectsBeyondPhysicalCeilingWhileAcquiring() {
        #expect(!ThumbnailAdmissionPolicy.shouldAdmit(
            frameIndex: ThumbnailAdmissionPolicy.maximumPhysicalFrameIndex + 1,
            mediaLoaded: false,
            isAcquiringThumbnails: true,
            statusFrameCount: nil,
            projectFrameCount: 36
        ))
        #expect(ThumbnailAdmissionPolicy.shouldAdmit(
            frameIndex: ThumbnailAdmissionPolicy.maximumPhysicalFrameIndex,
            mediaLoaded: false,
            isAcquiringThumbnails: true,
            statusFrameCount: nil,
            projectFrameCount: 1
        ), "the physical ceiling itself is still an admitted index, not an off-by-one exclusion")
    }

    @Test("thumbnail admission: once acquisition settles, the tighter nominal ceiling applies again — a late straggler beyond the nominal count is rejected")
    func thumbnailAdmissionRevertsToNominalCeilingOnceSettled() {
        #expect(!ThumbnailAdmissionPolicy.shouldAdmit(
            frameIndex: 37,
            mediaLoaded: true,
            isAcquiringThumbnails: false,
            statusFrameCount: nil,
            projectFrameCount: 36
        ))
    }

    @Test("thumbnail admission: once acquisition has settled, capacity-only status cannot create scan slots")
    func thumbnailAdmissionRejectsWithNoFrameCeiling() {
        #expect(!ThumbnailAdmissionPolicy.shouldAdmit(
            frameIndex: 1,
            mediaLoaded: true,
            isAcquiringThumbnails: false,
            statusFrameCount: nil,
            projectFrameCount: nil
        ))
    }

    @Test("capacity-only real holder status cannot create selectable scan slots")
    @MainActor
    func capacityOnlyHolderCreatesNoScanSlots() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        let capacityOnlyStatus = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30","mediaLoaded":false,"carrier":"roll36","lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: capacityOnlyStatus))

        model.toggleFrameSelection(1)
        #expect(model.selectedFrames.isEmpty)
        #expect(model.scanReadiness(for: [1]) == .projectRequired)
        await client.terminate()
    }

    @Test("scanner.thumbnail is ignored end-to-end through SessionModel.handle before any mediaLoaded/acquisition signal has arrived")
    @MainActor
    func thumbnailIgnoredWithNoSignalYet() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        let thumbnail = Data(
            #"{"event":"scanner.thumbnail","payload":{"frameIndex":1,"thumbnail":{"brightness":0.5,"tint":0.0}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.thumbnail", rawLine: thumbnail))

        #expect(model.thumbnails.isEmpty)
        await client.terminate()
    }

    @Test("scan.frameCompleted computes transport-smear reason from receipt hardwareTelemetry")
    @MainActor
    func frameCompletedComputesTransportSmear() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"

        let smearCompleted = Data(
            #"{"event":"scan.frameCompleted","payload":{"jobId":"job-1","frameIndex":5,"receipt":{"jobId":"job-1","frameIndex":5,"startedAt":"2024-01-01T00:00:00Z","durationMs":1000,"passes":1,"resolutionDpi":4000,"bitDepth":16,"channels":"rgbi","engineVersion":"0.1.0","deviceId":"real-ls5000-0","simulated":false,"settingsFingerprint":"abc","hardwareTelemetry":{"exposure":{"focusPosition":0,"exposureMultiplier":1,"redExposureUs":1,"greenExposureUs":1,"blueExposureUs":1},"clipping":{"fractions":[0,0,0],"clipLevel":1,"warningFraction":0.1,"warning":false},"focusDetail":{"method":"contrast","verdict":"sharp","score":null,"textureSpan":0.5},"transportSmear":{"verdict":"smear","startRow":10,"suffixRows":5,"minimumMatches":3,"tailMedianRms":null,"tailMinCorr":null,"preTailMedianRms":null,"textureSpan":null,"reason":"trailing edge blur"}}}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scan.frameCompleted", rawLine: smearCompleted))
        #expect(model.frameTransportSmearReasons[5] == "trailing edge blur")

        let cleanCompleted = Data(
            #"{"event":"scan.frameCompleted","payload":{"jobId":"job-1","frameIndex":6,"receipt":{"jobId":"job-1","frameIndex":6,"startedAt":"2024-01-01T00:00:01Z","durationMs":1000,"passes":1,"resolutionDpi":4000,"bitDepth":16,"channels":"rgbi","engineVersion":"0.1.0","deviceId":"real-ls5000-0","simulated":false,"settingsFingerprint":"def","hardwareTelemetry":{"exposure":{"focusPosition":0,"exposureMultiplier":1,"redExposureUs":1,"greenExposureUs":1,"blueExposureUs":1},"clipping":{"fractions":[0,0,0],"clipLevel":1,"warningFraction":0.1,"warning":false},"focusDetail":{"method":"contrast","verdict":"sharp","score":null,"textureSpan":0.5},"transportSmear":{"verdict":"clean","startRow":null,"suffixRows":0,"minimumMatches":0,"tailMedianRms":null,"tailMinCorr":null,"preTailMedianRms":null,"textureSpan":null,"reason":""}}}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scan.frameCompleted", rawLine: cleanCompleted))
        #expect(model.frameTransportSmearReasons[6] == nil)

        await client.terminate()
    }

    // MARK: - ResumeBatchPolicy (root cause: ScanPanelView.showResumeBatch
    // used to compare `pendingFrameCount` against `status?.frameCount`, a
    // completely different frame-count signal. A brand-new project with
    // zero receipts and a nominal 36-frame roll read as "partial" whenever
    // a real preview detected more physical frames (e.g. 39) than the
    // project's own nominal count — verified live 2026-07-25. The fix
    // requires `completedCount > 0`, sourced from the same
    // `project.pendingFrames` manifest response `pendingFrameCount` already
    // uses, never from `status.frameCount`.)

    @Test("resume batch never appears for a fresh project with zero completed frames, even though its pending count alone looks like a partial roll")
    func resumeBatchHiddenForFreshProjectWithZeroReceipts() {
        // The exact live bug: 36 nominal frames pending, none completed.
        #expect(!ResumeBatchPolicy.shouldShowResumeBatch(completedCount: 0, pendingCount: 36))
    }

    @Test("resume batch appears once at least one frame has completed and at least one is still pending")
    func resumeBatchShownForGenuinePartialRoll() {
        #expect(ResumeBatchPolicy.shouldShowResumeBatch(completedCount: 10, pendingCount: 26))
    }

    @Test("resume batch never appears once every frame is already complete — nothing left to resume")
    func resumeBatchHiddenWhenFullyComplete() {
        #expect(!ResumeBatchPolicy.shouldShowResumeBatch(completedCount: 36, pendingCount: 0))
    }

    @Test("resume batch never appears for a project with no pending frames and no completed frames either (e.g. every remaining frame excluded)")
    func resumeBatchHiddenWithNothingPendingOrCompleted() {
        #expect(!ResumeBatchPolicy.shouldShowResumeBatch(completedCount: 0, pendingCount: 0))
    }

    // MARK: - FrameRangeSelection (Shift-click range-select helper)

    @Test("frame range selection is inclusive and order-independent regardless of click direction")
    func frameRangeSelectionIsOrderIndependent() {
        #expect(FrameRangeSelection.inclusiveRange(anchor: 5, clicked: 10) == 5...10)
        #expect(FrameRangeSelection.inclusiveRange(anchor: 10, clicked: 5) == 5...10)
    }

    @Test("frame range selection collapses to a single frame when the anchor and the clicked frame are the same")
    func frameRangeSelectionCollapsesToSingleFrame() {
        #expect(FrameRangeSelection.inclusiveRange(anchor: 7, clicked: 7) == 7...7)
    }

    // MARK: - SessionModel.selectFrame (Shift-click range-select wiring)

    @Test("selectFrame: a plain click toggles the frame and moves the range anchor; a later Shift-click adds the inclusive range from that anchor")
    @MainActor
    func selectFramePlainClickThenShiftClickAddsRange() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        let status = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30 (simulated)","mediaLoaded":true,"carrier":"roll36","frameCount":36,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: status))

        model.selectFrame(5, extendingSelectionIfShiftHeld: false)
        #expect(model.selectedFrameIndices == Set([5]))
        #expect(model.selectionAnchorFrameIndex == 5)

        model.selectFrame(10, extendingSelectionIfShiftHeld: true)
        #expect(model.selectedFrameIndices == Set(5...10))
        // Shift-click never moves the anchor.
        #expect(model.selectionAnchorFrameIndex == 5)

        await client.terminate()
    }

    @Test("selectFrame: Shift-click range-select only adds — it never drops frames selected outside the range")
    @MainActor
    func selectFrameShiftClickOnlyAddsNeverRemoves() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        let status = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30 (simulated)","mediaLoaded":true,"carrier":"roll36","frameCount":36,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: status))

        model.selectFrame(30, extendingSelectionIfShiftHeld: false)
        model.selectFrame(5, extendingSelectionIfShiftHeld: false)
        #expect(model.selectedFrameIndices == Set([5, 30]))
        // The anchor followed the second plain click.
        #expect(model.selectionAnchorFrameIndex == 5)

        model.selectFrame(8, extendingSelectionIfShiftHeld: true)
        // 5...8 gets added; frame 30 (outside the range) stays selected.
        #expect(model.selectedFrameIndices == Set(5...8).union([30]))

        await client.terminate()
    }

    @Test("selectFrame: a Shift-click before any anchor exists falls back to a plain toggle and still establishes the anchor")
    @MainActor
    func selectFrameShiftClickWithNoAnchorBootstraps() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        let status = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30 (simulated)","mediaLoaded":true,"carrier":"roll36","frameCount":36,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: status))

        #expect(model.selectionAnchorFrameIndex == nil)
        model.selectFrame(12, extendingSelectionIfShiftHeld: true)
        #expect(model.selectedFrameIndices == Set([12]))
        #expect(model.selectionAnchorFrameIndex == 12)

        model.selectFrame(15, extendingSelectionIfShiftHeld: true)
        #expect(model.selectedFrameIndices == Set(12...15))

        await client.terminate()
    }

    @Test("selectFrame: an out-of-range frame index is ignored, mirroring toggleFrameSelection's own guard")
    @MainActor
    func selectFrameIgnoresOutOfRangeIndex() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        let status = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30 (simulated)","mediaLoaded":true,"carrier":"roll36","frameCount":36,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: status))

        model.selectFrame(99, extendingSelectionIfShiftHeld: false)
        #expect(model.selectedFrameIndices.isEmpty)
        #expect(model.selectionAnchorFrameIndex == nil)

        await client.terminate()
    }

    // MARK: - MultisamplePassPolicy (root cause: the Scan Settings
    // Multi-sampling popup offered a fixed [1,2,4,8,16] regardless of which
    // device was connected; the real LS-5000 only accepts 4x and rejects
    // everything else from `scan.start` with INVALID_PARAMS — the owner
    // hit this twice live on 2026-07-25.)

    @Test("MultisamplePassPolicy: no device connected offers the fuller simulator-shaped range")
    func multisamplePassPolicyNoDeviceOffersSimulatedRange() {
        #expect(MultisamplePassPolicy.supportedOptions(for: nil) == [1, 2, 4, 8, 16])
    }

    @Test("MultisamplePassPolicy: a real device with no wire-reported capability list falls back to the documented [4]-only LS-5000 constraint")
    func multisamplePassPolicyRealDeviceFallsBackToFour() {
        let device = DeviceInfo(
            deviceId: "real-ls5000-0", model: "SUPER COOLSCAN 5000 ED", kind: "real",
            firmware: "bridge 0.1.0", connection: "USB (bridge)", supportedMultisamplePasses: nil
        )
        #expect(MultisamplePassPolicy.supportedOptions(for: device) == [4])
    }

    @Test("MultisamplePassPolicy: an empty wire-reported capability list is treated as absent, falling back to the kind-based default rather than offering zero options")
    func multisamplePassPolicyEmptyWireListFallsBackToKindDefault() {
        let device = DeviceInfo(
            deviceId: "real-ls5000-0", model: "SUPER COOLSCAN 5000 ED", kind: "real",
            firmware: "bridge 0.1.0", connection: "USB (bridge)", supportedMultisamplePasses: []
        )
        #expect(MultisamplePassPolicy.supportedOptions(for: device) == [4])
    }

    @Test("MultisamplePassPolicy: a simulated device keeps the fuller range even as an explicit DeviceInfo, not nil")
    func multisamplePassPolicySimulatedDeviceKeepsFullRange() {
        let device = DeviceInfo(
            deviceId: "sim-ls5000-0", model: "SUPER COOLSCAN 5000 ED", kind: "simulated",
            firmware: "1.03-sim", connection: "USB (simulated)", supportedMultisamplePasses: nil
        )
        #expect(MultisamplePassPolicy.supportedOptions(for: device) == [1, 2, 4, 8, 16])
    }

    @Test("MultisamplePassPolicy: a device that DOES report its own wire capability list is preferred (sorted) over both hardcoded fallbacks — forward-compatible with a future engine build that forwards it")
    func multisamplePassPolicyPrefersWireReportedList() {
        let device = DeviceInfo(
            deviceId: "real-ls9000-0", model: "SUPER COOLSCAN 9000 ED", kind: "real",
            firmware: "bridge 0.2.0", connection: "USB (bridge)", supportedMultisamplePasses: [8, 4]
        )
        #expect(MultisamplePassPolicy.supportedOptions(for: device) == [4, 8])
    }

    @Test("MultisamplePassPolicy.coerce leaves an already-supported value unchanged")
    func multisamplePassPolicyCoerceLeavesValidValueUnchanged() {
        #expect(MultisamplePassPolicy.coerce(4, into: [4]) == 4)
    }

    @Test("MultisamplePassPolicy.coerce moves an unsupported value to the nearest supported one, breaking ties toward the lower value")
    func multisamplePassPolicyCoerceMovesToNearest() {
        #expect(MultisamplePassPolicy.coerce(2, into: [4]) == 4)
        #expect(MultisamplePassPolicy.coerce(6, into: [4, 8]) == 4)
        #expect(MultisamplePassPolicy.coerce(9, into: [4, 8]) == 8)
    }

    @Test("MultisamplePassPolicy.coerce is a no-op against an empty options list")
    func multisamplePassPolicyCoerceNoOpOnEmptyOptions() {
        #expect(MultisamplePassPolicy.coerce(2, into: []) == 2)
    }

    @Test("MultisamplePassPolicy.label/optionsDescription render \"Off\" for 1x and \"N×\" for the rest")
    func multisamplePassPolicyLabelsAndDescriptions() {
        #expect(MultisamplePassPolicy.label(for: 1) == "Off")
        #expect(MultisamplePassPolicy.label(for: 4) == "4×")
        #expect(MultisamplePassPolicy.optionsDescription([1, 4]) == "Off, 4×")
    }

    // MARK: - SessionActivitySummary (session-aware sidebar status card)

    @Test("SessionActivitySummary is idle when neither a job nor an acquisition is active")
    func sessionActivitySummaryIdle() {
        let summary = SessionActivitySummary.current(
            isJobActive: false, isAcquiringThumbnails: false, receiptCount: 0,
            lastCompletedFrame: nil, progressTotalFrames: nil,
            thumbnailCount: 0, lastLoadedFrame: nil, statusFrameCount: nil
        )
        #expect(summary == .idle)
    }

    @Test("SessionActivitySummary.scanning reports completed/remaining/lastCompletedFrame from receiptCount and progress, mirroring ScanPanelView's own already-trusted signals")
    func sessionActivitySummaryScanning() {
        let summary = SessionActivitySummary.current(
            isJobActive: true, isAcquiringThumbnails: false, receiptCount: 10,
            lastCompletedFrame: 10, progressTotalFrames: 36,
            thumbnailCount: 36, lastLoadedFrame: 36, statusFrameCount: 36
        )
        #expect(summary == .scanning(completed: 10, remaining: 26, lastCompletedFrame: 10))
    }

    @Test("SessionActivitySummary.scanning keeps remaining unknown when no running total is reported")
    func sessionActivitySummaryScanningKeepsUnknownTotal() {
        let summary = SessionActivitySummary.current(
            isJobActive: true, isAcquiringThumbnails: false, receiptCount: 0,
            lastCompletedFrame: nil, progressTotalFrames: nil,
            thumbnailCount: 0, lastLoadedFrame: nil, statusFrameCount: nil
        )
        #expect(summary == .scanning(completed: 0, remaining: nil, lastCompletedFrame: nil))
    }

    @Test("SessionActivitySummary.loadingPreviews leaves remaining indeterminate before the preview establishes a total")
    func sessionActivitySummaryLoadingPreviews() {
        let summary = SessionActivitySummary.current(
            isJobActive: false, isAcquiringThumbnails: true, receiptCount: 0,
            lastCompletedFrame: nil, progressTotalFrames: nil,
            thumbnailCount: 20, lastLoadedFrame: 20, statusFrameCount: nil
        )
        #expect(summary == .loadingPreviews(completed: 20, remaining: nil, lastLoadedFrame: 20))
    }

    @Test("SessionActivitySummary never reports negative remaining even if completed already exceeds the known total")
    func sessionActivitySummaryRemainingNeverNegative() {
        let summary = SessionActivitySummary.current(
            isJobActive: true, isAcquiringThumbnails: false, receiptCount: 40,
            lastCompletedFrame: 40, progressTotalFrames: 36,
            thumbnailCount: 0, lastLoadedFrame: nil, statusFrameCount: nil
        )
        #expect(summary == .scanning(completed: 40, remaining: 0, lastCompletedFrame: 40))
    }

    // MARK: - dismissLastError (prominent workspace error banner)

    @Test("dismissLastError clears the current error banner without needing a new action")
    @MainActor
    func dismissLastErrorClearsMessage() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.handle(event: EngineEvent(name: "engine.terminated", rawLine: Data()))
        #expect(model.lastErrorMessage != nil)
        #expect(model.errorPresentation != nil)

        model.dismissLastError()
        #expect(model.lastErrorMessage == nil)
        #expect(model.errorPresentation == nil)

        await client.terminate()
    }

    // MARK: - Frame rotation (display-only; root cause: the grid's Rotate
    // control was unwired. No field in the wire protocol's
    // `FrameOverrides`/project manifest carries an orientation value today
    // — see `SessionModel.frameOrientations`'s own doc comment — so this
    // stays session-local rather than round-tripping to the engine.)

    @Test("FrameOrientation.normalized wraps any integer into the canonical 0..<360 range, including negative input")
    func frameOrientationNormalizesAnyInteger() {
        #expect(FrameOrientation.normalized(0) == 0)
        #expect(FrameOrientation.normalized(90) == 90)
        #expect(FrameOrientation.normalized(360) == 0)
        #expect(FrameOrientation.normalized(450) == 90)
        #expect(FrameOrientation.normalized(-90) == 270)
        #expect(FrameOrientation.normalized(-450) == 270)
    }

    @Test("FrameOrientation.accessibilityText is nil for an unrotated frame and honest degrees text otherwise")
    func frameOrientationAccessibilityTextIsHonest() {
        #expect(FrameOrientation.accessibilityText(0) == nil)
        #expect(FrameOrientation.accessibilityText(360) == nil)
        #expect(FrameOrientation.accessibilityText(-360) == nil)
        #expect(FrameOrientation.accessibilityText(90) == "rotated 90 degrees")
        #expect(FrameOrientation.accessibilityText(180) == "rotated 180 degrees")
        #expect(FrameOrientation.accessibilityText(270) == "rotated 270 degrees")
        #expect(FrameOrientation.accessibilityText(-90) == "rotated 270 degrees")
    }

    @Test("rotateFrame accumulates and normalizes into 0/90/180/270 both clockwise and counter-clockwise, and resetFrameOrientation clears it back to 0")
    @MainActor
    func rotateFrameAccumulatesNormalizesAndResets() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        #expect(model.frameOrientation(3) == 0)

        model.rotateFrame(3, by: 90)
        #expect(model.frameOrientation(3) == 90)

        model.rotateFrame(3, by: 90)
        #expect(model.frameOrientation(3) == 180)

        model.rotateFrame(3, by: 90)
        model.rotateFrame(3, by: 90)
        // 180 + 90 + 90 = 360 -> normalizes back to 0.
        #expect(model.frameOrientation(3) == 0)

        model.rotateFrame(3, by: -90)
        // 0 - 90 -> normalizes to 270, not a negative value.
        #expect(model.frameOrientation(3) == 270)

        model.resetFrameOrientation(3)
        #expect(model.frameOrientation(3) == 0)

        await client.terminate()
    }

    @Test("rotateFrame tracks each frame index independently")
    @MainActor
    func rotateFrameIsPerFrameIndependent() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        model.rotateFrame(1, by: 90)
        #expect(model.frameOrientation(1) == 90)
        #expect(model.frameOrientation(2) == 0)

        await client.terminate()
    }

    // MARK: - scan.completed terminal jobState resolution

    @Test("ScanCompletionPolicy keeps an existing terminal state and otherwise derives stopped/completed from the summary")
    func scanCompletionPolicyResolvesTerminalState() {
        let clean = ScanSummary(completed: [1, 2], failed: [], skipped: [], stopped: false)
        #expect(ScanCompletionPolicy.resolveJobState(current: nil, summary: clean) == .completed)
        #expect(ScanCompletionPolicy.resolveJobState(current: .scanning, summary: clean) == .completed)

        let partial = ScanSummary(completed: [1], failed: [2], skipped: [], stopped: false)
        #expect(ScanCompletionPolicy.resolveJobState(current: .scanning, summary: partial) == .completed)

        let stopped = ScanSummary(completed: [1], failed: [], skipped: [2], stopped: true)
        #expect(ScanCompletionPolicy.resolveJobState(current: .scanning, summary: stopped) == .stopped)

        #expect(ScanCompletionPolicy.resolveJobState(current: .failed, summary: clean) == .failed)
        #expect(ScanCompletionPolicy.resolveJobState(current: .stopped, summary: clean) == .stopped)
        #expect(ScanCompletionPolicy.resolveJobState(current: .completed, summary: stopped) == .completed)
    }

    @Test("scan.completed with a clean summary forces a terminal jobState when no terminal scan.jobState arrived, so isJobActive becomes false")
    @MainActor
    func scanCompletedForcesTerminalJobStateForCleanCompletion() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"
        model.handle(event: EngineEvent(name: "scan.jobState", rawLine: Data(
            #"{"event":"scan.jobState","payload":{"jobId":"job-1","state":"scanning"}}"#.utf8)))
        #expect(model.isJobActive)

        model.handle(event: EngineEvent(name: "scan.completed", rawLine: Data(
            #"{"event":"scan.completed","payload":{"jobId":"job-1","summary":{"completed":[1,2,3],"failed":[],"skipped":[],"stopped":false}}}"#.utf8)))

        #expect(model.isJobActive == false)
        #expect(model.jobState == .completed)
        await client.terminate()
    }

    @Test("scan.completed with a failed/partial summary still resolves the job to completed, so isJobActive becomes false")
    @MainActor
    func scanCompletedForcesTerminalJobStateForFailedPartialSummary() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"
        model.handle(event: EngineEvent(name: "scan.jobState", rawLine: Data(
            #"{"event":"scan.jobState","payload":{"jobId":"job-1","state":"scanning"}}"#.utf8)))
        #expect(model.isJobActive)

        model.handle(event: EngineEvent(name: "scan.completed", rawLine: Data(
            #"{"event":"scan.completed","payload":{"jobId":"job-1","summary":{"completed":[1],"failed":[2],"skipped":[],"stopped":false}}}"#.utf8)))

        #expect(model.isJobActive == false)
        #expect(model.jobState == .completed)
        await client.terminate()
    }

    @Test("scan.completed with a stopped summary resolves the job to stopped, so isJobActive becomes false")
    @MainActor
    func scanCompletedForcesStoppedJobStateForStoppedSummary() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"
        model.handle(event: EngineEvent(name: "scan.jobState", rawLine: Data(
            #"{"event":"scan.jobState","payload":{"jobId":"job-1","state":"scanning"}}"#.utf8)))
        #expect(model.isJobActive)

        model.handle(event: EngineEvent(name: "scan.completed", rawLine: Data(
            #"{"event":"scan.completed","payload":{"jobId":"job-1","summary":{"completed":[1],"failed":[],"skipped":[2],"stopped":true}}}"#.utf8)))

        #expect(model.isJobActive == false)
        #expect(model.jobState == .stopped)
        await client.terminate()
    }

    @Test("scan.completed never overrides an existing terminal jobState")
    @MainActor
    func scanCompletedNeverOverridesExistingTerminalJobState() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)
        model.jobId = "job-1"
        model.handle(event: EngineEvent(name: "scan.jobState", rawLine: Data(
            #"{"event":"scan.jobState","payload":{"jobId":"job-1","state":"scanning"}}"#.utf8)))
        model.handle(event: EngineEvent(name: "scan.jobState", rawLine: Data(
            #"{"event":"scan.jobState","payload":{"jobId":"job-1","state":"failed"}}"#.utf8)))
        #expect(model.jobState == .failed)

        model.handle(event: EngineEvent(name: "scan.completed", rawLine: Data(
            #"{"event":"scan.completed","payload":{"jobId":"job-1","summary":{"completed":[1],"failed":[],"skipped":[],"stopped":false}}}"#.utf8)))

        #expect(model.jobState == .failed)
        #expect(model.isJobActive == false)
        await client.terminate()
    }

    // MARK: - Frame horizontal mirror

    @Test("toggleFrameMirror flips per-frame horizontal mirror, setFrameMirror sets it, reset clears it, and frames default to unmirrored")
    @MainActor
    func frameMirrorTogglesSetsResetsAndDefaults() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        #expect(model.frameMirror(3) == false)
        model.toggleFrameMirror(3)
        #expect(model.frameMirror(3) == true)
        model.toggleFrameMirror(3)
        #expect(model.frameMirror(3) == false)
        model.setFrameMirror(true, for: 4)
        #expect(model.frameMirror(4) == true)
        model.resetFrameMirror(4)
        #expect(model.frameMirror(4) == false)

        await client.terminate()
    }

    @Test("frame mirror tracks each frame independently and clears when media state clears")
    @MainActor
    func frameMirrorIsPerFrameIndependentAndClearsWithMedia() async throws {
        let client = try EngineClient(engineURL: URL(fileURLWithPath: "/bin/cat"))
        let model = SessionModel(engineClient: client)

        model.toggleFrameMirror(1)
        #expect(model.frameMirror(1) == true)
        #expect(model.frameMirror(2) == false)

        let notLoaded = Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null}}}"#.utf8
        )
        model.handle(event: EngineEvent(name: "scanner.status", rawLine: notLoaded))

        #expect(model.frameMirror(1) == false)
        #expect(model.frameMirrors.isEmpty)
        await client.terminate()
    }

    // MARK: - AutoCropAffordance

    @Test("AutoCropAffordance is offered only for exactly one selected frame backed by a real imagePath preview")
    func autoCropAffordanceAvailability() {
        let realPreview = Thumbnail(brightness: nil, tint: nil, imagePath: "/tmp/slot-0001.tif")
        let simulatorPreview = Thumbnail(brightness: 0.5, tint: 0.1, imagePath: nil)

        #expect(AutoCropAffordance.isOffered(selectedFrameIndices: [5], thumbnails: [5: realPreview]))
        #expect(!AutoCropAffordance.isOffered(selectedFrameIndices: [5], thumbnails: [5: simulatorPreview]))
        #expect(!AutoCropAffordance.isOffered(selectedFrameIndices: [5], thumbnails: [:]))
        #expect(!AutoCropAffordance.isOffered(selectedFrameIndices: [], thumbnails: [5: realPreview]))
        #expect(!AutoCropAffordance.isOffered(selectedFrameIndices: [5, 6], thumbnails: [5: realPreview, 6: realPreview]))
    }
}
