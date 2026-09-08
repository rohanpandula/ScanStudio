import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

private enum ControlServerStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// CF-02: an `NSLock`-guarded error collector for `DispatchQueue
/// .concurrentPerform`'s multiple simultaneous worker closures --
/// `E2ELineBuffer` (`ControlSocketEndToEndTests.swift`) is this
/// repository's existing precedent for this exact shape (a small
/// `@unchecked Sendable` type instead of a captured `var` mutated directly
/// from concurrently-executing closures).
private final class ControlServerErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func snapshot() -> [Error] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
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

/// A real client for these tests: dials the server via
/// `ControlSocketDialer.dial`, writes lines, and blocks (up to a receive
/// timeout) on a raw `read()` for the next complete line -- never
/// sleep-polls. Framing reuses the same `LineFramer` the server itself
/// uses, so a read that returns more than one line's worth (or a partial
/// line) stays correct across calls. Not an actor: used sequentially,
/// within one test's own body, never shared across a concurrency boundary.
///
/// Uses raw POSIX `read`/`write` on the dialed descriptor rather than
/// `FileHandle`: `FileHandle.availableData` blocks with no timeout of its
/// own, and (separately, discovered while building this suite) raises an
/// uncatchable `NSFileHandleOperationException` on certain I/O errors --
/// wrong properties for a test harness where a mistaken assumption about
/// how much data was actually sent must fail fast, not hang or crash the
/// whole run. `SO_RCVTIMEO` turns "no more data is ever coming" into a
/// bounded, ordinary `nil` return.
///
/// The actual blocking syscalls run on a dedicated background queue,
/// bridged back with a continuation -- the same shape this suite's own
/// `ControlChannelServer.write(fd:bytes:)` uses. A blocking call made
/// directly inside an `async` test function body would otherwise occupy
/// one of Swift Concurrency's own cooperative-pool threads (sized to this
/// machine's 10 cores) for the length of the block; with many tests in
/// this suite running concurrently, that starved the pool that the
/// server's own actor/`MainActor` hops also need, and every connection in
/// every *other* concurrently-running test stopped making progress until
/// the blocked read finally gave up (discovered as suite-wide failures
/// that never reproduced with a single test run in isolation).
private final class TestControlClient {
    private let fd: Int32
    private var framer = LineFramer()
    private var buffered: [String] = []
    private let ioQueue = DispatchQueue(label: "com.scanstudio.controlchannel.test-client")

