// Per-command routing proofs for the nine device-lifecycle and
// motion-capable D-05 commands Plan 05 wires onto `ControlChannelDispatcher`
// (Task 1: scanner.list/rescan/connect/disconnect). Plans 05's Tasks 2 and 3
// extend this same suite for preview.acquire/scanner.eject and
// scan.start/stop/resume.
//
// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint: every
// test here drives a fake `EngineClientProtocol` actor. No scanner motion,
// no GUI, no real engine binary.

import Foundation
import Testing

@testable import ScanStudioKit

private enum MotionRoutingStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private let motionRoutingDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

/// A fake *real* device fixture (Task 2) -- `hardwareMotionReadiness` is
/// always `.notApplicable` (motion always allowed) for a simulated device,
/// so a "motion not ready" test needs a device that reports `kind: "real"`,
/// exactly like `DeviceConnectionLifecycleTests.swift`'s own device
/// fixture. This is a label in a mocked engine response, never real
/// hardware or motion.
private let motionRoutingRealDevice = DeviceInfo(
    deviceId: "real-ls5000-motion-routing-test",
    model: "LS-5000 ED",
    kind: "real",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

/// The directory a `scan.resume`-with-no-pending-frames test opens instead
/// of `motionRoutingProjectDirectory` -- routes the stub's `project.open`
/// case to `motionRoutingProject(includeFrames: false)` below.
private let motionRoutingProjectDirectory = "/tmp/motion-routing-test"
private let motionRoutingEmptyProjectDirectory = "/tmp/motion-routing-test-no-frames"

/// A minimal project fixture (Task 3) whose one frame has no draft
/// alignment or rotation, so `startMockScan()`'s
/// `persistFrameGeometryBeforeScan` step is a no-op and never issues an
/// unscripted `project.setFrameAlignment` request -- confirmed by reading
/// `desiredFrameGeometry(for:persistedFrame:)` and mirroring
/// `ControlChannelDispatcherTests.swift`'s own `controlDispatcherProject()`.
/// `includeFrames: false` keeps `frameCount: 1` (so `projectMediaMismatch`
/// still matches the previewed carrier/frame count) but declares zero
/// `ProjectFrame` entries, so `restoreProjectProgress` -- called
/// synchronously from `openProject` -- computes `pendingFrames == []`
/// immediately, exactly the input a `scan.resume` "nothing pending" test
/// needs; `selectedFrames`-driven tests are unaffected since they never
/// read `pendingFrames`.
private func motionRoutingProject(
    frameIndex: Int = 1,
    includeFrames: Bool = true,
    rollExposureLock: RollExposureLock? = nil
) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "motion-routing-project",
        name: "Motion routing test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/motion-routing/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/motion-routing/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/motion-routing/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        rollExposureLock: rollExposureLock,
        createdAt: "2026-09-07T00:00:00Z",
        frames: includeFrames ? [ProjectFrame(index: frameIndex, excluded: false, receipts: [])] : []
    )
}

