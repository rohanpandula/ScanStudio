import Foundation
import Testing

@testable import ScanStudioKit

private enum ConnectionLifecycleStubError: Error {
    case forcedFailure
    case unexpectedMethod(String)
    case unexpectedResultType
}

private actor ConnectionLifecycleEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "connection-lifecycle-stub"

    private let device = DeviceInfo(
        deviceId: "real-ls5000-test",
        model: "LS-5000 ED",
        kind: "real",
        firmware: "test",
        connection: "usb",
        supportedMultisamplePasses: [4]
    )
    private let project = ScanProject(
        schemaVersion: 1,
        id: "connection-lifecycle-project",
        name: "Connection lifecycle",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/connection-lifecycle/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/connection-lifecycle/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/connection-lifecycle/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-08-02T00:00:00Z",
        frames: [ProjectFrame(index: 1, excluded: false, receipts: [])]
    )
    private var connectRequestCount = 0
    private var connectContinuation: CheckedContinuation<ConnectResult, Error>?
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var scanStartRequestCount = 0
    private var scanStartContinuation: CheckedContinuation<ScanStartResult, Error>?
    private var scanStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let acquireError: EngineRequestError?

    init(
        acquireError: EngineRequestError? = EngineRequestError(
            code: "NOT_CONNECTED",
            message: "bridge error NOT_CONNECTED: no device is open",
            recoverable: true
        )
    ) {
        self.acquireError = acquireError
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
    ) async throws -> Result {
        switch method {
        case "scanner.list":
            return try cast(ScannerListResult(devices: [device]), as: Result.self)
        case "scanner.connect":
            connectRequestCount += 1
            resumeSatisfiedWaiters()
            let result = try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
            }
            return try cast(result, as: Result.self)
        case "scanner.acquireThumbnails":
            if let acquireError {
                throw acquireError
            }
            return try cast(
                AcquireThumbnailsAck(accepted: true, frames: []),
                as: Result.self
            )
        case "project.open":
            return try cast(
                ProjectOpenResult(
                    project: project,
                    directory: "/tmp/connection-lifecycle"
                ),
                as: Result.self
            )
        case "scan.start":
            scanStartRequestCount += 1
            resumeSatisfiedScanStartWaiters()
            let result = try await withCheckedThrowingContinuation { continuation in
                scanStartContinuation = continuation
            }
            return try cast(result, as: Result.self)
        default:
            throw ConnectionLifecycleStubError.unexpectedMethod(method)
        }
    }

    func waitForConnectRequestCount(_ count: Int) async {
        guard connectRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func succeedConnect() {
        connectContinuation?.resume(returning: ConnectResult(
            device: device,
            status: ScannerStatus(
                connected: true,
                adapter: "SA-21",
                mediaLoaded: false,
                carrier: nil,
                frameCount: nil,
                lamp: "unknown",
                transport: "idle",
                activeJobId: nil,
                filmPresent: nil,
                motionArmed: true
            )
        ))
        connectContinuation = nil
    }

    func waitForScanStartRequestCount(_ count: Int) async {
        guard scanStartRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            scanStartWaiters.append((count, continuation))
        }
    }

    func succeedScanStart(jobId: String) {
        scanStartContinuation?.resume(returning: ScanStartResult(jobId: jobId))
        scanStartContinuation = nil
    }

    func failConnect() {
        connectContinuation?.resume(throwing: ConnectionLifecycleStubError.forcedFailure)
        connectContinuation = nil
    }

    func numberOfConnectRequests() -> Int {
        connectRequestCount
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = requestWaiters.filter { connectRequestCount >= $0.count }
        requestWaiters.removeAll { connectRequestCount >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func resumeSatisfiedScanStartWaiters() {
        let satisfied = scanStartWaiters.filter {
            scanStartRequestCount >= $0.count
        }
        scanStartWaiters.removeAll {
            scanStartRequestCount >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func cast<Result: Decodable & Sendable>(
        _ value: some Sendable,
        as _: Result.Type
    ) throws -> Result {
        guard let result = value as? Result else {
            throw ConnectionLifecycleStubError.unexpectedResultType
        }
        return result
    }
}

@MainActor
private func waitForInitialConnectionDiscovery(_ model: SessionModel) async -> Bool {
    for _ in 0..<200 {
        if !model.isDiscoveringDevices {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return !model.isDiscoveringDevices
}

@MainActor
private func prepareConnectionLifecycleScanReadiness(
    _ model: SessionModel
) async -> Bool {
    await model.openProject(directory: "/tmp/connection-lifecycle")
    model.handle(event: EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}"#.utf8
        )
    ))
    let token = PreviewIntentToken()
    guard await model.requestPreview(.refreshSavedProject(token: token))
        == .started
    else {
        return false
    }
    model.handle(event: EngineEvent(
        name: "scanner.thumbnail",
        rawLine: Data(
            #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":{"brightness":0.5,"tint":0.0}}}"#.utf8
        )
    ))
    model.handle(event: EngineEvent(
        name: "scanner.thumbnailsComplete",
        rawLine: Data(
            #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":1}}"#.utf8
        )
    ))
    return model.scanReadiness(for: [1]).isReady
}

@Suite("Device connection lifecycle")
struct DeviceConnectionLifecycleTests {
    @Test("Connecting state spans the scanner connect request and clears on success")
    @MainActor
    func connectingStateSpansSuccess() async {
        let stub = ConnectionLifecycleEngineStub()
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let operation = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        #expect(model.isConnectingDevice)

        await stub.succeedConnect()
        await operation.value
        #expect(model.isConnectingDevice == false)
        #expect(model.status?.connected == true)
    }

    @Test("Failure and validation early return never leave a stale connecting state")
    @MainActor
    func failureAndEarlyReturnClearState() async {
        let failingStub = ConnectionLifecycleEngineStub()
        let failingModel = SessionModel(engineClient: failingStub)
        #expect(await waitForInitialConnectionDiscovery(failingModel))

        let failingOperation = Task { @MainActor in
            await failingModel.connect(deviceId: "real-ls5000-test")
        }
        await failingStub.waitForConnectRequestCount(1)
        #expect(failingModel.isConnectingDevice)
        await failingStub.failConnect()
        await failingOperation.value
        #expect(failingModel.isConnectingDevice == false)
        #expect(failingModel.lastErrorMessage != nil)

        let earlyReturnStub = ConnectionLifecycleEngineStub()
        let earlyReturnModel = SessionModel(engineClient: earlyReturnStub)
        #expect(await waitForInitialConnectionDiscovery(earlyReturnModel))
        await earlyReturnModel.connect(deviceId: "missing-scanner")
        #expect(earlyReturnModel.isConnectingDevice == false)
        #expect(await earlyReturnStub.numberOfConnectRequests() == 0)
        #expect(earlyReturnModel.lastErrorMessage?.contains("missing-scanner") == true)
    }

    @Test("An overlapping connect is ignored while the first request owns the lifecycle")
    @MainActor
    func duplicateConnectIsSerialized() async {
        let stub = ConnectionLifecycleEngineStub()
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let first = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        let duplicate = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await duplicate.value

        #expect(await stub.numberOfConnectRequests() == 1)
        #expect(model.isConnectingDevice)
        await stub.succeedConnect()
        await first.value
        #expect(model.isConnectingDevice == false)
    }

    @Test("Cancellation clears connecting state without discarding an accepted connection")
    @MainActor
    func cancellationClearsState() async {
        let stub = ConnectionLifecycleEngineStub()
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let operation = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        #expect(model.isConnectingDevice)
        operation.cancel()
        await stub.succeedConnect()
        await operation.value

        #expect(model.isConnectingDevice == false)
        #expect(model.device?.deviceId == "real-ls5000-test")
        #expect(model.status?.connected == true)
        #expect(model.lastErrorMessage == nil)
    }

    @Test("A bridge NOT_CONNECTED refusal invalidates stale connected UI state")
    @MainActor
    func notConnectedRefusalInvalidatesStaleConnection() async {
        let stub = ConnectionLifecycleEngineStub()
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let connection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await connection.value
        #expect(model.status?.connected == true)
        #expect(model.device?.kind == "real")

        let outcome = await model.requestPreview(
            .initial(token: PreviewIntentToken())
        )

        #expect(outcome == .failedToStart)
        #expect(model.status == nil)
        #expect(model.device == nil)
        #expect(model.lastErrorMessage?.contains("NOT_CONNECTED") == true)

        let presentation = model.errorPresentation
        #expect(
            presentation?.technicalDetails.contains(
                "preview.failed code=NOT_CONNECTED uiConnectedBefore=true"
            ) == true
        )
        #expect(
            presentation?.technicalDetails.contains(
                "connection.invalidated reason=NOT_CONNECTED source=preview uiConnectedBefore=true"
            ) == true
        )
        let issueBody = presentation.flatMap {
            URLComponents(url: $0.issueURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "body" }?
                .value
        }
        #expect(issueBody?.contains("Recent diagnostic events:") == true)
        #expect(issueBody?.contains("preview.failed code=NOT_CONNECTED") == true)
        #expect(issueBody?.contains("real-ls5000-test") == false)
    }

    @Test("An asynchronous bridge death clears READY from its correlated disconnected status")
    @MainActor
    func asynchronousBridgeDeathInvalidatesConnection() async {
        let stub = ConnectionLifecycleEngineStub(acquireError: nil)
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let connection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await connection.value

        let token = PreviewIntentToken()
        #expect(await model.requestPreview(.initial(token: token)) == .started)
        #expect(model.status?.connected == true)

        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(token.id.uuidString)","code":"BRIDGE_STREAM_STALLED","message":"bridge event stream ended before preview completion"}}"#.utf8
            )
        ))
        #expect(model.device != nil)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(token.id.uuidString)","status":{"connected":false,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"off","transport":"idle","activeJobId":null,"filmPresent":null}}}"#.utf8
            )
        ))

        #expect(model.device == nil)
        #expect(model.status == nil)
        #expect(model.isAcquiringThumbnails == false)
        #expect(
            model.errorPresentation?.technicalDetails.contains(
                "connection.invalidated reason=NOT_CONNECTED source=scanner.status uiConnectedBefore=true"
            ) == true
        )
    }

    @Test("A typed asynchronous preview ownership loss clears READY before its closing status")
    @MainActor
    func asynchronousPreviewOwnershipLossInvalidatesOnce() async {
        let stub = ConnectionLifecycleEngineStub(acquireError: nil)
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let connection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await connection.value

        let token = PreviewIntentToken()
        #expect(await model.requestPreview(.initial(token: token)) == .started)
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"operationId":"\#(token.id.uuidString)","code":"NOT_CONNECTED","message":"bridge session ownership was lost asynchronously mid-preview; sessionEpoch=2; bridgeGenerationStart=1; bridgeGenerationCurrent=2; bridgeHealthy=false"}}"#.utf8
            )
        ))

        #expect(model.device == nil)
        #expect(model.status == nil)
        #expect(model.isAcquiringThumbnails == false)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"operationId":"\#(token.id.uuidString)","status":{"connected":false,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"off","transport":"idle","activeJobId":null,"filmPresent":null}}}"#.utf8
            )
        ))

        let details = model.errorPresentation?.technicalDetails ?? ""
        #expect(details.contains("bridgeGenerationStart=1"))
        #expect(details.contains("bridgeGenerationCurrent=2"))
        #expect(
            details.components(separatedBy: "connection.invalidated").count - 1
                == 1
        )
    }

    @Test("A scan worker NOT_CONNECTED event invalidates once and records its failure code")
    @MainActor
    func asynchronousScanBridgeDeathInvalidatesOnce() async {
        let stub = ConnectionLifecycleEngineStub()
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let connection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await connection.value
        model.jobId = "job-bridge-loss"

        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"job-bridge-loss","frameIndex":1,"state":"failed","attempt":1,"error":{"code":"NOT_CONNECTED","message":"bridge process generation changed; reconnect required","recoverable":false}}}"#.utf8
            )
        ))
        #expect(model.device == nil)
        #expect(model.status == nil)
        #expect(model.jobId == "job-bridge-loss")

        // The engine closes an ownership-loss job before it emits the
        // disconnected status. Keep the active id long enough to consume
        // those terminal events instead of orphan-buffering them.
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"job-bridge-loss","state":"failed"}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"job-bridge-loss","summary":{"completed":[],"failed":[1],"skipped":[],"stopped":false}}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":false,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"off","transport":"idle","activeJobId":null,"filmPresent":null}}}"#.utf8
            )
        ))

        #expect(model.device == nil)
        #expect(model.status == nil)
        #expect(model.jobId == nil)
        let details = model.errorPresentation?.technicalDetails ?? ""
        #expect(details.contains("bridge process generation changed"))
        #expect(details.contains(
            "scan.frame.failed attempt=1 code=NOT_CONNECTED frameIndex=1 uiConnectedBefore=true"
        ))
        #expect(
            details.components(separatedBy: "connection.invalidated").count - 1
                == 1
        )
    }

    @Test("Terminal events from a lost connection never replay into a reused job id")
    @MainActor
    func staleTerminalEventsDoNotContaminateReusedJobId() async {
        let stub = ConnectionLifecycleEngineStub()
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let firstConnection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await firstConnection.value
        model.beginJob(id: "mock-job-1")
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"mock-job-1","state":"scanning"}}"#.utf8
            )
        ))

        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"mock-job-1","frameIndex":1,"state":"failed","attempt":1,"error":{"code":"NOT_CONNECTED","message":"bridge ownership was lost","recoverable":false}}}"#.utf8
            )
        ))
        #expect(model.jobId == "mock-job-1")

        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"mock-job-1","state":"failed"}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"mock-job-1","summary":{"completed":[],"failed":[1],"skipped":[],"stopped":false}}}"#.utf8
            )
        ))
        #expect(model.jobId == nil)
        #expect(model.jobState == .failed)

        // A late duplicate after terminal closure is from the retired job.
        // It must be dropped, not held for a future bridge process whose
        // counter may legitimately reuse "mock-job-1".
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"mock-job-1","state":"failed"}}"#.utf8
            )
        ))

        let secondConnection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(2)
        await stub.succeedConnect()
        await secondConnection.value
        model.beginJob(id: "mock-job-1")

        #expect(model.jobId == "mock-job-1")
        #expect(model.jobState == .queued)
        #expect(model.scanSummary == nil)
    }

    @Test("A scan-start response from a retired connection is discarded")
    @MainActor
    func lateScanStartResponseCannotCreateJobAfterReconnect() async {
        let stub = ConnectionLifecycleEngineStub(acquireError: nil)
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let firstConnection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await firstConnection.value
        #expect(await prepareConnectionLifecycleScanReadiness(model))

        let oldStart = Task { @MainActor in
            try? await model.dispatchScanStart(frames: [1])
        }
        await stub.waitForScanStartRequestCount(1)
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"mock-job-1","state":"scanning"}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":false,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"off","transport":"idle","activeJobId":null,"filmPresent":null}}}"#.utf8
            )
        ))

        let secondConnection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(2)
        await stub.succeedConnect()
        await secondConnection.value
        await stub.succeedScanStart(jobId: "mock-job-1")

        #expect(await oldStart.value == nil)
        #expect(model.status?.connected == true)
        #expect(model.jobId == nil)
        #expect(model.jobState == nil)
    }

    @Test("Events that beat a valid scan-start response are applied to that job")
    @MainActor
    func earlyScanEventStillBuffersWithinCurrentConnection() async {
        let stub = ConnectionLifecycleEngineStub(acquireError: nil)
        let model = SessionModel(engineClient: stub)
        #expect(await waitForInitialConnectionDiscovery(model))

        let connection = Task { @MainActor in
            await model.connect(deviceId: "real-ls5000-test")
        }
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await connection.value
        #expect(await prepareConnectionLifecycleScanReadiness(model))

        let start = Task { @MainActor in
            try? await model.dispatchScanStart(frames: [1])
        }
        await stub.waitForScanStartRequestCount(1)
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"mock-job-1","state":"scanning"}}"#.utf8
            )
        ))
        await stub.succeedScanStart(jobId: "mock-job-1")

        let result = await start.value
        #expect(result?.jobId == "mock-job-1")
        if let jobId = result?.jobId {
            model.beginJob(id: jobId)
        }
        #expect(model.jobState == .scanning)
    }
}
