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
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "motion-routing-stub"

    /// Every request this stub has received since the last `clearLog()`, in
    /// order -- the CTRL-03 proof that a routing arm invoked the one
    /// expected engine method reads this list, never a return value or a
    /// state side effect.
    private(set) var recordedMethods: [String] = []
    private(set) var requestCounts: [String: Int] = [:]

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
            return try cast(ScannerListResult(devices: [motionRoutingDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: motionRoutingDevice,
                status: ScannerStatus(
                    connected: true, adapter: "SA-21", mediaLoaded: false, carrier: nil,
                    frameCount: nil, lamp: "unknown", transport: "idle", activeJobId: nil,
                    filmPresent: nil, motionArmed: true
                )
            ), as: Result.self)
        case "scanner.disconnect":
            return try cast(EmptyResult(), as: Result.self)
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

@Suite("Control channel motion routing")
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
        #expect(scannerListResult.devices.map(\.deviceId) == [motionRoutingDevice.deviceId])
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
        #expect(scannerListResult.devices.map(\.deviceId) == [motionRoutingDevice.deviceId])
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
}
