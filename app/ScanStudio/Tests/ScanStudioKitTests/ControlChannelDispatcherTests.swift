import Foundation
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

private func expectFailure(_ response: ControlResponse, id expectedId: UInt64, code expectedCode: ControlErrorCode) {
    guard case .failure(let id, let error) = response else {
        Issue.record("expected a failure response but got \(response)")
        return
    }
    #expect(id == expectedId)
    #expect(error.code == expectedCode.rawValue)
}

@Suite("Control channel dispatcher")
struct ControlChannelDispatcherTests {
    // MARK: Hello / schema version gate

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

        let response = await dispatcher.handle(.jobGet(id: 19))
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
            .status(id: 20), .framesList(id: 21), .settingsGet(id: 22), .outputsGet(id: 23), .jobGet(id: 24),
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
}
