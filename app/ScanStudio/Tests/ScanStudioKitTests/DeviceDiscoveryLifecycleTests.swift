import Foundation
import Testing

@testable import ScanStudioKit

private enum DiscoveryStubError: Error {
    case forcedFailure
    case unexpectedMethod(String)
    case unexpectedResultType
}

private actor DiscoveryEngineStub: EngineClientProtocol {
    enum Mode: Sendable {
        case gatedSuccess
        case failure
    }

    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "discovery-stub"

    private let mode: Mode
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(mode: Mode) {
        self.mode = mode
        self.events = AsyncStream { _ in }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        guard method == "scanner.list" else {
            throw DiscoveryStubError.unexpectedMethod(method)
        }
        guard mode == .gatedSuccess else {
            throw DiscoveryStubError.forcedFailure
        }

        await withCheckedContinuation { continuation in
            parked.append(continuation)
            resumeSatisfiedWaiters()
        }

        guard let result = ScannerListResult(devices: []) as? Result else {
            throw DiscoveryStubError.unexpectedResultType
        }
        return result
    }

    func waitUntilParkedCount(_ count: Int) async {
        guard parked.count < count else { return }
        await withCheckedContinuation { continuation in
            parkedWaiters.append((count, continuation))
        }
    }

    func releaseOne() {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume()
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = parkedWaiters.filter { parked.count >= $0.count }
        parkedWaiters.removeAll { parked.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private func waitForDiscoveryState(
    _ expected: Bool,
    model: SessionModel
) async -> Bool {
    for _ in 0..<200 {
        if model.isDiscoveringDevices == expected {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return model.isDiscoveringDevices == expected
}

@Suite("Device discovery lifecycle")
struct DeviceDiscoveryLifecycleTests {
    @Test("Overlapping refreshes stay discovering until both finish")
    @MainActor
    func overlappingRefreshes() async {
        let stub = DiscoveryEngineStub(mode: .gatedSuccess)
        let model = SessionModel(engineClient: stub)

        await stub.waitUntilParkedCount(1)
        await stub.releaseOne()
        #expect(await waitForDiscoveryState(false, model: model))

        let first = Task { @MainActor in
            await model.refreshAvailableDevices()
        }
        await stub.waitUntilParkedCount(1)

        let second = Task { @MainActor in
            await model.refreshAvailableDevices()
        }
        await stub.waitUntilParkedCount(2)
        #expect(model.isDiscoveringDevices)

        await stub.releaseOne()
        await first.value
        #expect(model.isDiscoveringDevices)

        await stub.releaseOne()
        await second.value
        #expect(model.isDiscoveringDevices == false)
    }

    @Test("A failed refresh always clears the discovering state")
    @MainActor
    func failedRefreshResetsState() async {
        let stub = DiscoveryEngineStub(mode: .failure)
        let model = SessionModel(engineClient: stub)

        #expect(await waitForDiscoveryState(false, model: model))
        #expect(model.lastErrorMessage != nil)

        await model.refreshAvailableDevices()
        #expect(model.isDiscoveringDevices == false)
        #expect(model.lastErrorMessage != nil)
    }
}
