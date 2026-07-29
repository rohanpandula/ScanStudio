import Foundation
import Testing

@testable import ScanStudioKit

private enum ScannerStatusRefreshStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private actor ScannerStatusRefreshEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "scanner-status-refresh-stub"

    private let device = DeviceInfo(
        deviceId: "real-ls5000-status-test",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supportedMultisamplePasses: [4]
    )
    private var statusRequestCount = 0
    private var movementCalls: [String] = []
    private let holdStatusResponse: Bool
    private var statusMediaLoadedResponses: [Bool]
    private var statusFilmPresentResponses: [Bool?]
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var statusWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        holdStatusResponse: Bool = false,
        statusMediaLoadedResponses: [Bool] = [false],
        statusFilmPresentResponses: [Bool?] = [true]
    ) {
        self.holdStatusResponse = holdStatusResponse
        self.statusMediaLoadedResponses = statusMediaLoadedResponses
        self.statusFilmPresentResponses = statusFilmPresentResponses
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
    ) async throws -> Result {
        let value: any Sendable
        switch method {
        case "scanner.list":
            value = ScannerListResult(devices: [device])
        case "scanner.connect":
            value = ConnectResult(
                device: device,
                status: status(motionArmed: false)
            )
        case "scanner.status":
            statusRequestCount += 1
            let waiters = statusWaiters
            statusWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if holdStatusResponse {
                await withCheckedContinuation { continuation in
                    statusContinuation = continuation
                }
            }
            let mediaLoaded = statusMediaLoadedResponses.isEmpty
                ? false
                : statusMediaLoadedResponses.removeFirst()
            let filmPresent: Bool? = statusFilmPresentResponses.isEmpty
                ? true
                : statusFilmPresentResponses.removeFirst()
            value = status(
                motionArmed: true,
                mediaLoaded: mediaLoaded,
                filmPresent: filmPresent
            )
        case "scanner.acquireThumbnails":
            movementCalls.append(method)
            value = AcquireThumbnailsAck(accepted: true, frames: [])
        case "scanner.eject":
            movementCalls.append(method)
            value = EmptyResult()
        case "roll.approve":
            movementCalls.append(method)
            value = EmptyResult()
        case "scan.start":
            movementCalls.append(method)
            value = ScanStartResult(jobId: "unexpected-motion-job")
        default:
            throw ScannerStatusRefreshStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw ScannerStatusRefreshStubError.unexpectedResultType
        }
        return result
    }

    func numberOfStatusRequests() -> Int {
        statusRequestCount
    }

    func recordedMovementCalls() -> [String] {
        movementCalls
    }

    func waitForStatusRequest() async {
        guard statusRequestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            statusWaiters.append(continuation)
        }
    }

    func resumeStatusResponse() {
        statusContinuation?.resume()
        statusContinuation = nil
    }

    private func status(
        motionArmed: Bool,
        mediaLoaded: Bool = false,
        filmPresent: Bool? = true
    ) -> ScannerStatus {
        ScannerStatus(
            connected: true,
            adapter: "SA-30",
            mediaLoaded: mediaLoaded,
            carrier: mediaLoaded ? "strip" : nil,
            frameCount: mediaLoaded ? 1 : nil,
            lamp: "stable",
            transport: "idle",
            activeJobId: nil,
            filmPresent: filmPresent,
            motionArmed: motionArmed
        )
    }
}

@MainActor
private func establishPreviewBoundState(
    in model: SessionModel
) async -> PreviewIntentToken {
    let previewToken = PreviewIntentToken()
    let preview = await model.requestPreview(
        .initial(token: previewToken)
    )
    #expect(preview == .started)
    model.handle(event: EngineEvent(
        name: "scanner.thumbnail",
        rawLine: Data(
            #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(previewToken.id.uuidString)","frameIndex":1,"thumbnail":{"imagePath":"/tmp/status-film-presence.tif"}}}"#.utf8
        )
    ))
    model.handle(event: EngineEvent(
        name: "scanner.thumbnailsComplete",
        rawLine: Data(
            #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(previewToken.id.uuidString)","count":1}}"#.utf8
        )
    ))
    model.toggleFrameSelection(1)
    #expect(model.thumbnails[1] != nil)
    #expect(model.selectedFrameIndices == [1])
    return previewToken
}

@Suite("Scanner status refresh")
struct ScannerStatusRefreshTests {
    @Test("refreshScannerStatus performs one read-only status request and adopts its readiness")
    @MainActor
    func refreshAdoptsCurrentStatus() async {
        let client = ScannerStatusRefreshEngineStub()
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")
        #expect(model.status?.motionArmed == false)
        let preview = await model.requestPreview(
            .initial(token: PreviewIntentToken())
        )
        #expect(preview == .rejected)
        #expect(model.lastErrorMessage != nil)

        await model.refreshScannerStatus()

        #expect(await client.numberOfStatusRequests() == 1)
        #expect(model.status?.motionArmed == true)
        #expect(model.lastErrorMessage == nil)
    }

    @Test("a status response from a replaced connection cannot overwrite the new session")
    @MainActor
    func staleResponseIsDiscarded() async {
        let client = ScannerStatusRefreshEngineStub(holdStatusResponse: true)
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")

        let refresh = Task { @MainActor in
            await model.refreshScannerStatus()
        }
        await client.waitForStatusRequest()
        await model.connect(deviceId: "real-ls5000-status-test")
        #expect(model.status?.motionArmed == false)

        await client.resumeStatusResponse()
        await refresh.value

        #expect(model.status?.motionArmed == false)
    }

