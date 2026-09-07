// Round-trip proofs of `ControlChannelClient` against a real
// `ControlChannelServer` over a real AF_UNIX socket (plan 02-04). No
// scanner motion, no GUI, no real engine binary -- a fake
// `EngineClientProtocol` actor and `sim-ls5000-0`-shaped fixtures only,
// mirroring plan 02-02's own `ControlChannelServerTests.swift` test-harness
// idioms (`shortSocketPath`, the fake-engine-stub/idle-model pair, and
// `MotionRoutingEngineStub`'s hold/release/waitForRequestCount trio) rather
// than inventing new ones.

import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

private enum ControlClientStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint --
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`), matching the real simulator this suite stands
/// in for.
private let controlClientDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

/// Fake engine mirroring `ControlChannelServerTests.ControlServerEngineStub`
/// (`scanner.list`/`scanner.rescan` auto-succeed), extended with
/// `ControlChannelMotionRoutingTests.MotionRoutingEngineStub`'s
/// hold/release/waitForRequestCount trio, trimmed to exactly what this
/// suite needs: holding `scanner.rescan` so a test can provoke one
/// deterministically in-flight, blocked engine request.
private actor ControlClientEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "control-client-stub"

    private(set) var requestCounts: [String: Int] = [:]
    private var heldMethods: Set<String> = []
    private var openGates: Set<String> = []
    private var gateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var countWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Gates every subsequent request for `method` until `release(_:)` is
    /// called. Only affects requests issued after this call, so
    /// `SessionModel.init`'s own incidental `scanner.list` discovery
    /// request is never accidentally gated.
    func hold(_ method: String) {
        heldMethods.insert(method)
    }

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
        _ method: String,
        params _: Params
    ) async throws -> Result {
        requestCounts[method, default: 0] += 1
        resumeSatisfiedCountWaiters(for: method)
        await awaitGate(method)
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [controlClientDevice]), as: Result.self)
        default:
            throw ControlClientStubError.unexpectedMethod(method)
        }
    }

    private func awaitGate(_ method: String) async {
        guard heldMethods.contains(method), !openGates.contains(method) else { return }
        await withCheckedContinuation { continuation in
            gateWaiters[method, default: []].append(continuation)
        }
    }

    private func resumeSatisfiedCountWaiters(for method: String) {
        let satisfied = countWaiters.filter { $0.method == method && (requestCounts[method] ?? 0) >= $0.count }
        countWaiters.removeAll { $0.method == method && (requestCounts[method] ?? 0) >= $0.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else {
            throw ControlClientStubError.unexpectedResultType
        }
        return result
    }
}

/// Resolves the one `scanner.list` request `SessionModel.init` always fires
/// (fire-and-forget), then waits for it to settle. Bounded `Task.yield()`
/// polling per this codebase's own established idiom for this exact
/// situation -- never a fixed sleep, since the request's own resolution is
/// already deterministic via `waitForRequestCount`.
@MainActor
private func makeIdleModel(_ stub: ControlClientEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    await stub.waitForRequestCount("scanner.list", 1)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

/// Builds a short `AF_UNIX` path under a per-test, per-label directory this
/// suite owns -- never the per-user temporary-directory API (its container
/// path is long enough to overflow `sun_path`), never anywhere under the
/// real home directory.
private func shortSocketPath(_ label: String) -> String {
    let directory = "/tmp/ss-cli-\(label)-\(UInt32.random(in: 0..<UInt32.max))"
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

/// A synthetic `scanner.status` event that flips `filmPresent` -- used to
/// provoke a `SessionModel` change deterministically, mirroring
/// `ControlChannelServerTests.filmPresenceChangedEvent`/
/// `ControlBusyIndicatorTests.makeEjectableModel`'s idiom of injecting a
/// raw event directly via `SessionModel.handle(event:)` rather than
/// routing it through the engine stub.
private func filmPresenceChangedEvent(filmPresent: Bool) -> EngineEvent {
    EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"""
            {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":\#(filmPresent),"motionArmed":true}}}
            """#.utf8
        )
    )
}

@Suite("Control channel client", .timeLimit(.minutes(1)))
struct ControlChannelClientTests {
    // MARK: Task 1 -- dial, hello, id-matched request/response

    @Test("open() against a path with no listener throws a socket error shaped like ENOENT/ECONNREFUSED")
    func openFailsAgainstMissingListener() async throws {
        let path = shortSocketPath("missing")
        do {
            _ = try await ControlChannelClient.open(path: path, clientName: "test")
            Issue.record("expected open() to throw against a path with no listener")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == ENOENT || error.errnoValue == ECONNREFUSED)
        }
    }

    @Test("open() against a live server completes hello and reports the app's schema version")
    func openCompletesHelloAndReportsSchemaVersion() async throws {
        let path = shortSocketPath("hello")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        let hello = await client.helloResult
        #expect(hello?.schemaVersion == ControlSchema.version)
        #expect(hello?.appName == "ScanStudio")

        await client.shutdown()
        await server.stop()
    }

    @Test("A status request's .result bytes decode into a ControlStatusResult")
    func statusRequestDecodesIntoControlStatusResult() async throws {
        let path = shortSocketPath("status")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        let response = try await client.requestWithoutParams(method: "status")
        guard case .result(let data) = response else {
            Issue.record("expected a .result response for status")
            return
        }
        let status = try JSONDecoder().decode(ControlStatusResult.self, from: data)
        #expect(status.hardwareMotionReadiness.isEmpty == false)

        await client.shutdown()
        await server.stop()
    }

    @Test("Two requests issued concurrently on one connection each resolve their own continuation, matched by id")
    func concurrentRequestsMatchByIdNotArrivalOrder() async throws {
        let path = shortSocketPath("concurrent")
        defer { removeSocketDirectory(for: path) }
        let stub = ControlClientEngineStub()
        let server = ControlChannelServer(sessionModel: await makeIdleModel(stub))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        await stub.hold("scanner.rescan")

        let rescanTask = Task { try await client.requestWithoutParams(method: "scanner.rescan") }
        await stub.waitForRequestCount("scanner.rescan", 1)

        // scanner.rescan is now blocked inside the (held) engine call. A
        // concurrent, non-mutating `status` request on the same connection
        // must still resolve -- proving the client matched it by id, not
        // by the order the two requests were sent in.
        let statusResponse = try await client.requestWithoutParams(method: "status")
        guard case .result = statusResponse else {
            Issue.record("expected status to resolve while scanner.rescan is still held")
            return
        }

        await stub.release("scanner.rescan")
        let rescanResponse = try await rescanTask.value
        guard case .result = rescanResponse else {
            Issue.record("expected the released scanner.rescan to eventually resolve too")
            return
        }

        await client.shutdown()
        await server.stop()
    }

    @Test("A command refused by a gate returns .failure whose code and recoverable equal what the dispatcher produced")
    func gateRefusedCommandReturnsTypedFailureValue() async throws {
        let path = shortSocketPath("refused")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        let response = try await client.request(
            method: "scan.start",
            params: ControlScanStartParams(motionConfirmed: false)
        )
        guard case .failure(let payload) = response else {
            Issue.record("expected scan.start without motionConfirmed to be refused")
            return
        }
        #expect(payload.code == ControlErrorCode.confirmationRequired.rawValue)
        #expect(payload.recoverable == false)

        await client.shutdown()
        await server.stop()
    }

    @Test("shutdown() while a request is in flight resumes that request with a connectionClosed error rather than hanging")
    func shutdownWhileRequestInFlightResumesWithConnectionClosedError() async throws {
        let path = shortSocketPath("shutdown")
        defer { removeSocketDirectory(for: path) }
        let stub = ControlClientEngineStub()
        let server = ControlChannelServer(sessionModel: await makeIdleModel(stub))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        await stub.hold("scanner.rescan")

        let rescanTask = Task { try await client.requestWithoutParams(method: "scanner.rescan") }
        await stub.waitForRequestCount("scanner.rescan", 1)

        await client.shutdown()

        do {
            _ = try await rescanTask.value
            Issue.record("expected the in-flight request to throw once shutdown() ran")
        } catch let error as ControlChannelClientError {
            #expect(error == .connectionClosed)
        }

        await server.stop()
    }

    // MARK: Task 2 -- client-side event routing over a live connection

    @Test("After events.subscribe, the first element of events() decodes as a control.snapshot carrying a ControlStatusResult")
    func firstEventElementIsControlSnapshot() async throws {
        let path = shortSocketPath("snapshot")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        guard case .result = try await client.requestWithoutParams(method: "events.subscribe") else {
            Issue.record("expected events.subscribe to succeed")
            return
        }

        var iterator = await client.events().makeAsyncIterator()
        guard let firstLine = await iterator.next() else {
            Issue.record("expected at least one event line")
            return
        }
        let envelope = try JSONDecoder().decode(EventEnvelope<ControlStatusResult>.self, from: firstLine)
        #expect(envelope.event == "control.snapshot")
        #expect(ControlChannelClient.decodeStatusSnapshot(fromEventLine: firstLine) != nil)

        await client.shutdown()
        await server.stop()
    }

    @Test("A SessionModel mutation after a subscription produces a control.changed element on the same connection")
    func subscriptionSeesControlChangedAfterMutation() async throws {
        let path = shortSocketPath("changed")
        defer { removeSocketDirectory(for: path) }
        let model = await makeIdleModel(ControlClientEngineStub())
        let server = ControlChannelServer(sessionModel: model)
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        _ = try await client.requestWithoutParams(method: "events.subscribe")

        var iterator = await client.events().makeAsyncIterator()
        _ = await iterator.next() // the initial control.snapshot

        await model.handle(event: filmPresenceChangedEvent(filmPresent: true))

        guard let changedLine = await iterator.next() else {
            Issue.record("expected a control.changed event line")
            return
        }
        let envelope = try JSONDecoder().decode(EventEnvelope<ControlStatusResult>.self, from: changedLine)
        #expect(envelope.event == "control.changed")

        await client.shutdown()
        await server.stop()
    }

    @Test("decodeStatusSnapshot returns nil for a control.dropped line")
    func decodeStatusSnapshotReturnsNilForDroppedNotice() {
        let line = Data(#"{"event":"control.dropped","payload":{"droppedEvents":3}}"#.utf8)
        #expect(ControlChannelClient.decodeStatusSnapshot(fromEventLine: line) == nil)
    }

    @Test("A connection that never subscribed produces no events, while a status request on it still round-trips")
    func nonSubscribedConnectionProducesNoEvents() async throws {
        let path = shortSocketPath("nosub")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        guard case .result = try await client.requestWithoutParams(method: "status") else {
            Issue.record("expected status to round-trip on a connection that never subscribed")
            return
        }

        // Nothing was ever subscribed on this connection, so nothing was
        // ever queued into its event stream; shutdown() finishes that
        // (empty) stream immediately rather than leaving the loop below
        // waiting forever for an element that will never arrive.
        await client.shutdown()
        var receivedCount = 0
        for await _ in await client.events() {
            receivedCount += 1
        }
        #expect(receivedCount == 0)

        await server.stop()
    }

    @Test("shutdown() finishes the stream so a for await loop over events() terminates")
    func shutdownTerminatesForAwaitLoopOverEvents() async throws {
        let path = shortSocketPath("terminate")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server.start(path: path)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        _ = try await client.requestWithoutParams(method: "events.subscribe")
        let stream = await client.events()

        // Consumes the initial control.snapshot, then loops awaiting a
        // second element that never arrives on its own -- the loop only
        // ends because `shutdown()` (below) finishes the stream, proving a
        // real `for await` consumer does not hang once the connection
        // closes.
        let drain = Task { () -> Int in
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            var extraElementCount = 0
            while await iterator.next() != nil {
                extraElementCount += 1
            }
            return extraElementCount
        }
        await client.shutdown()
        let extraElementsAfterSnapshot = await drain.value
        #expect(extraElementsAfterSnapshot == 0)

        await server.stop()
    }

    // MARK: Task 3 -- the non-fatal property `AppDelegate` relies on

    @Test("A second start() at a live path throws while the first server keeps serving a real client")
    func secondStartAtLivePathThrowsWhileFirstServerKeepsServing() async throws {
        let path = shortSocketPath("live-owner")
        defer { removeSocketDirectory(for: path) }

        // The exact condition `AppDelegate.init()`'s fire-and-forget start
        // swallows (D-05/T-02-17), exercised at the layer where it is
        // testable: a second server started at a path the first already
        // owns must throw, and the first server must keep serving real
        // clients regardless.
        let server1 = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        try await server1.start(path: path)

        let server2 = ControlChannelServer(sessionModel: await makeIdleModel(ControlClientEngineStub()))
        do {
            try await server2.start(path: path)
            Issue.record("expected the second start() to throw while the first is live")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == EADDRINUSE)
        }

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        guard case .result = try await client.requestWithoutParams(method: "status") else {
            Issue.record("expected the first server to still answer status after the second server's failed start")
            return
        }

        await client.shutdown()
        await server1.stop()
    }
}
