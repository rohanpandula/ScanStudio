// Per-command routing proofs for the last nine D-05 commands Plan 06 wires
// onto `ControlChannelDispatcher` (Task 1: frames.include/frames.exclude/
// review.approve). Task 2 extends this same suite for the project-lifecycle,
// settings, outputs, and diagnostics-export commands.
//
// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint: every
// test here drives a fake `EngineClientProtocol` actor. No scanner motion,
// no GUI, no real engine binary.

import Foundation
import Testing

@testable import ScanStudioKit

private enum ProjectRoutingStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private let projectRoutingDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

private let projectRoutingProjectDirectory = "/tmp/project-routing-test"

/// A minimal one-frame project fixture, modelled on
/// `ControlChannelMotionRoutingTests.swift`'s `motionRoutingProject(...)`:
/// no draft alignment or rotation, so `startMockScan()`'s
/// `persistFrameGeometryBeforeScan` step is a no-op and never issues an
/// unscripted `project.setFrameAlignment` request.
private func projectRoutingProject(frameIndex: Int = 1) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "project-routing-project",
        name: "Project routing test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/project-routing/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/project-routing/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/project-routing/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-09-07T00:00:00Z",
        frames: [ProjectFrame(index: frameIndex, excluded: false, receipts: [])]
    )
}

/// Fake engine modelled on `MotionRoutingEngineStub`
/// (`ControlChannelMotionRoutingTests.swift`): one generic gate mechanism
/// (`hold(_:)`/`release(_:)`/`waitForRequestCount(_:_:)`) shared by every
/// scripted method, rather than a dedicated `CheckedContinuation` property
/// pair per method.
private actor ProjectRoutingEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "project-routing-stub"

    /// Every request this stub has received since the last `clearLog()`, in
    /// order -- the proof that a routing arm invoked the one expected
    /// engine method, never inferred from a return value alone.
    private(set) var recordedMethods: [String] = []
    private(set) var requestCounts: [String: Int] = [:]
    /// The `excluded` argument of every `project.setFrameExcluded` request,
    /// in order -- the only way to tell `frames.include` and
    /// `frames.exclude` apart from this stub's point of view, since both
    /// call the identical `"project.setFrameExcluded"` engine method.
    private(set) var recordedFrameExclusionFlags: [Bool] = []

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
        recordedFrameExclusionFlags.removeAll()
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
            return try cast(ScannerListResult(devices: [projectRoutingDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: projectRoutingDevice,
                status: ScannerStatus(
                    connected: true, adapter: "SA-21", mediaLoaded: false, carrier: nil,
                    frameCount: nil, lamp: "unknown", transport: "idle", activeJobId: nil,
                    filmPresent: nil, motionArmed: true
                )
            ), as: Result.self)
        case "scanner.acquireThumbnails":
            return try cast(AcquireThumbnailsAck(accepted: true, frames: []), as: Result.self)
        case "project.open":
            let directory = (params as? ProjectOpenParams)?.directory ?? projectRoutingProjectDirectory
            return try cast(
                ProjectOpenResult(project: projectRoutingProject(), directory: directory),
                as: Result.self
            )
        case "project.setFrameExcluded":
            if let excludedParams = params as? SetFrameExcludedParams {
                recordedFrameExclusionFlags.append(excludedParams.excluded)
            }
            return try cast(SetFrameResult(project: projectRoutingProject()), as: Result.self)
        case "roll.approve":
            return try cast(EmptyResult(), as: Result.self)
        case "scan.start":
            return try cast(ScanStartResult(jobId: "project-routing-job"), as: Result.self)
        default:
            throw ProjectRoutingStubError.unexpectedMethod(method)
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
        guard let result = value as? Result else { throw ProjectRoutingStubError.unexpectedResultType }
        return result
    }
}

