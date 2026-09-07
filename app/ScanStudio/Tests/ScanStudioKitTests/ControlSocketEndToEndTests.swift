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
// A second, more consequential finding: `SessionModel.selectedFrameIndices`
// (what `roll.save`/`scan.start` actually schedule) starts empty and is
// populated ONLY by GUI-only interactive methods (`selectFrame`,
// `toggleFrameSelection`, `selectAllFrames`, `invertFrameSelection`) --
// `scanner.thumbnail`'s event handler fills `thumbnails`, never
// `selectedFrameIndices`. There is no D-08 channel command that selects a
// frame before a project exists (`frames.include`/`frames.exclude` need the
// project `roll.save` itself is waiting on a selection to create). A pure
// CLI-only caller therefore has no way to make `roll save`'s selection
// non-empty in Phase 2 as shipped. This is not a bug this plan's
// `files_modified` can fix (no Commands/ file, no ControlWireProtocol.swift,
// no ControlChannelDispatcher.swift here), and it is not a source change --
// per this plan's own `<interfaces>`, "the suite's host may need to reach
// them through EngineClient directly at setup time" already grants exactly
// this kind of setup-time host access (the same allowance `sim.loadMedia`
// setup already relies on). This suite's host therefore calls
// `SessionModel.selectAllFrames()` directly, once, immediately after the
// preview it drove through the real CLI completes -- exactly what a human
// operator's contact-sheet view does automatically, and exactly the
// counterpart to loading the simulated carrier. **This is recorded here as
// a genuine phase-scope finding**: Phase 2's D-08 command tree has no
// channel-level frame-selection command, so an attach-mode CLI caller with
// no GUI ever rendered cannot drive a roll from a cold start without this
// same bridge. Worth a `frames select`/`frames select-all` command in a
// later phase; out of scope to add here.
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
// Coverage, not order, is otherwise exactly the plan's suggested shape:
// connect -> status -> preview -> settings/outputs get -> roll save (starts
// job A) -> stop -> frames list/exclude/include -> roll list -> re-preview
// -> resume --wait (drains what `stop` left pending) -> scan --wait (a
// genuine re-scan of the now-fully-receipted selection) -> eject ->
// diagnostics export -> events --follow, plus the two negative paths.

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

        // Short /tmp path, never the real ~/.scanstudio/control.sock --
        // mirrors ScanstudioCLIProcessTests.swift's shortSocketPath.
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

/// Runs the real built binary with `arguments` plus `--socket socketPath`.
/// The blocking `Process`/`Pipe` spawn/read/wait sequence runs on a
/// dedicated background queue via a continuation -- never inline on Swift's
/// cooperative thread pool -- mirroring `ScanstudioCLIProcessTests.swift`'s
/// `runCLI` and the identical fix `ScanstudioCLIConfirmationTests.swift`'s
/// `runConfirmationCLI` needed for the same thread-pool-starvation reason
/// (both plans' own SUMMARY.md deviations).
private func runE2ECLI(_ arguments: [String], socketPath: String) async throws -> E2EStepResult {
    let binary = try EndToEndCLILocator.resolve()
    let allArguments = arguments + ["--socket", socketPath]
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<E2EStepResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                process.executableURL = binary
                process.arguments = allArguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: E2EStepResult(
                    arguments: arguments,
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            } catch {
                continuation.resume(throwing: error)
            }
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

@Suite(
    "Control socket end to end",
    .enabled(if: ProcessInfo.processInfo.environment["SCANSTUDIO_CLI_E2E"] == "1"),
    .timeLimit(.minutes(10))
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

            // -- Frame selection setup: see this file's header comment --
            // no D-08 command can select a frame before a project exists.
            // Reached directly on the host, mirroring the contact sheet's
            // own default-select-all behaviour a real operator gets for
            // free from the GUI.
            await host.model.selectAllFrames()
            let selectedFrameCount = await host.model.selectedFrames.count
            #expect(selectedFrameCount == 6, "selectAllFrames did not select all 6 previewed frames")

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
}
