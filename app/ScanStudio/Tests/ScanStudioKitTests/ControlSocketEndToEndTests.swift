// Socket-only CLI acceptance against the real engine and simulated media.
// Opt-in with SCANSTUDIO_CLI_E2E=1; HOST_MODE selects in-process or headless.
// Uses 100 DPI to exercise real rendering cheaply. A stopped batch needs a
// fresh preview before resume, matching the application's registration gate.

import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

// MARK: - Host (HEAD-02 / PKG-02 seam)

/// Which real host the acceptance sequence's CLI subprocesses connect to.
/// Exactly one case exists in Phase 2 -- Phase 3 adds a headless-host case
/// (HEAD-02), Phase 4 a packaged-bundle case (PKG-02), each an addition to
/// this enum rather than a rewrite of the sequence below.
enum EndToEndHostKind: String, Sendable {
    case inProcess = "in-process", headless
}

struct UnsupportedHostModeError: Error { let hostMode: String }

@MainActor
private struct EndToEndHost {
    let kind: EndToEndHostKind
    let handle: SessionHost.Handle?
    let hostPid: Int32
    let socketPath: String
    let tempRoot: URL
    let enginePids: [Int32]
    private let originalEnvironment: [String: String]
    private static let isolatedKeys = [
        "HOME", "CFFIXED_USER_HOME", "TMPDIR", "SCANSTUDIO_TIMESCALE", "SCANSTUDIO_BRIDGE_CMD",
        "SCANSTUDIO_HW_MOTION", "SCANSTUDIO_BRIDGE_SOURCE", "SCANSTUDIO_BRIDGE_PYTHON",
        "SCANSTUDIO_BRIDGE_TRANSPORT", "SCANSTUDIO_BRIDGE_BASE_DIR"
    ]

