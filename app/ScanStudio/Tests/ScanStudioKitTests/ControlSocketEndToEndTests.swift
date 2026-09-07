// Phase 2 plan 02-07: the end-to-end proof that a fresh agent with only
// shell access can run a roll. Drives the real, built `scanstudio-cli`
// binary as a genuine subprocess, over a real `AF_UNIX` socket, against an
// in-process host bound to the real `scanstudio-engine` and `sim-ls5000-0`
// -- no fake `EngineClientProtocol`, unlike every other suite in this
// target. This is the one place in the phase a real engine subprocess runs.
//
// Opt-in via SCANSTUDIO_CLI_E2E=1: this suite needs a built debug engine
// (`cargo build` in `app/ScanStudio/engine`) and a built CLI
// (`swift build --product scanstudio-cli`), so a bare `swift test` (and
// therefore `make test` and CI) must never pay that cost or require that
// toolchain. `scripts/cli_attach_acceptance.sh` is how this suite is
// actually run -- it builds both, exports SCANSTUDIO_ENGINE_PATH, and runs
// this filtered target as its own mandatory, named phase gate.
//
// The host under test is a parameter (`EndToEndHostKind`) so Phase 3 can
// point the same acceptance sequence at a headless host (HEAD-02) and
// Phase 4 at the packaged bundle (PKG-02) as an addition to this enum, not
// a rewrite of the sequence below -- every step only ever needs a socket
// path to dial.
//
// ## Deviations from the plan's suggested order, and why
//
// D-17c's literal shape ("save -> scan --wait -> ...") and the plan's own
// "suggested starting order" both put `frames list/exclude/include` BEFORE
// `roll save`. Reading the shipped code (not just CONTROL.md's prose)
// shows that is impossible: `ControlChannelDispatcher.validatedFrameIndex`
// refuses `frames.include`/`frames.exclude` with `INVALID_PARAMS` unless
// `sessionModel.project != nil` (`ControlChannelDispatcher.swift`'s own
// "Frame selection validation" section), and `SessionModel.project` stays
// `nil` until `createProject`/`roll.save`/`roll.open` runs -- a preview
// alone never creates one. `frames.list` itself is literally driven by
// `sessionModel.project?.frames ?? []`, so calling it before any project
// exists would only prove it tolerates an empty project, not that frame
// selection works. This suite therefore runs `frames list/exclude/include`
// AFTER `roll save`, against the project `roll save` just created, which is
// the only order the shipped code actually supports.
//
// A second finding, now CLOSED (CR-02, code-review fix): at the time this
// suite was first written, `SessionModel.selectedFrameIndices` (what
// `roll.save`/`scan.start` actually schedule) started empty and was
// populated ONLY by GUI-only interactive methods (`selectFrame`,
// `toggleFrameSelection`, `selectAllFrames`, `invertFrameSelection`) --
// `scanner.thumbnail`'s event handler fills `thumbnails`, never
// `selectedFrameIndices`. There was no D-08 channel command that selected a
// frame before a project exists (`frames.include`/`frames.exclude` need the
// project `roll.save` itself is waiting on a selection to create). A pure
// CLI-only caller therefore had no way to make `roll save`'s selection
// non-empty, and this suite's own host bridged the gap by calling
// `SessionModel.selectAllFrames()` directly on the host process -- a
// capability no real external CLI operator or agent has. The fix: a new
// `frames.select` channel command (`ControlFramesSelectParams`, routed by
// `ControlChannelDispatcher` to `SessionModel.setFrameSelection(_:)` /
// `selectAllFrames()` / `clearFrameSelection()`) and its CLI counterpart
// `frames select <ranges> | --all | --none`. This suite now drives frame
// selection through the real CLI and socket (`frames select --all`, right
// after the preview it drove through the real CLI completes), exactly like
// every other step -- the host-side bridge below is gone.
//
// A third finding: `SessionModel`'s default capture recipe is 4000 DPI (the
// real scanner's native resolution) -- a real, CPU-bound full-resolution
// render whose cost `SCANSTUDIO_TIMESCALE` cannot touch (that variable only
// scales simulated hardware motion delays). At the default, a single
// simulated frame did not finish rendering within a generously bounded
// wait. This suite exercises `settings set --resolution 100` before saving,
// reaching the exact acceptance-testing resolution `scripts/
// verify_mac_acceptance.py`'s own `RECIPE` already establishes as this
// repository's sanctioned fast-path, over the real channel rather than
// hand-copying the constant.
//
// A fourth finding: `SessionModel`'s scan-summary handler deliberately
// clears `latestCompletedPreviewOperationId` whenever a job's summary
// reports `stopped` ("never reuse interrupted transport registration to
// authorize another run" -- the handler's own comment), and that same
// signal gates both `scanReadiness`'s `hasTargetPreviews` decision and
// `resumeBatch`'s own guard. A stopped job therefore cannot be resumed
// without a fresh preview in between -- a genuine physical-safety property
// (re-verify transport state before continuing an interrupted roll), not a
// bug. This suite re-previews (`--intent refreshSavedProject`) after `stop`
// and before `resume` to match what the shipped code actually requires.
//
// A fifth finding, in this suite's own harness rather than the shipped
// product: `E2EEventsFollower.terminate()`'s original `process.terminate()`
// + `process.waitUntilExit()` could hang indefinitely -- confirmed with
// `sample` against a genuinely stuck run, which showed the whole suite
// parked in `waitUntilExit()` after the SIGTERM had already been sent.
// Fixed with the same bounded-wait-then-give-up shape this plan's own
// constraints require of every subprocess teardown
// (`AppDelegate.applicationWillTerminate`'s `DispatchSemaphore` +
// `.wait(timeout:)` pattern), so a wedged reap can no longer hang the
// suite.
//
// A sixth finding, in the shipped `--wait` mechanism itself: `sample`
// against a second genuinely stuck run showed a `scan --confirm-motion
// --wait` subprocess parked reading its own stdout (i.e. the CLI process
// itself was still alive, waiting on `JobWaiter.waitForTerminalOutcome`'s
// event loop), while a concurrent host-side poll showed the job had
// already reached `jobId: nil, jobState: .completed`. `JobWaiter` requires
// a terminal snapshot whose `jobId` is both non-nil and different from the
// pre-start id; if `SessionModel` clears `jobId` back to `nil` in the same
// update that reaches a terminal state, and the `@Observable`-driven event
// relay coalesces that into one observed snapshot, the exact snapshot
// `JobWaiter` needs never arrives. This reproduced intermittently, more
// often for a fast-completing re-scan than a longer initial one, and
// worse under this shared machine's own scheduling pressure. Not a bug
// this plan's `files_modified` can fix. Every `runE2ECLI` call (see its
// own doc comment) is therefore bounded and kills the subprocess on
// timeout, converting a rare indefinite hang into a fast, diagnosable
// failure -- exactly this plan's own "every subprocess gets a bounded
// wait then a kill on teardown" constraint, applied to the one place it
// was still missing.
//
// Coverage, not order, is otherwise exactly the plan's suggested shape:
// connect -> status -> preview -> frames select --all (CR-02) -> settings/
// outputs get -> roll save (starts job A) -> stop -> frames list/exclude/
// include -> roll list -> re-preview -> resume --wait (drains what `stop`
// left pending) -> scan --wait (a genuine re-scan of the now-fully-receipted
// selection) -> eject -> diagnostics export -> events --follow, plus the two
// negative paths.

