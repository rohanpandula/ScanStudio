import Foundation
import Testing

@testable import ScanStudioKit

private enum BusyIndicatorStubError: Error {
    case forcedFailure
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint.
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`) with no separate motion-arming setup, exactly
/// like the real simulator this suite stands in for.
private let busyIndicatorDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

/// Fake engine modelled directly on `ConnectionLifecycleEngineStub`
/// (`DeviceConnectionLifecycleTests.swift`) — per-method response scripting
/// via `CheckedContinuation` so a test can hold a request in flight
/// deterministically, never by a fixed sleep.
private actor BusyIndicatorEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "busy-indicator-stub"

    private var listRequestCount = 0
    private var listContinuation: CheckedContinuation<ScannerListResult, Error>?
    private var listWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private var connectRequestCount = 0
    private var connectContinuation: CheckedContinuation<ConnectResult, Error>?
    private var connectWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private var ejectRequestCount = 0
    private var ejectContinuation: CheckedContinuation<EmptyResult, Error>?
    private var ejectWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
    ) async throws -> Result {
        switch method {
        case "scanner.list", "scanner.rescan":
            listRequestCount += 1
            resumeSatisfiedListWaiters()
            let result = try await withCheckedThrowingContinuation { continuation in
                listContinuation = continuation
            }
            return try cast(result, as: Result.self)
        case "scanner.connect":
            connectRequestCount += 1
            resumeSatisfiedConnectWaiters()
            let result = try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
            }
            return try cast(result, as: Result.self)
        case "scanner.eject":
            ejectRequestCount += 1
            resumeSatisfiedEjectWaiters()
            let result = try await withCheckedThrowingContinuation { continuation in
                ejectContinuation = continuation
            }
            return try cast(result, as: Result.self)
        default:
            throw BusyIndicatorStubError.unexpectedMethod(method)
        }
    }

    func waitForListRequestCount(_ count: Int) async {
        guard listRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            listWaiters.append((count, continuation))
        }
    }

    /// Defaults to an empty device list so a freshly constructed model's
    /// `availableDevices` starts empty, matching the one real nesting case
    /// (`connect()`'s internal `await refreshAvailableDevices()`) a test
    /// needs to exercise.
    func succeedList(devices: [DeviceInfo] = []) {
        listContinuation?.resume(returning: ScannerListResult(devices: devices))
        listContinuation = nil
    }

    func waitForConnectRequestCount(_ count: Int) async {
        guard connectRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            connectWaiters.append((count, continuation))
        }
    }

    func succeedConnect() {
        connectContinuation?.resume(returning: ConnectResult(
            device: busyIndicatorDevice,
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

    func numberOfConnectRequests() -> Int {
        connectRequestCount
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

    func failEject() {
        ejectContinuation?.resume(throwing: BusyIndicatorStubError.forcedFailure)
        ejectContinuation = nil
    }

    private func resumeSatisfiedListWaiters() {
        let satisfied = listWaiters.filter { listRequestCount >= $0.count }
        listWaiters.removeAll { listRequestCount >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func resumeSatisfiedConnectWaiters() {
        let satisfied = connectWaiters.filter { connectRequestCount >= $0.count }
        connectWaiters.removeAll { connectRequestCount >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func resumeSatisfiedEjectWaiters() {
        let satisfied = ejectWaiters.filter { ejectRequestCount >= $0.count }
        ejectWaiters.removeAll { ejectRequestCount >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func cast<Result: Decodable & Sendable>(
        _ value: some Sendable,
        as _: Result.Type
    ) throws -> Result {
        guard let result = value as? Result else {
            throw BusyIndicatorStubError.unexpectedResultType
        }
        return result
    }
}

/// Resolves the one `scanner.list` request `SessionModel.init` always fires
/// (fire-and-forget), then waits for it to settle. Bounded `Task.yield()`
/// polling per this codebase's own established idiom for this exact
/// situation (e.g. `SessionEventPolicyTests.swift`'s
/// `for _ in 0..<30 where ... { await Task.yield() }`) — never a fixed
/// sleep, since the request's own resolution is already deterministic via
/// `waitForListRequestCount`/`succeedList` above.
@MainActor
private func makeIdleModel(
    _ stub: BusyIndicatorEngineStub,
    initialDevices: [DeviceInfo] = []
) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    await stub.waitForListRequestCount(1)
    await stub.succeedList(devices: initialDevices)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

@Suite("Control busy indicator")
struct ControlBusyIndicatorTests {
    @Test("Idle state has no mutating operation in flight once initial discovery settles")
    @MainActor
    func idleStateHasNoMutatingOperationInFlight() async {
        let stub = BusyIndicatorEngineStub()
        let model = await makeIdleModel(stub)
        #expect(model.mutatingOperationInFlight == nil)
    }

    @Test("The flag spans an eject and clears once the engine confirms it")
    @MainActor
    func flagSpansEjectAndClearsOnSuccess() async {
        let stub = BusyIndicatorEngineStub()
        let model = await makeIdleModel(stub)

        let operation = Task { @MainActor in
            await model.eject()
        }
        await stub.waitForEjectRequestCount(1)
        #expect(model.mutatingOperationInFlight == "scanner.eject")

        await stub.succeedEject()
        await operation.value
        #expect(model.mutatingOperationInFlight == nil)
    }

    @Test("The flag clears on the failure path too -- this is what defer buys over a hand-rolled clear")
    @MainActor
    func flagClearsOnEjectFailure() async {
        let stub = BusyIndicatorEngineStub()
        let model = await makeIdleModel(stub)

        let operation = Task { @MainActor in
            await model.eject()
        }
        await stub.waitForEjectRequestCount(1)
        #expect(model.mutatingOperationInFlight == "scanner.eject")

        await stub.failEject()
        await operation.value
        #expect(model.mutatingOperationInFlight == nil)
        #expect(model.lastErrorMessage != nil)
    }

    @Test("Nesting keeps the outer connect name visible through the nested refreshAvailableDevices await")
    @MainActor
    func nestingKeepsOuterNameVisible() async {
        let stub = BusyIndicatorEngineStub()
        let model = await makeIdleModel(stub)
        #expect(model.availableDevices.isEmpty)

        let operation = Task { @MainActor in
            await model.connect(deviceId: busyIndicatorDevice.deviceId)
        }
        // connect()'s own beginMutatingOperation("scanner.connect") runs
        // before its internal `await refreshAvailableDevices()`
        // (SessionModel.swift, connect(), the `if availableDevices.isEmpty`
        // branch): availableDevices is empty, so that branch is taken. The
        // second scanner.list request overall (the first was init's own
        // discovery, already resolved by makeIdleModel) is that nested call.
        await stub.waitForListRequestCount(2)
        #expect(model.mutatingOperationInFlight == "scanner.connect")

        await stub.succeedList(devices: [busyIndicatorDevice])
        await stub.waitForConnectRequestCount(1)
        await stub.succeedConnect()
        await operation.value

        #expect(model.mutatingOperationInFlight == nil)
        #expect(model.device?.deviceId == busyIndicatorDevice.deviceId)
    }

    @Test("Existing single-flight connect behaviour is unchanged by the new flag")
    @MainActor
    func duplicateConnectStillSerialized() async {
        let stub = BusyIndicatorEngineStub()
        let model = await makeIdleModel(stub, initialDevices: [busyIndicatorDevice])

        let first = Task { @MainActor in
            await model.connect(deviceId: busyIndicatorDevice.deviceId)
        }
        await stub.waitForConnectRequestCount(1)
        let duplicate = Task { @MainActor in
            await model.connect(deviceId: busyIndicatorDevice.deviceId)
        }
        await duplicate.value

        #expect(await stub.numberOfConnectRequests() == 1)
        #expect(model.isConnectingDevice)
        #expect(model.mutatingOperationInFlight == "scanner.connect")

        await stub.succeedConnect()
        await first.value
        #expect(model.isConnectingDevice == false)
        #expect(model.mutatingOperationInFlight == nil)
    }

    // RESEARCH Pitfall 2: `pendingScanStart`, `pendingAttendedScanApproval`,
    // and `pendingManualReviewApproval` are declared `private` inside
    // SessionModel.swift and stay that way. Swift's `private` restricts
    // them to SessionModel's own type declaration, so this file -- a
    // different file, even under `@testable import` into the same
    // ScanStudioKit target -- cannot reference `model.pendingScanStart` or
    // the other two; doing so would be a compile error, not something a
    // runtime assertion could demonstrate. `nestingKeepsOuterNameVisible`
    // above is this suite's actual coverage of the reentrancy case those
    // flags used to leave unobservable outside SessionModel.swift: it
    // proves `mutatingOperationInFlight` reports the right in-flight
    // operation across the one call path (`connect()` -> nested
    // `refreshAvailableDevices()`) that a dispatcher in a different file
    // could never see before this plan.
}
