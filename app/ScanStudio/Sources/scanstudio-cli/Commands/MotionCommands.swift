// Confirmation-gated motion commands (D-08/D-11/SAFE-01/SAFE-02).
//
// Every command in this file that can move film declares its own parse-time
// confirmation guard, verbatim -- never behind a shared helper a future
// command could forget to call (see this plan's own `<constraints>`).
// ArgumentParser runs that guard before `run()`, so a missing flag never
// opens a socket: `RollCommands.swift`'s `Roll.Save` gate (plan 02-05) is
// the exact shape every gate below repeats.

import ArgumentParser
import Foundation
import ScanStudioKit

/// `preview --film-loaded` -> `preview.acquire` (CLI-03). A `"rejected"`/
/// `"failedToStart"` outcome is still a *successful* response (exit 0) --
/// the request was accepted and answered definitively, not refused. This
/// is the one D-08 motion command where a non-`"started"` outcome is not
/// itself a failure.
struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: """
        Acquire a film preview. Requires --film-loaded. A "rejected" or \
        "failedToStart" outcome is still a successful response (exit 0) -- \
        it is a definitive answer, not a failure.
        """
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("film-loaded"), help: "Required: confirms film is physically loaded in the scanner.")
    var filmLoaded = false

    @Option(name: .customLong("intent"), help: "initial | replaceFilmProcess | refreshSavedProject. Defaults to initial.")
    var intent: String?

    /// WR-05: constructing the canonical `ControlPreviewAcquireParams`
    /// directly (its `filmProcess` field is `FilmProcess?`, not a bare
    /// `String?`) requires a real `FilmProcess` value here, so this is now
    /// validated at parse time via the same `transform:` pattern
    /// `RollCommands.swift`'s `--film-process`/`--carrier` already use --
    /// a tightening from the previous "passed through unvalidated, the
    /// host reports an unrecognized value" behavior, not a regression: an
    /// invalid value now fails client-side (ArgumentParser's own usage
    /// error, exit 64) before any connection opens, instead of round-
    /// tripping to the host first for the identical exit code.
    @Option(name: .customLong("film-process"), help: "Required when --intent replaceFilmProcess is given: positive, c41ColorNegative, bwNegative, or kodachrome.", transform: {
        guard let value = FilmProcess(rawValue: $0) else {
            throw ValidationError("film-process must be one of: \(FilmProcess.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    })
    var filmProcess: FilmProcess?

    mutating func validate() throws {
        guard filmLoaded else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"preview\" requires --film-loaded.",
                guidance: "Confirm film is physically loaded in the scanner, then retry with --film-loaded."
            )
            let text = try ControlCLIOutput.renderError(command: "preview.acquire", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
    }

    func run() async throws {
        try await CommandRunner.run(
            command: "preview.acquire",
            method: "preview.acquire",
            params: ControlPreviewAcquireParams(filmLoadedConfirmed: true, intent: intent, filmProcess: filmProcess),
            options: options
        )
    }
}

/// `review approve --confirm-motion` -> `review.approve` (CLI-05). Takes no
/// id -- CLI-05's "the review `operationId` is handled by the tool, not
/// typed by the operator" is satisfied by construction, since
/// `review.approve` itself carries no id on the wire.
///
/// Attended-scan-recovery approval (`SessionModel.approveEveryFrameAndScan()`)
/// is a *different* action with different confirmation semantics and has no
/// channel command yet (CONTROL.md's own "Not yet implemented" list) --
/// carried forward, not implemented here.
struct ReviewApprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Approve the pending manual review and start the scan. Requires --confirm-motion."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("confirm-motion"), help: "Required: this command starts a scan.")
    var confirmMotion = false

    mutating func validate() throws {
        guard confirmMotion else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"review approve\" requires --confirm-motion (it starts the scan).",
                guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
            )
            let text = try ControlCLIOutput.renderError(command: "review.approve", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
    }

    func run() async throws {
        try await CommandRunner.run(
            command: "review.approve",
            method: "review.approve",
            params: ControlReviewApproveParams(motionConfirmed: true),
            options: options
        )
    }
}

/// `review cancel` -> `review.cancel` (D-23/HEAD-12). No confirmation flag:
/// it authorizes no motion, approves nothing, and leaves the operator's
/// current frame selection untouched -- the fix for the 2026-09-07 case
/// where dismissing the review sheet silently cleared it.
struct ReviewCancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Dismiss the pending manual review without starting a scan or losing the current selection."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await CommandRunner.runWithoutParams(
            command: "review.cancel",
            method: "review.cancel",
            options: options
        )
    }
}