import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

// MARK: - Host (HEAD-02 / PKG-02 seam)

/// Which real host the acceptance sequence's CLI subprocesses connect to.
/// Exactly one case exists in Phase 2 -- Phase 3 adds a headless-host case
/// (HEAD-02), Phase 4 a packaged-bundle case (PKG-02), each an addition to
/// this enum rather than a rewrite of the sequence below.
enum EndToEndHostKind: Sendable {
    case inProcess
}

/// Thrown when `HOST_MODE` (set by `scripts/cli_attach_acceptance.sh`,
/// defaulting to `in-process` for a direct `swift test` invocation) names a
/// host kind this phase does not implement yet.
struct UnsupportedHostModeError: Error, CustomStringConvertible {
    let hostMode: String
    var description: String {
        "HOST_MODE '\(hostMode)' is not supported in Phase 2 (only 'in-process' -- "
            + "Phase 3 adds 'headless', Phase 4 adds 'bundle')."
    }
}

/// The `.inProcess` host: `EngineLocator.locate()` -> real `EngineClient` ->
/// real `SessionModel` -> real `ControlChannelServer` on a short `/tmp`
/// socket -- mirrors `AppDelegate.init()`/`applicationWillTerminate` minus
/// AppKit (`ScanStudioApp.swift` lines ~176-201, ~255-269).
@MainActor
private struct EndToEndHost {
    let kind = EndToEndHostKind.inProcess
    let model: SessionModel
    let engineClient: EngineClient
    let server: ControlChannelServer
    let socketPath: String
    let tempRoot: URL
    private let originalHome: String?
    private let originalTMPDIR: String?
    private let originalTimeScale: String?