/// Fake engine modelled on `ConnectionLifecycleEngineStub`
/// (`DeviceConnectionLifecycleTests.swift`) and `ControlDispatcherEngineStub`
/// (`ControlChannelDispatcherTests.swift`). Rather than one dedicated
/// `CheckedContinuation` property pair per scripted method (this suite needs
/// several across Tasks 1-3), every method shares one gate mechanism:
/// `hold(_:)` marks a method name to block on until `release(_:)` opens it,
/// and `waitForRequestCount(_:_:)` lets a test observe "this call has
/// arrived" deterministically, never by a fixed sleep. `hold(_:)` only
/// affects requests issued *after* it is called, so `SessionModel.init`'s
/// own incidental `scanner.list` discovery request is never accidentally
/// gated.
private actor MotionRoutingEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    private let eventsContinuation: AsyncStream<EngineEvent>.Continuation
    var engineVersion: String? = "motion-routing-stub"

    init() {
        var continuation: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    /// Every request this stub has received since the last `clearLog()`, in
    /// order -- the CTRL-03 proof that a routing arm invoked the one
    /// expected engine method reads this list, never a return value or a
    /// state side effect.
    private(set) var recordedMethods: [String] = []
    private(set) var requestCounts: [String: Int] = [:]
    /// The `mode` argument of every `scan.stop` request, in order -- the
    /// only way to tell `stopAfterCurrentFrame()` and `stopImmediately()`
    /// apart from this stub's point of view, since both call the identical
    /// `"scan.stop"` engine method (Task 3).
    private(set) var recordedScanStopModes: [String] = []

    private var heldMethods: Set<String> = []
    private var openGates: Set<String> = []
    private var gateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var countWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Clears the request log without touching gate state -- called once
    /// `SessionModel.init`'s own incidental discovery call has resolved, so
    /// it never pollutes a "received exactly this method" assertion.
    func clearLog() {
        recordedMethods.removeAll()
        requestCounts.removeAll()
        recordedScanStopModes.removeAll()
    }

    /// Gates every subsequent request for `method` until `release(_:)` is
    /// called.
    func hold(_ method: String) {
        heldMethods.insert(method)
    }

    /// Opens `method`'s gate, resuming every request currently blocked on
    /// it (and any later one, since `openGates` is sticky).
    func release(_ method: String) {
        openGates.insert(method)
        let waiting = gateWaiters.removeValue(forKey: method) ?? []
        for continuation in waiting { continuation.resume() }
    }

    func waitForRequestCount(_ method: String, _ count: Int) async {
        guard (requestCounts[method] ?? 0) < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((method, count, continuation))
        }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params
    ) async throws -> Result {
        recordedMethods.append(method)
        requestCounts[method, default: 0] += 1
        resumeSatisfiedCountWaiters(for: method)
        await awaitGate(method)
        switch method {
        case "scanner.list", "scanner.rescan":
            // Both fixtures are always discoverable so a test can connect
            // to either one by id without a separate scripted response.
            return try cast(ScannerListResult(devices: [motionRoutingDevice, motionRoutingRealDevice]), as: Result.self)
        case "scanner.connect":
            let requestedDeviceId = (params as? ConnectParams)?.deviceId
            let connectedDevice = requestedDeviceId == motionRoutingRealDevice.deviceId
                ? motionRoutingRealDevice
                : motionRoutingDevice
            return try cast(ConnectResult(
                device: connectedDevice,
                status: ScannerStatus(
                    connected: true, adapter: "SA-21", mediaLoaded: false, carrier: nil,
                    frameCount: nil, lamp: "unknown", transport: "idle", activeJobId: nil,
                    filmPresent: nil, motionArmed: true
                )
            ), as: Result.self)
        case "scanner.disconnect", "scanner.eject":
            return try cast(EmptyResult(), as: Result.self)
        case "scanner.acquireThumbnails":
            return try cast(AcquireThumbnailsAck(accepted: true, frames: []), as: Result.self)
        case "project.open":
            let requestedDirectory = (params as? ProjectOpenParams)?.directory ?? motionRoutingProjectDirectory
            let openedProject = requestedDirectory == motionRoutingEmptyProjectDirectory
                ? motionRoutingProject(includeFrames: false)
                : motionRoutingProject()
            return try cast(
                ProjectOpenResult(project: openedProject, directory: requestedDirectory),
                as: Result.self
            )
        case "roll.solveExposure":
            let solve = params as! RollSolveExposureParams
            let solution = RollExposureLock(
                slot: solve.frameIndex,
                rgbExposuresRaw10ns: [120_000, 130_000, 140_000],
                irMeteredExposureRaw10ns: 150_000,
                meterEvidencePath: "/tmp/motion-routing/meter.tif",
                meterEvidenceSha256: String(repeating: "a", count: 64),
                journalPath: "/tmp/motion-routing/journal.json",
                journalSha256: String(repeating: "b", count: 64)
            )
            let payload = RollExposureSolvedPayload(
                operationId: solve.operationId,
                solution: solution,
                project: motionRoutingProject(rollExposureLock: solution)
            )
            let data = try JSONEncoder().encode(TestEvent(event: "roll.exposureSolved", payload: payload))
            eventsContinuation.yield(EngineEvent(name: "roll.exposureSolved", rawLine: data))
            return try cast(RollSolveExposureAck(accepted: true), as: Result.self)
        case "scan.start":
            return try cast(ScanStartResult(jobId: "motion-routing-job"), as: Result.self)
        case "scan.stop":
            let stopMode = (params as? ScanStopParams)?.mode ?? "afterCurrentFrame"
            recordedScanStopModes.append(stopMode)
            return try cast(ScanStopResult(acknowledged: true, mode: stopMode), as: Result.self)
        default:
            throw MotionRoutingStubError.unexpectedMethod(method)
        }
    }

    private func awaitGate(_ method: String) async {
        guard heldMethods.contains(method), !openGates.contains(method) else { return }
        await withCheckedContinuation { continuation in
            gateWaiters[method, default: []].append(continuation)
        }
    }

    private func resumeSatisfiedCountWaiters(for method: String) {
        let current = requestCounts[method] ?? 0
        let satisfied = countWaiters.filter { $0.method == method && current >= $0.count }
        countWaiters.removeAll { $0.method == method && current >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw MotionRoutingStubError.unexpectedResultType }
        return result
    }
}

