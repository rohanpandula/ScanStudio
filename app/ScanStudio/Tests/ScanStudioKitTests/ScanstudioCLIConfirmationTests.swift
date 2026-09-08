// Per-command SAFE-01 confirmation-gate proofs plus the `--wait`/stop/
// resume/recoverable-passthrough and SAFE-04 refusal-observability proofs
// (plan 02-06). Execs the real built `scanstudio-cli` binary as a genuine
// subprocess against an in-process host -- mirrors
// `ScanstudioCLIProcessTests.swift`'s harness idioms (binary locator,
// in-process host, async `runCLI`) one file over, since those helpers are
// file-private there and this plan's own `files_modified` does not touch
// that file.
//
// Every test here passes `--socket` explicitly (a short `/tmp` test path)
// and never touches `~/.scanstudio/`. No scanner motion, no GUI, no real
// engine binary -- every test drives a fake `EngineClientProtocol` actor.

import Foundation
import Testing

@testable import ScanStudioKit

private enum ConfirmationStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint --
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`) even before any device is connected.
private let confirmationDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

private let confirmationProjectDirectory = "/tmp/confirmation-test-project"

/// A minimal one-frame project fixture whose frame has no draft alignment
/// or rotation, so `startMockScan()`'s `persistFrameGeometryBeforeScan`
/// step is a no-op and never issues an unscripted
/// `project.setFrameAlignment` request (mirrors
/// `ControlChannelMotionRoutingTests.swift`'s identical `motionRoutingProject`
/// fixture and its own documented rationale).
private func confirmationProject(frameIndex: Int = 1) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "confirmation-project",
        name: "Confirmation test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/confirmation-test/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/confirmation-test/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/confirmation-test/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-09-07T00:00:00Z",
        frames: [ProjectFrame(index: frameIndex, excluded: false, receipts: [])]
    )
}

/// Fake engine covering every wire method a test in this file drives,
/// modelled on `ControlChannelMotionRoutingTests.swift`'s
/// `MotionRoutingEngineStub` (scan.start/scan.stop) and
/// `ControlRecoverablePassthroughTests.swift`'s `RecoverablePassthroughEngineStub`
/// (`failNext`, for the SAFE-02 recoverable-error proof). Built as one
/// cohesive type covering all three tasks' needs up front, mirroring
/// `ControlChannelClient.swift`'s own precedent for a single-commit type
/// whose tests land incrementally.
private actor ConfirmationEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "confirmation-stub"

    /// The fixed job id every scripted `scan.start` answers with -- known
    /// ahead of time so a test can construct matching synthetic
    /// `scan.jobState`/`scan.frameState` events.
    static let jobId = "confirmation-scan-job"

    private(set) var requestCounts: [String: Int] = [:]
    private(set) var recordedScanStopModes: [String] = []
    private(set) var recordedScanStarts: [ScanStartParams] = []
    private var scriptedFailures: [String: EngineRequestError] = [:]

    /// Scripts the next call to `method` to throw `error` instead of
    /// answering normally -- removed from the schedule once consumed, so a
    /// second call to the same method answers the fixed happy path.
    func failNext(_ method: String, with error: EngineRequestError) {
        scriptedFailures[method] = error
    }

    func requestCount(_ method: String) -> Int {
        requestCounts[method, default: 0]
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params
    ) async throws -> Result {
        requestCounts[method, default: 0] += 1
        if let failure = scriptedFailures.removeValue(forKey: method) {
            throw failure
        }
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [confirmationDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: confirmationDevice,
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
            let directory = (params as? ProjectOpenParams)?.directory ?? confirmationProjectDirectory
            return try cast(
                ProjectOpenResult(project: confirmationProject(), directory: directory),
                as: Result.self
            )
        case "scan.start":
            guard let scan = params as? ScanStartParams else {
                throw ConfirmationStubError.unexpectedResultType
            }
            recordedScanStarts.append(scan)
            let count = requestCounts[method] ?? 1
            let jobId = count == 1 ? Self.jobId : "\(Self.jobId)-\(count)"
            return try cast(ScanStartResult(jobId: jobId), as: Result.self)
        case "scan.stop":
            let mode = (params as? ScanStopParams)?.mode ?? "afterCurrentFrame"
            recordedScanStopModes.append(mode)
            return try cast(ScanStopResult(acknowledged: true, mode: mode), as: Result.self)
        default:
            throw ConfirmationStubError.unexpectedMethod(method)
        }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw ConfirmationStubError.unexpectedResultType }
        return result
    }
}

/// Bounded `Task.yield()` polling for `SessionModel.init`'s fire-and-forget
/// discovery call, per this codebase's established idiom (never a fixed
/// sleep).
@MainActor
private func makeConfirmationIdleModel(_ stub: ConfirmationEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

/// A short `AF_UNIX` path under a per-test, per-label directory this suite
/// owns -- never the per-user temporary-directory API (its container path
/// is long enough to overflow `sun_path`), never anywhere under the real
/// home directory.
private func confirmationSocketPath(_ label: String) -> String {
    let directory = "/tmp/ss-cli-confirm-\(label)-\(UInt32.random(in: 0..<UInt32.max))"
    let path = directory + "/s.sock"
    precondition(path.utf8.count < 104, "test socket path must be < 104 bytes, got \(path.utf8.count): \(path)")
    return path
}

private func removeConfirmationSocketDirectory(for path: String) {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: directory)
}

/// An in-process host: a real `ControlChannelServer` bound to a short
/// `/tmp` path, feeding one shared `SessionModel` backed by a fake
/// `EngineClientProtocol`. Every test execs the real built `scanstudio-cli`
/// binary against this host as a genuine subprocess.
@MainActor
private struct ConfirmationHost {
    let model: SessionModel
    let stub: ConfirmationEngineStub
    let server: ControlChannelServer
    let socketPath: String

    static func start(label: String) async throws -> ConfirmationHost {
        let stub = ConfirmationEngineStub()
        let model = await makeConfirmationIdleModel(stub)
        let server = ControlChannelServer(sessionModel: model)
        let path = confirmationSocketPath(label)
        try await server.start(path: path)
        return ConfirmationHost(model: model, stub: stub, server: server, socketPath: path)
    }
}

/// Connects, opens the one-frame project fixture, fakes a media-loaded
/// status, completes a preview with a plain (not `needsApproval`)
/// thumbnail, and selects frame 1 -- reaching `scanReadiness(for: [1])
/// .isReady == true` without ever pausing on manual review. Mirrors
/// `ControlChannelMotionRoutingTests.swift`'s identical
/// `prepareMotionRoutingScanReadiness` helper (private to that file, so
/// this is its own copy, not a shared import).
@MainActor
@discardableResult
private func prepareConfirmationScanReadiness(_ model: SessionModel) async -> Bool {
    await model.connect(deviceId: confirmationDevice.deviceId)
    await model.openProject(directory: confirmationProjectDirectory)
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
    model.toggleFrameSelection(1)
    return model.scanReadiness(for: [1]).isReady
}

