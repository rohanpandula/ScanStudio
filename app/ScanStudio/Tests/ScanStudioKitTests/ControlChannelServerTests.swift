import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

private enum ControlServerStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint --
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`), matching the real simulator this suite stands
/// in for.
private let controlServerDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

/// Fake engine modelled on `ControlDispatcherEngineStub`
/// (`ControlChannelDispatcherTests.swift`) and `BusyIndicatorEngineStub`
/// (`ControlBusyIndicatorTests.swift`), trimmed to what this suite needs:
/// `scanner.list`/`scanner.rescan` auto-succeed synchronously (covers
/// `SessionModel.init`'s own incidental discovery call). Tests that need to
/// provoke a `SessionModel` state change drive it by injecting a synthetic
/// event directly (the `ControlBusyIndicatorTests.makeEjectableModel`
/// idiom), so no other method needs scripting here.
private actor ControlServerEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "control-server-stub"

    private(set) var listRequestCount = 0
    private var listWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
    ) async throws -> Result {
        switch method {
        case "scanner.list", "scanner.rescan":
            listRequestCount += 1
            resumeSatisfiedListWaiters()
            return try cast(ScannerListResult(devices: [controlServerDevice]), as: Result.self)
        default:
            throw ControlServerStubError.unexpectedMethod(method)
        }
    }

    func waitForListRequestCount(_ count: Int) async {
        guard listRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            listWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedListWaiters() {
        let satisfied = listWaiters.filter { listRequestCount >= $0.count }
        listWaiters.removeAll { listRequestCount >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else {
            throw ControlServerStubError.unexpectedResultType
        }
        return result
    }
}

/// Resolves the one `scanner.list` request `SessionModel.init` always fires
/// (fire-and-forget), then waits for it to settle. Bounded `Task.yield()`
/// polling per this codebase's own established idiom for this exact
/// situation (`ControlBusyIndicatorTests.makeIdleModel`) -- never a fixed
/// sleep, since the request's own resolution is already deterministic via
/// `waitForListRequestCount`.
@MainActor
private func makeIdleModel(_ stub: ControlServerEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    await stub.waitForListRequestCount(1)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

/// Builds a short `AF_UNIX` path under a per-test, per-label directory this
/// suite owns -- never the per-user temporary-directory API (its container
/// path is long enough to overflow `sun_path`), never anywhere under the
/// real home directory. `ControlChannelServer.start(path:)`'s own
/// `prepareDirectory` step creates and `chmod`s the directory; this helper
/// only computes the path and asserts its length up front.
private func shortSocketPath(_ label: String) -> String {
    let directory = "/tmp/ss-ctl-\(label)-\(UInt32.random(in: 0..<UInt32.max))"
    let path = directory + "/s.sock"
    precondition(path.utf8.count < 104, "test socket path must be < 104 bytes, got \(path.utf8.count): \(path)")
    return path
}

/// Removes the per-test directory `shortSocketPath` implies (socket file
/// and directory both), so no artifact remains under `/tmp` after the
/// suite runs.
private func removeSocketDirectory(for path: String) {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: directory)
}

@Suite("Control channel server", .timeLimit(.minutes(1)))
struct ControlChannelServerTests {
    // MARK: Task 1 -- path policy, dial/probe, bind/stale-reclaim lifecycle

    @Test("validate() enforces the 104-byte sun_path bound at the boundary")
    func validateEnforcesSunPathBound() throws {
        let prefix = "/tmp/"
        let exactly104 = prefix + String(repeating: "a", count: 104 - prefix.utf8.count)
        #expect(exactly104.utf8.count == 104)
        do {
            try ControlSocketPath.validate(exactly104)
            Issue.record("expected a 104-byte path to be refused")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == ENAMETOOLONG)
        }

        let exactly103 = prefix + String(repeating: "a", count: 103 - prefix.utf8.count)
        #expect(exactly103.utf8.count == 103)
        try ControlSocketPath.validate(exactly103)
    }

    @Test("probeIsLive is false for a path that has never existed")
    func probeIsLiveFalseForMissingPath() {
        let path = shortSocketPath("missing")
        #expect(ControlSocketDialer.probeIsLive(path: path) == false)
    }

    @MainActor
    @Test("A live listener is detected by probeIsLive, and a second start() at the same path refuses")
    func liveListenerRefusesSecondStart() async throws {
        let path = shortSocketPath("live")
        defer { removeSocketDirectory(for: path) }

        let server1 = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server1.start(path: path)

        #expect(ControlSocketDialer.probeIsLive(path: path))

        let server2 = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        do {
            try await server2.start(path: path)
            Issue.record("expected the second start() to throw while the first is live")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == EADDRINUSE)
        }

        await server1.stop()
    }

    @MainActor
    @Test("simulateHostCrash() leaves the file on disk but probeIsLive sees it as dead, and a successor reclaims it")
    func crashedSocketIsReclaimed() async throws {
        let path = shortSocketPath("crash")
        defer { removeSocketDirectory(for: path) }

        let server1 = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server1.start(path: path)

        await server1.simulateHostCrash()

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(ControlSocketDialer.probeIsLive(path: path) == false)

        let server2 = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server2.start(path: path)
        #expect(await server2.isListening)

        await server2.stop()
    }

    @MainActor
    @Test("start() sets the socket file to 0600 and its directory to 0700")
    func startSetsPermissions() async throws {
        let path = shortSocketPath("modes")
        defer { removeSocketDirectory(for: path) }

        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let socketPermissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(socketPermissions == 0o600)

        let directory = (path as NSString).deletingLastPathComponent
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        #expect(directoryPermissions == 0o700)

        await server.stop()
    }

    @MainActor
    @Test("stop() unlinks the path it bound")
    func stopRemovesPath() async throws {
        let path = shortSocketPath("stop")
        defer { removeSocketDirectory(for: path) }

        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)
        #expect(FileManager.default.fileExists(atPath: path))

        await server.stop()
        #expect(FileManager.default.fileExists(atPath: path) == false)
        #expect(await server.isListening == false)
    }
}