private struct TestEvent<Payload: Encodable>: Encodable {
    let event: String
    let payload: Payload
}

/// Bounded `Task.yield()` polling, per this codebase's established idiom
/// (`ControlBusyIndicatorTests.swift`, `ControlChannelDispatcherTests.swift`)
/// for waiting out a fire-and-forget async call without a fixed sleep.
@MainActor
private func makeIdleModel(_ stub: MotionRoutingEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

@MainActor
private func makeDispatcher() async -> (model: SessionModel, stub: MotionRoutingEngineStub, dispatcher: ControlChannelDispatcher) {
    let stub = MotionRoutingEngineStub()
    let model = await makeIdleModel(stub)
    await stub.clearLog()
    let dispatcher = ControlChannelDispatcher(sessionModel: model)
    return (model, stub, dispatcher)
}

@MainActor
@discardableResult
private func greet(_ dispatcher: ControlChannelDispatcher) async -> ControlResponse {
    await dispatcher.handle(.hello(
        id: 0,
        params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "motion-routing-tests")
    ))
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
/// `prepareConnectionLifecycleScanReadiness` and
/// `ControlChannelDispatcherTests.swift`'s `driveModelToPendingManualReview`
/// (Task 3): connects, opens a project, fakes a media-loaded status,
/// completes a preview with a plain (not `needsApproval`) thumbnail, and
/// selects frame 1 -- reaching `scanReadiness(for: [1]).isReady == true`
/// without ever pausing on manual review. The `connect(deviceId:)` call is
/// required, not cosmetic: `dispatchScanStart`'s own
/// `scanStartRequestIsCurrent` guard additionally checks
/// `diagnosticUIConnected` (`device != nil && status?.connected == true`),
/// and only `connect(deviceId:)` sets `device` -- a synthetic
/// `scanner.status` event alone sets `status` but never `device`, so
/// without this call `dispatchScanStart` would silently return `nil`
/// (RESEARCH Pitfall 1) rather than ever reaching `scan.start`. Passing
/// `motionRoutingEmptyProjectDirectory` opens a project with zero
/// `ProjectFrame` entries, so `pendingFrames` (set synchronously by
/// `openProject`'s own `restoreProjectProgress`) is `[]` -- what a
/// `scan.resume` "nothing pending" test needs; `selectedFrames`-driven
/// tests are unaffected since they never read `pendingFrames`.
@MainActor
private func prepareMotionRoutingScanReadiness(
    _ model: SessionModel, directory: String = motionRoutingProjectDirectory
) async -> Bool {
    await model.connect(deviceId: motionRoutingDevice.deviceId)
    await model.openProject(directory: directory)
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
            {"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":{"brightness":0.5,"tint":0.0}}}
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
    guard directory != motionRoutingEmptyProjectDirectory else {
        // This project declares no frames at all, so frame 1 is not a
        // structurally valid target (`validFrameIndices` is empty) --
        // `scanReadiness(for: [1])` would read `.targetRequired` for the
        // wrong reason. The caller only needs the connected/previewed
        // preconditions established above, with `pendingFrames` left at
        // its structural `[]`; the preview having started is proof enough.
        return true
    }
    model.toggleFrameSelection(1)
    return model.scanReadiness(for: [1]).isReady
}

/// D-23/HEAD-12 (`review.cancel`'s own test): identical to
/// `prepareMotionRoutingScanReadiness`, except the one thumbnail carries
/// `needsApproval: true` -- the minimal live path to a scan attempt that
/// pauses on `pendingManualReviewScan` rather than reaching `scan.start`.
/// Mirrors `ControlChannelDispatcherTests.swift`'s own
/// `driveModelToPendingManualReview` (private to that file).
@MainActor
private func driveMotionRoutingToPendingManualReview(_ model: SessionModel) async -> Bool {
    await model.connect(deviceId: motionRoutingDevice.deviceId)
    await model.openProject(directory: motionRoutingProjectDirectory)
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

/// Connects to the fake "real" device fixture, then injects a synthetic
/// `scanner.status` event carrying `motionArmed: false` -- the live-state
/// route `DeviceConnectionLifecycleTests.swift` drives throughout, never a
/// settable test seam added to `SessionModel`. Drives
/// `sessionModel.hardwareMotionReadiness` to `.notEnabled` (`allowsMotion
/// == false`).
@MainActor
private func driveHardwareMotionNotReady(_ model: SessionModel) async {
    await model.connect(deviceId: motionRoutingRealDevice.deviceId)
    model.handle(event: EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"""
            {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":null,"motionArmed":false}}}
            """#.utf8
        )
    ))
}