/// Feeds a synthetic `scan.jobState` event directly to `model` -- the same
/// out-of-band-mutation technique `ControlChannelMotionRoutingTests.swift`
/// uses throughout (`model.handle(event:)`), which the dispatcher's own
/// observation-tracking subscription reacts to identically regardless of
/// whether the mutation came from a real engine event or a test.
@MainActor
private func driveConfirmationJobState(_ model: SessionModel, jobId: String, state: String) {
    model.handle(event: EngineEvent(
        name: "scan.jobState",
        rawLine: Data(#"{"event":"scan.jobState","payload":{"jobId":"\#(jobId)","state":"\#(state)"}}"#.utf8)
    ))
}

@MainActor
private func driveConfirmationCompleted(_ model: SessionModel, jobId: String, frameIndex: Int = 1) {
    model.handle(event: EngineEvent(
        name: "scan.completed",
        rawLine: Data(
            #"{"event":"scan.completed","payload":{"jobId":"\#(jobId)","summary":{"completed":[\#(frameIndex)],"failed":[],"skipped":[],"stopped":false}}}"#.utf8
        )
    ))
}

/// Feeds a synthetic `scan.frameState` failure so `job.get`'s
/// `frameErrorCodes` has a real entry to assert on, mirroring OUT-03's own
/// `FEED_JAM` fixture (`ControlRecoverablePassthroughTests.swift`).
@MainActor
private func driveConfirmationFrameFailure(_ model: SessionModel, jobId: String, frameIndex: Int) {
    model.handle(event: EngineEvent(
        name: "scan.frameState",
        rawLine: Data(
            #"""
            {"event":"scan.frameState","payload":{"jobId":"\#(jobId)","frameIndex":\#(frameIndex),"state":"failed","attempt":1,"error":{"code":"FEED_JAM","message":"film jammed mid-feed","recoverable":true}}}
            """#.utf8
        )
    ))
}

/// Waits for "the host's dispatch of the caller's own scan.start/
/// scan.resume request has completed" -- i.e. `SessionModel.beginJob(id:)`
/// has run and `model.jobId` is set.
///
/// This must not give up early: `SessionModel.eventIsRelevant(_:source:)`
/// only buffers an out-of-order job event while `dispatchScanStart`'s own
/// `pendingScanStart` marker is still set; once `dispatchScanStart` returns
/// and clears it, an event for a job that has not yet called `beginJob`
/// is silently dropped (`eventIsRelevant` returns `false`, no buffering).
/// If this helper gave up before `beginJob` actually ran, a caller that
/// then drove `scanning`/`completed` anyway would have those events
/// dropped, and the *real* `beginJob` running later would overwrite
/// `jobState` back to `.queued` -- permanently orphaning the subprocess's
/// `--wait`, since nothing would ever drive it to a terminal state again.
/// A real subprocess plus a real socket round trip is also a different
/// timing domain than an in-process actor hop, and under this suite's own
/// concurrent test load a pure `Task.yield()` loop was observed to
/// exhaust its budget before `beginJob` ran -- hence the real sleep
/// between checks here, not just a yield.
@MainActor
private func waitForConfirmationJobToBegin(_ model: SessionModel) async {
    for _ in 0..<11_000 where model.jobId == nil {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private enum ConfirmationCLILocator {
    struct LocateError: Error, CustomStringConvertible {
        let description: String
    }

    /// Resolves `.build/debug/scanstudio-cli` from this file's own source
    /// path -- three `deletingLastPathComponent()` hops from
    /// `Tests/ScanStudioKitTests/…` to the package root, matching
    /// `EngineLocator`'s own source-relative idiom (never an absolute
    /// developer path).
    static func resolve() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ScanstudioCLIConfirmationTests.swift -> ScanStudioKitTests/
            .deletingLastPathComponent() // ScanStudioKitTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> package root
        let binary = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("scanstudio-cli")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw LocateError(
                description: "scanstudio-cli binary not found at \(binary.path). Run `swift build --product scanstudio-cli` first."
            )
        }
        return binary
    }
}

private struct ConfirmationCLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Thrown when a CLI subprocess spawned by `runConfirmationCLI` does not
/// exit within its bound. CR-01: this file's own `--wait` tests can now
/// drive `SessionModel.applyCompleted` (not just `applyJobState`), which is
/// exactly the code path that used to leave `JobWaiter.waitForTerminalOutcome`
/// hanging forever -- and this suite's `.timeLimit(.minutes(1))` trait does
/// NOT bound that hang, because the blocking `Process`/`Pipe` read below runs
/// on a raw `DispatchQueue.global` thread outside structured concurrency, not
/// as a cancellable `Task`. Mirrors `ControlSocketEndToEndTests.swift`'s
/// `runE2ECLI`/`E2ESubprocessTimeoutError` precedent so a future regression
/// in this area fails fast at the unit-test tier instead of only being
/// caught (as a flaky timeout) by the slower, opt-in E2E suite.
private struct ConfirmationSubprocessTimeoutError: Error, CustomStringConvertible {
    let arguments: [String]
    let timeoutSeconds: Double
    var description: String {
        "step `scanstudio-cli \(arguments.joined(separator: " "))` did not exit within "
            + "\(Int(timeoutSeconds))s -- killed. See `runConfirmationCLI`'s doc comment."
    }
}

/// See `ControlSocketEndToEndTests.swift`'s identical `SingleResumeGuard` --
/// duplicated per-file rather than shared, matching this suite's own
/// established precedent of copying (not importing) test-only helpers
/// across files (`runCLI`/`runConfirmationCLI`/`runE2ECLI` are three
/// independent copies of the same shape already).
private final class ConfirmationSingleResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Runs the real built binary with `arguments` plus `--socket socketPath`,
/// returning its exit status, stdout, and stderr. The blocking `Process`
/// spawn/read/wait sequence runs on a dedicated background queue via a
/// continuation -- never inline on Swift's cooperative thread pool. This is
/// the identical fix `ScanstudioCLIProcessTests.swift`'s `runCLI` needed
/// (02-05-SUMMARY.md deviation #2): blocking I/O called directly inside an
/// `async` test function occupies a cooperative-pool thread for the whole
/// blocking duration, and with several tests' hosts all needing
/// actor/`@MainActor` hops concurrently, the pool is exhausted and every
/// connection -- including the one this very call is waiting on -- stops
/// making progress.
///
/// A second, independent GCD timer races the same continuation
/// (`ConfirmationSingleResumeGuard` ensures exactly one resume): if the
/// subprocess has not exited within `timeoutSeconds`, it is killed and
/// `ConfirmationSubprocessTimeoutError` is thrown. 60s mirrors `runE2ECLI`'s
/// own wide margin -- every real step in this suite completes in well under
/// a second.
private func runConfirmationCLI(
    _ arguments: [String],
    socketPath: String,
    timeoutSeconds: Double = 60
) async throws -> ConfirmationCLIResult {
    let binary = try ConfirmationCLILocator.resolve()
    let allArguments = arguments + ["--socket", socketPath]
    let process = Process()
    process.executableURL = binary
    process.arguments = allArguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let resumeGuard = ConfirmationSingleResumeGuard()

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ConfirmationCLIResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard resumeGuard.tryClaim() else { return }
                continuation.resume(returning: ConfirmationCLIResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            } catch {
                guard resumeGuard.tryClaim() else { return }
                continuation.resume(throwing: error)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            guard resumeGuard.tryClaim() else { return }
            if process.isRunning {
                process.terminate()
            }
            continuation.resume(throwing: ConfirmationSubprocessTimeoutError(
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            ))
        }
    }
}

/// Thread-safe append-only line buffer fed by
/// `ConfirmationEventsFollower`'s background reader thread and polled by
/// the async test side -- a plain lock-protected class rather than an
/// actor, so the reader thread's synchronous, strictly-ordered appends
/// never risk being reordered by independently-scheduled `Task` hops onto
/// an actor's mailbox.
private final class ConfirmationLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var finished = false

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func snapshot() -> (lines: [String], finished: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (lines, finished)
    }
}

/// Runs `scanstudio-cli events --follow` as a genuine subprocess and
/// collects its stdout, one NDJSON line at a time -- the streaming
/// counterpart to `runConfirmationCLI`, which waits for a process to exit
/// (this one never does, until the host closes or the test terminates it).
/// The blocking `Process`/`Pipe` read loop runs on a dedicated background
/// queue, mirroring `runConfirmationCLI`'s own rationale for keeping
/// blocking I/O off Swift's cooperative thread pool.
private final class ConfirmationEventsFollower: @unchecked Sendable {
    private let process: Process
    private let buffer = ConfirmationLineBuffer()

    init(socketPath: String) throws {
        let binary = try ConfirmationCLILocator.resolve()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["events", "--follow", "--socket", socketPath]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        self.process = process

        let readHandle = stdoutPipe.fileHandleForReading
        let buffer = self.buffer
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break } // EOF: the process exited or the pipe closed
                pending.append(chunk)
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[..<newlineIndex]
                    pending.removeSubrange(...newlineIndex)
                    if let line = String(data: lineData, encoding: .utf8) {
                        buffer.append(line)
                    }
                }
            }
            buffer.markFinished()
        }

        try process.run()
    }

    /// Polls until some collected line's decoded JSON satisfies
    /// `predicate`, the stream ends, or a generous bound elapses -- the
    /// suite's own `.timeLimit` is the ultimate backstop. Unlike an
    /// in-process actor hop (where yielding alone lets the other side make
    /// progress, since both sides compete for the same actor queue), the
    /// data this polls for is written by a genuinely separate OS thread
    /// reading a real subprocess's pipe -- a pure `Task.yield()` loop can
    /// spin through its whole budget in microseconds without ever giving
    /// that thread a real scheduling slice, so this sleeps briefly between
    /// checks. Re-scans everything collected so far on each poll, which is
    /// cheap at this suite's line counts.
    func waitForLine(matching predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
        for _ in 0..<2_000 {
            let (lines, finished) = buffer.snapshot()
            for line in lines {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   predicate(object) {
                    return object
                }
            }
            if finished { return nil }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    func terminate() {
        process.terminate()
        process.waitUntilExit()
    }
}

@Suite("scanstudio-cli confirmation", .timeLimit(.minutes(1)))
struct ScanstudioCLIConfirmationTests {
    // MARK: Task 1 -- preview / review approve / eject confirmation gates (SAFE-01)

    @Test("preview without --film-loaded exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func previewWithoutFilmLoadedExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "preview-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["preview"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("review approve without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func reviewApproveWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "review-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["review", "approve"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("eject without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func ejectWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "eject-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["eject"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("preview --film-loaded against a live host exits 0 and the result carries an outcome, proving the request reached the host")
    func previewWithFilmLoadedReachesHost() async throws {
        let host = try await ConfirmationHost.start(label: "preview-confirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["preview", "--film-loaded"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["outcome"] is String)

        await host.server.stop()
    }

    @Test("review approve --confirm-motion against a live host with nothing pending reports the host's own GATE_REFUSED, not CONFIRMATION_REQUIRED -- proving the request reached the host")
    func reviewApproveWithConfirmMotionReachesHost() async throws {
        let host = try await ConfirmationHost.start(label: "review-confirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["review", "approve", "--confirm-motion"], socketPath: host.socketPath)
        #expect(result.exitCode != 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "GATE_REFUSED")

        await host.server.stop()
    }

    @Test("eject --confirm-motion against a live but disconnected host reports the host's own GATE_REFUSED, not CONFIRMATION_REQUIRED -- proving the request reached the host")
    func ejectWithConfirmMotionReachesHost() async throws {
        let host = try await ConfirmationHost.start(label: "eject-confirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["eject", "--confirm-motion"], socketPath: host.socketPath)
        #expect(result.exitCode != 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "GATE_REFUSED")

        await host.server.stop()
    }

    @Test("eject --confirm-motion --attach against a socket path with no listener exits 69 (HOST_UNREACHABLE), proving the 77 path above is not simply a connection failure")
    func ejectAgainstMissingListenerExitsHostUnreachable() async throws {
        let result = try await runConfirmationCLI(["eject", "--confirm-motion", "--attach"], socketPath: confirmationSocketPath("eject-no-listener"))
        #expect(result.exitCode == 69)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "HOST_UNREACHABLE")
    }

    // MARK: Task 2 -- scan / stop / resume and the --wait terminal-state observer

    @Test("scan without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func scanWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "scan-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["scan"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("resume without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func resumeWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "resume-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["resume"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("scan --confirm-motion without --wait against a ready host exits 0 and the result carries a jobId")
    func scanConfirmedWithoutWaitReturnsJobId() async throws {
        let host = try await ConfirmationHost.start(label: "scan-nowait")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        let result = try await runConfirmationCLI(["scan", "--confirm-motion"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["jobId"] as? String == ConfirmationEngineStub.jobId)

        await host.server.stop()
    }

    @Test("scan repeat requires a pass token before opening a control socket")
    func scanRepeatWithoutPassIsRejectedBeforeConnection() async throws {
        let result = try await runConfirmationCLI(
            ["scan", "--confirm-motion", "--frames", "1", "--repeat", "2"],
            socketPath: confirmationSocketPath("repeat-no-pass")
        )
        #expect(result.exitCode == 64)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["message"] as? String == "--pass is required when --repeat is greater than 1.")
    }

    @Test("scan repeat count is bounded to 1 through 100 before connection")
    func scanRepeatCountIsBounded() async throws {
        for count in [0, 101] {
            let result = try await runConfirmationCLI(
                ["scan", "--confirm-motion", "--repeat", String(count), "--pass", "Arep"],
                socketPath: confirmationSocketPath("repeat-bound-\(count)")
            )
            #expect(result.exitCode == 64)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let error = try #require(object["error"] as? [String: Any])
            #expect((error["message"] as? String)?.contains("1...100") == true)
        }
    }

    @Test("scan repeat snapshots selected frames and waits sequentially with Arep pass tokens")
    func scanRepeatUsesSequentialPassTokens() async throws {
        let host = try await ConfirmationHost.start(label: "scan-repeat")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        #expect(await prepareConfirmationScanReadiness(host.model))

        async let outcome = runConfirmationCLI(
            ["scan", "--confirm-motion", "--repeat", "2", "--pass", "Arep", "--quiet"],
            socketPath: host.socketPath
        )
        for _ in 0..<11_000 where await host.stub.requestCount("scan.start") < 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await host.stub.requestCount("scan.start") == 1)
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "scanning")
        await driveConfirmationCompleted(host.model, jobId: ConfirmationEngineStub.jobId)
        for _ in 0..<11_000 where await host.stub.requestCount("scan.start") < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await host.stub.requestCount("scan.start") == 2)
        let secondJobId = "\(ConfirmationEngineStub.jobId)-2"
        await driveConfirmationJobState(host.model, jobId: secondJobId, state: "scanning")
        await driveConfirmationCompleted(host.model, jobId: secondJobId)

        let result = try await outcome
        #expect(result.exitCode == 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["repeatCount"] as? Int == 2)
        #expect(resultObject["completedRepeatCount"] as? Int == 2)
        #expect(resultObject["passTokens"] as? [String] == ["Arep01", "Arep02"])
        #expect(resultObject["frames"] as? [Int] == [1])
        #expect((resultObject["jobs"] as? [[String: Any]])?.count == 2)
        let starts = await host.stub.recordedScanStarts
        #expect(starts.map(\.frames) == [[1], [1]])
        #expect(starts.map(\.passToken) == ["Arep01", "Arep02"])

        await host.server.stop()
    }

    @Test("scan --confirm-motion --wait driven to completed exits 0 and the result carries jobState completed and receiptCount")
    func scanWaitDrivenToCompletedExitsZero() async throws {
        let host = try await ConfirmationHost.start(label: "scan-wait-completed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        async let outcome = runConfirmationCLI(["scan", "--confirm-motion", "--wait"], socketPath: host.socketPath)
        await waitForConfirmationJobToBegin(host.model)
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "scanning")
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "completed")

        let result = try await outcome
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["jobState"] as? String == "completed")
        #expect(resultObject["receiptCount"] is Int)

        await host.server.stop()
    }

    @Test("scan --confirm-motion --wait driven to failed exits 65 and the result carries frameErrorCodes")
    func scanWaitDrivenToFailedExitsEngineOrGateError() async throws {
        let host = try await ConfirmationHost.start(label: "scan-wait-failed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        async let outcome = runConfirmationCLI(["scan", "--confirm-motion", "--wait"], socketPath: host.socketPath)
        await waitForConfirmationJobToBegin(host.model)
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "scanning")
        await driveConfirmationFrameFailure(host.model, jobId: ConfirmationEngineStub.jobId, frameIndex: 1)
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "failed")

        let result = try await outcome
        #expect(result.exitCode == 65)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["jobState"] as? String == "failed")
        let frameErrorCodes = try #require(resultObject["frameErrorCodes"] as? [String: String])
        #expect(frameErrorCodes["1"] == "FEED_JAM")

        await host.server.stop()
    }

    @Test("scan --confirm-motion --wait driven to stopped exits 0")
    func scanWaitDrivenToStoppedExitsZero() async throws {
        let host = try await ConfirmationHost.start(label: "scan-wait-stopped")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        async let outcome = runConfirmationCLI(["scan", "--confirm-motion", "--wait"], socketPath: host.socketPath)
        await waitForConfirmationJobToBegin(host.model)
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "scanning")
        await driveConfirmationJobState(host.model, jobId: ConfirmationEngineStub.jobId, state: "stopped")

        let result = try await outcome
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["jobState"] as? String == "stopped")

        await host.server.stop()
    }

    @Test("CR-01: scan --confirm-motion --wait driven to completed via a synthetic scan.completed event (which clears jobId in the same update that reaches a terminal jobState, unlike scan.jobState) still exits 0 rather than hanging")
    func scanWaitDrivenToCompletedViaScanCompletedEventExitsZero() async throws {
        let host = try await ConfirmationHost.start(label: "scan-wait-completed-event")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        async let outcome = runConfirmationCLI(["scan", "--confirm-motion", "--wait"], socketPath: host.socketPath)
        await waitForConfirmationJobToBegin(host.model)
        // Unlike driveConfirmationJobState (SessionModel.applyJobState, which
        // only ever touches jobState), this drives SessionModel.applyCompleted
        // -- the handler that clears jobId to nil in the same synchronous
        // update that first resolves jobState to a terminal value (CR-01).
        // Without JobWaiter's observedJobId fix, this hangs until the
        // suite's own .timeLimit(.minutes(1)) kills it.
        await host.model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"""
                {"event":"scan.completed","payload":{"jobId":"\#(ConfirmationEngineStub.jobId)","summary":{"completed":[1],"failed":[],"skipped":[],"stopped":false}}}
                """#.utf8
            )
        ))

        let result = try await outcome
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["jobState"] as? String == "completed")

        await host.server.stop()
    }

    @Test("scan --confirm-motion --wait whose host is shut down mid-wait exits 69 rather than hanging")
    func scanWaitHostGoneMidWaitExitsHostUnreachable() async throws {
        let host = try await ConfirmationHost.start(label: "scan-wait-host-gone")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        async let outcome = runConfirmationCLI(["scan", "--confirm-motion", "--wait"], socketPath: host.socketPath)
        await waitForConfirmationJobToBegin(host.model)
        await host.server.stop()

        let result = try await outcome
        #expect(result.exitCode == 69)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "HOST_UNREACHABLE")
    }

    @Test("stop with no active job exits with the host's GATE_REFUSED code and prints its message verbatim")
    func stopWithNoActiveJobExitsGateRefused() async throws {
        let host = try await ConfirmationHost.start(label: "stop-no-job")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["stop"], socketPath: host.socketPath)
        #expect(result.exitCode != 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "GATE_REFUSED")
        #expect((error["message"] as? String)?.contains("no job is active") == true)

        await host.server.stop()
    }

    @Test("stop --immediate against an active job sends mode immediate, recorded verbatim by the fake engine")
    func stopImmediateSendsImmediateMode() async throws {
        let host = try await ConfirmationHost.start(label: "stop-immediate")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)

        let startResult = try await runConfirmationCLI(["scan", "--confirm-motion"], socketPath: host.socketPath)
        #expect(startResult.exitCode == 0)

        let stopResult = try await runConfirmationCLI(["stop", "--immediate"], socketPath: host.socketPath)
        #expect(stopResult.exitCode == 0)
        let recordedModes = await host.stub.recordedScanStopModes
        #expect(recordedModes == ["immediate"])

        await host.server.stop()
    }

    @Test("SAFE-02: a recoverable FEED_JAM thrown from scan.start exits non-zero and reaches stdout as \"recoverable\": true, with exactly one scan.start request recorded")
    func scanRecoverableEngineErrorIsReportedNotRetried() async throws {
        let host = try await ConfirmationHost.start(label: "scan-recoverable")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let ready = await prepareConfirmationScanReadiness(host.model)
        #expect(ready)
        await host.stub.failNext("scan.start", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))

        let result = try await runConfirmationCLI(["scan", "--confirm-motion"], socketPath: host.socketPath)
        #expect(result.exitCode == 65)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "FEED_JAM")
        #expect(error["recoverable"] as? Bool == true)
        let startCount = await host.stub.requestCounts["scan.start"]
        #expect(startCount == 1)

        await host.server.stop()
    }

    // MARK: Task 3 -- events --follow and the SAFE-04 refusal-observability proof

    @Test("events without --follow exits 64")
    func eventsWithoutFollowExitsUsageError() async throws {
        let result = try await runConfirmationCLI(["events"], socketPath: confirmationSocketPath("events-no-follow"))
        #expect(result.exitCode == 64)
    }

    @Test("events --follow prints a first line whose parsed JSON carries schemaVersion, command == \"events\", and a control.snapshot payload")
    func eventsFollowFirstLineCarriesSnapshot() async throws {
        let host = try await ConfirmationHost.start(label: "events-first-line")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let follower = try ConfirmationEventsFollower(socketPath: host.socketPath)
        defer { follower.terminate() }

        let firstLine = await follower.waitForLine { _ in true }
        let object = try #require(firstLine)
        #expect(object["schemaVersion"] as? Int == ControlSchema.version)
        #expect(object["command"] as? String == "events")
        let event = try #require(object["event"] as? [String: Any])
        #expect(event["event"] as? String == "control.snapshot")
        #expect(event["payload"] is [String: Any])

        await host.server.stop()
    }

    @Test("driving a SessionModel mutation on the host produces a follower line whose event is control.changed")
    func eventsFollowObservesControlChangedAfterMutation() async throws {
        let host = try await ConfirmationHost.start(label: "events-changed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let follower = try ConfirmationEventsFollower(socketPath: host.socketPath)
        defer { follower.terminate() }

        // Wait for the first line so the follower's own events.subscribe has
        // definitely landed before the mutation below -- otherwise the
        // mutated state could race into the follower's very first snapshot
        // instead of arriving as its own separate control.changed line.
        _ = await follower.waitForLine { _ in true }
        await host.model.connect(deviceId: confirmationDevice.deviceId)

        let changed = await follower.waitForLine { object in
            (object["event"] as? [String: Any])?["event"] as? String == "control.changed"
        }
        #expect(changed != nil)

        await host.server.stop()
    }

    @Test("""
    SAFE-04: with events --follow running as a subprocess, a second process's refused command (roll save with no \
    frames selected) produces all three of: the second process's own exit code and error body, and a follower line \
    whose event is control.changed reflecting the refusal
    """)
    func eventsFollowObservesRefusalFromSecondProcess() async throws {
        let host = try await ConfirmationHost.start(label: "events-safe04")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let follower = try ConfirmationEventsFollower(socketPath: host.socketPath)
        defer { follower.terminate() }
        _ = await follower.waitForLine { _ in true }

        // "roll save --confirm-motion" reaches the wire (confirmed at both
        // the CLI's own parse-time gate and, since --confirm-motion is
        // given, the wire's motionConfirmed field) but is refused by the
        // host for an unrelated precondition -- no frames are selected.
        // saveRollAndScanSelectedFrames is always called and sets
        // lastErrorMessage itself before refusing, so this was already a
        // genuine SessionModel mutation a follower could observe as
        // control.changed even before the Gap 2 fix below. This test
        // predates that fix and still asserts on lastErrorMessage rather
        // than lastControlRefusal, deliberately -- it documents the case
        // that always worked. `ControlChannelClientTests.swift`'s
        // `independentFollowerObservesConfirmationRequiredRefusal` covers
        // the case that did not: a scan.start CONFIRMATION_REQUIRED
        // refusal, which confirmationRefusal(for:) used to return without
        // ever touching SessionModel at all.
        let refused = try await runConfirmationCLI(
            ["roll", "save", "--name", "x", "--carrier", "roll36", "--frame-count", "36", "--film-process", "c41ColorNegative", "--confirm-motion"],
            socketPath: host.socketPath
        )
        #expect(refused.exitCode != 0)
        let refusedObject = try #require(JSONSerialization.jsonObject(with: Data(refused.stdout.utf8)) as? [String: Any])
        let refusedError = try #require(refusedObject["error"] as? [String: Any])
        #expect(refusedError["code"] as? String == "GATE_REFUSED")

        let changed = await follower.waitForLine { object in
            guard let event = object["event"] as? [String: Any],
                  event["event"] as? String == "control.changed",
                  let payload = event["payload"] as? [String: Any]
            else { return false }
            return (payload["lastErrorMessage"] as? String)?.contains("Select at least one frame") == true
        }
        #expect(changed != nil)

        await host.server.stop()
    }

    @Test("root --help lists all sixteen D-08 command groups")
    func rootHelpListsAllCommandGroups() async throws {
        let result = try await runConfirmationCLI(["--help"], socketPath: confirmationSocketPath("root-help"))
        #expect(result.exitCode == 0)
        for group in [
            "connect", "disconnect", "rescan", "status", "preview", "frames", "review",
            "settings", "outputs", "roll", "scan", "stop", "resume", "eject", "diagnostics", "events"
        ] {
            #expect(result.stdout.contains(group), "expected --help to list \(group)")
        }
    }
}