    /// `tinyReceiveBuffer` shrinks this client's own `SO_RCVBUF` right
    /// after connecting, before anything is sent -- the only lever a test
    /// has (from the client side alone) to force the *server's* write to
    /// genuinely block after a small, predictable amount of unread data,
    /// rather than depending on this machine's default kernel socket
    /// buffer size. `receiveTimeoutSeconds` is a last-resort backstop
    /// against a wrong test assumption hanging the whole suite, not a
    /// normal per-operation budget: it defaults to just under the suite's
    /// own `.timeLimit(.minutes(1))`, since a full `swift test` run's
    /// worth of concurrently-executing tests can genuinely push an
    /// individual round trip past a few seconds under real scheduling
    /// contention, and a too-short default here would fail otherwise-
    /// correct tests, not just truly hung ones.
    init(path: String, tinyReceiveBuffer: Bool = false, receiveTimeoutSeconds: Int = 55) throws {
        fd = try ControlSocketDialer.dial(path: path)
        if tinyReceiveBuffer {
            var size: Int32 = 4096
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ line: String) async throws {
        var mutableData = Data(line.utf8)
        mutableData.append(0x0A)
        try await sendRawChunk(mutableData)
    }

    /// CF-01: writes exactly `data`'s bytes as their own `write(2)` call(s)
    /// -- no newline appended -- so a burst test can split many request
    /// lines into arbitrary, sub-line byte boundaries and issue each piece
    /// as its own rapid, separate syscall, the shape that reproduces
    /// out-of-order chunk feeding on the server side.
    func sendRawChunk(_ data: Data) async throws {
        let fd = self.fd
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                var offset = 0
                var thrown: Error?
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    while offset < raw.count {
                        let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                        if written > 0 {
                            offset += written
                            continue
                        }
                        if written < 0, errno == EINTR { continue }
                        thrown = ControlSocketError(context: "TestControlClient.send write()", errnoValue: errno)
                        return
                    }
                }
                if let thrown {
                    continuation.resume(throwing: thrown)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// CF-01: sends an EOF to the peer (`SHUT_WR`) while keeping this
    /// client's own read side open, so a test can still read every
    /// already-queued response back before the connection fully closes --
    /// `close()` below tears down both directions at once and would
    /// discard exactly the bytes such a test needs to observe.
    func shutdownWriteSide() {
        _ = Darwin.shutdown(fd, SHUT_WR)
    }

    /// Blocks (up to the receive timeout) until a full line is available;
    /// returns `nil` once the peer has closed (an EOF read), the receive
    /// timeout elapses with no more data, or any other read error -- the
    /// "next read returns nothing" proof for a connection Task 2 closed,
    /// and a bounded fallback for a test whose assumption about pending
    /// data turns out wrong.
    func readLine() async -> String? {
        while buffered.isEmpty {
            let fd = self.fd
            let bytes: [UInt8]? = await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
                ioQueue.async {
                    var chunk = [UInt8](repeating: 0, count: 1 << 16)
                    let bytesRead = chunk.withUnsafeMutableBytes { raw in
                        Darwin.read(fd, raw.baseAddress, raw.count)
                    }
                    continuation.resume(returning: bytesRead > 0 ? Array(chunk[0..<bytesRead]) : nil)
                }
            }
            guard let bytes else { return nil }
            buffered.append(contentsOf: framer.feed(Data(bytes)))
        }
        return buffered.removeFirst()
    }

    func close() {
        Darwin.close(fd)
    }
}

/// Sniffs just the top-level `id` field, decodable against either a
/// success or an error response envelope.
private struct ControlServerResponseIdSniff: Decodable { let id: UInt64 }

/// Sniffs just the top-level `event` field of an encoded
/// `ControlEventEnvelope` line (`control.snapshot`/`control.changed`/
/// `control.dropped`).
private struct ControlServerEventNameSniff: Decodable { let event: String }

private struct ControlServerDroppedNoticeSniff: Decodable {
    struct Payload: Decodable { let droppedEvents: Int }
    let event: String
    let payload: Payload
}

/// A synthetic `scanner.status` event that flips `filmPresent` -- used to
/// provoke a `SessionModel` change deterministically, mirroring
/// `ControlBusyIndicatorTests.makeEjectableModel`'s idiom of injecting a
/// raw event directly rather than routing it through the engine stub.
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

/// Sends `hello` then `events.subscribe` on `client`, discarding the hello
/// response, the subscribe response, and the initial `control.snapshot` --
/// the common setup for a connection that is already, actively reading its
/// event stream.
private func helloAndSubscribe(_ client: TestControlClient) async throws {
    try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
    _ = await client.readLine()
    try await client.send(#"{"id":2,"method":"events.subscribe","params":{}}"#)
    _ = await client.readLine() // subscribe response
    _ = await client.readLine() // control.snapshot
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

    @Test("validate() refuses a path that is itself a symlink (T-02-06)")
    func validateRefusesSymlinkPath() throws {
        let path = shortSocketPath("symlink")
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { removeSocketDirectory(for: path) }

        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp/ss-ctl-symlink-target-does-not-exist")

        do {
            try ControlSocketPath.validate(path)
            Issue.record("expected validate() to refuse a path that is itself a symlink")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == ELOOP)
        }
    }

    @Test("probeIsLive is false for a path that has never existed")
    func probeIsLiveFalseForMissingPath() {
        let path = shortSocketPath("missing")
        #expect(ControlSocketDialer.probeIsLive(path: path) == false)
    }

    @Test("the bind lock refuses a symlink")
    func bindLockRefusesSymlink() throws {
        let path = shortSocketPath("lock-symlink")
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { removeSocketDirectory(for: path) }
        try FileManager.default.createSymbolicLink(atPath: path + ".lock", withDestinationPath: path + ".target")

        do {
            _ = try ControlSocketPath.claim(path)
            Issue.record("expected a symlinked bind lock to be refused")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == ELOOP)
        }
        #expect(FileManager.default.fileExists(atPath: path + ".target") == false)
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
    @Test("WR-02: two servers starting concurrently at the same path -- exactly one binds, the other is refused EADDRINUSE, never both")
    func concurrentStartersAtSamePathOnlyOneWins() async throws {
        let path = shortSocketPath("concurrent-start")
        defer { removeSocketDirectory(for: path) }
        // Pre-created so both starters' own `prepareDirectory` calls find it
        // already present and skip `mkdir()` entirely -- `prepareDirectory`
        // has its own separate, pre-existing check-then-`mkdir()` TOCTOU
        // (unrelated to WR-02, out of this fix's scope) that two genuinely
        // concurrent first-ever starts at a brand-new directory can hit,
        // observed directly while developing this test (`mkdir` racing to
        // `EEXIST`). Sidestepped here so this test stays focused on WR-02's
        // own bind-time lock, not a different, already-there directory race.
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let serverA = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        let serverB = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))