    static func start() async throws -> EndToEndHost {
        let mode = ProcessInfo.processInfo.environment["HOST_MODE"] ?? "in-process"
        guard let kind = EndToEndHostKind(rawValue: mode) else {
            throw UnsupportedHostModeError(hostMode: mode)
        }
        let engineURL = try EngineLocator.locate()
        let root = URL(fileURLWithPath: "/tmp/ss-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("s.sock").path
        let original = ProcessInfo.processInfo.environment
        // The suite is serialized and runs alone. The in-process EngineClient
        // inherits these values; every CLI child also gets an explicit copy.
        for key in isolatedKeys { unsetenv(key) }
        setenv("HOME", root.path, 1)
        setenv("TMPDIR", root.path, 1)
        setenv("SCANSTUDIO_TIMESCALE", "0.1", 1)
        setenv("CFFIXED_USER_HOME", root.path, 1)
        var handle: SessionHost.Handle?
        var pid = getpid()
        do {
            if kind == .inProcess {
                handle = try await SessionHost.launch(
                    engineURL: engineURL, socketPath: socket,
                    diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
                    preferences: UserDefaults(suiteName: "dev.scanstudio.e2e.\(root.lastPathComponent)")!,
                    hostKind: .gui
                )
            } else {
                let result = try await runE2ECLI([
                    "host", "--detach", "--simulator", "--engine", engineURL.path,
                    "--log", root.appendingPathComponent("host.log").path
                ], socketPath: socket)
                #expect(result.exitCode == 0, Comment(rawValue: result.context))
                let envelope = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
                let body = try #require(envelope["result"] as? [String: Any])
                pid = try #require((body["hostPid"] as? NSNumber)?.int32Value)
            }
            let enginePids = try childEngines(of: pid)
            #expect(enginePids.count == 1, "expected exactly one engine under the host")
            let host = EndToEndHost(kind: kind, handle: handle, hostPid: pid, socketPath: socket, tempRoot: root, enginePids: enginePids, originalEnvironment: original)
            if let transcript = ProcessInfo.processInfo.environment["E2E_TRANSCRIPT"] {
                try appendE2ETranscript(["mode": kind.rawValue, "hostPid": Int(pid)], to: transcript)
            }
            let idle = try await host.waitForStatus { $0["mutatingOperationInFlight"] == nil || $0["mutatingOperationInFlight"] is NSNull }
            #expect(idle, "startup discovery did not settle")
            return host
        } catch {
            if let handle { await SessionHost.shutdown(handle) }
            if kind == .headless, pid > 1, pid != getpid() { kill(pid, SIGTERM) }
            restoreEnvironment(original)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func restoreEnvironment(_ original: [String: String]) {
        for key in isolatedKeys {
            if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    func stop() async {
        if let handle { await SessionHost.shutdown(handle) }
        else {
            _ = try? await runE2ECLI(["host", "stop"], socketPath: socketPath, timeoutSeconds: 15)
            if kill(hostPid, 0) == 0 { kill(hostPid, SIGKILL) }
        }
        for pid in enginePids {
            let deadline = ContinuousClock.now + .seconds(3)
            while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(kill(pid, 0) != 0, "host shutdown leaked engine pid \(pid)")
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        let suite = "dev.scanstudio.e2e.\(tempRoot.lastPathComponent)"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        Self.restoreEnvironment(originalEnvironment)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private static func childEngines(of pid: Int32) throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid), "-f", "scanstudio-engine"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }

    func assertSingleEngine() throws {
        #expect(try Self.childEngines(of: hostPid) == enginePids)
    }

    func status() async throws -> [String: Any] {
        let result = try await runE2ECLI(["status"], socketPath: socketPath)
        #expect(result.exitCode == 0, Comment(rawValue: result.context))
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        return try #require(envelope["result"] as? [String: Any])
    }

    func waitForStatus(_ predicate: ([String: Any]) -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(60)
        repeat {
            if predicate(try await status()) { return true }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return false
    }

    func waitUntilPreviewComplete() async -> Bool {
        (try? await waitForStatus { $0["previewComplete"] as? Bool == true }) ?? false
    }

    func waitUntilScanReady() async -> Bool {
        (try? await waitForStatus { $0["scanReadiness"] as? String == "ready" }) ?? false
    }

    func waitUntilJobSettled() async -> Bool {
        (try? await waitForStatus { $0["jobId"] == nil || $0["jobId"] is NSNull }) ?? false
    }

    func loadMedia(previewFixture: String? = nil, abortAtFrame: Int? = nil, abortCode: String? = nil) async throws {
        var args = ["sim", "load-media", "--carrier", "strip6"]
        if let previewFixture { args += ["--preview-fixture", previewFixture] }
        if let abortAtFrame { args += ["--abort-at-frame", String(abortAtFrame)] }
        if let abortCode { args += ["--abort-code", abortCode] }
        let result = try await runE2ECLI(args, socketPath: socketPath)
        #expect(result.exitCode == 0, Comment(rawValue: result.context))
        let body = try await status()
        let scanner = try #require(body["scanner"] as? [String: Any])
        #expect(scanner["mediaLoaded"] as? Bool == true)
    }
}

// MARK: - CLI subprocess runner

/// Resolves `.build/debug/scanstudio-cli` from this file's own source path
/// -- the identical three-hop, source-relative idiom
/// `ScanstudioCLIProcessTests.swift`'s `CLIProcessLocator` and
/// `ScanstudioCLIConfirmationTests.swift`'s `ConfirmationCLILocator` already
/// use (never an absolute developer path).
private enum EndToEndCLILocator {
    struct LocateError: Error, CustomStringConvertible {
        let description: String
    }

    static func resolve() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ControlSocketEndToEndTests.swift -> ScanStudioKitTests/
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

/// One acceptance step's outcome: exit status plus both streams, so a
/// failure message can show exactly what the subprocess printed rather than
/// a bare boolean (this plan's own requirement -- debugging a
/// fourteen-plus-step sequence from a pass/fail bit is not acceptable).
private struct E2EStepResult {
    let arguments: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var context: String {
        "step `scanstudio-cli \(arguments.joined(separator: " "))` exited \(exitCode)\n"
            + "stdout: \(stdout)\nstderr: \(stderr)"
    }
}

private func appendE2ETranscript(_ row: [String: Any], to path: String) throws {
    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    data.append(0x0a)
    if !FileManager.default.fileExists(atPath: path) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
    }
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: data)
}

/// Thrown when a CLI subprocess does not exit within `runE2ECLI`'s own
/// bound. Confirmed (via `sample` against a genuinely stuck run) as a real,
/// narrow race in the shipped `--wait` mechanism: `JobWaiter
/// .waitForTerminalOutcome` requires a terminal snapshot whose `jobId` is
/// both non-nil and different from the pre-start id, but `SessionModel`
/// can clear `jobId` back to `nil` in the same state transition that
/// reaches a terminal `jobState` -- if the `@Observable`-driven event
/// relay coalesces that transition into a single observed snapshot (more
/// likely the faster a simulated job completes, and worse under
/// scheduling pressure), the snapshot `JobWaiter` needed never arrives and
/// it waits forever. Not a bug this plan's `files_modified` could or
/// should fix (`JobWaiter.swift`, `SessionModel.swift`, and
/// `ControlChannelServer.swift`'s event relay are all out of scope here).
/// This plan's own constraint -- "every subprocess gets a bounded wait
/// then a kill on teardown" -- is what turns an occasional, indefinite
/// hang into a fast, diagnosable failure instead.
struct E2ESubprocessTimeoutError: Error, CustomStringConvertible {
    let arguments: [String]
    let timeoutSeconds: Double
    var description: String {
        "step `scanstudio-cli \(arguments.joined(separator: " "))` did not exit within "
            + "\(Int(timeoutSeconds))s -- killed. See this file's `runE2ECLI` doc comment."
    }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once even when two
/// independent callbacks (normal completion, timeout) race to resume it --
/// resuming twice is a fatal error, and this environment's own observed
/// timing makes that race real, not theoretical.
private final class SingleResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns `true` for the first caller (which must resume the
    /// continuation); `false` for every caller after (which must not).
    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Runs the real built binary with `arguments` plus `--socket socketPath`,
/// bounded by `timeoutSeconds`. The blocking `Process`/`Pipe` spawn/read/
/// wait sequence runs on a dedicated background queue via a continuation --
/// never inline on Swift's cooperative thread pool -- mirroring
/// `ScanstudioCLIProcessTests.swift`'s `runCLI` and the identical fix
/// `ScanstudioCLIConfirmationTests.swift`'s `runConfirmationCLI` needed for
/// the same thread-pool-starvation reason (both plans' own SUMMARY.md
/// deviations). A second, independent GCD timer races the same
/// continuation: if the subprocess has not exited by `timeoutSeconds`, it
/// is killed and `E2ESubprocessTimeoutError` is thrown instead of leaving
/// this suite (and `scripts/cli_attach_acceptance.sh`) hung indefinitely --
/// see `E2ESubprocessTimeoutError`'s own doc comment for why this is
/// necessary. 60s default: this environment's own real timings never
/// exceeded a few seconds per step even under load; this is a wide margin
/// for a shared machine, not a tight bound.
private func runE2ECLI(_ arguments: [String], socketPath: String, timeoutSeconds: Double = 60) async throws -> E2EStepResult {
    let binary = try EndToEndCLILocator.resolve()
    let allArguments = arguments + ["--socket", socketPath]
    let process = Process()
    process.executableURL = binary
    process.arguments = allArguments
    process.environment = ProcessInfo.processInfo.environment
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let resumeGuard = SingleResumeGuard()

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<E2EStepResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard resumeGuard.tryClaim() else { return }
                continuation.resume(returning: E2EStepResult(
                    arguments: arguments,
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
            continuation.resume(throwing: E2ESubprocessTimeoutError(arguments: arguments, timeoutSeconds: timeoutSeconds))
        }
    }
}

// MARK: - events --follow streaming reader

/// Thread-safe append-only line buffer, mirroring
/// `ScanstudioCLIConfirmationTests.swift`'s `ConfirmationLineBuffer` --
/// fed by a background reader thread, polled by predicate from the async
/// test side.
private final class E2ELineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Runs `scanstudio-cli events --follow` as a genuine subprocess, mirroring
/// `ScanstudioCLIConfirmationTests.swift`'s `ConfirmationEventsFollower`.
/// This suite's own coverage requirement is "bounded read then terminate":
/// wait for one line, assert its shape, `terminate()`.
private final class E2EEventsFollower: @unchecked Sendable {
    private let process: Process
    private let buffer = E2ELineBuffer()

    init(socketPath: String, commandArguments: [String] = ["events", "--follow"]) throws {
        let binary = try EndToEndCLILocator.resolve()
        let process = Process()
        process.executableURL = binary
        process.arguments = commandArguments + ["--socket", socketPath]
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
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[..<newlineIndex]
                    pending.removeSubrange(...newlineIndex)
                    if let line = String(data: lineData, encoding: .utf8) {
                        buffer.append(line)
                    }
                }
            }
        }

        try process.run()
    }

    /// Bounded real-sleep poll for the first collected line, per
    /// `ConfirmationEventsFollower.waitForLine`'s identical rationale: this
    /// buffer is fed by a genuinely separate OS thread reading a real
    /// subprocess's pipe, so a pure `Task.yield()` loop can spin through
    /// its whole budget without ever giving that thread a scheduling slice.
    @MainActor
    func waitForFirstLine() async -> [String: Any]? {
        await waitForLine { _ in true }
    }

    /// Bounded matching-line wait for commands whose first event is only a
    /// baseline. The same reader and timeout as `waitForFirstLine` keep the
    /// process test deterministic without adding another harness.
    @MainActor
    func waitForLine(where predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
        for _ in 0..<2_000 {
            for line in buffer.snapshot() {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   predicate(object) {
                    return object
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    /// Waits for the watcher process itself to observe the host-exit event
    /// and terminate with its distinct OPS exit code. A separate background
    /// waiter keeps the Swift cooperative pool free while `waitUntilExit()`
    /// reaps the real subprocess.
    func waitForExit(timeoutSeconds: Double = 15) async -> Int32? {
        if !process.isRunning { return process.terminationStatus }
        let process = self.process
        return await withCheckedContinuation { continuation in
            let guardBox = SingleResumeGuard()
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                guard guardBox.tryClaim() else { return }
                continuation.resume(returning: process.terminationStatus)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                guard guardBox.tryClaim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    func parsedLines() -> [[String: Any]] {
        buffer.snapshot().compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    /// Bounded wait then give up, mirroring `AppDelegate
    /// .applicationWillTerminate`'s own `DispatchSemaphore` + bounded
    /// `.wait(timeout:)` shape (this plan's own constraint: "every
    /// subprocess gets a bounded wait then a kill on teardown"). A plain
    /// `process.waitUntilExit()` here can block indefinitely -- confirmed
    /// via `sample` against a genuinely stuck run of this suite: `Process
    /// .terminate()` sends SIGTERM, but `waitUntilExit()`'s own reap can
    /// still hang past that signal under this environment's own process/
    /// pipe conditions. `process.terminate()` has already asked the
    /// subprocess to exit; this bound only prevents that from becoming an
    /// unbounded hang for the suite itself.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let finished = DispatchSemaphore(value: 0)
        let process = self.process
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 5)
    }
}

// MARK: - The acceptance sequence

// D-18 (plan 03-07 Task 3) added this suite's second `@Test`
// (`d18AutomationSurfaces`). `.serialized` is required, not cosmetic:
// `EndToEndHost.start()` (this file, above) calls `setenv("HOME", ...)`/
// `setenv("TMPDIR", ...)` -- process-wide mutable state, not thread- or
// test-local -- and restores the prior value in `stop()`. Swift Testing
// runs a suite's tests in parallel by default; two tests racing
// `EndToEndHost.start()`/`.stop()` concurrently could each spawn their own
// real engine subprocess under the OTHER test's `HOME`, silently
// corrupting both. This was previously safe only because exactly one
// `@Test` existed; verified here by observing the two tests visibly
// overlap in the test log (`started` for both before either `passed`)
// before this trait was added.
@Suite(
    "Control socket end to end",
    .enabled(if: ProcessInfo.processInfo.environment["SCANSTUDIO_CLI_E2E"] == "1"),
    .timeLimit(.minutes(10)),
    .serialized
)
@MainActor
struct ControlSocketEndToEndTests {
    @Test("""
    the real scanstudio-cli binary drives a real EngineClient against sim-ls5000-0 through a real \
    ControlChannelServer, exercising every documented command and both negative confirmation/host-\
    unreachable paths
    """)
    func fullAcceptanceSequence() async throws {
        let host = try await EndToEndHost.start()

        func step(_ arguments: [String]) async throws -> E2EStepResult {
            let result = try await runE2ECLI(arguments, socketPath: host.socketPath)
            if arguments.first == "resume" || Array(arguments.prefix(2)) == ["roll", "save"] {
                try await host.assertSingleEngine()
            }
            if let path = ProcessInfo.processInfo.environment["E2E_TRANSCRIPT"] {
                let body = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) ?? result.stdout
                let row: [String: Any] = ["args": arguments, "exit": result.exitCode, "stdout": body]
                try appendE2ETranscript(row, to: path)
            }
            return result
        }

        func resultObject(_ result: E2EStepResult) throws -> [String: Any] {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: result.context)
            )
            return try #require(object["result"] as? [String: Any], Comment(rawValue: result.context))
        }

        func errorObject(_ result: E2EStepResult) throws -> [String: Any] {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: result.context)
            )
            return try #require(object["error"] as? [String: Any], Comment(rawValue: result.context))
        }

        do {
            // -- Device enumeration guard (T-02-37): before any motion-
            // capable step, every enumerated device id must start with
            // "sim-", exactly as verify_mac_acceptance.py's Engine.connect()
            // asserts. `rescan` (not `scanner.list`, which has no Phase 2
            // subcommand) is this channel's device-discovery command.
            let rescanResult = try await step(["rescan"])
            #expect(rescanResult.exitCode == 0, Comment(rawValue: rescanResult.context))
            let rescanBody = try resultObject(rescanResult)
            let devices = try #require(rescanBody["devices"] as? [[String: Any]], Comment(rawValue: rescanResult.context))
            #expect(!devices.isEmpty, "rescan returned no devices")
            for device in devices {
                let deviceId = device["deviceId"] as? String ?? ""
                #expect(
                    deviceId.hasPrefix("sim-"),
                    "non-simulator device exposed to the acceptance run: \(deviceId)"
                )
            }
            #expect(
                devices.contains { ($0["deviceId"] as? String) == "sim-ls5000-0" },
                "sim-ls5000-0 was not among the enumerated devices: \(devices)"
            )

            // -- connect / status --
            let connectResult = try await step(["connect", "--device", "sim-ls5000-0"])
            #expect(connectResult.exitCode == 0, Comment(rawValue: connectResult.context))

            let statusResult = try await step(["status"])
            #expect(statusResult.exitCode == 0, Comment(rawValue: statusResult.context))
            let statusBody = try resultObject(statusResult)
            let connectedDevice = try #require(statusBody["device"] as? [String: Any], Comment(rawValue: statusResult.context))
            #expect(connectedDevice["deviceId"] as? String == "sim-ls5000-0")

            try await host.loadMedia()

            // -- preview --
            let previewResult = try await step(["preview", "--film-loaded"])
            #expect(previewResult.exitCode == 0, Comment(rawValue: previewResult.context))
            let previewBody = try resultObject(previewResult)
            #expect(previewBody["outcome"] as? String == "started", Comment(rawValue: previewResult.context))

            let previewCompleted = await host.waitUntilPreviewComplete()
            #expect(previewCompleted, "preview did not reach scanner.thumbnailsComplete within the bound")

            // -- frames select --all: CR-02's fix. `frames.select` lets a
            // pure CLI-only caller populate SessionModel.selectedFrameIndices
            // over the real socket, before any project exists -- see this
            // file's header comment (second finding, now closed) and
            // `ControlFramesSelectParams`'s own doc comment. Mirrors the
            // contact sheet's default Select All behaviour a real operator
            // gets for free from the GUI, reached here through the real CLI
            // subprocess and socket, not the host process's SessionModel
            // directly.
            let selectAllResult = try await step(["frames", "select", "--all"])
            #expect(selectAllResult.exitCode == 0, Comment(rawValue: selectAllResult.context))
            let selectedFrameCount = (try await host.status()["selectedFrames"] as? [Int])?.count ?? 0
            #expect(selectedFrameCount == 6, "frames select --all did not select all 6 previewed frames")

            // -- settings / outputs (read-only) --
            let settingsResult = try await step(["settings", "get"])
            #expect(settingsResult.exitCode == 0, Comment(rawValue: settingsResult.context))
            let settingsBody = try resultObject(settingsResult)
            #expect(settingsBody["capture"] is [String: Any])
            #expect(settingsBody["processing"] is [String: Any])

            let outputsResult = try await step(["outputs", "get"])
            #expect(outputsResult.exitCode == 0, Comment(rawValue: outputsResult.context))
            let outputsBody = try resultObject(outputsResult)
            #expect(outputsBody["outputs"] is [String: Any])

            // -- settings set --resolution 100: SessionModel's default
            // capture resolution is 4000 DPI (the real scanner's native
            // resolution) -- a real, CPU-bound full-resolution render, at a
            // cost `SCANSTUDIO_TIMESCALE` cannot touch (that only scales
            // simulated hardware motion delays, not actual image-buffer
            // generation). Found by running this suite against the real
            // engine: 36 frames at the default resolution never finished
            // frame 1 within a bounded wait. `verify_mac_acceptance.py`'s
            // own RECIPE already establishes 100 DPI as this repository's
            // sanctioned acceptance-testing resolution -- this suite
            // exercises `settings set` to reach the identical, already-
            // proven-fast configuration over the real channel instead of
            // hand-copying the constant. --
            let settingsSetResult = try await step(["settings", "set", "--resolution", "100"])
            #expect(settingsSetResult.exitCode == 0, Comment(rawValue: settingsSetResult.context))

            // -- roll save --confirm-motion: creates the project and starts
            // job A scanning all 6 selected frames (D-17c: save already
            // starts a scan). A 6-frame strip, not the 36-frame roll: this
            // suite already drives connect/preview/save/stop/re-preview/
            // resume/scan/eject/diagnostics/events through a real engine
            // subprocess, so keeping the actual capture count small keeps
            // the whole sequence's wall-clock time reasonable without
            // weakening what it proves -- coverage of every command, not
            // frame count, is the contract (see this file's header
            // comment). --
            let saveResult = try await step([
                "roll", "save",
                "--name", "e2e-roll",
                "--carrier", "strip6",
                "--frame-count", "6",
                "--film-process", "c41ColorNegative",
                "--confirm-motion"
            ])
            #expect(saveResult.exitCode == 0, Comment(rawValue: saveResult.context))
            let saveBody = try resultObject(saveResult)
            #expect(saveBody["saved"] as? Bool == true, Comment(rawValue: saveResult.context))
            #expect((saveBody["projectDirectory"] as? String)?.isEmpty == false, Comment(rawValue: saveResult.context))

            // -- status --job <id>: read the just-started job's id, then
            // its own aggregate, while it is still tracked. --
            let midJobStatus = try await step(["status"])
            #expect(midJobStatus.exitCode == 0, Comment(rawValue: midJobStatus.context))
            let midJobBody = try resultObject(midJobStatus)
            let jobId = try #require(midJobBody["jobId"] as? String, Comment(rawValue: midJobStatus.context))
            #expect(!jobId.isEmpty)

            let jobStatusResult = try await step(["status", "--job", jobId])
            #expect(jobStatusResult.exitCode == 0, Comment(rawValue: jobStatusResult.context))
            let jobStatusBody = try resultObject(jobStatusResult)
            #expect(jobStatusBody["jobId"] as? String == jobId, Comment(rawValue: jobStatusResult.context))

            // -- stop: request a stop after the current frame, then wait
            // for it to actually land before resume (which requires
            // jobId == nil) is asked to run. --
            let stopResult = try await step(["stop"])
            #expect(stopResult.exitCode == 0, Comment(rawValue: stopResult.context))
            let stopped = await host.waitUntilJobSettled()
            if !stopped {
                let status = try await host.status()
                Issue.record("stop did not settle: \(status)")
            }

            // -- frames list / exclude / include: only meaningful once a
            // project exists (see this file's header comment). --
            let framesListResult = try await step(["frames", "list"])
            #expect(framesListResult.exitCode == 0, Comment(rawValue: framesListResult.context))
            let framesListBody = try resultObject(framesListResult)
            let frames = try #require(framesListBody["frames"] as? [[String: Any]], Comment(rawValue: framesListResult.context))
            #expect(frames.count == 6, "expected 6 frames in the saved project, found \(frames.count)")

            let excludeResult = try await step(["frames", "exclude", "6"])
            #expect(excludeResult.exitCode == 0, Comment(rawValue: excludeResult.context))

            let includeResult = try await step(["frames", "include", "6"])
            #expect(includeResult.exitCode == 0, Comment(rawValue: includeResult.context))

            // -- roll list --
            let rollListResult = try await step(["roll", "list"])
            #expect(rollListResult.exitCode == 0, Comment(rawValue: rollListResult.context))
            let rollListBody = try resultObject(rollListResult)
            let projects = try #require(rollListBody["projects"] as? [[String: Any]], Comment(rawValue: rollListResult.context))
            #expect(!projects.isEmpty, "roll list returned no projects after roll save")

            // -- Re-preview after a stop: a third finding, discovered the
            // same way as the other two -- running this suite against the
            // real engine. `SessionModel`'s own scan-summary handler
            // deliberately clears `latestCompletedPreviewOperationId` when
            // a job's summary reports `stopped` ("never reuse interrupted
            // transport registration to authorize another run" -- the
            // handler's own comment), which is exactly the signal
            // `scanReadiness`'s `hasTargetPreviews` gate and `resumeBatch`'s
            // own guard both require. A stopped job therefore cannot be
            // resumed without a fresh preview in between -- a genuine
            // physical-safety property (re-verify transport state before
            // continuing an interrupted roll), not a bug this plan's
            // `files_modified` could or should change. This suite's
            // sequence re-previews here to match what the shipped code
            // actually requires. --
            let rePreviewResult = try await step(["preview", "--film-loaded", "--intent", "refreshSavedProject"])
            #expect(rePreviewResult.exitCode == 0, Comment(rawValue: rePreviewResult.context))
            let rePreviewBody = try resultObject(rePreviewResult)
            #expect(rePreviewBody["outcome"] as? String == "started", Comment(rawValue: rePreviewResult.context))
            let rePreviewCompleted = await host.waitUntilScanReady()
            #expect(rePreviewCompleted, "re-preview after stop did not restore scan readiness within the bound")

            // -- resume --confirm-motion --wait: drains whatever `stop`
            // left pending. Blocks on the real event stream -- no polling,
            // no synthetic events, this is the real engine. --
            let resumeResult = try await step(["resume", "--confirm-motion", "--wait"])
            #expect(resumeResult.exitCode == 0, Comment(rawValue: resumeResult.context))
            let resumeBody = try resultObject(resumeResult)
            #expect(resumeBody["jobState"] as? String == "completed", Comment(rawValue: resumeResult.context))

            // -- scan --confirm-motion --wait: a genuine re-scan of the
            // now-fully-receipted selection (D-17c's "re-scan" step). --
            let dryRun = try await step(["scan", "--dry-run"])
            #expect(dryRun.exitCode == 0, Comment(rawValue: dryRun.context))
            #expect(try resultObject(dryRun)["ready"] as? Bool == true)
            let registered = try await step(["wait", "--for", "registered", "--timeout", "1"])
            #expect(registered.exitCode == 0, Comment(rawValue: registered.context))
            let scanResult = try await step(["scan", "--confirm-motion", "--wait"])
            #expect(scanResult.exitCode == 0, Comment(rawValue: scanResult.context))
            let scanBody = try resultObject(scanResult)
            #expect(scanBody["jobState"] as? String == "completed", Comment(rawValue: scanResult.context))

            // Exercise the CLI repeat loop across real subprocess/socket boundaries.
            let projectDirectory = try #require(saveBody["projectDirectory"] as? String)
            let manifestURL = URL(fileURLWithPath: projectDirectory).appendingPathComponent("manifest.json")
            func retainedReceipts() throws -> [[String: Any]] {
                let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
                let frames = try #require(manifest["frames"] as? [[String: Any]])
                return frames.flatMap { $0["receipts"] as? [[String: Any]] ?? [] }
            }
            let beforeRepeat = try retainedReceipts()
            var originalFiles: [String: Data] = [:]
            for receipt in beforeRepeat {
                for value in (receipt["outputs"] as? [String: Any] ?? [:]).filter({ $0.key.hasSuffix("Path") }).values {
                    if let path = value as? String {
                        originalFiles[path] = try Data(contentsOf: URL(fileURLWithPath: path))
                    }
                }
            }
            let repeated = try await step(["scan", "--frames", "1", "--repeat", "2", "--pass", "Arep", "--confirm-motion", "--wait"])
            #expect(repeated.exitCode == 0, Comment(rawValue: repeated.context))
            let afterRepeat = try retainedReceipts()
            #expect(afterRepeat.count == beforeRepeat.count + 2)
            for original in beforeRepeat {
                #expect(afterRepeat.contains { NSDictionary(dictionary: $0).isEqual(to: original) })
            }
            let repetitions = afterRepeat.filter { ($0["passToken"] as? String)?.hasPrefix("Arep") == true }
            #expect(Set(repetitions.compactMap { $0["passToken"] as? String }) == ["Arep01", "Arep02"])
            #expect(Set(repetitions.compactMap { $0["jobId"] as? String }).count == 2)
            #expect(repetitions.allSatisfy { $0["frameIndex"] as? Int == 1 })
            for (path, bytes) in originalFiles {
                #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
            }

            let verified = try await step(["roll", "verify", "--pass", "Arep01"])
            #expect(verified.exitCode == 0, Comment(rawValue: verified.context))
            #expect(try resultObject(verified)["status"] as? String == "pass")
            let simulatedClipping = try await step(["roll", "verify", "--pass", "Arep01", "--no-clipping"])
            #expect(simulatedClipping.exitCode == 65, Comment(rawValue: simulatedClipping.context))
            #expect(try resultObject(simulatedClipping)["status"] as? String == "unknown")

            let slotMapURL = host.tempRoot.appendingPathComponent("slot-map.json")
            try Data(#"{"1":1}"#.utf8).write(to: slotMapURL)
            let collectionURL = host.tempRoot.appendingPathComponent("calibration-export")
            let collectArguments = ["roll", "collect", "--to", collectionURL.path, "--stock", "sim-test", "--pass", "Arep01", "--slot-map", slotMapURL.path]
            let collected = try await step(collectArguments)
            #expect(collected.exitCode == 0, Comment(rawValue: collected.context))
            #expect(FileManager.default.fileExists(atPath: collectionURL.appendingPathComponent("file-hashes.txt").path))
            #expect(FileManager.default.fileExists(atPath: collectionURL.appendingPathComponent("sim-test_01_Arep01-receipt.json").path))
            let collision = try await step(collectArguments)
            #expect(collision.exitCode == 64, Comment(rawValue: collision.context))
            for (path, bytes) in originalFiles {
                #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
            }

            // -- eject --confirm-motion --
            let ejectResult = try await step(["eject", "--confirm-motion"])
            #expect(ejectResult.exitCode == 0, Comment(rawValue: ejectResult.context))

            // -- diagnostics export --to <temp dir> --
            let diagnosticsDirectory = host.tempRoot.appendingPathComponent("diag-export", isDirectory: true)
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            let diagnosticsResult = try await step(["diagnostics", "export", "--to", diagnosticsDirectory.path])
            #expect(diagnosticsResult.exitCode == 0, Comment(rawValue: diagnosticsResult.context))
            let diagnosticsBody = try resultObject(diagnosticsResult)
            #expect((diagnosticsBody["path"] as? String)?.isEmpty == false, Comment(rawValue: diagnosticsResult.context))
            #expect(diagnosticsBody["entries"] is [Any], Comment(rawValue: diagnosticsResult.context))

            // -- events --follow: bounded read then terminate. --
            let follower = try E2EEventsFollower(socketPath: host.socketPath)
            let firstLine = await follower.waitForFirstLine()
            follower.terminate()
            let firstLineObject = try #require(firstLine, "events --follow produced no first line within the bound")
            #expect(firstLineObject["schemaVersion"] as? Int == ControlSchema.version)
            #expect(firstLineObject["command"] as? String == "events")
            let followedEvent = try #require(firstLineObject["event"] as? [String: Any])
            #expect(followedEvent["event"] as? String == "control.snapshot")

            // -- Negative path 1: a motion command run without its
            // confirmation flag exits 77 with CONFIRMATION_REQUIRED, before
            // any connection to this same reachable host. --
            let unconfirmedResult = try await step(["preview"])
            #expect(unconfirmedResult.exitCode == 77, Comment(rawValue: unconfirmedResult.context))
            let unconfirmedError = try errorObject(unconfirmedResult)
            #expect(unconfirmedError["code"] as? String == "CONFIRMATION_REQUIRED", Comment(rawValue: unconfirmedResult.context))

            // -- Negative path 2: any command against a dead socket exits
            // 69 with HOST_UNREACHABLE. --
            let deadSocketPath = host.tempRoot.appendingPathComponent("dead.sock").path
            let unreachableResult = try await runE2ECLI(["status"], socketPath: deadSocketPath)
            #expect(unreachableResult.exitCode == 69, Comment(rawValue: unreachableResult.context))
            let unreachableError = try errorObject(unreachableResult)
            #expect(unreachableError["code"] as? String == "HOST_UNREACHABLE", Comment(rawValue: unreachableResult.context))
        } catch {
            await host.stop()
            throw error
        }

        await host.stop()
    }

    @Test("CLI creates a calibration roll without a scanner connection or motion confirmation")
    func calibrationBootstrapWithoutScan() async throws {
        let host = try await EndToEndHost.start()
        let watcher = try E2EEventsFollower(
            socketPath: host.socketPath,
            commandArguments: ["status", "--watch", "--attach"]
        )
        do {
            let baseline = await watcher.waitForFirstLine()
            let baselineObject = try #require(baseline, "status --watch produced no baseline within the bound")
            #expect(baselineObject["command"] as? String == "status")
            let baselineEvent = try #require(baselineObject["event"] as? [String: Any])
            #expect(baselineEvent["event"] as? String == "control.snapshot")

            let saved = try await runE2ECLI([
                "roll", "save", "--name", "calibration-bootstrap", "--carrier", "strip6",
                "--frame-count", "6", "--film-process", "c41ColorNegative", "--no-scan"
            ], socketPath: host.socketPath)
            #expect(saved.exitCode == 0, Comment(rawValue: saved.context))
            let body = try #require(JSONSerialization.jsonObject(with: Data(saved.stdout.utf8)) as? [String: Any])
            let result = try #require(body["result"] as? [String: Any])
            #expect(result["outcome"] as? String == "saved")
            #expect(result["saved"] as? Bool == true)
            let directory = try #require(result["projectDirectory"] as? String)
            #expect(FileManager.default.fileExists(atPath: directory))
            let changed = await watcher.waitForLine { object in
                guard let event = object["event"] as? [String: Any],
                      event["event"] as? String == "control.changed",
                      let payload = event["payload"] as? [String: Any]
                else { return false }
                return payload["projectDirectory"] as? String == directory
            }
            #expect(changed != nil, "status --watch did not report the saved project identity")

            let status = try await runE2ECLI(["status"], socketPath: host.socketPath)
            #expect(status.exitCode == 0, Comment(rawValue: status.context))
            let statusBody = try #require(JSONSerialization.jsonObject(with: Data(status.stdout.utf8)) as? [String: Any])
            let state = try #require(statusBody["result"] as? [String: Any])
            #expect(state["jobId"] == nil || state["jobId"] is NSNull)
            #expect(state["device"] == nil || state["device"] is NSNull)
            #expect(state["previewComplete"] as? Bool == false)

            let dryRun = try await runE2ECLI(["scan", "--dry-run"], socketPath: host.socketPath)
            #expect(dryRun.exitCode == 65, Comment(rawValue: dryRun.context))
            let dryRunEnvelope = try #require(
                JSONSerialization.jsonObject(with: Data(dryRun.stdout.utf8)) as? [String: Any]
            )
            let dryRunResult = try #require(dryRunEnvelope["result"] as? [String: Any])
            #expect(dryRunResult["ready"] as? Bool == false)
            let stateAfterDryRun = try await host.status()
            #expect(stateAfterDryRun["jobId"] == nil || stateAfterDryRun["jobId"] is NSNull)
            #expect(stateAfterDryRun["device"] == nil || stateAfterDryRun["device"] is NSNull)
            #expect(stateAfterDryRun["previewComplete"] as? Bool == false)

            let linkHealth = try await runE2ECLI(["link", "health"], socketPath: host.socketPath)
            #expect(linkHealth.exitCode == 0, Comment(rawValue: linkHealth.context))
            let linkEnvelope = try #require(
                JSONSerialization.jsonObject(with: Data(linkHealth.stdout.utf8)) as? [String: Any]
            )
            let linkResult = try #require(linkEnvelope["result"] as? [String: Any])
            #expect(linkResult["status"] as? String == "unknown")

            let sessionArchive = host.tempRoot.appendingPathComponent("session-evidence.zip")
            let exported = try await runE2ECLI(
                ["session", "export", "--to", sessionArchive.path],
                socketPath: host.socketPath
            )
            #expect(exported.exitCode == 0, Comment(rawValue: exported.context))
            let exportEnvelope = try #require(
                JSONSerialization.jsonObject(with: Data(exported.stdout.utf8)) as? [String: Any]
            )
            let exportResult = try #require(exportEnvelope["result"] as? [String: Any])
            #expect(exportResult["path"] as? String == sessionArchive.path)
            #expect(exportResult["includedEntryCount"] as? Int == 2)
            #expect(exportResult["missingEntryCount"] as? Int == 2)
            let archiveBytes = try Data(contentsOf: sessionArchive)
            #expect(archiveBytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))
            #expect(archiveBytes.range(of: Data("manifest.json".utf8)) != nil)
            #expect(archiveBytes.range(of: Data("diagnostics.jsonl".utf8)) != nil)
            #expect(archiveBytes.range(of: Data("control-transcript.ndjson".utf8)) != nil)

            await host.stop()
            let watcherExit = await watcher.waitForExit()
            #expect(watcherExit == 76, "status --watch exited (String(describing: watcherExit)), expected host-exit 76")
            let hostExitEvents = watcher.parsedLines().filter { object in
                guard let event = object["event"] as? [String: Any] else { return false }
                return event["event"] as? String == "control.hostExited"
            }
            #expect(hostExitEvents.count == 1, "expected exactly one control.hostExited event")
        } catch {
            watcher.terminate()
            await host.stop()
            throw error
        }
        watcher.terminate()
        await host.stop()
    }