    static func start() async throws -> EndToEndHost {
        // scripts/cli_attach_acceptance.sh sets HOST_MODE explicitly
        // (defaulting to "in-process"); a direct `swift test` invocation
        // leaves it unset, which defaults identically here. Phase 2
        // implements exactly one host kind -- this is the seam Phase 3
        // (HEAD-02, "headless") and Phase 4 (PKG-02, "bundle") extend.
        let hostMode = ProcessInfo.processInfo.environment["HOST_MODE"] ?? "in-process"
        guard hostMode == "in-process" else {
            throw UnsupportedHostModeError(hostMode: hostMode)
        }

        // Read SCANSTUDIO_ENGINE_PATH (if the caller set it) before this
        // function touches any environment variable itself.
        let engineURL = try EngineLocator.locate()

        let tempRoot = URL(
            fileURLWithPath: "/tmp/ss-e2e-\(UInt32.random(in: 0..<UInt32.max))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        let originalTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        let originalTimeScale = ProcessInfo.processInfo.environment["SCANSTUDIO_TIMESCALE"]

        // T-02-37/T-02-38: scrub before spawning the real engine, mirroring
        // verify_mac_acceptance.py's isolated_environment(root). EngineClient
        // (not in this plan's files_modified) has no environment-injection
        // API -- its internal `Process` always inherits this test process's
        // own ambient environment -- so this suite's own process environment
        // is the only lever available; every child `Process()` this file or
        // EngineClient spawns without an explicit `.environment` inherits it.
        // Restored in `stop()`. Safe here only because this suite always
        // runs in isolation (`.enabled(if:)` plus `--filter` in
        // scripts/cli_attach_acceptance.sh) -- never concurrently with any
        // other suite in the same `swift test` process.
        setenv("HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path, 1)
        unsetenv("SCANSTUDIO_BRIDGE_CMD")
        unsetenv("SCANSTUDIO_HW_MOTION")
        // SessionModel.connect(deviceId:) reads this directly and passes it
        // as the simulator's own ConnectOptions.timeScale -- no source
        // change needed to make a 36-frame simulated roll fast. 0.1 matches
        // this codebase's own engine/src/sim.rs #[test]s' convention
        // (several use 0.01); 0.1 leaves headroom for this suite's own
        // subprocess-spawn latency to reliably land `stop` mid-job rather
        // than after the whole roll has already completed.
        setenv("SCANSTUDIO_TIMESCALE", "0.1", 1)

        let client = try EngineClient(engineURL: engineURL)
        let model = SessionModel(
            engineClient: client,
            diagnosticsDirectory: tempRoot.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let server = ControlChannelServer(sessionModel: model)

        // Short /tmp path, never the app's own real default control socket
        // location under the user's home directory -- mirrors
        // ScanstudioCLIProcessTests.swift's shortSocketPath.
        let socketDirectory = tempRoot.appendingPathComponent("sock", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let socketPath = socketDirectory.appendingPathComponent("s.sock").path
        precondition(
            socketPath.utf8.count < 104,
            "e2e socket path must be < 104 bytes, got \(socketPath.utf8.count): \(socketPath)"
        )
        try await server.start(path: socketPath)

        // SessionModel.init() kicks off its own startup device discovery
        // (mutatingOperationInFlight == "scanner.list", isDiscoveringDevices
        // == true) before this function ever returns. A CLI step landing
        // before that settles is refused CONTROLLER_BUSY -- found by
        // running this suite against the real engine and reading the
        // refusal's own message. Mirrors ScanstudioCLIProcessTests.swift's
        // makeIdleModel, but with a bounded real sleep rather than a pure
        // Task.yield() loop, since this is a real subprocess/engine timing
        // domain, not a fake in-process stub.
        for _ in 0..<3_000 where model.isDiscoveringDevices {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        return EndToEndHost(
            model: model,
            engineClient: client,
            server: server,
            socketPath: socketPath,
            tempRoot: tempRoot,
            originalHome: originalHome,
            originalTMPDIR: originalTMPDIR,
            originalTimeScale: originalTimeScale
        )
    }

    /// Bounded wait then kill, mirroring `AppDelegate.applicationWillTerminate`'s
    /// identical `server.stop()` + `client.terminate()` sequence, then
    /// restores every environment variable `start()` touched and removes
    /// this run's own temporary root. Safe to call even after a thrown
    /// step -- every caller reaches this via `do`/`catch`.
    func stop() async {
        await server.stop()
        await engineClient.terminate()
        if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        if let originalTMPDIR { setenv("TMPDIR", originalTMPDIR, 1) } else { unsetenv("TMPDIR") }
        if let originalTimeScale {
            setenv("SCANSTUDIO_TIMESCALE", originalTimeScale, 1)
        } else {
            unsetenv("SCANSTUDIO_TIMESCALE")
        }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Bounded, real-sleep poll (never a pure `Task.yield()` loop -- plan
    /// 02-06's own SUMMARY.md documents exactly why a yield-only loop can
    /// starve against a real subprocess/engine timing domain) for the
    /// preview this suite drove through the CLI to fully land, so
    /// `selectAllFrames()` selects a fully-previewed set and `resume`'s own
    /// later `latestCompletedPreviewOperationId` precondition is satisfied.
    func waitUntilPreviewComplete() async -> Bool {
        for _ in 0..<12_000 {
            if model.latestCompletedPreviewOperationId != nil { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return model.latestCompletedPreviewOperationId != nil
    }

    /// Bounded, real-sleep poll for a requested stop to actually land
    /// (`jobId` cleared, no job active) before `resume` -- which itself
    /// requires `jobId == nil` -- is asked to run.
    func waitUntilJobSettled() async -> Bool {
        for _ in 0..<12_000 {
            if model.jobId == nil && !model.isJobActive { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return model.jobId == nil && !model.isJobActive
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

    init(socketPath: String) throws {
        let binary = try EndToEndCLILocator.resolve()
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
    func waitForFirstLine() async -> [String: Any]? {
        for _ in 0..<2_000 {
            if let first = buffer.snapshot().first,
               let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] {
                return object
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
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
struct ControlSocketEndToEndTests {
    @Test("""
    the real scanstudio-cli binary drives a real EngineClient against sim-ls5000-0 through a real \
    ControlChannelServer, exercising every documented command and both negative confirmation/host-\
    unreachable paths
    """)
    func fullAcceptanceSequence() async throws {
        let host = try await EndToEndHost.start()

        func step(_ arguments: [String]) async throws -> E2EStepResult {
            try await runE2ECLI(arguments, socketPath: host.socketPath)
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

            // -- Simulator media setup: no D-08 command loads simulated
            // media (it is engine-level, not channel-level -- see this
            // file's own header comment and this plan's <interfaces>).
            // Reached directly on the host, exactly as sim.loadMedia is in
            // verify_mac_acceptance.py's Engine.connect().
            await host.model.loadCarrier(.strip6)

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
            let selectedFrameCount = await host.model.selectedFrames.count
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
                let jobId = await host.model.jobId
                let isJobActive = await host.model.isJobActive
                let jobState = await host.model.jobState
                let pending = await host.model.pendingFrameCount
                let completed = await host.model.completedFrameCount
                let message: String = "job did not settle: jobId=\(String(describing: jobId)) isJobActive=\(isJobActive) "
                    + "jobState=\(String(describing: jobState)) pending=\(pending) completed=\(completed)"
                Issue.record(Comment(rawValue: message))
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
            let rePreviewCompleted = await host.waitUntilPreviewComplete()
            #expect(rePreviewCompleted, "re-preview after stop did not reach scanner.thumbnailsComplete within the bound")

            // -- resume --confirm-motion --wait: drains whatever `stop`
            // left pending. Blocks on the real event stream -- no polling,
            // no synthetic events, this is the real engine. --
            let resumeResult = try await step(["resume", "--confirm-motion", "--wait"])
            #expect(resumeResult.exitCode == 0, Comment(rawValue: resumeResult.context))
            let resumeBody = try resultObject(resumeResult)
            #expect(resumeBody["jobState"] as? String == "completed", Comment(rawValue: resumeResult.context))

            // -- scan --confirm-motion --wait: a genuine re-scan of the
            // now-fully-receipted selection (D-17c's "re-scan" step). --
            let scanResult = try await step(["scan", "--confirm-motion", "--wait"])
            #expect(scanResult.exitCode == 0, Comment(rawValue: scanResult.context))
            let scanBody = try resultObject(scanResult)
            #expect(scanBody["jobState"] as? String == "completed", Comment(rawValue: scanResult.context))

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

        /// `SessionModel.loadCarrier(_:)` does not yet carry a
        /// `previewFixture` argument -- plan 03-04 owns extending the
        /// control-level `sim.loadMedia` wiring for that. This test drives
        /// the engine's own `sim.loadMedia` a second time, directly
        /// through the host's `engineClient`, with the fixture added.
        /// Re-loading the identical carrier is idempotent for every field
        /// `SessionModel.status` already holds from the `loadCarrier(_:)`
        /// call that must precede this one -- so this call only arms the
        /// fixture, it changes nothing `SessionModel`-observable.
        struct FixtureLoadMediaParams: Encodable, Sendable {
            let carrier: String
            let previewFixture: String
        }
        func armBoundaryAndBlankFixture(on host: EndToEndHost) async throws {
            await host.model.loadCarrier(.strip6)
            let _: ScannerStatus = try await host.engineClient.request(
                "sim.loadMedia",
                params: FixtureLoadMediaParams(carrier: SimulatedFilmCarrier.strip6.rawValue, previewFixture: "boundaryAndBlank")
            )
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
}