        // Fired as two independent, concurrently-running Tasks (not two
        // sequential `await`s) -- `serverA`/`serverB` are two distinct
        // actor instances, so nothing about Swift's own actor isolation
        // serializes them relative to each other; only WR-02's own
        // bind-time `flock` does. Whichever of the two wins that lock
        // proceeds through probe -> unlink -> bind exactly as before; the
        // loser is refused immediately (still holding the lock) or, if it
        // only reaches the lock after the winner has already finished
        // binding and released it, is refused by the pre-existing
        // live-probe check instead -- either path yields the same
        // EADDRINUSE shape, so the outcome is deterministic regardless of
        // exactly how the two Tasks happen to interleave.
        func attemptStart(_ server: ControlChannelServer) async -> Result<Void, Error> {
            do {
                try await server.start(path: path)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        async let outcomeA = attemptStart(serverA)
        async let outcomeB = attemptStart(serverB)
        let outcomes = await [outcomeA, outcomeB]

        let successCount = outcomes.filter { if case .success = $0 { return true } else { return false } }.count
        #expect(successCount == 1, "exactly one of two concurrent starters at the same path must bind, never zero or both")

        let refusals = outcomes.compactMap { outcome -> ControlSocketError? in
            guard case .failure(let error) = outcome else { return nil }
            return error as? ControlSocketError
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.errnoValue == EADDRINUSE)

        await serverA.stop()
        await serverB.stop()
    }

    @Test("CF-02: two first-ever prepareDirectory calls at a brand-new path both succeed, mkdir()'s EEXIST is success")
    func concurrentPrepareDirectoryAtABrandNewPathAllSucceed() throws {
        // Repeated against a fresh path each time -- CF-02 was a narrow
        // check-then-`mkdir()` TOCTOU window, and a single lucky pass
        // proves little about a race this tight.
        for _ in 0..<20 {
            let path = shortSocketPath("cf02-\(UInt32.random(in: 0..<UInt32.max))")
            defer { removeSocketDirectory(for: path) }
            let directory = (path as NSString).deletingLastPathComponent

            let errors = ControlServerErrorCollector()
            // Eight concurrent workers race `prepareDirectory(for:)` at a
            // path that has never existed -- exactly the CF-02 window two
            // first-ever `scanstudio-cli host` starters can hit. The old
            // check-then-`mkdir()` let one loser observe `fileExists ==
            // false`, lose the race to actually create it, and throw on
            // `EEXIST`; `mkdir() == 0 || errno == EEXIST` being success
            // closes it, so every worker here must return with no error.
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    try ControlSocketPath.prepareDirectory(for: path)
                } catch {
                    errors.append(error)
                }
            }
            let collectedErrors = errors.snapshot()
            #expect(collectedErrors.isEmpty, "expected every concurrent prepareDirectory call to succeed, got: \(collectedErrors)")

            var info = stat()
            #expect(stat(directory, &info) == 0, "the directory must exist after every racer returns")
            #expect((info.st_mode & 0o777) == 0o700, "the unconditional chmod must still land regardless of which racer created the directory")
        }
    }

    @Test("WR-03: a connection accepted while stop() runs concurrently is closed too, never left open past stop()'s return")
    func adoptAfterStopClosesTheLateConnection() async throws {
        let path = shortSocketPath("adopt-after-stop")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        // `stop()`'s own body has no internal `await` (every step is a
        // synchronous dictionary/syscall operation), so once scheduled it
        // always runs to completion in one atomic step on the server's
        // actor -- the only way `adopt(_:)` can still be mid-flight when
        // `stop()` drains the actor is via `adopt(_:)`'s own
        // `await MainActor.run { ControlChannelDispatcher(...) }` hop.
        // A bounded, non-suspending busy-wait scheduled on the MainActor
        // just before triggering the connection below reliably holds that
        // hop pending for the whole window, constructing WR-03's race
        // directly rather than depending on incidental scheduling luck to
        // hit a window otherwise measured in microseconds.
        let occupancyMilliseconds = 200.0
        let occupier = Task { @MainActor in
            let deadline = Date().addingTimeInterval(occupancyMilliseconds / 1000)
            while Date() < deadline {}
        }
        await Task.yield() // let the occupier actually start and claim the MainActor

        let client = try TestControlClient(path: path)
        // Bounds only how long this test waits before calling stop(), so
        // the accept handler's own dedicated GCD queue has time to fire
        // and spawn adopt(_:)'s Task first -- the pass/fail outcome below
        // is decided by the connection's actual usability afterward, not
        // by this sleep's exact duration.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await server.stop()

        _ = await occupier.value // let adopt()'s pending MainActor hop finally resolve

        // Whether adopt() registered the connection then unwound it
        // (WR-03's own fix, exercised if the connection was accepted
        // before stop() ran) or the connection was never accepted in time
        // at all, it must not be usable afterward either way.
        try? await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        #expect(await client.readLine() == nil, "a connection accepted while stop() ran concurrently must not remain open")

        client.close()
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
    @Test("stop leaves a replacement at the old socket path")
    func stopPreservesReplacementPath() async throws {
        let path = shortSocketPath("replacement")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        #expect(unlink(path) == 0)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: URL(fileURLWithPath: path))
        await server.stop()

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == replacement)
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

    // MARK: Task 2 -- accept loop, per-connection dispatcher, line handling
    //
    // None of these tests are `@MainActor`: `adopt(_:)` hops to `MainActor`
    // to construct each connection's dispatcher, and these tests block on
    // real socket reads. Running the blocking read itself on `MainActor`
    // would starve that same hop and deadlock -- `makeIdleModel`'s own
    // `@MainActor` is still reachable via a plain `await` from here.

    @Test("A hello line gets back a response whose id matches and whose result carries the schema version")
    func helloRoundTrip() async throws {
        let path = shortSocketPath("hello")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        guard let line = await client.readLine() else {
            Issue.record("expected a hello response line")
            return
        }
        struct HelloSuccessEnvelope: Decodable { let id: UInt64; let result: ControlHelloResult }
        guard let envelope = try? JSONDecoder().decode(HelloSuccessEnvelope.self, from: Data(line.utf8)) else {
            Issue.record("expected a decodable hello success envelope, got: \(line)")
            return
        }
        #expect(envelope.id == 1)
        #expect(envelope.result.schemaVersion == ControlSchema.version)
        #expect(envelope.result.host == .gui)
        #expect(envelope.result.hostPid == ProcessInfo.processInfo.processIdentifier)

        client.close()
        await server.stop()
    }

    @Test("A headless server identifies itself in hello")
    func headlessHelloReportsHostKindAndPid() async throws {
        let path = shortSocketPath("hello-headless")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(
            sessionModel: await makeIdleModel(ControlServerEngineStub()),
            hostKind: .headless
        )
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        guard let line = await client.readLine() else {
            Issue.record("expected a hello response line")
            return
        }
        struct HelloSuccessEnvelope: Decodable { let id: UInt64; let result: ControlHelloResult }
        guard let envelope = try? JSONDecoder().decode(HelloSuccessEnvelope.self, from: Data(line.utf8)) else {
            Issue.record("expected a decodable hello success envelope, got: \(line)")
            return
        }
        #expect(envelope.result.host == .headless)
        #expect(envelope.result.hostPid == ProcessInfo.processInfo.processIdentifier)

        client.close()
        await server.stop()
    }

    @Test("A pipelined hello is processed before the first status request")
    func helloPrecedesPipelinedStatus() async throws {
        let path = shortSocketPath("hello-pipeline")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        let hello = #"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#
        let status = #"{"id":2,"method":"status","params":{}}"#
        let pipelined = Data((hello + "\n" + status + "\n").utf8)
        try await client.sendRawChunk(pipelined)
        guard let helloLine = await client.readLine(), let statusLine = await client.readLine() else {
            Issue.record("expected hello and status responses")
            return
        }
        #expect(helloLine.contains(#""id":1"#), "hello must be the first response: \(helloLine)")
        #expect(statusLine.contains(#""id":2"#), "status must be the second response: \(statusLine)")
        let statusError = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(statusLine.utf8))
        #expect(statusError?.error.code != ControlErrorCode.helloRequired.rawValue)

        client.close()
        await server.stop()
    }

    @Test("A request before hello is refused with HELLO_REQUIRED")
    func requestBeforeHelloRefused() async throws {
        let path = shortSocketPath("prehello")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":1,"method":"status","params":{}}"#)
        guard let line = await client.readLine() else {
            Issue.record("expected a response line")
            return
        }
        guard let error = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(line.utf8)) else {
            Issue.record("expected an error envelope, got: \(line)")
            return
        }
        #expect(error.id == 1)
        #expect(error.error.code == ControlErrorCode.helloRequired.rawValue)

        client.close()
        await server.stop()
    }

    @Test("A hello with the wrong schemaVersion is refused with SCHEMA_VERSION_MISMATCH")
    func helloVersionMismatchRefused() async throws {
        let path = shortSocketPath("badversion")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version + 1),"clientName":"test"}}"#)
        guard let line = await client.readLine() else {
            Issue.record("expected a response line")
            return
        }
        guard let error = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(line.utf8)) else {
            Issue.record("expected an error envelope, got: \(line)")
            return
        }
        #expect(error.error.code == ControlErrorCode.schemaVersionMismatch.rawValue)

        client.close()
        await server.stop()
    }

    @Test("A malformed line is refused with INVALID_PARAMS and the connection stays open")
    func malformedLineRefusedConnectionStaysOpen() async throws {
        let path = shortSocketPath("malformed")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send("not json at all")
        guard let line = await client.readLine() else {
            Issue.record("expected a response line")
            return
        }
        guard let error = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(line.utf8)) else {
            Issue.record("expected an error envelope, got: \(line)")
            return
        }
        #expect(error.error.code == ControlErrorCode.invalidParams.rawValue)

        // The connection must still be open: a follow-up hello still works.
        try await client.send(#"{"id":9,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        #expect(await client.readLine() != nil)

        client.close()
        await server.stop()
    }

    @Test("A line over maxRequestLineBytes is refused with INVALID_PARAMS and the connection is then closed")
    func oversizedLineRefusedAndClosed() async throws {
        let path = shortSocketPath("oversized")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        let oversized = String(repeating: "a", count: ControlChannelDispatcher.maxRequestLineBytes + 1)
        // The server closes its end mid-write once the accumulated bytes
        // cross the bound (T-02-08); a resulting broken-pipe error on this
        // send is an expected side effect of that race, not a test
        // failure -- the refusal line read below is the actual proof, and
        // the server always writes it before it closes.
        let start = Date()
        try? await client.send(oversized)

        guard let line = await client.readLine() else {
            Issue.record("expected an INVALID_PARAMS response before closure")
            return
        }
        guard let error = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(line.utf8)) else {
            Issue.record("expected an error envelope, got: \(line)")
            return
        }
        #expect(error.error.code == ControlErrorCode.invalidParams.rawValue)
        #expect(await client.readLine() == nil)
        // WR-01 fix regression guard: an earlier draft of the fix checked
        // only the post-framing residual, which "forgets" that a line
        // which just completed was itself oversized once its bytes are
        // subtracted out as consumed -- the guard silently stopped
        // refusing early, the whole ~1 MiB line buffered to completion
        // before decode(_:)'s own separate bound finally caught it, and
        // the `readLine() == nil` check above only passed because the
        // client's own 55s receive timeout elapsed with the connection
        // never actually closed (T-02-08's entire point defeated, but
        // silently -- this test still reported green). A tight wall-clock
        // bound turns any recurrence into a fast, loud failure instead.
        #expect(Date().timeIntervalSince(start) < 5.0, "must be refused and closed promptly, not only after a client-side receive timeout")

        client.close()
        await server.stop()
    }

    @Test("WR-01: many small, complete lines whose combined bytes exceed maxRequestLineBytes stay open, and every one is answered")
    func manySmallLinesExceedingTotalBytesStayOpen() async throws {
        let path = shortSocketPath("many-small-lines")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":0,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        _ = await client.readLine() // hello response

        // This machine's own `net.local.stream.recvspace` (confirmed via
        // `sysctl`, and directly via a debug probe against `feed(fd:chunk:)`
        // during this test's own development) caps a single `availableData`
        // read at 8,192 bytes -- nowhere near the 1 MiB bound, so a literal
        // single chunk exceeding it cannot be constructed through a real
        // loopback socket here. This test still sends fully sequentially
        // (one request round-tripped to completion before the next is
        // sent), which keeps exactly one `feed()` call in flight at a time
        // -- not because of a still-open hazard (CF-01 now serializes
        // every chunk through one ordered per-connection inbox regardless
        // of how many `availableData` firings arrive back to back --
        // `burstOfRequestsOnOneConnectionIsAnsweredInOrderWithNoSpuriousFailures`
        // below is the dedicated proof of that), but because sequential
        // round trips are simplest for what this test alone needs to show:
        // WR-01's own claim -- many small, complete lines whose bytes sum well past the 1 MiB bound
        // over the connection's lifetime must never be refused, since
        // `pendingLineBytes` is the *current unterminated residual*, never
        // a running total of everything ever sent.
        let padding = String(repeating: "a", count: 8_000)
        let requestCount = 150
        var totalBytesSent = 0
        for id in 1...requestCount {
            let line = #"{"id":\#(id),"method":"status","params":{"padding":"\#(padding)"}}"#
            totalBytesSent += line.utf8.count + 1
            try await client.send(line)
            guard let responseLine = await client.readLine() else {
                Issue.record("connection closed early at request \(id) of \(requestCount)")
                return
            }
            guard let sniff = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(responseLine.utf8)) else {
                Issue.record("expected a decodable response envelope, got: \(responseLine)")
                return
            }
            #expect(sniff.id == UInt64(id))
            #expect(
                (try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(responseLine.utf8))) == nil,
                "request \(id) must not be refused"
            )
        }
        #expect(
            totalBytesSent > ControlChannelDispatcher.maxRequestLineBytes,
            "test setup must actually exceed the bound in cumulative bytes sent"
        )

        client.close()
        await server.stop()
    }

    /// Splits `data` into `pieceCount` roughly-even, byte-boundary (not
    /// line-boundary) pieces -- several lines land inside one piece and
    /// several pieces land inside one line, exercising both directions of
    /// `LineFramer`'s own buffering rather than one write per line.
    private func splitIntoChunks(_ data: Data, pieceCount: Int) -> [Data] {
        let chunkSize = max(1, data.count / pieceCount)
        var pieces: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            pieces.append(data[offset..<end])
            offset = end
        }
        return pieces
    }

    @Test("CF-01: a burst of request lines on one connection is answered in order, with no spurious id:0 or refusal")
    func burstOfRequestsOnOneConnectionIsAnsweredInOrderWithNoSpuriousFailures() async throws {
        let path = shortSocketPath("cf01-burst")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":0,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        _ = await client.readLine() // hello response

        let requestCount = 500
        for burst in 0..<5 {
            var combined = Data()
            for id in 1...requestCount {
                combined.append(Data(#"{"id":\#(id),"method":"status","params":{}}"#.utf8))
                combined.append(0x0A)
            }
            // ~50 rapid separate write(2) calls, back to back with no
            // delay -- the shape CF-01's old per-chunk `Task { feed(...) }`
            // spawn could feed `LineFramer` out of order under.
            for chunk in splitIntoChunks(combined, pieceCount: 50) {
                try await client.sendRawChunk(chunk)
            }

            var seenIds: Set<UInt64> = []
            for _ in 0..<requestCount {
                guard let line = await client.readLine() else {
                    Issue.record("burst \(burst): connection closed early, only \(seenIds.count)/\(requestCount) responses seen")
                    break
                }
                guard let sniff = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(line.utf8)) else {
                    Issue.record("burst \(burst): expected a decodable response envelope, got: \(line)")
                    continue
                }
                #expect(sniff.id != 0, "burst \(burst): a spurious id:0 response means a request was mis-framed, got: \(line)")
                if let errorEnvelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(line.utf8)) {
                    #expect(
                        errorEnvelope.error.code != ControlErrorCode.invalidParams.rawValue
                            && errorEnvelope.error.code != ControlErrorCode.unknownCommand.rawValue,
                        "burst \(burst): request \(sniff.id) was spuriously refused: \(line)"
                    )
                }
                seenIds.insert(sniff.id)
            }
            #expect(seenIds.count == requestCount, "burst \(burst): expected \(requestCount) distinct response ids, got \(seenIds.count)")
            #expect(
                seenIds == Set((1...requestCount).map(UInt64.init)),
                "burst \(burst): response ids must be exactly 1...\(requestCount), missing: \(Set(1...requestCount).subtracting(seenIds.map { Int($0) }))"
            )
        }

        client.close()
        await server.stop()
    }

    @Test("CF-01: EOF on a connection never overtakes requests that arrived before it")
    func endOfFileDoesNotOvertakeAlreadyReceivedRequests() async throws {
        let path = shortSocketPath("cf01-eof")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":0,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        _ = await client.readLine() // hello response

        let requestCount = 200
        var combined = Data()
        for id in 1...requestCount {
            combined.append(Data(#"{"id":\#(id),"method":"status","params":{}}"#.utf8))
            combined.append(0x0A)
        }
        for chunk in splitIntoChunks(combined, pieceCount: 40) {
            try await client.sendRawChunk(chunk)
        }
        // Sent immediately after the last write, with no delay -- the
        // exact race CF-01 closes: the old code's independent
        // `Task { closeConnection(fd) }` for this EOF had no ordering
        // guarantee relative to the still-in-flight `Task { feed(...) }`s
        // for the requests just written, and could tear the connection
        // down before every one of them was answered.
        client.shutdownWriteSide()

        var seenIds: Set<UInt64> = []
        while let line = await client.readLine() {
            if let sniff = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(line.utf8)) {
                seenIds.insert(sniff.id)
            }
        }
        #expect(
            seenIds == Set((1...requestCount).map(UInt64.init)),
            "every request sent before EOF must receive its response before the connection closes; got \(seenIds.count)/\(requestCount)"
        )

        client.close()
        await server.stop()
    }

    @Test("A second connection's pre-hello request is still refused after a different connection has already greeted")
    func perConnectionGreetedStateIsIsolated() async throws {
        let path = shortSocketPath("isolated")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let first = try TestControlClient(path: path)
        try await first.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"first"}}"#)
        guard let firstLine = await first.readLine() else {
            Issue.record("expected the first connection's hello response")
            return
        }
        #expect((try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(firstLine.utf8))) == nil)

        let second = try TestControlClient(path: path)
        try await second.send(#"{"id":1,"method":"status","params":{}}"#)
        guard let secondLine = await second.readLine() else {
            Issue.record("expected the second connection's response")
            return
        }
        guard let error = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(secondLine.utf8)) else {
            Issue.record("expected an error envelope for the ungreeted second connection, got: \(secondLine)")
            return
        }
        #expect(error.error.code == ControlErrorCode.helloRequired.rawValue)

        first.close()
        second.close()
        await server.stop()
    }

    @Test("Two requests on one connection get their responses back in request order")
    func responsesArriveInRequestOrder() async throws {
        let path = shortSocketPath("ordered")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        _ = await client.readLine()

        try await client.send(#"{"id":2,"method":"status","params":{}}"#)
        try await client.send(#"{"id":3,"method":"status","params":{}}"#)

        guard let secondLine = await client.readLine(), let thirdLine = await client.readLine() else {
            Issue.record("expected two response lines")
            return
        }
        let secondId = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(secondLine.utf8))
        let thirdId = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(thirdLine.utf8))
        #expect(secondId?.id == 2)
        #expect(thirdId?.id == 3)

        client.close()
        await server.stop()
    }

    // MARK: Task 3 -- bounded per-connection event relay

    @Test("A subscribing client receives a control.snapshot event line first, before any state change")
    func subscribeReceivesSnapshotFirst() async throws {
        let path = shortSocketPath("snapshot")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"test"}}"#)
        _ = await client.readLine()

        try await client.send(#"{"id":2,"method":"events.subscribe","params":{}}"#)
        guard let subscribeResponseLine = await client.readLine() else {
            Issue.record("expected an events.subscribe response line")
            return
        }
        #expect((try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: Data(subscribeResponseLine.utf8))) == nil)

        guard let eventLine = await client.readLine() else {
            Issue.record("expected a control.snapshot event line")
            return
        }
        let eventName = try? JSONDecoder().decode(ControlServerEventNameSniff.self, from: Data(eventLine.utf8)).event
        #expect(eventName == "control.snapshot")

        client.close()
        await server.stop()
    }

    @Test("A SessionModel mutation after a subscription produces a control.changed line on the same connection")
    func subscriptionSeesControlChangedAfterMutation() async throws {
        let path = shortSocketPath("changed")
        defer { removeSocketDirectory(for: path) }
        let model = await makeIdleModel(ControlServerEngineStub())
        let server = ControlChannelServer(sessionModel: model)
        try await server.start(path: path)

        let client = try TestControlClient(path: path)
        try await helloAndSubscribe(client)

        await model.handle(event: filmPresenceChangedEvent(filmPresent: true))

        guard let eventLine = await client.readLine() else {
            Issue.record("expected a control.changed event line")
            return
        }
        let eventName = try? JSONDecoder().decode(ControlServerEventNameSniff.self, from: Data(eventLine.utf8)).event
        #expect(eventName == "control.changed")

        client.close()
        await server.stop()
    }

    @Test("A connection that never subscribed receives no event lines while a subscribed connection does")
    func nonSubscribedConnectionReceivesNoEvents() async throws {
        let path = shortSocketPath("nosub")
        defer { removeSocketDirectory(for: path) }
        let model = await makeIdleModel(ControlServerEngineStub())
        let server = ControlChannelServer(sessionModel: model)
        try await server.start(path: path)

        let subscriber = try TestControlClient(path: path)
        try await helloAndSubscribe(subscriber)

        let bystander = try TestControlClient(path: path)
        try await bystander.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"bystander"}}"#)
        _ = await bystander.readLine()

        await model.handle(event: filmPresenceChangedEvent(filmPresent: true))

        guard let subscriberLine = await subscriber.readLine() else {
            Issue.record("expected the subscriber to receive control.changed")
            return
        }
        let subscriberEventName = try? JSONDecoder().decode(ControlServerEventNameSniff.self, from: Data(subscriberLine.utf8)).event
        #expect(subscriberEventName == "control.changed")

        // The bystander must not receive an event line: round-trip an
        // ordinary request and prove the very next line on its connection
        // is that response, not a leaked event.
        try await bystander.send(#"{"id":9,"method":"status","params":{}}"#)
        guard let bystanderLine = await bystander.readLine() else {
            Issue.record("expected the bystander's status response")
            return
        }
        let bystanderId = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(bystanderLine.utf8))
        #expect(bystanderId?.id == 9)

        subscriber.close()
        bystander.close()
        await server.stop()
    }

    @Test("an excessive request pipeline is disconnected at the in-flight bound")
    func excessivePipelineIsDisconnected() async throws {
        let path = shortSocketPath("pipeline-bound")
        defer { removeSocketDirectory(for: path) }
        let server = ControlChannelServer(sessionModel: await makeIdleModel(ControlServerEngineStub()))
        try await server.start(path: path)

        let client = try TestControlClient(path: path, receiveTimeoutSeconds: 5)
        try await client.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"pipeline"}}"#)
        #expect(await client.readLine() != nil)

        let lines = (0...ControlChannelServer.inFlightRequestBound)
            .map { #"{"id":\#($0 + 2),"method":"status","params":{}}"# }
            .joined(separator: "\n") + "\n"
        try await client.sendRawChunk(Data(lines.utf8))
        #expect(await client.readLine() == nil)

        client.close()
        await server.stop()
    }

    @Test("A stalled subscriber's overflowing queue does not block a different connection's status round trip, and the stalled peer later sees control.dropped before the next control.changed")
    func stalledSubscriberDoesNotBlockAnotherConnection() async throws {
        let path = shortSocketPath("stalled")
        defer { removeSocketDirectory(for: path) }
        let model = await makeIdleModel(ControlServerEngineStub())
        let server = ControlChannelServer(sessionModel: model)
        try await server.start(path: path)

        // Connection A subscribes but never reads afterward -- not even
        // its own subscribe response or the initial snapshot -- simulating
        // a consumer that has stopped draining its socket. A tiny receive
        // buffer forces the server's write to genuinely block after a
        // small, predictable amount of unread data, rather than depending
        // on this machine's default kernel socket buffer size (measured
        // large enough in practice to otherwise absorb this whole test's
        // mutation count without ever blocking).
        let stalled = try TestControlClient(path: path, tinyReceiveBuffer: true)
        try await stalled.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"stalled"}}"#)
        try await stalled.send(#"{"id":2,"method":"events.subscribe","params":{}}"#)

        // Drive far more mutations than the outbound queue bound so this
        // server's own bounded queue overflows (Pitfall 3's drop-oldest
        // path). Coalescing in the dispatcher's own change-observation
        // (independently measured at ~90%+ fidelity for rapid mutations)
        // still leaves comfortably more real notifications than the bound.
        let overflowMutationCount = ControlChannelServer.outboundQueueBound * 3
        for index in 0..<overflowMutationCount {
            await model.handle(event: filmPresenceChangedEvent(filmPresent: index % 2 == 0))
        }

        // A second, ordinary connection must still complete a request
        // while the stalled connection's queue is backed up.
        let other = try TestControlClient(path: path)
        try await other.send(#"{"id":1,"method":"hello","params":{"schemaVersion":\#(ControlSchema.version),"clientName":"other"}}"#)
        _ = await other.readLine()
        try await other.send(#"{"id":9,"method":"status","params":{}}"#)
        guard let otherLine = await other.readLine() else {
            Issue.record("expected the other connection's status response despite the stalled subscriber")
            return
        }
        let otherId = try? JSONDecoder().decode(ControlServerResponseIdSniff.self, from: Data(otherLine.utf8))
        #expect(otherId?.id == 9)

        // Now let the stalled connection resume reading and look for the
        // control.dropped notice, bounded so a wrong assumption fails
        // clearly instead of hanging.
        var droppedNotice: ControlServerDroppedNoticeSniff?
        for _ in 0..<(overflowMutationCount + 10) {
            guard let line = await stalled.readLine() else { break }
            if let sniff = try? JSONDecoder().decode(ControlServerDroppedNoticeSniff.self, from: Data(line.utf8)),
               sniff.event == "control.dropped" {
                droppedNotice = sniff
                break
            }
        }
        #expect(droppedNotice != nil)
        #expect((droppedNotice?.payload.droppedEvents ?? 0) > 0)

        stalled.close()
        other.close()
        await server.stop()
    }
}