    // MARK: - D-18 automation surfaces (plan 03-07 Task 3)
    //
    // A second `@Test` sharing this suite's own `EndToEndHost`/`runE2ECLI`
    // harness, rather than extending `fullAcceptanceSequence` above --
    // that sequence's own timing and its six documented deviations stay
    // completely untouched. `resultObject`/`errorObject` are duplicated
    // here (not extracted to file scope) for the same reason: zero risk of
    // perturbing the existing, already-green sequence.
    //
    // Each of the seven D-18 surfaces below is proven against a *fresh*
    // `EndToEndHost`/project where the surface needs one (a project, once
    // created by `roll.save`/`roll run`, cannot be replaced on the same
    // session -- `GATE_REFUSED` -- so three hosts run in sequence rather
    // than one). All three use `.strip6` (6 frames) so the `boundaryAndBlank`
    // fixture's own "second-to-last flagged, last blank" positions land on
    // frames 5 and 6 exactly as plan 03-07 Task 2's own tests pin.
    @Test("""
    D-18: status --refresh, pre-project blankConfidence, frames select --skip-blank, a paused manual \
    review's contentConfidence, roll save --auto-approve, and roll run's own receipt/progress/ETA -- \
    all against sim-ls5000-0 with the boundaryAndBlank simulator fixture armed
    """)
    func d18AutomationSurfaces() async throws {
        func envelopeObject(_ result: E2EStepResult) throws -> [String: Any] {
            try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: result.context)
            )
        }
        func resultObject(_ result: E2EStepResult) throws -> [String: Any] {
            try #require(try envelopeObject(result)["result"] as? [String: Any], Comment(rawValue: result.context))
        }

        func armBoundaryAndBlankFixture(on host: EndToEndHost) async throws {
            try await host.loadMedia(previewFixture: "boundaryAndBlank")
        }

        // ---- Host A: status --refresh, pre-project blankConfidence,
        // skip-blank, and a paused (not auto-approved) manual review ----
        let hostA = try await EndToEndHost.start()
        func stepA(_ arguments: [String]) async throws -> E2EStepResult {
            try await runE2ECLI(arguments, socketPath: hostA.socketPath)
        }
        do {
            let connectResult = try await stepA(["connect", "--device", "sim-ls5000-0"])
            #expect(connectResult.exitCode == 0, Comment(rawValue: connectResult.context))

            try await armBoundaryAndBlankFixture(on: hostA)

            // -- Surface 1: status --refresh succeeds and carries `scanner`. --
            let refreshResult = try await stepA(["status", "--refresh"])
            #expect(refreshResult.exitCode == 0, Comment(rawValue: refreshResult.context))
            let refreshBody = try resultObject(refreshResult)
            #expect(refreshBody["scanner"] is [String: Any], Comment(rawValue: refreshResult.context))

            let previewResult = try await stepA(["preview", "--film-loaded"])
            #expect(previewResult.exitCode == 0, Comment(rawValue: previewResult.context))
            let previewCompleted = await hostA.waitUntilPreviewComplete()
            #expect(previewCompleted, "preview did not reach scanner.thumbnailsComplete within the bound")

            // -- Surface 2: pre-project frames list carries a decodable
            // raster for every frame now that Task 2's fixture is armed --
            // hasThumbnail true and a non-null blankConfidence throughout. --
            let framesListResult = try await stepA(["frames", "list"])
            #expect(framesListResult.exitCode == 0, Comment(rawValue: framesListResult.context))
            let framesListBody = try resultObject(framesListResult)
            let frames = try #require(framesListBody["frames"] as? [[String: Any]], Comment(rawValue: framesListResult.context))
            #expect(frames.count == 6, "expected 6 previewed frames, found \(frames.count)")
            for frame in frames {
                let index = frame["index"] as? Int ?? -1
                #expect(frame["hasThumbnail"] as? Bool == true, "frame \(index) missing hasThumbnail")
                #expect(frame["blankConfidence"] != nil, "frame \(index) missing blankConfidence")
            }

            // -- Surface 3: frames select --skip-blank skips the blank
            // fixture frame (6) but keeps the flagged-yet-textured frame
            // (5) -- blank-skipping and manual-review-flagging are
            // independent signals. --
            let skipBlankResult = try await stepA(["frames", "select", "--skip-blank"])
            #expect(skipBlankResult.exitCode == 0, Comment(rawValue: skipBlankResult.context))
            // `skipped` is merged onto the already-rendered envelope
            // (`FrameCommands.swift`'s own `mergeSkippedIntoRenderedOutput`),
            // so it is a top-level sibling of `result`, not nested inside it.
            let skipBlankEnvelope = try envelopeObject(skipBlankResult)
            let skipped = try #require(skipBlankEnvelope["skipped"] as? [[String: Any]], Comment(rawValue: skipBlankResult.context))
            let skippedIndices = Set(skipped.compactMap { $0["index"] as? Int })
            #expect(skippedIndices.contains(6), "the blank fixture frame (6) should have been skipped")
            #expect(!skippedIndices.contains(5), "the flagged-but-textured frame (5) must not be skipped as blank")

            // -- Surface 4: roll save (no --auto-approve) under the fixture
            // pauses at manualReviewPending, and a following status names
            // the flagged frame with a numeric contentConfidence. --
            let saveResult = try await stepA([
                "roll", "save", "--name", "d18-review-pending", "--carrier", "strip6",
                "--frame-count", "6", "--film-process", "c41ColorNegative", "--confirm-motion"
            ])
            #expect(saveResult.exitCode == 0, Comment(rawValue: saveResult.context))
            let saveBody = try resultObject(saveResult)
            #expect(saveBody["outcome"] as? String == "manualReviewPending", Comment(rawValue: saveResult.context))

            let statusAfterSaveResult = try await stepA(["status"])
            #expect(statusAfterSaveResult.exitCode == 0, Comment(rawValue: statusAfterSaveResult.context))
            let statusAfterSaveBody = try resultObject(statusAfterSaveResult)
            let manualReviewPending = try #require(
                statusAfterSaveBody["manualReviewPending"] as? [String: Any],
                Comment(rawValue: statusAfterSaveResult.context)
            )
            let pendingFrames = try #require(manualReviewPending["frames"] as? [[String: Any]], Comment(rawValue: statusAfterSaveResult.context))
            let flaggedFrame = try #require(
                pendingFrames.first { ($0["index"] as? Int) == 5 },
                "frame 5 must be the one named by manualReviewPending: \(pendingFrames)"
            )
            let contentConfidence = flaggedFrame["contentConfidence"]
            #expect(
                (contentConfidence as? Double) != nil || (contentConfidence as? Int) != nil,
                "contentConfidence must be a number, got \(String(describing: contentConfidence))"
            )
        } catch {
            await hostA.stop()
            throw error
        }
        await hostA.stop()

        // ---- Host B: roll save --auto-approve resolves the same pending
        // review, and --auto-approve without --confirm-motion refuses
        // client-side ----
        let hostB = try await EndToEndHost.start()
        func stepB(_ arguments: [String]) async throws -> E2EStepResult {
            try await runE2ECLI(arguments, socketPath: hostB.socketPath)
        }
        do {
            let connectResult = try await stepB(["connect", "--device", "sim-ls5000-0"])
            #expect(connectResult.exitCode == 0, Comment(rawValue: connectResult.context))
            try await armBoundaryAndBlankFixture(on: hostB)

            let previewResult = try await stepB(["preview", "--film-loaded"])
            #expect(previewResult.exitCode == 0, Comment(rawValue: previewResult.context))
            let previewCompleted = await hostB.waitUntilPreviewComplete()
            #expect(previewCompleted, "preview did not reach scanner.thumbnailsComplete within the bound")

            let selectAllResult = try await stepB(["frames", "select", "--all"])
            #expect(selectAllResult.exitCode == 0, Comment(rawValue: selectAllResult.context))

            // -- Surface 5b: --auto-approve without --confirm-motion exits
            // 77 before any connection -- the host's own stub/request count
            // is unreachable from this harness, so the exit code and the
            // fact this same host is reused successfully right after are
            // the proof no connection was consumed. --
            let noConfirmResult = try await stepB([
                "roll", "save", "--auto-approve",
                "--name", "d18-should-not-save", "--carrier", "strip6",
                "--frame-count", "6", "--film-process", "c41ColorNegative"
            ])
            #expect(noConfirmResult.exitCode == 77, Comment(rawValue: noConfirmResult.context))

            // -- Surface 5a: roll save --auto-approve --confirm-motion
            // resolves the pending review (frame 5's own contentConfidence
            // is high -- it is a Textured, not Blank, fixture tile). --
            let saveAutoApproveResult = try await stepB([
                "roll", "save", "--auto-approve", "--confirm-motion",
                "--name", "d18-auto-approve", "--carrier", "strip6",
                "--frame-count", "6", "--film-process", "c41ColorNegative"
            ])
            #expect(saveAutoApproveResult.exitCode == 0, Comment(rawValue: saveAutoApproveResult.context))
            let saveAutoApproveBody = try resultObject(saveAutoApproveResult)
            let autoApproved = try #require(saveAutoApproveBody["autoApproved"] as? [Int], Comment(rawValue: saveAutoApproveResult.context))
            #expect(!autoApproved.isEmpty, "auto-approve should have resolved the pending review")
            #expect(autoApproved.contains(5))
        } catch {
            await hostB.stop()
            throw error
        }
        await hostB.stop()

        // ---- Host C: roll run's own receipt, terminal jobState, on-disk
        // copy, manifest non-interference, and measured progress/ETA ----
        let hostC = try await EndToEndHost.start()
        func stepC(_ arguments: [String]) async throws -> E2EStepResult {
            try await runE2ECLI(arguments, socketPath: hostC.socketPath)
        }
        do {
            let connectResult = try await stepC(["connect", "--device", "sim-ls5000-0"])
            #expect(connectResult.exitCode == 0, Comment(rawValue: connectResult.context))
            try await armBoundaryAndBlankFixture(on: hostC)

            // Matches fullAcceptanceSequence's own documented finding:
            // SessionModel's default 4000 DPI capture is too slow for a
            // bounded wait; 100 DPI is this repository's own sanctioned
            // acceptance-testing resolution.
            let settingsSetResult = try await stepC(["settings", "set", "--resolution", "100"])
            #expect(settingsSetResult.exitCode == 0, Comment(rawValue: settingsSetResult.context))

            // roll run performs its own preview/select/save internally --
            // no separate preview/select/save steps precede it. --frame-
            // count is deliberately omitted so this run also exercises
            // D-15's own scanner-reported default.
            let runResult = try await stepC([
                "roll", "run",
                "--name", "d18-roll-run",
                "--carrier", "strip6",
                "--film-process", "c41ColorNegative",
                "--film-loaded", "--confirm-motion",
                "--skip-blank", "--auto-approve", "--wait"
            ])
            #expect(runResult.exitCode == 0, Comment(rawValue: runResult.context))
            let runBody = try resultObject(runResult)

            // -- Surface 6a: the receipt's steps array names every step in
            // D-15's order. --
            let steps = try #require(runBody["steps"] as? [[String: Any]], Comment(rawValue: runResult.context))
            let stepNames = steps.compactMap { $0["step"] as? String }
            for expectedStep in [
                "refresh", "status", "preview", "previewComplete",
                "framesList", "framesSelect", "rollSave", "reviewStatus", "reviewApprove", "wait"
            ] {
                #expect(stepNames.contains(expectedStep), "roll run's receipt is missing step \"\(expectedStep)\": \(stepNames)")
            }
            #expect(steps.allSatisfy { ($0["outcome"] as? String) == "ok" }, "every step of a fully-successful roll run must be recorded \"ok\": \(steps)")

            // -- Surface 6b: terminal jobState. --
            #expect(runBody["jobState"] as? String == "completed", Comment(rawValue: runResult.context))

            // -- Surface 6c: the on-disk receipt exists and parses as the
            // same object printed on stdout. --
            let projectDirectory = try #require(
                (runBody["project"] as? [String: Any])?["directory"] as? String,
                Comment(rawValue: runResult.context)
            )
            let receiptPath = try #require(runBody["receiptPath"] as? String, Comment(rawValue: runResult.context))
            #expect(FileManager.default.fileExists(atPath: receiptPath), "receiptPath \(receiptPath) does not exist")
            #expect(
                URL(fileURLWithPath: receiptPath).lastPathComponent.hasPrefix("cli-run-"),
                "receiptPath's filename must match the documented cli-run-<timestamp>.json pattern, got \(receiptPath)"
            )
            let receiptFromDisk = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: receiptPath))) as? [String: Any]
            )
            // The on-disk copy cannot self-reference the very path it is
            // being written to -- receiptPath is populated on the in-memory
            // receipt only after write(toProjectDirectory:) already
            // returned that path, so it is the one field the two are
            // expected to differ on; every other field must match exactly.
            var runBodyWithoutReceiptPath = runBody
            runBodyWithoutReceiptPath.removeValue(forKey: "receiptPath")
            #expect(
                NSDictionary(dictionary: receiptFromDisk) == NSDictionary(dictionary: runBodyWithoutReceiptPath),
                "the on-disk receipt must parse as the same object printed on stdout (aside from receiptPath)"
            )

            // -- Surface 6d: manifest.json is never touched by the receipt
            // write. RollRunReceiptTests.swift's own writeLandsBesideThe-
            // Manifest already proves this for the pure write function in
            // isolation; this proves it holds end to end, through the real
            // socket and CLI. --
            let manifestURL = URL(fileURLWithPath: projectDirectory).appendingPathComponent("manifest.json")
            let mtimeAfterRun = try #require(
                FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
            )
            try await Task.sleep(nanoseconds: 300_000_000)
            let mtimeAfterSettling = try #require(
                FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
            )
            #expect(mtimeAfterRun == mtimeAfterSettling, "manifest.json must not be touched after roll run completes")

            // -- Surface 7: a --wait run without --quiet produced at least
            // one progress line on stderr, in the documented shape, while
            // stdout parsed as exactly one JSON object (already proven by
            // resultObject(runResult) above, which requires exactly one
            // top-level JSON object). --
            #expect(
                runResult.stderr.range(of: #"frame \d+/\d+ pass \d+/\d+ eta \S+"#, options: .regularExpression) != nil,
                "expected at least one \"frame N/M pass P/Q eta ...\" line on stderr, got: \(runResult.stderr)"
            )

            // -- Surface 7: a completed job still reports a numeric
            // etaSeconds. Plain `status`, not `status --job <id>`: the
            // documented CR-01 behavior (SessionModel.applyCompleted
            // clears jobId in the same update that reaches the terminal
            // jobState) means runBody["jobId"] is already nil by the time
            // this receipt was built -- confirmed empirically running this
            // very test -- so `--job <id>`'s own `jobResult.jobId == job`
            // comparison has no id left to match. `progress` (unlike
            // jobId) is never reset on completion, so it still carries the
            // job's own last measured value; plain `status` reads it from
            // the identical source `job.get` would. --
            #expect(runBody["jobId"] == nil, "documenting the known CR-01 jobId-clears-on-completion behavior this assertion works around")
            let plainStatusResult = try await stepC(["status"])
            #expect(plainStatusResult.exitCode == 0, Comment(rawValue: plainStatusResult.context))
            let plainStatusBody = try resultObject(plainStatusResult)
            let jobProgress = try #require(plainStatusBody["progress"] as? [String: Any], Comment(rawValue: plainStatusResult.context))
            let etaSeconds = jobProgress["etaSeconds"]
            #expect(
                (etaSeconds as? Double) != nil || (etaSeconds as? Int) != nil,
                "etaSeconds must be a measured number, got \(String(describing: etaSeconds))"
            )
        } catch {
            await hostC.stop()
            throw error
        }
        await hostC.stop()
    }

    // D-19..D-24 (HEAD-12, plan 03-08 Task 4): the 2026-09-07 real-hardware
    // batch abort, replayed against sim-ls5000-0 and recovered from through
    // the CLI alone -- a third `@Test` sharing this suite's own
    // `EndToEndHost`/`runE2ECLI`/`.serialized` trait, named separately so a
    // failure here never hides inside `fullAcceptanceSequence`'s own name.
    @Test("""
    D-19..D-24: a simulated batch abort on sim-ls5000-0 is attributed to the frame that raised it \
    (never INTERNAL), leaves every later frame notAttempted, and is recovered from through the CLI \
    alone -- excluding the failed frame without reopening the roll, resuming the rest, and a \
    partial-application frames exclude report -- with no GUI and no hardware.
    """)
    func aBatchAbortIsAttributedAndRecoverableThroughTheCLIAlone() async throws {
        let host = try await EndToEndHost.start()

        func step(_ arguments: [String]) async throws -> E2EStepResult {
            try await runE2ECLI(arguments, socketPath: host.socketPath)
        }
        func envelopeObject(_ result: E2EStepResult) throws -> [String: Any] {
            try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: result.context)
            )
        }
        func resultObject(_ result: E2EStepResult) throws -> [String: Any] {
            try #require(try envelopeObject(result)["result"] as? [String: Any], Comment(rawValue: result.context))
        }
        func errorObject(_ result: E2EStepResult) throws -> [String: Any] {
            try #require(try envelopeObject(result)["error"] as? [String: Any], Comment(rawValue: result.context))
        }

        do {
            // -- Device enumeration guard (T-02-37), copied from
            // fullAcceptanceSequence: every enumerated deviceId is sim-
            // before any motion-capable step. --
            let rescanResult = try await step(["rescan"])
            #expect(rescanResult.exitCode == 0, Comment(rawValue: rescanResult.context))
            let rescanBody = try resultObject(rescanResult)
            let devices = try #require(rescanBody["devices"] as? [[String: Any]], Comment(rawValue: rescanResult.context))
            for device in devices {
                let deviceId = device["deviceId"] as? String ?? ""
                #expect(deviceId.hasPrefix("sim-"), "non-simulator device exposed to the acceptance run: \(deviceId)")
            }

            let connectResult = try await step(["connect", "--device", "sim-ls5000-0"])
            #expect(connectResult.exitCode == 0, Comment(rawValue: connectResult.context))

            let settingsSetResult = try await step(["settings", "set", "--resolution", "100"])
            #expect(settingsSetResult.exitCode == 0, Comment(rawValue: settingsSetResult.context))

            // Arms the abort at frame 3 with the exact bridge code the
            // 2026-09-07 incident itself raised.
            try await host.loadMedia(abortAtFrame: 3, abortCode: "ROLL_MISMATCH")

            let previewResult = try await step(["preview", "--film-loaded"])
            #expect(previewResult.exitCode == 0, Comment(rawValue: previewResult.context))
            let previewCompleted = await host.waitUntilPreviewComplete()
            #expect(previewCompleted, "preview did not reach scanner.thumbnailsComplete within the bound")

            // -- D-21: select 1-4, deliberately leaving 5-6 unselected, so
            // `roll save` persists them as exclusions at creation time. --
            let selectResult = try await step(["frames", "select", "1-4"])
            #expect(selectResult.exitCode == 0, Comment(rawValue: selectResult.context))

            // `roll save ... --wait` on a batch that ends failed exits 65
            // (documented in CONTROL.md's own Exit codes section) -- the
            // printed result is still the job's own terminal snapshot,
            // `MotionStartRunner`'s shared `--wait` tail for `scan`/
            // `resume`/`roll save` alike.
            let saveResult = try await step([
                "roll", "save", "--name", "batch-abort-e2e", "--carrier", "strip6",
                "--frame-count", "6", "--film-process", "c41ColorNegative", "--confirm-motion", "--wait"
            ])
            #expect(saveResult.exitCode == 65, Comment(rawValue: saveResult.context))
            let saveBody = try resultObject(saveResult)
            #expect(saveBody["jobState"] as? String == "failed", Comment(rawValue: saveResult.context))
            // Documented CR-01 behavior (see d18AutomationSurfaces's own
            // comment): SessionModel.applyCompleted clears jobId in the
            // same update that reaches the terminal jobState, so this
            // bare (no explicit jobId) snapshot's own top-level jobId is
            // already absent by the time it was captured -- `progress`,
            // unlike jobId, is never reset on completion, so the id
            // survives there. The detailed D-19 checks (notAttemptedFrames,
            // finishedAt) belong on the explicit `status --job <id>` call
            // below, not this bare snapshot -- an absent/null jobId keeps
            // job.get's historical "currently tracked job" shape
            // byte-for-byte (D-19's own documented contract).
            let saveProgress = try #require(saveBody["progress"] as? [String: Any], Comment(rawValue: saveResult.context))
            let firstJobId = try #require(saveProgress["jobId"] as? String, Comment(rawValue: saveResult.context))

            // The save --wait response can observe the job's terminal state
            // before the per-frame projection has published its terminal
            // error. Wait for the job-specific terminal snapshot carrying
            // the attributed frame code before reading frames/list.
            var frame3FailurePublished = false
            for _ in 0..<200 {
                let pollResult = try await step(["status", "--job", firstJobId])
                #expect(pollResult.exitCode == 0, Comment(rawValue: pollResult.context))
                let pollBody = try resultObject(pollResult)
                let frameErrorCodes = pollBody["frameErrorCodes"] as? [String: String]
                if pollBody["jobState"] as? String == "failed",
                   frameErrorCodes?["3"] == "ROLL_MISMATCH" {
                    frame3FailurePublished = true
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(frame3FailurePublished, "the failed job must publish frame 3's attributed terminal error")

            // -- D-20: frames list names the armed frame's real cause,
            // never INTERNAL, and every later frame is notAttempted with
            // no error. --
            let framesListResult = try await step(["frames", "list"])
            #expect(framesListResult.exitCode == 0, Comment(rawValue: framesListResult.context))
            let framesListBody = try resultObject(framesListResult)
            let frames = try #require(framesListBody["frames"] as? [[String: Any]], Comment(rawValue: framesListResult.context))
            let frame3 = try #require(frames.first { ($0["index"] as? Int) == 3 }, "frame 3 missing: \(frames)")
            #expect(frame3["state"] as? String == "failed")
            #expect(frame3["errorCode"] as? String == "ROLL_MISMATCH", "frame 3's own cause must never flatten to INTERNAL: \(frame3)")
            let frame3Message = try #require(frame3["errorMessage"] as? String, "frame 3 missing errorMessage: \(frame3)")
            #expect(frame3Message.contains("ROLL_MISMATCH"))
            let frame4 = try #require(frames.first { ($0["index"] as? Int) == 4 }, "frame 4 missing: \(frames)")
            #expect(frame4["state"] as? String == "notAttempted")
            #expect(frame4["errorCode"] == nil, "a notAttempted frame must carry no error: \(frame4)")
            for excludedIndex in [5, 6] {
                let excludedFrame = try #require(
                    frames.first { ($0["index"] as? Int) == excludedIndex }, "frame \(excludedIndex) missing: \(frames)"
                )
                #expect(
                    excludedFrame["excluded"] as? Bool == true,
                    "frame \(excludedIndex) was never selected before roll save and must be excluded (D-21): \(excludedFrame)"
                )
            }

            // -- status.lastErrorMessage carries the bridge's own text, and
            // pendingFrames omits the frames the operator never selected
            // (D-21). --
            let statusResult = try await step(["status"])
            #expect(statusResult.exitCode == 0, Comment(rawValue: statusResult.context))
            let statusBody = try resultObject(statusResult)
            let lastErrorMessage = try #require(statusBody["lastErrorMessage"] as? String, Comment(rawValue: statusResult.context))
            #expect(lastErrorMessage.contains("ROLL_MISMATCH"))
            let pendingFramesAfterAbort = try #require(statusBody["pendingFrames"] as? [Int], Comment(rawValue: statusResult.context))
            #expect(
                !pendingFramesAfterAbort.contains(5) && !pendingFramesAfterAbort.contains(6),
                "frames the operator never selected must never be offered for resume: \(pendingFramesAfterAbort)"
            )
            #expect(pendingFramesAfterAbort.contains(4))

            // -- D-19: the finished job stays queryable, with per-frame
            // codes and a finishedAt timestamp; an unknown id is
            // JOB_NOT_FOUND. --
            let jobStatusResult = try await step(["status", "--job", firstJobId])
            #expect(jobStatusResult.exitCode == 0, Comment(rawValue: jobStatusResult.context))
            let jobStatusBody = try resultObject(jobStatusResult)
            #expect(jobStatusBody["jobState"] as? String == "failed", Comment(rawValue: jobStatusResult.context))
            #expect(jobStatusBody["finishedAt"] is String, "a terminal job must carry finishedAt: \(jobStatusBody)")
            let frameErrorCodes = try #require(jobStatusBody["frameErrorCodes"] as? [String: String], Comment(rawValue: jobStatusResult.context))
            #expect(frameErrorCodes["3"] == "ROLL_MISMATCH")

            let unknownJobResult = try await step(["status", "--job", "does-not-exist"])
            #expect(unknownJobResult.exitCode == 65, Comment(rawValue: unknownJobResult.context))
            let unknownJobError = try errorObject(unknownJobResult)
            #expect(unknownJobError["code"] as? String == "JOB_NOT_FOUND", Comment(rawValue: unknownJobResult.context))

            // -- Recovery, D-22: excluding the armed frame updates
            // pendingFrames immediately -- no roll open anywhere in this
            // sequence. --
            let excludeFrame3Result = try await step(["frames", "exclude", "3"])
            #expect(excludeFrame3Result.exitCode == 0, Comment(rawValue: excludeFrame3Result.context))

            let statusAfterExcludeResult = try await step(["status"])
            #expect(statusAfterExcludeResult.exitCode == 0, Comment(rawValue: statusAfterExcludeResult.context))
            let statusAfterExcludeBody = try resultObject(statusAfterExcludeResult)
            let pendingFramesAfterExclude = try #require(
                statusAfterExcludeBody["pendingFrames"] as? [Int], Comment(rawValue: statusAfterExcludeResult.context)
            )
            #expect(
                !pendingFramesAfterExclude.contains(3),
                "excluding frame 3 must be visible in pendingFrames immediately, without reopening the roll: \(pendingFramesAfterExclude)"
            )
            #expect(pendingFramesAfterExclude == [4])

            // -- D-23: resume either starts directly or pauses for review;
            // either way, review cancel (if needed) must never clear the
            // selection. --
            let selectedFramesBeforeResume = statusAfterExcludeBody["selectedFrames"] as? [Int]
            let resumeResult = try await step(["resume", "--confirm-motion"])
            #expect(resumeResult.exitCode == 0, Comment(rawValue: resumeResult.context))
            let resumeBody = try resultObject(resumeResult)
            let resumeOutcome = resumeBody["outcome"] as? String

            if resumeOutcome == "manualReviewPending" {
                let cancelResult = try await step(["review", "cancel"])
                #expect(cancelResult.exitCode == 0, Comment(rawValue: cancelResult.context))
                let statusAfterCancelResult = try await step(["status"])
                #expect(statusAfterCancelResult.exitCode == 0, Comment(rawValue: statusAfterCancelResult.context))
                let statusAfterCancelBody = try resultObject(statusAfterCancelResult)
                #expect(
                    (statusAfterCancelBody["selectedFrames"] as? [Int]) == selectedFramesBeforeResume,
                    "review cancel must never clear the operator's selection (D-23)"
                )

                let reselectResult = try await step(["frames", "select", "4"])
                #expect(reselectResult.exitCode == 0, Comment(rawValue: reselectResult.context))
                let secondResumeResult = try await step(["resume", "--confirm-motion", "--wait"])
                #expect(secondResumeResult.exitCode == 0, Comment(rawValue: secondResumeResult.context))
                let secondResumeBody = try resultObject(secondResumeResult)
                #expect(secondResumeBody["jobState"] as? String == "completed", Comment(rawValue: secondResumeResult.context))
            } else {
                // Without --wait, a resume that actually started prints an
                // immediate job.get snapshot instead of {outcome}
                // (MotionStartRunner's own pre-existing, unchanged
                // behavior for this path -- resumeOutcome is nil here, not
                // "started", because this body has no outcome key at all).
                let resumedJobId = try #require(
                    resumeBody["jobId"] as? String,
                    "expected an immediate job.get snapshot naming the resumed job: \(resumeBody)"
                )
                var finalJobState: String?
                for _ in 0..<200 {
                    let pollResult = try await step(["status", "--job", resumedJobId])
                    #expect(pollResult.exitCode == 0, Comment(rawValue: pollResult.context))
                    let pollBody = try resultObject(pollResult)
                    if let state = pollBody["jobState"] as? String, ["completed", "failed", "stopped"].contains(state) {
                        finalJobState = state
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                #expect(finalJobState == "completed", "the resumed job must complete: \(String(describing: finalJobState))")
            }

            // -- The resumed job completes frame 4, never re-touching the
            // excluded frame (3) or the already-completed frames (1, 2). --
            let finalFramesListResult = try await step(["frames", "list"])
            #expect(finalFramesListResult.exitCode == 0, Comment(rawValue: finalFramesListResult.context))
            let finalFramesListBody = try resultObject(finalFramesListResult)
            let finalFrames = try #require(finalFramesListBody["frames"] as? [[String: Any]], Comment(rawValue: finalFramesListResult.context))
            let finalFrame4 = try #require(finalFrames.first { ($0["index"] as? Int) == 4 }, "frame 4 missing: \(finalFrames)")
            #expect(finalFrame4["state"] as? String == "completed", "frame 4 must have completed once resumed: \(finalFrame4)")

            // -- D-24: a partial frames exclude range reports both applied
            // and failed, and exits 65. --
            let partialExcludeResult = try await step(["frames", "exclude", "4,99"])
            #expect(partialExcludeResult.exitCode == 65, Comment(rawValue: partialExcludeResult.context))
            let partialExcludeEnvelope = try envelopeObject(partialExcludeResult)
            let applied = try #require(partialExcludeEnvelope["applied"] as? [Int], Comment(rawValue: partialExcludeResult.context))
            let failedEntries = try #require(partialExcludeEnvelope["failed"] as? [[String: Any]], Comment(rawValue: partialExcludeResult.context))
            #expect(applied == [4])
            #expect(failedEntries.count == 1)
            #expect(failedEntries.first?["index"] as? Int == 99)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }
}