    @Test("real preview, scan, and eject refuse motion until readiness is affirmative")
    @MainActor
    func motionActionsFailClosed() async {
        let client = ScannerStatusRefreshEngineStub()
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")

        let preview = await model.requestPreview(
            .initial(token: PreviewIntentToken())
        )
        await model.scanSingleFrame(1)
        await model.eject()

        #expect(preview == .rejected)
        #expect(await client.recordedMovementCalls().isEmpty)
        #expect(
            model.lastErrorMessage
                == HardwareMotionReadiness.notEnabled.guidance
        )
    }

    @Test("a direct no-media refresh clears all preview-bound UI and blocks approval or retry dispatch")
    @MainActor
    func noMediaRefreshClearsPreviewBoundState() async {
        let client = ScannerStatusRefreshEngineStub(
            statusMediaLoadedResponses: [true, false]
        )
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")
        await model.refreshScannerStatus()
        #expect(model.status?.mediaLoaded == true)

        let previewToken = PreviewIntentToken()
        let preview = await model.requestPreview(
            .initial(token: previewToken)
        )
        #expect(preview == .started)
        model.handle(event: EngineEvent(
            name: "scanner.thumbnail",
            rawLine: Data(
                #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(previewToken.id.uuidString)","frameIndex":1,"thumbnail":{"imagePath":"/tmp/status-refresh-preview.tif"}}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(previewToken.id.uuidString)","count":1}}"#.utf8
            )
        ))
        model.beginJob(id: "manual-review-job")
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"manual-review-job","frameIndex":1,"state":"failed","attempt":1,"error":{"code":"MANUAL_REVIEW_REQUIRED","message":"review boundary","recoverable":true}}}"#.utf8
            )
        ))
        model.toggleFrameSelection(1)
        model.openFrameDetail(1)

        #expect(model.thumbnails[1] != nil)
        #expect(model.frameErrors[1]?.code == FrameFailureLabel.manualReviewCode)
        #expect(model.selectedFrameIndices == [1])
        #expect(model.detailFrameIndex == 1)
        #expect(model.latestCompletedPreviewOperationId == previewToken.id.uuidString)

        await model.refreshScannerStatus()

        #expect(model.status?.connected == true)
        #expect(model.status?.mediaLoaded == false)
        #expect(model.thumbnails.isEmpty)
        #expect(model.frameErrors.isEmpty)
        #expect(model.selectedFrameIndices.isEmpty)
        #expect(model.detailFrameIndex == nil)
        #expect(model.latestCompletedPreviewOperationId == nil)

        await model.approveAndRetryFrame(1)
        await model.scanSingleFrame(1)
        #expect(await client.recordedMovementCalls() == ["scanner.acquireThumbnails"])
    }

    @Test("a direct no-film refresh clears preview state even when previewEstablished remains true")
    @MainActor
    func noFilmRefreshClearsPreviewBoundState() async {
        let client = ScannerStatusRefreshEngineStub(
            statusMediaLoadedResponses: [true, true],
            statusFilmPresentResponses: [true, false]
        )
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")
        await model.refreshScannerStatus()

        _ = await establishPreviewBoundState(in: model)

        await model.refreshScannerStatus()

        #expect(model.status?.mediaLoaded == true)
        #expect(model.status?.filmPresent == false)
        #expect(model.thumbnails.isEmpty)
        #expect(model.selectedFrameIndices.isEmpty)
    }

    @Test("an accepted no-film status event clears preview state even when previewEstablished remains true")
    @MainActor
    func noFilmStatusEventClearsPreviewBoundState() async {
        let client = ScannerStatusRefreshEngineStub(
            statusMediaLoadedResponses: [true],
            statusFilmPresentResponses: [true]
        )
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")
        await model.refreshScannerStatus()

        let previewToken = await establishPreviewBoundState(in: model)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(previewToken.id.uuidString)","status":{"connected":true,"adapter":"SA-30","mediaLoaded":true,"carrier":"strip","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":false,"motionArmed":true}}}"#.utf8
            )
        ))

        #expect(model.status?.mediaLoaded == true)
        #expect(model.status?.filmPresent == false)
        #expect(model.thumbnails.isEmpty)
        #expect(model.selectedFrameIndices.isEmpty)
    }

    @Test("unknown film presence never clears an otherwise established preview")
    @MainActor
    func unknownFilmPresencePreservesPreviewBoundState() async {
        let client = ScannerStatusRefreshEngineStub(
            statusMediaLoadedResponses: [true, true],
            statusFilmPresentResponses: [true, nil]
        )
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-status-test")
        await model.refreshScannerStatus()
        let previewToken = await establishPreviewBoundState(in: model)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(previewToken.id.uuidString)","status":{"connected":true,"adapter":"SA-30","mediaLoaded":true,"carrier":"strip","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":null,"motionArmed":true}}}"#.utf8
            )
        ))

        #expect(model.status?.filmPresent == nil)
        #expect(model.thumbnails[1] != nil)
        #expect(model.selectedFrameIndices == [1])

        await model.refreshScannerStatus()

        #expect(model.status?.mediaLoaded == true)
        #expect(model.status?.filmPresent == nil)
        #expect(model.thumbnails[1] != nil)
        #expect(model.selectedFrameIndices == [1])
    }
}