/// The `review` command group -- `approve` and `cancel`, grouped so the
/// invocation reads `review approve`/`review cancel`, matching D-08's tree.
struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Manual-review actions.",
        subcommands: [ReviewApprove.self, ReviewCancel.self]
    )
}

/// `eject --confirm-motion` -> `scanner.eject` (CLI-05). The host applies
/// its own layered gate (hardware motion readiness, then
/// `DeviceBarEjectPolicy.canOffer`) -- this command only owns the
/// parse-time confirmation layer.
struct Eject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eject",
        abstract: "Eject the film. Requires --confirm-motion."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("confirm-motion"), help: "Required: this command moves film.")
    var confirmMotion = false

    mutating func validate() throws {
        guard confirmMotion else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"eject\" requires --confirm-motion.",
                guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
            )
            let text = try ControlCLIOutput.renderError(command: "scanner.eject", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
    }

    func run() async throws {
        try await CommandRunner.run(
            command: "scanner.eject",
            method: "scanner.eject",
            params: ControlScannerEjectParams(motionConfirmed: true),
            options: options
        )
    }
}

/// `scan --confirm-motion [--wait]` -> `scan.start` (CLI-08). Pre-checks
/// `scanReadiness(for: selectedFrames)` host-side -- this command owns only
/// the parse-time confirmation layer.
struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Start scanning the selected frames. Requires --confirm-motion."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("confirm-motion"), help: "Required: this command starts a scan.")
    var confirmMotion = false

    @Flag(name: .customLong("wait"), help: "Block until the job reaches a terminal state, observed on the event stream -- never polled.")
    var wait = false

    mutating func validate() throws {
        guard confirmMotion else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"scan\" requires --confirm-motion.",
                guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
            )
            let text = try ControlCLIOutput.renderError(command: "scan.start", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
    }

    func run() async throws {
        try await MotionStartRunner.run(
            command: "scan.start",
            method: "scan.start",
            params: ControlScanStartParams(motionConfirmed: true),
            options: options,
            wait: wait,
            quiet: options.quiet
        )
    }
}

/// `stop [--immediate]` -> `scan.stop` (CLI-09). No confirmation flag --
/// stopping never starts motion. Absent `--immediate`, `mode` is omitted
/// entirely so the host applies its own documented stop-mode default
/// (`ControlScanStopParams` already carries a public initializer -- Plan
/// 02-01's one params struct with no confirmation field -- so this command
/// needs no wire mirror).
struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the active scan job."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("immediate"), help: "Stop immediately rather than after the current frame completes.")
    var immediate = false

    func run() async throws {
        try await CommandRunner.run(
            command: "scan.stop",
            method: "scan.stop",
            params: ControlScanStopParams(mode: immediate ? "immediate" : nil),
            options: options
        )
    }
}

/// `resume --confirm-motion [--wait]` -> `scan.resume` (CLI-09). Routes to
/// `resumeBatch()`, which only ever touches the engine's pending frames.
struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume the batch's pending frames. Requires --confirm-motion."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("confirm-motion"), help: "Required: this command starts a scan.")
    var confirmMotion = false

    @Flag(name: .customLong("wait"), help: "Block until the job reaches a terminal state, observed on the event stream -- never polled.")
    var wait = false

    mutating func validate() throws {
        guard confirmMotion else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"resume\" requires --confirm-motion.",
                guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
            )
            let text = try ControlCLIOutput.renderError(command: "scan.resume", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
    }

    func run() async throws {
        try await MotionStartRunner.run(
            command: "scan.resume",
            method: "scan.resume",
            params: ControlScanResumeParams(motionConfirmed: true),
            options: options,
            wait: wait,
            quiet: options.quiet
        )
    }
}

