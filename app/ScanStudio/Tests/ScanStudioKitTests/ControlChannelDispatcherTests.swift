import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ScanStudioKit

private enum ControlDispatcherStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint.
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`), matching the real simulator these tests stand
/// in for.
private let controlDispatcherDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

private func controlDispatcherProject(frameIndex: Int = 1) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "control-dispatcher-project",
        name: "Control dispatcher test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/control-dispatcher/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/control-dispatcher/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/control-dispatcher/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-09-07T00:00:00Z",
        frames: [ProjectFrame(index: frameIndex, excluded: false, receipts: [])]
    )
}

/// Fake engine modelled on `ConnectionLifecycleEngineStub`
/// (`DeviceConnectionLifecycleTests.swift`) and `BusyIndicatorEngineStub`
/// (`ControlBusyIndicatorTests.swift`). `scanner.list`/`scanner.rescan`
/// auto-succeed synchronously (this suite never needs to observe their
/// timing); `scanner.eject` alone is `CheckedContinuation`-scripted so a
/// test can hold it in flight deterministically for the busy-preamble
/// proof, never by a fixed sleep.
private actor ControlDispatcherEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "control-dispatcher-stub"

    /// Every request except the fire-and-forget `scanner.list`/
    /// `scanner.rescan` call `SessionModel.init` always issues. Excluding
    /// that incidental discovery call is what lets a refusal-path test
    /// assert this count is exactly `0` -- the literal proof that the
    /// refusal never reached the engine on behalf of the refused command.
    private(set) var requestCount = 0
    private(set) var lastCorrelationToken: String?

    private var ejectRequestCount = 0
    private var ejectContinuation: CheckedContinuation<EmptyResult, Error>?
    private var ejectWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
    ) async throws -> Result {
        if method != "scanner.list", method != "scanner.rescan" {
            requestCount += 1
        }
        lastCorrelationToken = RequestCorrelationContext.token
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [controlDispatcherDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: controlDispatcherDevice,
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
            ), as: Result.self)
        case "scanner.status":
            if RequestCorrelationContext.token == "trace-fixture:3" {
                throw EngineRequestError(
                    code: "NOT_CONNECTED",
                    message: "simulated traced refusal",
                    recoverable: false
                )
            }
            // Deliberately distinct from `scanner.connect`'s own status
            // above (mediaLoaded/carrier/frameCount/filmPresent all
            // differ) -- proves a `scanner.refresh` test observes a fresh
            // read, not an echoed, unchanged snapshot.
            return try cast(ScannerStatus(
                connected: true,
                adapter: "SA-21",
                mediaLoaded: true,
                carrier: "mounted",
                frameCount: 6,
                lamp: "stable",
                transport: "idle",
                activeJobId: nil,
                filmPresent: true,
                motionArmed: true
            ), as: Result.self)
        case "scanner.acquireThumbnails":
            return try cast(AcquireThumbnailsAck(accepted: true, frames: []), as: Result.self)
        case "project.open":
            return try cast(
                ProjectOpenResult(project: controlDispatcherProject(), directory: "/tmp/control-dispatcher-test"),
                as: Result.self
            )
        case "scanner.eject":
            ejectRequestCount += 1
            resumeSatisfiedEjectWaiters()
            let result = try await withCheckedThrowingContinuation { continuation in
                ejectContinuation = continuation
            }
            return try cast(result, as: Result.self)
        default:
            throw ControlDispatcherStubError.unexpectedMethod(method)
        }
    }

    func waitForEjectRequestCount(_ count: Int) async {
        guard ejectRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            ejectWaiters.append((count, continuation))
        }
    }

    func succeedEject() {
        ejectContinuation?.resume(returning: EmptyResult())
        ejectContinuation = nil
    }

    func correlationToken() -> String? { lastCorrelationToken }

    private func resumeSatisfiedEjectWaiters() {
        let satisfied = ejectWaiters.filter { ejectRequestCount >= $0.count }
        ejectWaiters.removeAll { ejectRequestCount >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw ControlDispatcherStubError.unexpectedResultType }
        return result
    }
}

/// Bounded `Task.yield()` polling, per this codebase's established idiom
/// (`ControlBusyIndicatorTests.swift`, `SessionEventPolicyTests.swift`) for
/// waiting out a fire-and-forget async call without a fixed sleep.
@MainActor
private func makeIdleModel(_ stub: ControlDispatcherEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

@MainActor
private func makeDispatcher() async -> (model: SessionModel, stub: ControlDispatcherEngineStub, dispatcher: ControlChannelDispatcher) {
    let stub = ControlDispatcherEngineStub()
    let model = await makeIdleModel(stub)
    let dispatcher = ControlChannelDispatcher(sessionModel: model)
    return (model, stub, dispatcher)
}

@MainActor
@discardableResult
private func greet(_ dispatcher: ControlChannelDispatcher) async -> ControlResponse {
    await dispatcher.handle(.hello(
        id: 0,
        params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "control-dispatcher-tests")
    ))
}

/// Mirrors `ControlEventEnvelope`'s wire shape for the decode direction --
/// the production type is encode-only (D-06's dispatcher is the server end
/// of this channel), so a test needs its own small `Decodable` twin to read
/// a stream element back.
private struct ControlEventEnvelopeProbe<Payload: Decodable>: Decodable {
    let event: String
    let payload: Payload
}

/// `ControlResponseEnvelope` (`ControlWireProtocol.swift`) is encode-only
/// like `ControlEventEnvelopeProbe`'s own production twin above -- this is
/// the same idiom, a `Decodable` mirror for reading a success envelope
/// back in a `handleLine(_:)`-driven test.
private struct ControlResponseEnvelopeProbe<Result: Decodable>: Decodable {
    let id: UInt64
    let result: Result
}

private func expectFailure(_ response: ControlResponse, id expectedId: UInt64, code expectedCode: ControlErrorCode) {
    guard case .failure(let id, let error) = response else {
        Issue.record("expected a failure response but got \(response)")
        return
    }
    #expect(id == expectedId)
    #expect(error.code == expectedCode.rawValue)
}

/// Mirrors `DeviceConnectionLifecycleTests.swift`'s
/// `prepareConnectionLifecycleScanReadiness`, with the one frame's thumbnail
/// carrying `needsApproval`/`warnings` instead of a plain `brightness`/`tint`
/// preview tile -- the minimal live path to a scan attempt that pauses on
/// `pendingManualReviewScan` rather than reaching `scan.start`.
@MainActor
private func driveModelToPendingManualReview(_ model: SessionModel) async -> Bool {
    await model.openProject(directory: "/tmp/control-dispatcher-test")
    model.handle(event: EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"""
            {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
            """#.utf8
        )
    ))
    let token = PreviewIntentToken()
    guard await model.requestPreview(.refreshSavedProject(token: token)) == .started else { return false }
    model.handle(event: EngineEvent(
        name: "scanner.thumbnail",
        rawLine: Data(
            #"""
            {"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":{"needsApproval":true,"warnings":["ambiguous-boundary"]}}}
            """#.utf8
        )
    ))
    model.handle(event: EngineEvent(
        name: "scanner.thumbnailsComplete",
        rawLine: Data(
            #"""
            {"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":1}}
            """#.utf8
        )
    ))
    model.toggleFrameSelection(1)
    guard model.scanReadiness(for: [1]).isReady else { return false }
    await model.startMockScan()
    return model.pendingManualReviewScan != nil
}

/// Drives a cold, pre-project preview whose one thumbnail is exactly the
/// raw JSON fragment `thumbnailJSON` (so a caller can inject an
/// `imagePath`-bearing or plain simulator-shaped tile interchangeably) --
/// D-12's pre-project `frames.list` source and its `BlankFrameHint` cache
/// only ever populate from this same "scanner.thumbnail" event path.
@MainActor
private func drivePreProjectPreviewThumbnail(_ model: SessionModel, thumbnailJSON: String) async -> Bool {
    model.handle(event: EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"""
            {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
            """#.utf8
        )
    ))
    let token = PreviewIntentToken()
    guard await model.requestPreview(.initial(token: token)) == .started else { return false }
    model.handle(event: EngineEvent(
        name: "scanner.thumbnail",
        rawLine: Data(
            #"""
            {"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":\#(thumbnailJSON)}}
            """#.utf8
        )
    ))
    model.handle(event: EngineEvent(
        name: "scanner.thumbnailsComplete",
        rawLine: Data(
            #"""
            {"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":1}}
            """#.utf8
        )
    ))
    return true
}

/// Writes a uniform single-channel PNG (`BlankFrameHintTests.swift`'s own
/// synthesized-fixture idiom, never a committed image) into a fresh temp
/// directory this function itself owns, and returns its path -- the
/// `imagePath` a fake `"scanner.thumbnail"` event needs to give
/// `ThumbnailLuminance.decodeLuminance(atPath:)` something real to decode.
private func writeUniformGrayPNGForDispatcherTest(value: UInt8, width: Int = 143, height: Int = 96) -> String? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
    let fileURL = directory.appendingPathComponent("frame.png")
    var buffer = [UInt8](repeating: value, count: width * height)
    guard let context = CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ), let cgImage = context.makeImage() else { return nil }
    guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return fileURL.path
}

// WR-02: `wait*` helpers here are built on `withCheckedContinuation`, which
// never resumes on its own -- a routing regression used to hang the suite
// instead of failing fast. `.timeLimit` is Swift Testing's suite-level bound
// (minutes is its minimum granularity).
@Suite("Control channel dispatcher", .timeLimit(.minutes(1)))
struct ControlChannelDispatcherTests {
    // MARK: Hello / schema version gate

    @Test("A traced engine refusal keeps one token in dispatch context and diagnostics")
    @MainActor
    func correlatedRefusalReachesEngineAndDiagnosticTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scanstudio-correlation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "scanstudio-correlation-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let stub = ControlDispatcherEngineStub()
        let model = SessionModel(
            engineClient: stub,
            preferences: preferences,
            diagnosticsDirectory: directory
        )
        let discoveryDeadline = ContinuousClock.now + .seconds(1)
        while model.isDiscoveringDevices, ContinuousClock.now < discoveryDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!model.isDiscoveringDevices)
        await model.connect(deviceId: controlDispatcherDevice.deviceId)
        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)

        let token = "trace-fixture:3"
        let line = Data(
            #"{"id":3,"method":"scanner.refresh","params":{},"metadata":{"correlationToken":"\#(token)"}}"#.utf8
        )
        let responseData = await dispatcher.handleLine(line)
        let response = try JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)

        #expect(response.error.code == "NOT_CONNECTED")
        #expect(await stub.correlationToken() == token)
        let log = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let diagnostics = try String(contentsOf: log, encoding: .utf8)
        #expect(diagnostics.contains("\"correlationToken\":\"\(token)\""))
        #expect(diagnostics.contains("\"controlRequestId\":\"3\""))
    }

    @Test("A request before any hello is refused with HELLO_REQUIRED")
    @MainActor
    func requestBeforeHelloIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        let line = Data(#"{"id":7,"method":"status","params":{}}"#.utf8)
        let responseData = await dispatcher.handleLine(line)
        let envelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(envelope?.id == 7)
        #expect(envelope?.error.code == ControlErrorCode.helloRequired.rawValue)
        #expect(await stub.requestCount == 0)
    }

    @Test("A hello with the wrong schemaVersion is refused with SCHEMA_VERSION_MISMATCH")
    @MainActor
    func helloVersionMismatchIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        let response = await dispatcher.handle(.hello(
            id: 1,
            params: ControlHelloParams(schemaVersion: ControlSchema.version + 1, clientName: "test-client")
        ))
        expectFailure(response, id: 1, code: .schemaVersionMismatch)
        #expect(await stub.requestCount == 0)
    }

    @Test("A rejected hello does not half-open the channel -- later commands still require hello")
    @MainActor
    func rejectedHelloDoesNotHalfOpenChannel() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        let rejected = await dispatcher.handle(.hello(
            id: 1,
            params: ControlHelloParams(schemaVersion: ControlSchema.version + 1, clientName: "test-client")
        ))
        expectFailure(rejected, id: 1, code: .schemaVersionMismatch)

        let following = await dispatcher.handle(.status(id: 2))
        expectFailure(following, id: 2, code: .helloRequired)
        #expect(await stub.requestCount == 0)
    }

    @Test("A hello with the correct schemaVersion succeeds and unblocks later commands")
    @MainActor
    func matchingHelloUnblocksLaterCommands() async {
        let (_, _, dispatcher) = await makeDispatcher()
        let helloResponse = await greet(dispatcher)
        guard case .success(let id, let result) = helloResponse, case .hello(let hello) = result else {
            Issue.record("expected a hello success result")
            return
        }
        #expect(id == 0)
        #expect(hello.schemaVersion == ControlSchema.version)

        // `.status` is still a Task 2 placeholder at this point in the plan;
        // this only proves the greeting itself unblocked the channel -- a
        // later command is no longer refused *for lack of a hello*.
        let following = await dispatcher.handle(.status(id: 3))
        if case .failure(_, let error) = following {
            #expect(error.code != ControlErrorCode.helloRequired.rawValue)
        }
    }

    // MARK: Decode failures

    @Test("An unknown method name is refused with UNKNOWN_COMMAND, carrying the request's own id")
    @MainActor
    func unknownMethodIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let line = Data(#"{"id":42,"method":"totally.unknown","params":{}}"#.utf8)
        let responseData = await dispatcher.handleLine(line)
        let envelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(envelope?.id == 42)
        #expect(envelope?.error.code == ControlErrorCode.unknownCommand.rawValue)
        #expect(envelope?.error.message.contains("totally.unknown") == true)
        #expect(await stub.requestCount == 0)
    }

    @Test("A line that is not JSON at all is refused with INVALID_PARAMS and never crashes")
    @MainActor
    func malformedLineIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let responseData = await dispatcher.handleLine(Data("not json at all".utf8))
        let envelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(envelope?.error.code == ControlErrorCode.invalidParams.rawValue)
        #expect(await stub.requestCount == 0)
    }

    @Test("A line one byte over maxRequestLineBytes is refused with INVALID_PARAMS without being parsed")
    @MainActor
    func oversizedLineIsRefusedWithoutParsing() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let oversized = Data(repeating: 0x61, count: ControlChannelDispatcher.maxRequestLineBytes + 1)
        let responseData = await dispatcher.handleLine(oversized)
        let envelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(envelope?.id == 0)
        #expect(envelope?.error.code == ControlErrorCode.invalidParams.rawValue)
        #expect(await stub.requestCount == 0)
    }

    // MARK: Confirmation (D-08)

    @Test("scanner.eject with motionConfirmed absent is refused with CONFIRMATION_REQUIRED")
    @MainActor
    func ejectWithoutConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let line = Data(#"{"id":9,"method":"scanner.eject","params":{}}"#.utf8)
        let responseData = await dispatcher.handleLine(line)
        let envelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(envelope?.id == 9)
        #expect(envelope?.error.code == ControlErrorCode.confirmationRequired.rawValue)
        #expect(await stub.requestCount == 0)
    }

    @Test("scanner.eject with motionConfirmed: false is refused with CONFIRMATION_REQUIRED")
    @MainActor
    func ejectWithFalseConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let line = Data(#"{"id":10,"method":"scanner.eject","params":{"motionConfirmed":false}}"#.utf8)
        let responseData = await dispatcher.handleLine(line)
        let envelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(envelope?.id == 10)
        #expect(envelope?.error.code == ControlErrorCode.confirmationRequired.rawValue)
        #expect(await stub.requestCount == 0)
    }

    // MARK: Busy (D-07)

    @Test("A mutating command is refused with CONTROLLER_BUSY naming the in-flight operation")
    @MainActor
    func mutatingCommandRefusedWhileBusy() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        // CR-02: `eject()` now also gates on `DeviceBarEjectPolicy.canOffer`
        // (connected, transport idle, no active job, film to release), not
        // only `hardwareMotionReadiness` -- a fresh disconnected model no
        // longer reaches the engine's `scanner.eject` at all. Establish the
        // same eject-offerable state `ControlChannelMotionRoutingTests.swift`
        // uses so this busy-preamble proof still exercises a genuinely
        // in-flight eject.
        await model.connect(deviceId: controlDispatcherDevice.deviceId)
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
                """#.utf8
            )
        ))

        let ejectOperation = Task { @MainActor in
            await model.eject()
        }
        await stub.waitForEjectRequestCount(1)
        #expect(model.mutatingOperationInFlight == "scanner.eject")

        let response = await dispatcher.handle(.scannerEject(id: 99, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected CONTROLLER_BUSY, got \(response)")
            await stub.succeedEject()
            await ejectOperation.value
            return
        }
        #expect(id == 99)
        #expect(error.code == ControlErrorCode.controllerBusy.rawValue)
        #expect(error.guidance == "scanner.eject")

        await stub.succeedEject()
        await ejectOperation.value
        #expect(model.mutatingOperationInFlight == nil)
    }

    // MARK: scanner.refresh (D-11)

    @Test("scanner.refresh returns the engine's fresh status, distinct from the pre-refresh snapshot")
    @MainActor
    func scannerRefreshReturnsFreshStatus() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.connect(deviceId: controlDispatcherDevice.deviceId)
        let beforeStatus = model.status
        let requestCountBefore = await stub.requestCount

        let response = await dispatcher.handle(.scannerRefresh(id: 42))

        guard case .success(let id, .scannerRefresh(let result)) = response else {
            Issue.record("expected a scannerRefresh success, got \(response)")
            return
        }
        #expect(id == 42)
        #expect(result.scanner != beforeStatus)
        #expect(result.scanner?.mediaLoaded == true)
        #expect(result.scanner?.frameCount == 6)
        #expect(model.status == result.scanner)
        // Proves the refresh actually reached the engine (not an echoed
        // cached value): exactly one new request beyond whatever connect
        // already made.
        #expect(await stub.requestCount == requestCountBefore + 1)
    }

    @Test("scanner.refresh while another mutating operation is in flight is refused CONTROLLER_BUSY")
    @MainActor
    func scannerRefreshRefusedWhileBusy() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.connect(deviceId: controlDispatcherDevice.deviceId)
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
                """#.utf8
            )
        ))

        let ejectOperation = Task { @MainActor in
            await model.eject()
        }
        await stub.waitForEjectRequestCount(1)
        #expect(model.mutatingOperationInFlight == "scanner.eject")

        let response = await dispatcher.handle(.scannerRefresh(id: 100))
        expectFailure(response, id: 100, code: .controllerBusy)

        await stub.succeedEject()
        await ejectOperation.value
        #expect(model.mutatingOperationInFlight == nil)
    }

    @Test("scanner.refresh ignores an extraneous motionConfirmed field and never requires confirmation")
    @MainActor
    func scannerRefreshIgnoresMotionConfirmedField() async {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.connect(deviceId: controlDispatcherDevice.deviceId)

        let line = Data(#"{"id":7,"method":"scanner.refresh","params":{"motionConfirmed":true}}"#.utf8)
        let responseData = await dispatcher.handleLine(line)
        let envelope = try? JSONDecoder().decode(
            ControlResponseEnvelopeProbe<ControlScannerRefreshResult>.self,
            from: responseData
        )
        #expect(envelope?.id == 7)
        #expect(envelope?.result.scanner?.connected == true)

        // Never CONFIRMATION_REQUIRED, regardless of what params carried --
        // scanner.refresh has no confirmation gate to trip.
        let errorEnvelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: responseData)
        #expect(errorEnvelope == nil)
    }

    // MARK: GATE_REFUSED normalization

    @Test("gateRefusal(scanReadiness:) reports the scanReadiness gate for a non-ready decision, and nil when ready")
    @MainActor
    func gateRefusalScanReadinessSource() async {
        let (_, _, dispatcher) = await makeDispatcher()
        let refusal = dispatcher.gateRefusal(scanReadiness: .projectRequired)
        #expect(refusal?.code == ControlErrorCode.gateRefused.rawValue)
        #expect(refusal?.gate == ControlGate.scanReadiness.rawValue)
        #expect(refusal?.recoverable == false)
        #expect(dispatcher.gateRefusal(scanReadiness: .ready) == nil)
    }

    @Test("gateRefusal(motionReadiness:) reports the hardwareMotion gate when motion is not allowed, and nil when it is")
    @MainActor
    func gateRefusalMotionReadinessSource() async {
        let (_, _, dispatcher) = await makeDispatcher()
        let refusal = dispatcher.gateRefusal(motionReadiness: .notEnabled)
        #expect(refusal?.code == ControlErrorCode.gateRefused.rawValue)
        #expect(refusal?.gate == ControlGate.hardwareMotion.rawValue)
        #expect(dispatcher.gateRefusal(motionReadiness: .notApplicable) == nil)
    }

    @Test("gateRefusal(scanReadiness:) falls through to the refeedRequired source once the transport needs a refeed")
    @MainActor
    func gateRefusalRefeedRequiredSource() async {
        let (model, _, dispatcher) = await makeDispatcher()

        let token = PreviewIntentToken()
        let outcome = await model.requestPreview(.initial(token: token))
        #expect(outcome == .started)
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"code":"REFEED_REQUIRED","message":"eject or refeed","operationId":"\#(token.id.uuidString)"}}"#
                    .utf8
            )
        ))
        #expect(model.refeedRequired == true)

        let refusal = dispatcher.gateRefusal(scanReadiness: nil)
        #expect(refusal?.code == ControlErrorCode.gateRefused.rawValue)
        #expect(refusal?.gate == ControlGate.refeedRequired.rawValue)
    }

    @Test("gateRefusal(scanReadiness:) falls through to the manualReviewPending source once a scan pauses on it")
    @MainActor
    func gateRefusalManualReviewPendingSource() async {
        let (model, _, dispatcher) = await makeDispatcher()
        #expect(await driveModelToPendingManualReview(model))

        let refusal = dispatcher.gateRefusal(scanReadiness: nil)
        #expect(refusal?.code == ControlErrorCode.gateRefused.rawValue)
        #expect(refusal?.gate == ControlGate.manualReviewPending.rawValue)
    }

    // MARK: Read-only aggregates (Task 2)

    @Test("Case names for hardwareMotionReadiness/scanReadiness are derived by plain String(describing:)")
    func readinessCaseNamesAreStable() {
        #expect(String(describing: HardwareMotionReadiness.ready) == "ready")
        #expect(String(describing: ScanReadinessPolicy.Decision.hardwareMotionNotReady) == "hardwareMotionNotReady")
    }

    @Test(".status mirrors device, scanner status, and the live readiness case names")
    @MainActor
    func statusMirrorsSessionState() async {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.status(id: 14))
        guard case .success(let id, let result) = response, case .status(let status) = result else {
            Issue.record("expected a status success result")
            return
        }
        #expect(id == 14)
        #expect(status.device == model.device)
        #expect(status.scanner == model.status)
        #expect(status.mutatingOperationInFlight == model.mutatingOperationInFlight)
        #expect(status.hardwareMotionReadiness == String(describing: model.hardwareMotionReadiness))
        #expect(status.scanReadiness == String(describing: model.scanReadiness(for: model.selectedFrames)))
    }

    @Test("Repeated status calls never touch the engine and return identical payloads")
    @MainActor
    func statusIsPureAndRepeatable() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let baseline = await stub.requestCount

        var results: [ControlStatusResult] = []
        for i in 0..<10 {
            let response = await dispatcher.handle(.status(id: UInt64(i)))
            guard case .success(_, let result) = response, case .status(let status) = result else {
                Issue.record("expected a status success result")
                continue
            }
            results.append(status)
        }

        #expect(await stub.requestCount == baseline)
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 == results[0] })
    }

    @Test(".framesList against a model with no open project returns an empty frames array, not an error")
    @MainActor
    func framesListWithNoProjectIsEmpty() async {
        let (_, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.framesList(id: 15))
        guard case .success(_, let result) = response, case .framesList(let framesList) = result else {
            Issue.record("expected a framesList success result")
            return
        }
        #expect(framesList.frames.isEmpty)
    }

    @Test("A ControlFrameSummary strips hardware-diagnostic detail -- only the bare error code crosses the wire")
    @MainActor
    func framesListStripsDiagnosticDetailFromFrameErrors() async throws {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.openProject(directory: "/tmp/control-dispatcher-test")
        model.jobId = "job-diagnostic-detail-test"
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"""
                {"event":"scan.frameState","payload":{"jobId":"job-diagnostic-detail-test","frameIndex":1,"state":"failed","attempt":1,"error":{"code":"FEED_JAM","message":"jam","recoverable":true,"evidence":{"schemaVersion":1,"evidenceId":"ev-1","operationId":"op-1","sessionEpoch":"1"}}}}
                """#.utf8
            )
        ))
        #expect(model.frameErrors[1]?.evidence != nil)

        let response = await dispatcher.handle(.framesList(id: 16))
        guard case .success(_, let result) = response, case .framesList(let framesList) = result else {
            Issue.record("expected a framesList success result")
            return
        }
        let encoded = try JSONEncoder().encode(framesList)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!json.contains("evidence"))
        #expect(framesList.frames.first { $0.index == 1 }?.errorCode == "FEED_JAM")
    }

    @Test("frames.list before a project exists lists every previewed thumbnail with its blank-frame hint, needsApproval, and reviewEvidence (D-12/HEAD-06)")
    @MainActor
    func framesListPreProjectCarriesHintAndReviewEvidence() async throws {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let imagePath = try #require(writeUniformGrayPNGForDispatcherTest(value: 203))
        let thumbnailJSON = #"{"needsApproval":true,"warnings":["ambiguous-boundary"],"imagePath":"\#(imagePath)"}"#
        #expect(await drivePreProjectPreviewThumbnail(model, thumbnailJSON: thumbnailJSON))

        let response = await dispatcher.handle(.framesList(id: 20))
        guard case .success(_, let result) = response, case .framesList(let framesList) = result else {
            Issue.record("expected a framesList success result")
            return
        }
        #expect(framesList.frames.count == 1)
        let frame = try #require(framesList.frames.first)
        #expect(frame.index == 1)
        #expect(frame.hasThumbnail == true)
        #expect(frame.excluded == false)
        #expect(frame.needsApproval == true)
        #expect(frame.reviewEvidence == ["ambiguous-boundary"])
        // A uniform-gray tile is fully flat -- the hint must be present and
        // non-nil, whatever its exact value (BlankFrameHintTests.swift
        // already proves the formula itself).
        #expect(frame.blankConfidence != nil)
        #expect(frame.thumbnailStddev != nil)
        #expect(frame.thumbnailMean != nil)
        #expect(frame.endBonus != nil)
        #expect(frame.runBonus != nil)
    }

    @Test("frames.list reports all five hint fields as null together for a thumbnail with no decodable raster (T-03-31)")
    @MainActor
    func framesListPreProjectNullHintForUndecodableThumbnail() async {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        // Simulator-shaped: brightness/tint, no imagePath at all -- the
        // honest "no raster" case, never a fabricated score.
        #expect(await drivePreProjectPreviewThumbnail(model, thumbnailJSON: #"{"brightness":0.5,"tint":0.0}"#))

        let response = await dispatcher.handle(.framesList(id: 21))
        guard case .success(_, let result) = response, case .framesList(let framesList) = result else {
            Issue.record("expected a framesList success result")
            return
        }
        let frame = framesList.frames.first
        #expect(frame?.hasThumbnail == true)
        #expect(frame?.needsApproval == false)
        #expect(frame?.reviewEvidence == [])
        #expect(frame?.blankConfidence == nil)
        #expect(frame?.thumbnailStddev == nil)
        #expect(frame?.thumbnailMean == nil)
        #expect(frame?.endBonus == nil)
        #expect(frame?.runBonus == nil)
    }

    @Test(".settingsGet and .outputsGet mirror the live capture/processing/output recipes")
    @MainActor
    func settingsAndOutputsGetMirrorCurrentRecipes() async {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        model.scanResolutionDpi = 2_000

        let settingsResponse = await dispatcher.handle(.settingsGet(id: 17))
        guard case .success(_, let settingsResult) = settingsResponse, case .settings(let settings) = settingsResult else {
            Issue.record("expected a settings success result")
            return
        }
        #expect(settings.capture == model.captureRecipe)
        #expect(settings.processing == model.processingRecipe)

        let outputsResponse = await dispatcher.handle(.outputsGet(id: 18))
        guard case .success(_, let outputsResult) = outputsResponse, case .outputs(let outputs) = outputsResult else {
            Issue.record("expected an outputs success result")
            return
        }
        #expect(outputs.outputs == model.outputRecipe)
    }

    @Test(".jobGet reports job state and receipt count without leaking receipt paths")
    @MainActor
    func jobGetReportsCounts() async {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        model.jobId = "job-get-test"

        let response = await dispatcher.handle(.jobGet(id: 19, params: ControlJobGetParams()))
        guard case .success(_, let result) = response, case .job(let job) = result else {
            Issue.record("expected a job success result")
            return
        }
        #expect(job.jobId == "job-get-test")
        #expect(job.completedFrameCount == model.completedFrameCount)
        #expect(job.pendingFrameCount == model.pendingFrameCount)
        #expect(job.receiptCount == model.receipts.count)
    }

    @Test("The five read-only aggregates never touch the engine, before or after")
    @MainActor
    func readOnlyAggregatesNeverTouchEngine() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.openProject(directory: "/tmp/control-dispatcher-test")

        let requests: [ControlRequest] = [
            .status(id: 20), .framesList(id: 21), .settingsGet(id: 22), .outputsGet(id: 23),
            .jobGet(id: 24, params: ControlJobGetParams()),
        ]
        for request in requests {
            let before = await stub.requestCount
            let response = await dispatcher.handle(request)
            let after = await stub.requestCount
            #expect(after == before)
            guard case .success = response else {
                Issue.record("\(request.methodName) unexpectedly failed: \(response)")
                continue
            }
        }
    }

    // MARK: Event stream (Task 3)

    @Test("subscribeToEvents yields a control.snapshot element first, before any state change")
    @MainActor
    func subscribeYieldsSnapshotFirst() async throws {
        let (_, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        var iterator = dispatcher.subscribeToEvents().makeAsyncIterator()
        guard let first = await iterator.next() else {
            Issue.record("expected a snapshot element")
            return
        }
        let envelope = try JSONDecoder().decode(ControlEventEnvelopeProbe<ControlStatusResult>.self, from: first)
        #expect(envelope.event == "control.snapshot")
    }

    @Test("subscribeToEvents yields control.changed after a SessionModel state change")
    @MainActor
    func subscribeYieldsChangedAfterStateChange() async throws {
        let (model, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        var iterator = dispatcher.subscribeToEvents().makeAsyncIterator()
        _ = await iterator.next() // consume the initial snapshot

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30","mediaLoaded":true,"carrier":"roll36","frameCount":36,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
                """#.utf8
            )
        ))

        guard let changed = await iterator.next() else {
            Issue.record("expected a control.changed element")
            return
        }
        let envelope = try JSONDecoder().decode(ControlEventEnvelopeProbe<ControlStatusResult>.self, from: changed)
        #expect(envelope.event == "control.changed")
        #expect(envelope.payload.scanner?.connected == true)
        #expect(model.status?.connected == true)
    }

    @Test("Two independent subscribers each receive their own snapshot")
    @MainActor
    func twoSubscribersEachGetOwnSnapshot() async throws {
        let (_, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        var iteratorA = dispatcher.subscribeToEvents().makeAsyncIterator()
        var iteratorB = dispatcher.subscribeToEvents().makeAsyncIterator()
        guard let firstA = await iteratorA.next(), let firstB = await iteratorB.next() else {
            Issue.record("expected a snapshot on both streams")
            return
        }
        let envelopeA = try JSONDecoder().decode(ControlEventEnvelopeProbe<ControlStatusResult>.self, from: firstA)
        let envelopeB = try JSONDecoder().decode(ControlEventEnvelopeProbe<ControlStatusResult>.self, from: firstB)
        #expect(envelopeA.event == "control.snapshot")
        #expect(envelopeB.event == "control.snapshot")
    }

    @Test("events.subscribe's response snapshot matches a concurrent status call")
    @MainActor
    func eventsSubscribeResponseMatchesStatus() async {
        let (_, _, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let subscribeResponse = await dispatcher.handle(.eventsSubscribe(id: 25))
        let statusResponse = await dispatcher.handle(.status(id: 26))
        guard case .success(_, let subscribeResult) = subscribeResponse,
              case .eventsSubscribe(let subscribed) = subscribeResult,
              case .success(_, let statusResult) = statusResponse,
              case .status(let status) = statusResult
        else {
            Issue.record("expected success results from both events.subscribe and status")
            return
        }
        #expect(subscribed.subscribed == true)
        #expect(subscribed.snapshot == status)
    }
}