// WR-02: every wait helper in this file (`hold`/`release`/
// `waitForRequestCount`) is built on `withCheckedContinuation`, which never
// resumes on its own. A routing regression that breaks an expected engine
// call used to hang the suite forever instead of failing fast; `.timeLimit`
// is Swift Testing's suite-level bound (minutes is its minimum granularity),
// so a hung continuation now fails with a clear timeout instead.
@Suite("Control channel motion routing", .timeLimit(.minutes(1)))
struct ControlChannelMotionRoutingTests {
    // MARK: Device lifecycle (Task 1)

    @Test("scanner.list routes to refreshAvailableDevices(rescan: false) and refuses a concurrent second request")
    @MainActor
    func scannerListRoutesAndRefusesConcurrentSecondRequest() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.hold("scanner.list")

        let first = Task { @MainActor in
            await dispatcher.handle(.scannerList(id: 1))
        }
        await stub.waitForRequestCount("scanner.list", 1)
        #expect(model.mutatingOperationInFlight == "scanner.list")
        #expect(await stub.recordedMethods == ["scanner.list"])

        let busyResponse = await dispatcher.handle(.scannerList(id: 2))
        expectFailure(busyResponse, id: 2, code: .controllerBusy)
        if case .failure(_, let error) = busyResponse {
            #expect(error.guidance == "scanner.list")
        }
        #expect(await stub.requestCounts["scanner.list"] == 1)