/// The D-13 `--wait` interleaving shared identically by `Scan`/`Resume`, and
/// (D-17) `Roll.Save` (`RollCommands.swift`) -- three commands now, not two,
/// hence `internal` rather than `private`: subscribe, send the caller's own
/// start request, then either return the job id immediately or hand off to
/// `JobWaiter` for the terminal outcome. SAFE-02: sends exactly the
/// caller's one start request plus, only when waiting, `JobWaiter`'s own
/// two calls -- nothing here re-issues anything, and `quiet` only ever
/// suppresses a stderr write that `JobWaiter` itself never performs (see
/// its own header).
enum MotionStartRunner {
    static func run<Params: Encodable & Sendable>(
        command: String,
        method: String,
        params: Params,
        options: GlobalOptions,
        wait: Bool,
        quiet: Bool
    ) async throws {
        let client = try await CommandRunner.openConnection(command: command, options: options)

        var preStartJobId: String?
        if wait {
            do {
                preStartJobId = try await JobWaiter.subscribe(client: client)
            } catch {
                try await CommandRunner.fail(command: command, options: options, client: client, error: error)
            }
        }

        let startResponse = try await CommandRunner.request(
            command: command, method: method, params: params, options: options, client: client
        )
        guard case .result(let startData) = startResponse else {
            try await CommandRunner.finish(command: command, options: options, client: client, response: startResponse)
            return
        }

        // D-23/HEAD-12 (the 2026-09-07 batch abort): a paused-for-review
        // outcome is not "the job started" -- print it and stop here,
        // whether or not --wait was given, rather than falling through to
        // a job.get snapshot for a job that never started (the 19:25Z
        // case: `resume` printed the *previous* job's failed snapshot with
        // exit 0) or waiting on an event stream nothing will ever signal.
        let startObject = ((try? JSONSerialization.jsonObject(with: startData)) as? [String: Any]) ?? [:]
        if startObject["outcome"] as? String == "manualReviewPending" {
            try await CommandRunner.finish(command: command, options: options, client: client, response: startResponse)
            return
        }

        guard wait else {
            let jobResponse = try await CommandRunner.requestWithoutParams(
                command: command, method: "job.get", options: options, client: client
            )
            try await CommandRunner.finish(command: command, options: options, client: client, response: jobResponse)
            return
        }

        // stdout stays exactly one JSON object (D-09/D-17) -- progress is
        // written only to stderr, never here, and only unless --quiet.
        let onProgress: (@Sendable (ControlScanProgress) -> Void)?
        if quiet {
            onProgress = nil
        } else {
            onProgress = { (progress: ControlScanProgress) in
                FileHandle.standardError.write(Data((ControlProgressLine.render(progress) + "\n").utf8))
            }
        }

        do {
            guard let terminalResponse = try await JobWaiter.waitForTerminalOutcome(
                client: client,
                preStartJobId: preStartJobId,
                onProgress: onProgress
            ) else {
                await client.shutdown()
                let payload = ControlErrorPayload(
                    code: ControlCLIErrorCode.hostUnreachable.rawValue,
                    message: "\"\(command)\" was waiting on the job's event stream, but the control host went away.",
                    recoverable: false
                )
                let text = try ControlCLIOutput.renderError(command: command, payload: payload, human: options.human, context: await client.cliEnvelopeContext)
                print(text, terminator: "")
                throw ExitCode(ControlCLIExitCode.noHostReachable.rawValue)
            }
            guard case .result(let data) = terminalResponse else {
                try await CommandRunner.finish(command: command, options: options, client: client, response: terminalResponse)
                return
            }
            let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            let text = try ControlCLIOutput.renderResult(command: command, resultJSON: object, human: options.human, context: await client.cliEnvelopeContext)
            print(text, terminator: "")
            await client.shutdown()
            let finalState = (try? JSONDecoder().decode(ControlJobResult.self, from: data))?.jobState
            if finalState == .failed {
                throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            try await CommandRunner.fail(command: command, options: options, client: client, error: error)
        }
    }
}

// WR-05: the hand-duplicated wire-mirror structs that used to live here
// (`PreviewAcquireWireParams`/`ReviewApproveWireParams`/
// `ScannerEjectWireParams`/`ScanStartWireParams`/`ScanResumeWireParams`)
// are gone -- `ControlWireProtocol.swift`'s own canonical
// `ControlPreviewAcquireParams`/`ControlReviewApproveParams`/
// `ControlScannerEjectParams`/`ControlScanStartParams`/
// `ControlScanResumeParams` now each have an explicit `public init`, so
// every `run()` above constructs the canonical type directly.
