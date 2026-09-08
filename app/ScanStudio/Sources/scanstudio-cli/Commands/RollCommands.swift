// `roll save|open|list` (D-08/CLI-07).

import ArgumentParser
import Foundation
import ScanStudioKit

struct Roll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roll",
        abstract: "Save, open, or list rolls (projects).",
        // Run (D-15/HEAD-09, Commands/RunCommands.swift) lives in its own
        // file -- it composes Save's own request shape plus five other
        // already-shipped commands into one unattended walk, so it earns a
        // file of its own rather than crowding this one.
        subcommands: [Save.self, Open.self, List.self, Run.self]
    )

    /// `roll save` -> `roll.save`.
    ///
    /// SAFETY FINDING (see this plan's `<safety_finding>`): this routes to
    /// `SessionModel.saveRollAndScanSelectedFrames(name:carrier:
    /// frameCount:filmProcess:)` (SessionModel.swift:2762-2795), which
    /// creates the project and immediately calls
    /// `startScanOrRequestManualReview(frames:)` -- it moves film. D-08's
    /// literal subcommand tree names no confirmation flag for `roll save`,
    /// but PROJECT.md's standing "no scanner motion without an explicit
    /// confirmation flag" constraint applies anyway, mirroring Phase 1's
    /// identical tightening of `review.approve` beyond its own literal
    /// enumeration. `--confirm-motion` is required here, at parse time,
    /// before any socket is opened -- a CLI-level tightening beyond the
    /// channel's own params (T-02-27's parse-time layer; the wire's own
    /// `motionConfirmed` gate, plan 02-01 Task 3, is the independent
    /// second layer). A missing flag prints a CONFIRMATION_REQUIRED body
    /// and exits 77, exactly like the channel's own refusal for the
    /// identical condition -- before any connection exists.
    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Create the project from the current preview and scan the selected frames. Requires --confirm-motion."
        )

        @OptionGroup var options: GlobalOptions

        @Option(name: .customLong("name"), help: "Roll/project name.")
        var name: String

        @Option(name: .customLong("carrier"), help: "Film carrier: mounted, strip6, or roll36.", transform: {
            guard let value = SimulatedFilmCarrier(rawValue: $0) else {
                throw ValidationError("carrier must be one of: \(SimulatedFilmCarrier.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var carrier: SimulatedFilmCarrier

        @Option(name: .customLong("frame-count"), help: "Frame count for this carrier.")
        var frameCount: Int

        @Option(name: .customLong("film-process"), help: "Film process: positive, c41ColorNegative, bwNegative, or kodachrome.", transform: {
            guard let value = FilmProcess(rawValue: $0) else {
                throw ValidationError("film-process must be one of: \(FilmProcess.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var filmProcess: FilmProcess

        @Flag(name: .customLong("confirm-motion"), help: "Required: this command starts a scan.")
        var confirmMotion = false

        @Flag(name: .customLong("wait"), help: "Block until the job reaches a terminal state, observed on the event stream -- never polled.")
        var wait = false

        /// D-14/HEAD-08: when the save pauses for manual review, approve it
        /// automatically -- routing to the same `review.approve` the GUI's
        /// own "Confirm & Scan" uses -- if and only if every flagged
        /// frame's blank-frame `contentConfidence` clears
        /// `autoApproveMinimumContentConfidence`. Still requires
        /// `--confirm-motion`; see this struct's own `validate()`.
        @Flag(name: .customLong("auto-approve"), help: "Auto-approve a paused manual review when every flagged frame's content confidence is >= 0.8. Requires --confirm-motion.")
        var autoApprove = false

        /// D-14/HEAD-08: the minimum `contentConfidence` **every** flagged
        /// frame must clear before `--auto-approve` sends `review.approve`.
        /// The same number as `BlankFrameHint.defaultSkipThreshold` (0.8)
        /// for the same underlying reason -- both mean "confident enough to
        /// act on without a human" -- but a separate, independently named
        /// constant: the two gate different actions (one selects frames to
        /// scan, the other clears a safety gate a human would otherwise
        /// clear) and must be free to diverge if a later roll's own
        /// calibration data ever needs them to. The actual pass/fail
        /// decision lives in `ManualReviewAutoApproval.shouldAutoApprove(_:)`
        /// (`ControlCLISupport.swift`, which reads `BlankFrameHint`
        /// directly) -- this constant is used only for this command's own
        /// refusal message.
        static let autoApproveMinimumContentConfidence: Double = 0.8

        mutating func validate() throws {
            guard confirmMotion else {
                let payload = ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"roll save\" requires --confirm-motion (it creates the project and starts the scan).",
                    guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
                )
                let text = try ControlCLIOutput.renderError(command: "roll.save", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(77)
            }
            // A second, independent statement -- deliberately not relying
            // solely on the guard above -- so a future loosening of `roll
            // save`'s own --confirm-motion requirement could never silently
            // also open --auto-approve's gate (T-03-29).
            guard !autoApprove || confirmMotion else {
                let payload = ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"roll save --auto-approve\" requires --confirm-motion.",
                    guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
                )
                let text = try ControlCLIOutput.renderError(command: "roll.save", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(77)
            }
        }

        /// D-17: `roll save --wait` (without `--auto-approve`) runs through
        /// the same `MotionStartRunner` body `scan --wait`/`resume --wait`
        /// use -- same subscribe-first ordering, same `JobWaiter`, same
        /// terminal-state exit codes, no second wait implementation.
        /// Without `--wait`, `roll save` keeps its original single-request
        /// `CommandRunner.run` path unchanged: `MotionStartRunner`'s own
        /// `!wait` branch renders `job.get`'s aggregate instead of the
        /// start request's own result (the right call for
        /// `scan.start`/`scan.resume`, whose own result is an uninteresting
        /// `{}`) -- but `roll.save`'s own result (`{saved, projectName,
        /// projectDirectory, outcome}`) is the useful, documented body this
        /// command has always returned, and routing it through that branch
        /// would silently replace it with an unrelated `job.get` shape.
        /// `roll save` without `--wait` therefore never needs `JobWaiter`
        /// at all.
        ///
        /// `--auto-approve` needs the connection to stay open past
        /// `roll.save`'s own response (for a possible `status`/
        /// `review.approve` follow-up), which `MotionStartRunner`/
        /// `CommandRunner.run` cannot do -- both close their connection
        /// once their own single request resolves -- so it runs through
        /// `runAutoApprove` below instead, never through either of those.
        func run() async throws {
            let params = ControlRollSaveParams(name: name, carrier: carrier, frameCount: frameCount, filmProcess: filmProcess, motionConfirmed: true)
            guard autoApprove else {
                guard wait else {
                    try await CommandRunner.run(command: "roll.save", method: "roll.save", params: params, options: options)
                    return
                }
                try await MotionStartRunner.run(
                    command: "roll.save", method: "roll.save", params: params, options: options, wait: wait, quiet: options.quiet
                )
                return
            }
            try await runAutoApprove(params: params, options: options, wait: wait, quiet: options.quiet)
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a saved roll by its project directory.")

        @OptionGroup var options: GlobalOptions

        @Argument(help: "Project directory to open.")
        var directory: String

        func run() async throws {
            try await CommandRunner.run(
                command: "roll.open",
                method: "roll.open",
                params: ControlRollOpenParams(directory: directory),
                options: options
            )
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent rolls (projects).")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await CommandRunner.runWithoutParams(command: "roll.list", method: "roll.list", options: options)
        }
    }
}

// WR-05: the hand-duplicated `RollSaveWireParams` mirror that used to live
// here is gone -- `ControlWireProtocol.swift`'s own canonical
// `ControlRollSaveParams` now has an explicit `public init`, so `Save
// .run()` above constructs it directly.

/// `roll save --auto-approve`'s own request sequence (D-14/HEAD-08): send
/// `roll.save` on a connection that stays open; if its `outcome` is
/// `"manualReviewPending"`, follow with `status` (to read the flagged
/// frames' `contentConfidence`) and, only when
/// `ManualReviewAutoApproval.shouldAutoApprove` agrees, exactly one
/// `review.approve` -- all on that same connection, never a second dial.
/// SAFE-02: never a second approval attempt, never a retry. `--wait`
/// covers only the job `roll.save` itself might start (identical to `roll
/// save --wait` without `--auto-approve`) -- `review.approve` has no
/// `--wait` of its own anywhere in this CLI today, so a scan it starts is
/// reported, not waited on, the same as every other `review approve`
/// invocation.
private func runAutoApprove(
    params: ControlRollSaveParams,
    options: GlobalOptions,
    wait: Bool,
    quiet: Bool
) async throws {
    let command = "roll.save"
    let client = try await CommandRunner.openConnection(command: command, options: options)

    var preStartJobId: String?
    if wait {
        do {
            preStartJobId = try await JobWaiter.subscribe(client: client)
        } catch {
            try await CommandRunner.fail(command: command, options: options, client: client, error: error)
        }
    }

    let saveResponse = try await CommandRunner.request(command: command, method: "roll.save", params: params, options: options, client: client)
    guard case .result(let saveData) = saveResponse else {
        try await CommandRunner.finish(command: command, options: options, client: client, response: saveResponse)
        return
    }
    guard let saveResult = try? JSONDecoder().decode(ControlRollSaveResult.self, from: saveData) else {
        try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
    }

    guard saveResult.outcome == "manualReviewPending" else {
        // "started" (or "failed", not reachable from a .result envelope
        // today -- see ControlRollSaveResult's own doc comment): nothing
        // pending to approve, autoApproved is empty either way. --wait
        // only applies when a job actually started.
        try await finishRollSave(
            command: command, options: options, client: client,
            baseData: saveData, autoApproved: [], refusedBecause: nil,
            wait: wait && saveResult.outcome == "started", preStartJobId: preStartJobId, quiet: quiet
        )
        return
    }

    let statusResponse = try await CommandRunner.requestWithoutParams(command: command, method: "status", options: options, client: client)
    guard case .result(let statusData) = statusResponse else {
        try await CommandRunner.finish(command: command, options: options, client: client, response: statusResponse)
        return
    }
    guard let status = try? JSONDecoder().decode(ControlStatusResult.self, from: statusData) else {
        try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
    }
    let flaggedFrames = status.manualReviewPending?.frames ?? []

    guard ManualReviewAutoApproval.shouldAutoApprove(flaggedFrames) else {
        try await finishRollSave(
            command: command, options: options, client: client,
            baseData: saveData, autoApproved: [], refusedBecause: autoApproveRefusalReason(flaggedFrames),
            wait: false, preStartJobId: nil, quiet: quiet
        )
        return
    }

    let approveResponse = try await CommandRunner.request(
        command: command, method: "review.approve", params: ControlReviewApproveParams(motionConfirmed: true), options: options, client: client
    )
    guard case .result = approveResponse else {
        try await CommandRunner.finish(command: command, options: options, client: client, response: approveResponse)
        return
    }
    try await finishRollSave(
        command: command, options: options, client: client,
        baseData: saveData, autoApproved: flaggedFrames.map(\.index), refusedBecause: nil,
        wait: false, preStartJobId: nil, quiet: quiet
    )
}

/// The reason text merged into the rendered result as
/// `autoApproveRefusedBecause` when `shouldAutoApprove` refuses: names the
/// first frame that failed the bar, either because its content confidence
/// fell short (`"frame N contentConfidence 0.62 < 0.80"`) or because it
/// had none at all (`"frame N has no content confidence"`).
private func autoApproveRefusalReason(_ frames: [ControlManualReviewFrame]) -> String {
    let threshold = Roll.Save.autoApproveMinimumContentConfidence
    guard let culprit = frames.first(where: { ($0.contentConfidence ?? -1) < threshold }) else {
        return "no flagged frames to approve"
    }
    guard let confidence = culprit.contentConfidence else {
        return "frame \(culprit.index) has no content confidence"
    }
    return "frame \(culprit.index) contentConfidence \(String(format: "%.2f", confidence)) < \(String(format: "%.2f", threshold))"
}

/// Merges `autoApproved`/`autoApproveRefusedBecause` into `baseData`
/// (`roll.save`'s own already-fetched result body) and finishes the
/// command -- waiting for a terminal job state first when `wait` is true,
/// mirroring `MotionStartRunner`'s own wait tail (`MotionCommands.swift`).
/// Duplicated rather than shared: that runner always closes its own
/// connection once its single request resolves, and this command's
/// connection must have stayed open for the `status`/`review.approve` pair
/// `runAutoApprove` above may have already sent on it.
private func finishRollSave(
    command: String,
    options: GlobalOptions,
    client: ControlChannelClient,
    baseData: Data,
    autoApproved: [Int],
    refusedBecause: String?,
    wait: Bool,
    preStartJobId: String?,
    quiet: Bool
) async throws {
    guard wait else {
        var object = ((try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]) ?? [:]
        object["autoApproved"] = autoApproved
        if let refusedBecause {
            object["autoApproveRefusedBecause"] = refusedBecause
        }
        let resultData = (try? JSONSerialization.data(withJSONObject: object)) ?? baseData
        try await CommandRunner.finish(command: command, options: options, client: client, response: .result(resultData))
        return
    }

    let onProgress: (@Sendable (ControlScanProgress) -> Void)?
    if quiet {
        onProgress = nil
    } else {
        onProgress = { (progress: ControlScanProgress) in
            FileHandle.standardError.write(Data((ControlProgressLine.render(progress) + "\n").utf8))
        }
    }
    do {
        guard let terminalResponse = try await JobWaiter.waitForTerminalOutcome(client: client, preStartJobId: preStartJobId, onProgress: onProgress) else {
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
        var object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        object["autoApproved"] = autoApproved
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