        await stub.release("scanner.list")
        let firstResponse = await first.value
        guard case .success(_, let result) = firstResponse, case .scannerList(let scannerListResult) = result else {
            Issue.record("expected a scannerList success result, got \(firstResponse)")
            return
        }
        #expect(scannerListResult.devices.map(\.deviceId) == [motionRoutingDevice.deviceId, motionRoutingRealDevice.deviceId])
        #expect(model.mutatingOperationInFlight == nil)
    }

    @Test("scanner.rescan routes to refreshAvailableDevices(rescan: true) and refuses a concurrent second request")
    @MainActor
    func scannerRescanRoutesAndRefusesConcurrentSecondRequest() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.hold("scanner.rescan")

        let first = Task { @MainActor in
            await dispatcher.handle(.scannerRescan(id: 1))
        }
        await stub.waitForRequestCount("scanner.rescan", 1)
        #expect(model.mutatingOperationInFlight == "scanner.rescan")
        #expect(await stub.recordedMethods == ["scanner.rescan"])

        let busyResponse = await dispatcher.handle(.scannerRescan(id: 2))
        expectFailure(busyResponse, id: 2, code: .controllerBusy)
        if case .failure(_, let error) = busyResponse {
            #expect(error.guidance == "scanner.rescan")
        }
        #expect(await stub.requestCounts["scanner.rescan"] == 1)

        await stub.release("scanner.rescan")
        let firstResponse = await first.value
        guard case .success(_, let result) = firstResponse, case .scannerList(let scannerListResult) = result else {
            Issue.record("expected a scannerList success result, got \(firstResponse)")
            return
        }
        #expect(scannerListResult.devices.map(\.deviceId) == [motionRoutingDevice.deviceId, motionRoutingRealDevice.deviceId])
        #expect(model.mutatingOperationInFlight == nil)
    }

    @Test("scanner.connect routes to connect(deviceId:) and refuses a concurrent second request")
    @MainActor
    func scannerConnectRoutesAndRefusesConcurrentSecondRequest() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.hold("scanner.connect")

        let first = Task { @MainActor in
            await dispatcher.handle(.scannerConnect(id: 1, params: ControlScannerConnectParams(deviceId: motionRoutingDevice.deviceId)))
        }
        await stub.waitForRequestCount("scanner.connect", 1)
        #expect(model.mutatingOperationInFlight == "scanner.connect")
        #expect(await stub.recordedMethods == ["scanner.connect"])

        let busyResponse = await dispatcher.handle(.scannerConnect(id: 2, params: ControlScannerConnectParams(deviceId: motionRoutingDevice.deviceId)))
        expectFailure(busyResponse, id: 2, code: .controllerBusy)
        if case .failure(_, let error) = busyResponse {
            #expect(error.guidance == "scanner.connect")
            // The wire-level code, spelled literally: CONTROLLER_BUSY.
            #expect(error.code == "CONTROLLER_BUSY")
        }
        #expect(await stub.requestCounts["scanner.connect"] == 1)

        await stub.release("scanner.connect")
        let firstResponse = await first.value
        guard case .success = firstResponse else {
            Issue.record("expected scanner.connect to succeed, got \(firstResponse)")
            return
        }
        #expect(model.mutatingOperationInFlight == nil)
        #expect(model.device?.deviceId == motionRoutingDevice.deviceId)
    }

    @Test("scanner.connect for an unknown device id fails at the app-level-precondition branch, carrying SessionModel's own message")
    @MainActor
    func connectToUnknownDeviceIsAppLevelPreconditionFailure() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.scannerConnect(id: 5, params: ControlScannerConnectParams(deviceId: "does-not-exist")))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 5)
        #expect(error.code == ControlErrorCode.gateRefused.rawValue)
        #expect(error.gate == nil)
        #expect(error.guidance == "The engine has no device with id \"does-not-exist\".")
        #expect(await stub.recordedMethods.contains("scanner.connect") == false)
    }

    @Test("scanner.disconnect routes to disconnect() and refuses a concurrent second request")
    @MainActor
    func scannerDisconnectRoutesAndRefusesConcurrentSecondRequest() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.hold("scanner.disconnect")

        let first = Task { @MainActor in
            await dispatcher.handle(.scannerDisconnect(id: 1))
        }
        await stub.waitForRequestCount("scanner.disconnect", 1)
        #expect(model.mutatingOperationInFlight == "scanner.disconnect")
        #expect(await stub.recordedMethods == ["scanner.disconnect"])

        let busyResponse = await dispatcher.handle(.scannerDisconnect(id: 2))
        expectFailure(busyResponse, id: 2, code: .controllerBusy)
        if case .failure(_, let error) = busyResponse {
            #expect(error.guidance == "scanner.disconnect")
        }
        #expect(await stub.requestCounts["scanner.disconnect"] == 1)

        await stub.release("scanner.disconnect")
        let firstResponse = await first.value
        guard case .success = firstResponse else {
            Issue.record("expected scanner.disconnect to succeed, got \(firstResponse)")
            return
        }
        #expect(model.mutatingOperationInFlight == nil)
    }

    // MARK: Outcome helper prefix parse (Task 1)

    @Test("parseEngineCodePrefix recovers an engine-shaped CODE: message prefix and rejects non-code-shaped text")
    func parseEngineCodePrefixRecognizesEngineShapedMessagesOnly() {
        let engineShaped = ControlChannelDispatcher.parseEngineCodePrefix("NOT_CONNECTED: the scanner is not connected")
        #expect(engineShaped?.code == "NOT_CONNECTED")
        #expect(engineShaped?.remainder == "the scanner is not connected")

        #expect(ControlChannelDispatcher.parseEngineCodePrefix("This roll is already saved.") == nil)
        #expect(ControlChannelDispatcher.parseEngineCodePrefix("Choose a scanner from Connect: pick one, ScanStudio will not guess.") == nil)
    }

    // MARK: preview.acquire (Task 2)

    @Test("preview.acquire without filmLoadedConfirmed is refused with CONFIRMATION_REQUIRED before any engine call")
    @MainActor
    func previewAcquireWithoutConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.previewAcquire(
            id: 1, params: ControlPreviewAcquireParams(filmLoadedConfirmed: nil, intent: nil, filmProcess: nil)
        ))
        expectFailure(response, id: 1, code: .confirmationRequired)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("preview.acquire with confirmation on a not-motion-ready model is refused with GATE_REFUSED before any engine call")
    @MainActor
    func previewAcquireWithMotionNotReadyIsRefused() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await driveHardwareMotionNotReady(model)
        await stub.clearLog()

        let response = await dispatcher.handle(.previewAcquire(
            id: 2, params: ControlPreviewAcquireParams(filmLoadedConfirmed: true, intent: nil, filmProcess: nil)
        ))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.gate == ControlGate.hardwareMotion.rawValue)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("preview.acquire with intent replaceFilmProcess and no filmProcess is refused with INVALID_PARAMS")
    @MainActor
    func previewAcquireReplaceFilmProcessWithoutFilmProcessIsInvalid() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.previewAcquire(
            id: 3, params: ControlPreviewAcquireParams(filmLoadedConfirmed: true, intent: "replaceFilmProcess", filmProcess: nil)
        ))
        expectFailure(response, id: 3, code: .invalidParams)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("preview.acquire with an unrecognized intent string is refused with INVALID_PARAMS")
    @MainActor
    func previewAcquireUnknownIntentIsInvalid() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.previewAcquire(
            id: 4, params: ControlPreviewAcquireParams(filmLoadedConfirmed: true, intent: "banana", filmProcess: nil)
        ))
        expectFailure(response, id: 4, code: .invalidParams)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("A successful preview.acquire reaches scanner.acquireThumbnails and returns a parseable intentToken")
    @MainActor
    func previewAcquireSucceedsAndReachesAcquireThumbnails() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.previewAcquire(
            id: 5, params: ControlPreviewAcquireParams(filmLoadedConfirmed: true, intent: nil, filmProcess: nil)
        ))
        guard case .success(let id, let result) = response, case .previewAcquire(let previewResult) = result else {
            Issue.record("expected a previewAcquire success result, got \(response)")
            return
        }
        #expect(id == 5)
        #expect(previewResult.outcome == "started")
        #expect(UUID(uuidString: previewResult.intentToken) != nil)
        #expect(await stub.recordedMethods == ["scanner.acquireThumbnails"])
    }

    // MARK: scanner.eject (Task 2)

    @Test("scanner.eject without motionConfirmed is refused with CONFIRMATION_REQUIRED before any engine call")
    @MainActor
    func ejectWithoutConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.scannerEject(id: 1, params: ControlScannerEjectParams(motionConfirmed: nil)))
        expectFailure(response, id: 1, code: .confirmationRequired)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scanner.eject with confirmation on a not-motion-ready model is refused with GATE_REFUSED before any engine call")
    @MainActor
    func ejectWithMotionNotReadyIsRefused() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await driveHardwareMotionNotReady(model)
        await stub.clearLog()

        let response = await dispatcher.handle(.scannerEject(id: 2, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.gate == ControlGate.hardwareMotion.rawValue)
        #expect(await stub.recordedMethods.isEmpty)
    }

    // CR-02: `scanner.eject` while disconnected, mid-job, or mid-transport-
    // activity used to reach the engine unchallenged -- the dispatcher's own
    // pre-check now calls `DeviceBarEjectPolicy.canOffer`, the identical
    // function `DeviceBarView.canOfferEject` gates the GUI's Eject button
    // on, fed the same live `SessionModel` state.

    @Test("scanner.eject while disconnected is refused with GATE_REFUSED before any engine call")
    @MainActor
    func ejectWhileDisconnectedIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.scannerEject(id: 3, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 3)
        #expect(error.code == "GATE_REFUSED")
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scanner.eject while a job is active is refused with GATE_REFUSED before any engine call")
    @MainActor
    func ejectWhileJobActiveIsRefused() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.connect(deviceId: motionRoutingDevice.deviceId)
        model.beginJob(id: "motion-routing-eject-job-active")
        await stub.clearLog()

        let response = await dispatcher.handle(.scannerEject(id: 4, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 4)
        #expect(error.code == "GATE_REFUSED")
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scanner.eject while the transport is not idle is refused with GATE_REFUSED before any engine call")
    @MainActor
    func ejectWhileTransportNotIdleIsRefused() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.connect(deviceId: motionRoutingDevice.deviceId)
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"busy","activeJobId":null,"filmPresent":null,"motionArmed":true}}}
                """#.utf8
            )
        ))
        await stub.clearLog()

        let response = await dispatcher.handle(.scannerEject(id: 5, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 5)
        #expect(error.code == "GATE_REFUSED")
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scanner.eject in the incident case (filmPresent: true, mediaLoaded: false) succeeds, reaching exactly one scanner.eject request")
    @MainActor
    func ejectInIncidentCaseSucceeds() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.connect(deviceId: motionRoutingDevice.deviceId)
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-30","mediaLoaded":false,"carrier":"roll36","frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
                """#.utf8
            )
        ))
        await stub.clearLog()

        let response = await dispatcher.handle(.scannerEject(id: 6, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .success = response else {
            Issue.record("expected scanner.eject to succeed, got \(response)")
            return
        }
        #expect(await stub.recordedMethods == ["scanner.eject"])
    }

    // MARK: scan.start (Task 3)

    @Test("scan.start without motionConfirmed is refused with CONFIRMATION_REQUIRED before any engine call")
    @MainActor
    func scanStartWithoutConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.scanStart(id: 1, params: ControlScanStartParams(motionConfirmed: nil)))
        expectFailure(response, id: 1, code: .confirmationRequired)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scan.start with confirmation on a not-scan-ready model is refused with GATE_REFUSED naming the readiness reason")
    @MainActor
    func scanStartNotReadyIsRefused() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let decision = model.scanReadiness(for: model.selectedFrames)
        #expect(!decision.isReady)

        let response = await dispatcher.handle(.scanStart(id: 2, params: ControlScanStartParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.gate == ControlGate.scanReadiness.rawValue)
        #expect(error.guidance == decision.reason)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scan.start routes to startMockScan(), reaches scan.start, and refuses a concurrent second request")
    @MainActor
    func scanStartRoutesAndRefusesConcurrentSecondRequest() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        #expect(await prepareMotionRoutingScanReadiness(model))
        await stub.clearLog()
        await stub.hold("scan.start")

        let first = Task { @MainActor in
            await dispatcher.handle(.scanStart(id: 3, params: ControlScanStartParams(motionConfirmed: true)))
        }
        await stub.waitForRequestCount("scan.start", 1)
        #expect(model.mutatingOperationInFlight == "scan.start")
        #expect(await stub.recordedMethods == ["scan.start"])

        let busyResponse = await dispatcher.handle(.scanStart(id: 4, params: ControlScanStartParams(motionConfirmed: true)))
        expectFailure(busyResponse, id: 4, code: .controllerBusy)
        #expect(await stub.requestCounts["scan.start"] == 1)

        await stub.release("scan.start")
        let firstResponse = await first.value
        guard case .success = firstResponse else {
            Issue.record("expected scan.start to succeed, got \(firstResponse)")
            return
        }
        #expect(model.mutatingOperationInFlight == nil)
    }

    // MARK: scan.stop (Task 3)

    @Test("scan.stop with mode absent reaches stopAfterCurrentFrame while mode: \"immediate\" reaches stopImmediately")
    @MainActor
    func scanStopRoutesByMode() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        model.beginJob(id: "motion-routing-job-1")
        await stub.clearLog()

        let afterCurrentResponse = await dispatcher.handle(.scanStop(id: 1, params: ControlScanStopParams(mode: nil)))
        guard case .success = afterCurrentResponse else {
            Issue.record("expected scan.stop (afterCurrentFrame) to succeed, got \(afterCurrentResponse)")
            return
        }
        #expect(await stub.recordedMethods == ["scan.stop"])
        #expect(await stub.recordedScanStopModes == ["afterCurrentFrame"])

        model.beginJob(id: "motion-routing-job-2")
        await stub.clearLog()
        let immediateResponse = await dispatcher.handle(.scanStop(id: 2, params: ControlScanStopParams(mode: "immediate")))
        guard case .success = immediateResponse else {
            Issue.record("expected scan.stop (immediate) to succeed, got \(immediateResponse)")
            return
        }
        #expect(await stub.recordedMethods == ["scan.stop"])
        #expect(await stub.recordedScanStopModes == ["immediate"])
    }

    @Test("scan.stop with an unrecognized mode is refused with INVALID_PARAMS before any engine call")
    @MainActor
    func scanStopUnknownModeIsInvalid() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        model.beginJob(id: "motion-routing-job")
        await stub.clearLog()
        let response = await dispatcher.handle(.scanStop(id: 3, params: ControlScanStopParams(mode: "sideways")))
        expectFailure(response, id: 3, code: .invalidParams)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scan.stop with no active job is refused with GATE_REFUSED, not a silent success")
    @MainActor
    func scanStopWithNoActiveJobIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.scanStop(id: 4, params: ControlScanStopParams(mode: nil)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 4)
        #expect(error.code == "GATE_REFUSED")
        #expect(await stub.recordedMethods.isEmpty)
    }

    // MARK: scan.resume (Task 3)

    @Test("scan.resume without motionConfirmed is refused with CONFIRMATION_REQUIRED before any engine call")
    @MainActor
    func scanResumeWithoutConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.scanResume(id: 1, params: ControlScanResumeParams(motionConfirmed: nil)))
        expectFailure(response, id: 1, code: .confirmationRequired)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("scan.resume when pendingFrames is empty is refused with GATE_REFUSED naming .targetRequired")
    @MainActor
    func scanResumeWithNoPendingFramesIsRefused() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        #expect(await prepareMotionRoutingScanReadiness(model, directory: motionRoutingEmptyProjectDirectory))
        #expect(model.pendingFrames.isEmpty)
        await stub.clearLog()

        let response = await dispatcher.handle(.scanResume(id: 2, params: ControlScanResumeParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.gate == ControlGate.scanReadiness.rawValue)
        #expect(error.guidance == ScanReadinessPolicy.Decision.targetRequired.reason)
        // D-22/HEAD-12 (CF-12/CF-13, the 2026-09-07 batch abort): the arm
        // now refreshes pendingFrames from the engine before evaluating
        // readiness, so exactly that one read reaches the engine -- never
        // a motion-capable call, and never more than the one refresh.
        #expect(await stub.recordedMethods == ["project.pendingFrames"])
    }

    // WR-01: `resumeBatch()`'s own guard reads three `private` flags plus
    // `isResumingBatch` this dispatcher cannot see directly -- these two
    // tests prove a `scan.resume` racing each of them gets a typed refusal
    // instead of a silent success (RESEARCH Pitfall 1), the same failure
    // mode CR-01 closes for `scan.start`.

    @Test("scan.resume reports GATE_REFUSED, not a silent success, while a scan is already starting")
    @MainActor
    func scanResumeIsRefusedWhilePendingScanStart() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        #expect(await prepareMotionRoutingScanReadiness(model))
        await stub.clearLog()
        await stub.hold("scan.start")

        // `scanSingleFrame(_:)` (unlike `startMockScan()`) never calls
        // `beginMutatingOperation`, so `mutatingOperationInFlight` stays nil
        // throughout -- the dispatcher's generic busy preamble cannot catch
        // this race. Only `resumeBatch()`'s own `pendingScanStart` guard can.
        let scanTask = Task { @MainActor in
            await model.scanSingleFrame(1)
        }
        await stub.waitForRequestCount("scan.start", 1)
        #expect(model.mutatingOperationInFlight == nil)

        let response = await dispatcher.handle(.scanResume(id: 7, params: ControlScanResumeParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            await stub.release("scan.start")
            await scanTask.value
            return
        }
        #expect(id == 7)
        #expect(error.code == "GATE_REFUSED")
        #expect(await stub.requestCounts["scan.start"] == 1)

        await stub.release("scan.start")
        await scanTask.value
    }

    @Test("resumeBatch reports a typed refusal instead of a silent no-op while a resume is already in flight")
    @MainActor
    func resumeBatchRefusesSecondDirectCallWhileResuming() async {
        let (model, stub, _) = await makeDispatcher()
        #expect(await prepareMotionRoutingScanReadiness(model))
        await stub.clearLog()
        await stub.hold("project.pendingFrames")

        let first = Task { @MainActor in
            await model.resumeBatch()
        }
        await stub.waitForRequestCount("project.pendingFrames", 1)
        #expect(model.isResumingBatch)
        #expect(model.mutatingOperationInFlight == "scan.resume")

        // A direct `SessionModel` call -- IN-01: not gated by the
        // dispatcher's own busy preamble -- used to return silently here
        // with `lastErrorMessage` untouched.
        await model.resumeBatch()
        #expect(model.lastErrorMessage == "A resume is already in progress.")

        await stub.release("project.pendingFrames")
        _ = await first.value
    }

    @Test("roll.solveExposure requires explicit motion confirmation")
    @MainActor
    func solveExposureRequiresConfirmation() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.rollSolveExposure(
            id: 41,
            params: ControlRollSolveExposureParams(frame: 1, motionConfirmed: false)
        ))
        expectFailure(response, id: 41, code: .confirmationRequired)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("roll.solveExposure waits for terminal evidence and installs the persisted project lock")
    @MainActor
    func solveExposurePersistsReturnedProject() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        #expect(await prepareMotionRoutingScanReadiness(model))
        await stub.clearLog()

        let response = await dispatcher.handle(.rollSolveExposure(
            id: 42,
            params: ControlRollSolveExposureParams(frame: 1, motionConfirmed: true)
        ))
        guard case .success(let id, let result) = response,
              case .rollExposure(let exposure) = result
        else {
            Issue.record("expected exposure solution, got \(response)")
            return
        }
        #expect(id == 42)
        #expect(exposure.solution.rgbExposuresRaw10ns == [120_000, 130_000, 140_000])
        #expect(model.project?.rollExposureLock == exposure.solution)
        #expect(model.mutatingOperationInFlight == nil)
        #expect(await stub.recordedMethods == ["roll.solveExposure"])
    }

    // MARK: - D-23/HEAD-12: review.cancel (CF-10/CF-11)

    @Test("review.cancel preserves the selection and starts nothing")
    @MainActor
    func reviewCancelPreservesTheSelectionAndStartsNothing() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        #expect(await driveMotionRoutingToPendingManualReview(model))
        let selectionBefore = model.selectedFrameIndices
        #expect(model.jobId == nil)
        await stub.clearLog()

        let response = await dispatcher.handle(.reviewCancel(id: 9))
        guard case .success = response else {
            Issue.record("expected review.cancel to succeed, got \(response)")
            return
        }
        #expect(model.pendingManualReviewScan == nil, "the pending review must be dismissed")
        #expect(model.selectedFrameIndices == selectionBefore, "the operator's selection must be byte-identical before and after")
        #expect(model.jobId == nil, "review.cancel must never start a scan")
        #expect(await stub.recordedMethods.isEmpty, "review.cancel must issue no engine request beyond the cancel itself")
    }

    @Test("review.cancel with nothing pending is refused with GATE_REFUSED naming manualReviewPending")
    @MainActor
    func reviewCancelWithNothingPendingIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.reviewCancel(id: 10))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 10)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.gate == ControlGate.manualReviewPending.rawValue)
        #expect(await stub.recordedMethods.isEmpty)
    }
}