/// Bounded `Task.yield()` polling, per this codebase's established idiom,
/// for waiting out a fire-and-forget async call without a fixed sleep.
@MainActor
private func makeIdleModel(_ stub: ProjectRoutingEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

@MainActor
private func makeDispatcher() async -> (model: SessionModel, stub: ProjectRoutingEngineStub, dispatcher: ControlChannelDispatcher) {
    let stub = ProjectRoutingEngineStub()
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
        params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "project-routing-tests")
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

/// Connects, opens the fixture project, fakes a media-loaded status,
/// completes a preview whose one thumbnail carries `needsApproval`, and
/// selects frame 1 -- reaching `pendingManualReviewScan != nil` via
/// `startMockScan()`'s live manual-review branch, modelled on
/// `ControlChannelDispatcherTests.swift`'s `driveModelToPendingManualReview`.
/// The `connect(deviceId:)` call is required, not cosmetic (Plan 05's own
/// finding): `dispatchScanStart`'s `scanStartRequestIsCurrent` guard reads
/// `diagnosticUIConnected` (`device != nil && status?.connected == true`),
/// and only `connect(deviceId:)` sets `device` -- without it, a subsequent
/// `review.approve` success would call `roll.approve` but silently stop
/// short of `scan.start`.
@MainActor
private func driveToPendingManualReview(_ model: SessionModel) async -> Bool {
    await model.connect(deviceId: projectRoutingDevice.deviceId)
    await model.openProject(directory: projectRoutingProjectDirectory)
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

@Suite("Control channel project routing")
struct ControlChannelProjectRoutingTests {
    // MARK: frames.include / frames.exclude

    @Test("frames.exclude with a valid index reaches project.setFrameExcluded and refuses a concurrent second request")
    @MainActor
    func framesExcludeRoutesAndRefusesConcurrentSecondRequest() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.openProject(directory: projectRoutingProjectDirectory)
        await stub.clearLog()
        await stub.hold("project.setFrameExcluded")

        let first = Task { @MainActor in
            await dispatcher.handle(.framesExclude(id: 1, params: ControlFrameSelectionParams(frameIndex: 1)))
        }
        await stub.waitForRequestCount("project.setFrameExcluded", 1)
        #expect(model.mutatingOperationInFlight == "frames.exclude")
        #expect(await stub.recordedMethods == ["project.setFrameExcluded"])

        let busyResponse = await dispatcher.handle(.framesExclude(id: 2, params: ControlFrameSelectionParams(frameIndex: 1)))
        expectFailure(busyResponse, id: 2, code: .controllerBusy)
        if case .failure(_, let error) = busyResponse {
            // The wire-level code, spelled literally: CONTROLLER_BUSY.
            #expect(error.code == "CONTROLLER_BUSY")
            #expect(error.guidance == "frames.exclude")
        }
        #expect(await stub.requestCounts["project.setFrameExcluded"] == 1)

        await stub.release("project.setFrameExcluded")
        let firstResponse = await first.value
        guard case .success = firstResponse else {
            Issue.record("expected frames.exclude to succeed, got \(firstResponse)")
            return
        }
        #expect(model.mutatingOperationInFlight == nil)
        #expect(await stub.recordedFrameExclusionFlags == [true])
    }

    @Test("frames.include with the same index reaches project.setFrameExcluded with the inverse flag")
    @MainActor
    func framesIncludeReachesSameEngineMethodWithInverseFlag() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.openProject(directory: projectRoutingProjectDirectory)
        await stub.clearLog()

        let response = await dispatcher.handle(.framesInclude(id: 1, params: ControlFrameSelectionParams(frameIndex: 1)))
        guard case .success = response else {
            Issue.record("expected frames.include to succeed, got \(response)")
            return
        }
        #expect(await stub.recordedMethods == ["project.setFrameExcluded"])
        #expect(await stub.recordedFrameExclusionFlags == [false])
    }

    @Test("frames.exclude with no project open is refused with INVALID_PARAMS before any engine call")
    @MainActor
    func framesExcludeWithNoProjectOpenIsInvalid() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.framesExclude(id: 1, params: ControlFrameSelectionParams(frameIndex: 1)))
        expectFailure(response, id: 1, code: .invalidParams)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("frames.exclude with an index past the end of the project is refused with INVALID_PARAMS before any engine call")
    @MainActor
    func framesExcludeWithIndexPastTheEndIsInvalid() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.openProject(directory: projectRoutingProjectDirectory)
        await stub.clearLog()

        let response = await dispatcher.handle(.framesExclude(id: 2, params: ControlFrameSelectionParams(frameIndex: 5)))
        expectFailure(response, id: 2, code: .invalidParams)
        #expect(await stub.recordedMethods.isEmpty)
    }

    // MARK: review.approve

    @Test("review.approve without motionConfirmed is refused with CONFIRMATION_REQUIRED before any engine call")
    @MainActor
    func reviewApproveWithoutConfirmationIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.reviewApprove(id: 1, params: ControlReviewApproveParams(motionConfirmed: nil)))
        expectFailure(response, id: 1, code: .confirmationRequired)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("review.approve with confirmation but no pending manual review is refused with GATE_REFUSED naming manualReviewPending")
    @MainActor
    func reviewApproveWithNoPendingReviewIsRefused() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        let response = await dispatcher.handle(.reviewApprove(id: 2, params: ControlReviewApproveParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.gate == ControlGate.manualReviewPending.rawValue)
        #expect(await stub.recordedMethods.isEmpty)
    }

    @Test("review.approve with confirmation and a pending manual review reaches the scan-start path")
    @MainActor
    func reviewApproveWithPendingReviewReachesScanStartPath() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        #expect(await driveToPendingManualReview(model))
        await stub.clearLog()

        let response = await dispatcher.handle(.reviewApprove(id: 3, params: ControlReviewApproveParams(motionConfirmed: true)))
        guard case .success = response else {
            Issue.record("expected review.approve to succeed, got \(response)")
            return
        }
        #expect(await stub.recordedMethods == ["roll.approve", "scan.start"])
        #expect(model.pendingManualReviewScan == nil)
    }
}
