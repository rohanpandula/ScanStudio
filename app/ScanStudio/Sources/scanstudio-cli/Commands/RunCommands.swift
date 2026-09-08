// `roll run` (D-15/HEAD-09): the CLI-side composition of six already-shipped
// commands into one unattended walk, with a durable per-step receipt. Adds
// no wire command and no SessionModel method -- every request below is one
// an operator could already send by hand with commands already shipped
// elsewhere in this CLI (Commands/DeviceCommands.swift,
// Commands/MotionCommands.swift, Commands/FrameCommands.swift,
// Commands/RollCommands.swift).
//
// SAFE-02 is structural, exactly like every other multi-request command in
// this target: one attempt per step, on one connection, and the first
// refusal stops the walk dead -- no retry, no alternative path, no second
// approval. `sendStep`/`refreshScanner` below are the only two places that
// send a request as part of the walk, and both record either outcome into
// the receipt before returning -- nothing here re-issues anything.
//
// SAFE-03: the run's own receipt is a brand-new file beside the project's
// other saved state (`ControlRunReceipt.write`,
// ScanStudioKit/ControlCLISupport.swift) -- this file names no durable
// artifact of its own and never opens any of the project's existing ones.

import ArgumentParser
import Foundation
import ScanStudioKit

extension Roll {
    /// `roll run` -> D-15's own composed sequence: `scanner.refresh` +
    /// `status` (with plan 03-05's one permitted non-motion reconnect) ->
    /// `preview.acquire` -> wait for `status.previewComplete` ->
    /// `frames.list` + `frames.select` -> `roll.save` -> `review.approve`
    /// only when `--auto-approve` did not already resolve a paused review
    /// -> wait for the job's terminal state. One connection for the whole
    /// run.
    ///
    /// stdout is always the run's own receipt, rendered through
    /// `ControlCLIOutput.renderResult` -- never `renderError`, even when a
    /// step refused: the receipt's own `steps` array is what names the
    /// refusal. The process exit code is separately the first failing
    /// step's own code, or 0 (D-15).
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: """
            Run a whole roll unattended: refresh, preview, select, save, and \
            (by default) wait for the scan to finish. Requires --film-loaded \
            and --confirm-motion. Prints one JSON run receipt and, once a \
            project exists, writes a copy beside its manifest.
            """
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

        /// D-15: defaults to the scanner's own reported frame count from
        /// this run's own initial refresh -- never guessed. See
        /// `RollRun.run()`'s own step 1.
        @Option(name: .customLong("frame-count"), help: "Frame count for this carrier. Defaults to the scanner's own reported frame count from this run's initial refresh.")
        var frameCount: Int?

        @Flag(name: .customLong("allow-unverified-hardware"), help: "Allow connecting to a recognized but unverified scanner for this run.")
        var allowUnverifiedHardware = false

        @Option(name: .customLong("film-process"), help: "Film process: positive, c41ColorNegative, bwNegative, or kodachrome.", transform: {
            guard let value = FilmProcess(rawValue: $0) else {
                throw ValidationError("film-process must be one of: \(FilmProcess.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var filmProcess: FilmProcess

        @Flag(name: .customLong("film-loaded"), help: "Required: confirms film is physically loaded in the scanner.")
        var filmLoaded = false

        @Flag(name: .customLong("confirm-motion"), help: "Required: this command moves film and starts a scan.")
        var confirmMotion = false

        @Flag(name: .customLong("skip-blank"), help: "Select previewed frames whose blank-frame confidence is below the threshold, instead of every previewed frame.")
        var skipBlank = false

        @Flag(name: .customLong("auto-approve"), help: "Auto-approve a paused manual review when every flagged frame's content confidence is >= 0.8.")
        var autoApprove = false

        /// On by default -- `--no-wait` returns immediately once the scan
        /// starts (or once a review is left pending) instead of blocking
        /// for a terminal job state.
        @Flag(name: .customLong("wait"), inversion: .prefixedNo, help: "Wait for the job to reach a terminal state before returning. On by default; pass --no-wait to return immediately once the scan starts (or once a review is left pending).")
        var wait = true

        /// Two independent statements, exactly like `Roll.Save`'s own gate
        /// (RollCommands.swift) and `Preview`'s own gate
        /// (MotionCommands.swift) -- never one combined check, so a future
        /// loosening of one flag's requirement can never silently loosen
        /// the other (T-03-36). Both print and exit 77 before any socket
        /// opens.
        mutating func validate() throws {
            guard filmLoaded else {
                let payload = ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"roll run\" requires --film-loaded (it acquires a preview).",
                    guidance: "Confirm film is physically loaded in the scanner, then retry with --film-loaded."
                )
                let text = try ControlCLIOutput.renderError(command: "roll.run", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(77)
            }
            guard confirmMotion else {
                let payload = ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"roll run\" requires --confirm-motion (it creates the project and starts the scan).",
                    guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
                )
                let text = try ControlCLIOutput.renderError(command: "roll.run", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(77)
            }
        }

        func run() async throws {
            try await RollRun.run(
                name: name,
                carrier: carrier,
                requestedFrameCount: frameCount,
                filmProcess: filmProcess,
                skipBlank: skipBlank,
                autoApprove: autoApprove,
                wait: wait,
                allowUnverifiedHardware: allowUnverifiedHardware,
                options: options
            )
        }
    }
}

/// D-15's own composition. Kept separate from `Roll.Run` (which owns only
/// parsing/validation) so `RollRunReceiptTests.swift` can exercise
/// `ControlRunReceipt` itself -- the pure, unit-testable half of this file
/// -- with no ArgumentParser, no subprocess, and no socket. This type is
/// the only thing in this file that opens a connection.
enum RollRun {
    static func run(
        name: String,
        carrier: SimulatedFilmCarrier,
        requestedFrameCount: Int?,
        filmProcess: FilmProcess,
        skipBlank: Bool,
        autoApprove: Bool,
        wait: Bool,
        allowUnverifiedHardware: Bool,
        options: GlobalOptions,
        job: ScanJobDocument? = nil
    ) async throws {
        let command = job == nil ? "roll.run" : "run"
        let client = try await CommandRunner.openConnection(command: command, options: options)
        var receipt = ControlRunReceipt()
        var exitCode: Int32 = 0
        if let job {
            guard let initialData = try await sendStep(
                "initialStatus", method: "status", params: EmptyParams(),
                command: command, options: options, client: client,
                receipt: &receipt, exitCode: &exitCode
            ) else {
                try await finish(receipt: receipt, exitCode: exitCode, command: command, options: options, client: client)
                return
            }
            guard let initialStatus = try? JSONDecoder().decode(ControlStatusResult.self, from: initialData) else {
                try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
            }
            guard initialStatus.projectDirectory == nil else {
                let payload = ControlErrorPayload(
                    .gateRefused,
                    message: "A declarative new-roll job requires a host with no open project."
                )
                exitCode = recordRefusal(
                    payload, step: "initialProject", command: "status",
                    startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt
                )
                try await finish(receipt: receipt, exitCode: exitCode, command: command, options: options, client: client)
                return
            }
            guard try await sendStep("connect", method: "scanner.connect", params: ControlScannerConnectParams(deviceId: job.deviceId, allowUnverifiedHardware: allowUnverifiedHardware),
                                    command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode) != nil else {
                try await finish(receipt: receipt, exitCode: exitCode, command: command, options: options, client: client)
                return
            }
        }

        try await walk(
            name: name, carrier: carrier, requestedFrameCount: requestedFrameCount,
            filmProcess: filmProcess, skipBlank: skipBlank, autoApprove: autoApprove, wait: wait,
            allowUnverifiedHardware: allowUnverifiedHardware, job: job,
            command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
        )

        try await finish(receipt: receipt, exitCode: exitCode, command: command, options: options, client: client)
    }

    // MARK: - The walk itself (D-15's seven numbered steps)

    private static func walk(
        name: String,
        carrier: SimulatedFilmCarrier,
        requestedFrameCount: Int?,
        filmProcess: FilmProcess,
        skipBlank: Bool,
        autoApprove: Bool,
        wait: Bool,
        allowUnverifiedHardware: Bool,
        job: ScanJobDocument?,
        command: String,
        options: GlobalOptions,
        client: ControlChannelClient,
        receipt: inout ControlRunReceipt,
        exitCode: inout Int32
    ) async throws {
        // Subscribe BEFORE preview.acquire (step 2) -- JobWaiter.subscribe's
        // own "call before the start request" ordering rule (JobWaiter.swift),
        // reused here so the previewComplete transition (step 3) is never
        // missed, and so the returned pre-run jobId is what step 7's wait
        // compares against.
        let preRunJobId: String?
        do {
            preRunJobId = try await JobWaiter.subscribe(client: client)
        } catch {
            try await CommandRunner.fail(command: command, options: options, client: client, error: error)
        }

        // Step 1: scanner.refresh (with D-16's one permitted reconnect),
        // then status -- the same pair `status --refresh` sends.
        guard try await refreshScanner(command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode, allowUnverifiedHardware: allowUnverifiedHardware) else { return }
        guard let statusData = try await sendStep(
            "status", method: "status", params: EmptyParams(),
            command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
        ) else { return }
        guard let status = try? JSONDecoder().decode(ControlStatusResult.self, from: statusData) else {
            try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
        }

        if job != nil {
            let filmLoaded = status.device?.kind == "simulated" ? status.scanner?.mediaLoaded == true : status.scanner?.filmPresent == true
            guard status.projectDirectory == nil, filmLoaded, status.motionAllowed else {
                let payload = ControlErrorPayload(.gateRefused, message: "A declarative new-roll job requires a host with no open project, loaded film, and motion readiness.")
                exitCode = recordRefusal(payload, step: "initialReadiness", command: "status", startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt)
                return
            }
        }

        // `refreshScanner` can succeed without reconnecting when the GUI
        // already opened an unverified device. The run flag is per-command;
        // never inherit the GUI's opt-in through that live session.
        if UnverifiedHardwarePolicy.shouldRefuseConnectedUnverified(
            verification: status.scanner?.hardwareVerification,
            allowUnverified: allowUnverifiedHardware
        ) {
            let payload = ControlErrorPayload(
                code: "NOT_SUPPORTED",
                message: "\"roll run\" requires --allow-unverified-hardware for an unverified scanner.",
                recoverable: false,
                guidance: "Retry with --allow-unverified-hardware after confirming the scanner is intended for this run."
            )
            exitCode = recordRefusal(
                payload,
                step: "status",
                command: "status",
                startedAt: ControlRunReceipt.isoTimestamp(),
                receipt: &receipt
            )
            return
        }

        guard let frameCount = requestedFrameCount ?? status.scanner?.frameCount else {
            let payload = ControlErrorPayload(
                .gateRefused,
                message: "\"roll run\" has no --frame-count and the scanner's own status reported none; refusing rather than guessing how many frames to move."
            )
            exitCode = recordRefusal(payload, step: "frameCount", command: "frameCount", startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt)
            return
        }

        if let job {
            // A new roll has no registration/project yet. Check everything
            // else, including output space, before acquiring its preview;
            // the complete report is checked again before capture below.
            guard let data = try await sendStep(
                "previewPreflight", method: "scan.preflight",
                params: ControlScanPreflightParams(frames: job.frames, capture: job.capture, outputs: job.outputs, deviceId: job.deviceId),
                command: command, options: options, client: client,
                receipt: &receipt, exitCode: &exitCode
            ) else { return }
            let report = try JSONDecoder().decode(ScanPreflightReport.self, from: data)
            if let failed = report.checks.first(where: {
                !$0.passed && $0.code != "REGISTRATION_REQUIRED" && $0.code != "SCAN_NOT_READY"
            }) {
                exitCode = recordRefusal(
                    ControlErrorPayload(.gateRefused, message: failed.guidance),
                    step: failed.code, command: "scan.preflight",
                    startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt
                )
                return
            }
            guard try await sendStep(
                "settings", method: "settings.set",
                params: ControlSettingsSetParams(capture: job.capture, processing: job.processing),
                command: command, options: options, client: client,
                receipt: &receipt, exitCode: &exitCode
            ) != nil else { return }
        }

        // Step 2: preview.acquire.
        guard let previewData = try await sendStep(
            "preview", method: "preview.acquire",
            params: ControlPreviewAcquireParams(filmLoadedConfirmed: true, filmProcess: filmProcess),
            command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
        ) else { return }
        guard let previewResult = try? JSONDecoder().decode(ControlPreviewAcquireResult.self, from: previewData) else {
            try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
        }
        // A "rejected"/"failedToStart" outcome is a definitive, successful
        // answer (Preview's own doc comment, MotionCommands.swift) -- not a
        // refusal -- but there is no preview in progress to wait on, so the
        // walk ends here at exit 0: nothing further can be attempted.
        guard previewResult.outcome == "started" else { return }

        // Step 3: wait for previewComplete off the event stream this run
        // already subscribed to -- never a `status` poll of its own.
        let previewStartedAt = ControlRunReceipt.isoTimestamp()
        let previewCompleted = await waitForPreviewComplete(client: client)
        guard previewCompleted else {
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.internalCode.rawValue,
                message: "\"roll run\" was waiting for the preview to complete, but it did not within the bound.",
                recoverable: false
            )
            exitCode = recordRefusal(payload, step: "previewComplete", command: "previewComplete", startedAt: previewStartedAt, receipt: &receipt)
            return
        }
        receipt.record(step: "previewComplete", command: "previewComplete", exitCode: 0, outcome: "ok", startedAt: previewStartedAt, endedAt: ControlRunReceipt.isoTimestamp())

        // Step 4: frames.list, then frames.select -- reusing
        // SkipBlankSelection (ScanStudioKit/ControlCLISupport.swift), the
        // same pure rule `frames select --skip-blank` uses, without
        // re-opening a connection.
        guard let listData = try await sendStep(
            "framesList", method: "frames.list", params: EmptyParams(),
            command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
        ) else { return }
        guard let framesList = try? JSONDecoder().decode(ControlFramesListResult.self, from: listData) else {
            try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
        }

        let selected: [Int]
        let skippedSummaries: [ControlFrameSummary]
        if let job {
            selected = job.frames
            skippedSummaries = []
            guard Set(selected).isSubset(of: Set(framesList.frames.map(\.index))) else {
                let payload = ControlErrorPayload(.gateRefused, message: "The preview does not contain every frame in the approved job.")
                exitCode = recordRefusal(payload, step: "framesSelect", command: "frames.select", startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt)
                return
            }
        } else if skipBlank {
            (selected, skippedSummaries) = SkipBlankSelection.select(from: framesList.frames, threshold: BlankFrameHint.defaultSkipThreshold)
        } else {
            selected = framesList.frames.map(\.index)
            skippedSummaries = []
        }
        // T-03-30: silently selecting nothing would look like success --
        // the same refusal `frames select --skip-blank` already gives this
        // exact condition (FrameCommands.swift's own runSkipBlank).
        guard !selected.isEmpty else {
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.invalidRange.rawValue,
                message: "\"roll run\" would select no frames: no previewed frames are available to scan.",
                recoverable: false
            )
            exitCode = recordRefusal(payload, step: "framesSelect", command: "frames.select", startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt)
            return
        }

        let selectParams = (skipBlank || job != nil) ? ControlFramesSelectParams(indices: selected) : ControlFramesSelectParams(all: true)
        guard (try await sendStep(
            "framesSelect", method: "frames.select", params: selectParams,
            command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
        )) != nil else { return }
        receipt.frames.selected = selected
        receipt.frames.skipped = skippedSummaries.map(\.index)

        // Step 5: roll.save.
        guard let saveData = try await sendStep(
            "rollSave", method: "roll.save",
            params: ControlRollSaveParams(name: name, carrier: carrier, frameCount: frameCount, filmProcess: filmProcess, motionConfirmed: job == nil, startScan: job == nil),
            command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
        ) else { return }
        guard let saveResult = try? JSONDecoder().decode(ControlRollSaveResult.self, from: saveData) else {
            try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
        }
        receipt.project = ControlRunReceipt.Project(name: saveResult.projectName, directory: saveResult.projectDirectory)

        var scanOutcome = saveResult.outcome
        if let job {
            guard let directory = saveResult.projectDirectory else {
                try await CommandRunner.fail(
                    command: command, options: options, client: client,
                    error: ControlChannelClientError.malformedResponse
                )
            }
            let path = URL(fileURLWithPath: directory).appendingPathComponent("approved-job-" + UUID().uuidString + ".json")
            do {
                try job.normalizedJSON().write(to: path, options: .withoutOverwriting)
                receipt.approvedJobPath = path.path
            } catch { try await CommandRunner.fail(command: command, options: options, client: client, error: error) }
            guard try await sendStep("outputs", method: "outputs.set", params: ControlOutputsSetParams(outputs: job.outputs),
                                    command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode) != nil,
                  let gateData = try await sendStep("preflight", method: "scan.preflight", params: ControlScanPreflightParams(frames: selected),
                                                   command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode) else { return }
            let gates = try JSONDecoder().decode(ScanPreflightReport.self, from: gateData)
            guard gates.ready else {
                let failed = gates.checks.first { !$0.passed }
                let payload = ControlErrorPayload(.gateRefused, message: failed?.guidance ?? "Preflight refused the scan.")
                exitCode = recordRefusal(payload, step: failed?.code ?? "preflight", command: "scan.preflight", startedAt: ControlRunReceipt.isoTimestamp(), receipt: &receipt)
                return
            }
            guard let data = try await sendStep("scan", method: "scan.start", params: ControlScanStartParams(motionConfirmed: true, frames: selected),
                                               command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode) else { return }
            scanOutcome = try JSONDecoder().decode(ControlScanOutcomeResult.self, from: data).outcome
        }
        var jobStarted = scanOutcome == "started"

        // Step 6: manual review, only when roll.save itself paused for one.
        if scanOutcome == "manualReviewPending" {
            guard let statusData2 = try await sendStep(
                "reviewStatus", method: "status", params: EmptyParams(),
                command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
            ) else { return }
            guard let status2 = try? JSONDecoder().decode(ControlStatusResult.self, from: statusData2) else {
                try await CommandRunner.fail(command: command, options: options, client: client, error: ControlChannelClientError.malformedResponse)
            }
            let flagged = status2.manualReviewPending?.frames ?? []
            if autoApprove, ManualReviewAutoApproval.shouldAutoApprove(flagged) {
                guard (try await sendStep(
                    "reviewApprove", method: "review.approve", params: ControlReviewApproveParams(motionConfirmed: true),
                    command: command, options: options, client: client, receipt: &receipt, exitCode: &exitCode
                )) != nil else { return }
                receipt.frames.autoApproved = flagged.map(\.index)
                jobStarted = true
            } else {
                // --auto-approve absent, or the predicate refused: the
                // review stays pending -- a legitimate outcome the
                // operator must decide, never a failure (D-15). The walk
                // ends here at exit 0.
                return
            }
        }

        // Step 7: wait for the job's terminal state, only when a job
        // actually started and the caller asked to wait.
        guard wait, jobStarted else { return }
        let onProgress: (@Sendable (ControlScanProgress) -> Void)?
        if options.quiet {
            onProgress = nil
        } else {
            onProgress = { progress in
                FileHandle.standardError.write(Data((ControlProgressLine.render(progress) + "\n").utf8))
            }
        }
        let waitStartedAt = ControlRunReceipt.isoTimestamp()
        guard let terminalResponse = try await JobWaiter.waitForTerminalOutcome(client: client, preStartJobId: preRunJobId, onProgress: onProgress) else {
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.hostUnreachable.rawValue,
                message: "\"roll.run\" was waiting on the job's event stream, but the control host went away.",
                recoverable: false
            )
            exitCode = recordRefusal(payload, step: "wait", command: "job.get", startedAt: waitStartedAt, receipt: &receipt)
            return
        }
        switch terminalResponse {
        case .result(let data):
            let jobResult = try? JSONDecoder().decode(ControlJobResult.self, from: data)
            receipt.jobId = jobResult?.jobId
            receipt.jobState = jobResult?.jobState.map { String(describing: $0) }
            guard jobResult?.jobState != .failed else {
                // The wire call itself succeeded -- only the job's own
                // terminal state was a failure -- mirroring
                // MotionStartRunner's identical tail (MotionCommands.swift).
                let payload = ControlErrorPayload(.gateRefused, message: "\"roll run\"'s job ended in a failed state.")
                exitCode = recordRefusal(payload, step: "wait", command: "job.get", startedAt: waitStartedAt, receipt: &receipt)
                return
            }
            receipt.record(step: "wait", command: "job.get", exitCode: 0, outcome: "ok", startedAt: waitStartedAt, endedAt: ControlRunReceipt.isoTimestamp())
        case .failure(let payload):
            exitCode = recordRefusal(payload, step: "wait", command: "job.get", startedAt: waitStartedAt, receipt: &receipt)
        }
    }

    // MARK: - One request, recorded (SAFE-02's single point of enforcement)

    /// Sends one request as part of the walk and records it into `receipt`
    /// either way. Returns the raw result `Data` on success; on
    /// `.failure`, records the refusal and returns `nil` -- the walk's own
    /// signal to stop right there and attempt nothing further (SAFE-02).
    private static func sendStep<Params: Encodable & Sendable>(
        _ step: String,
        method: String,
        params: Params,
        command: String,
        options: GlobalOptions,
        client: ControlChannelClient,
        receipt: inout ControlRunReceipt,
        exitCode: inout Int32
    ) async throws -> Data? {
        let startedAt = ControlRunReceipt.isoTimestamp()
        let response = try await CommandRunner.request(command: command, method: method, params: params, options: options, client: client)
        switch response {
        case .result(let data):
            receipt.record(step: step, command: method, exitCode: 0, outcome: "ok", startedAt: startedAt, endedAt: ControlRunReceipt.isoTimestamp())
            return data
        case .failure(let payload):
            exitCode = recordRefusal(payload, step: step, command: method, startedAt: startedAt, receipt: &receipt)
            return nil
        }
    }

    /// Records `step` as a refused entry (`outcome: "refused"`, endedAt
    /// stamped now) and returns its mapped D-10 exit code -- the one place
    /// every refusal in this walk, wire-originated or CLI-local, becomes
    /// both a receipt entry and an exit code.
    private static func recordRefusal(
        _ payload: ControlErrorPayload,
        step: String,
        command: String,
        startedAt: String,
        receipt: inout ControlRunReceipt
    ) -> Int32 {
        let mapped = ControlCLIExitCode.forErrorCode(payload.code).rawValue
        receipt.record(step: step, command: command, exitCode: mapped, outcome: "refused", startedAt: startedAt, endedAt: ControlRunReceipt.isoTimestamp())
        return mapped
    }

    /// Mirrors `Status.refreshOrReconnect(client:)` (DeviceCommands.swift)
    /// exactly -- D-15 names "scanner.refresh, then status" as one step,
    /// and `status --refresh`'s own reconnect is invisible plumbing inside
    /// it, never a distinct visible failure of its own. Sends exactly one
    /// `scanner.refresh`; only on a `NOT_CONNECTED` failure does it send
    /// exactly one `scanner.connect` (no explicit device --
    /// `DeviceSelectionPolicy` resolves it, same as a bare `connect`)
    /// followed by exactly one more `scanner.refresh` -- never a loop.
    /// Records exactly one "refresh" receipt entry regardless of which
    /// path was taken.
    private static func refreshScanner(
        command: String,
        options: GlobalOptions,
        client: ControlChannelClient,
        receipt: inout ControlRunReceipt,
        exitCode: inout Int32,
        allowUnverifiedHardware: Bool
    ) async throws -> Bool {
        let startedAt = ControlRunReceipt.isoTimestamp()
        let firstResponse = try await CommandRunner.request(command: command, method: "scanner.refresh", params: EmptyParams(), options: options, client: client)
        guard case .failure(let firstPayload) = firstResponse else {
            receipt.record(step: "refresh", command: "scanner.refresh", exitCode: 0, outcome: "ok", startedAt: startedAt, endedAt: ControlRunReceipt.isoTimestamp())
            return true
        }
        guard firstPayload.code == "NOT_CONNECTED" else {
            exitCode = recordRefusal(firstPayload, step: "refresh", command: "scanner.refresh", startedAt: startedAt, receipt: &receipt)
            return false
        }

        let connectResponse = try await CommandRunner.request(command: command, method: "scanner.connect", params: ControlScannerConnectParams(allowUnverifiedHardware: allowUnverifiedHardware), options: options, client: client)
        if case .failure(let payload) = connectResponse {
            exitCode = recordRefusal(payload, step: "refresh", command: "scanner.connect", startedAt: startedAt, receipt: &receipt)
            return false
        }

        let secondResponse = try await CommandRunner.request(command: command, method: "scanner.refresh", params: EmptyParams(), options: options, client: client)
        if case .failure(let payload) = secondResponse {
            exitCode = recordRefusal(payload, step: "refresh", command: "scanner.refresh", startedAt: startedAt, receipt: &receipt)
            return false
        }

        receipt.record(step: "refresh", command: "scanner.refresh", exitCode: 0, outcome: "ok", startedAt: startedAt, endedAt: ControlRunReceipt.isoTimestamp())
        return true
    }

    /// Reads events already flowing on `client`'s subscription (armed
    /// before `preview.acquire` was sent) until a snapshot's
    /// `previewComplete` is `true`, bounded by the same 12,000 x 5ms == 60s
    /// real-sleep cadence `ControlSocketEndToEndTests.swift`'s own
    /// `EndToEndHost.waitUntilPreviewComplete()` uses. Never issues a
    /// `status` request of its own (SAFE-02/no polling).
    ///
    /// Bounding a push-based `AsyncStream` safely means the losing side of
    /// the race must actually terminate, not merely be marked cancelled --
    /// `for await` over `client.events()` does not observe cooperative
    /// cancellation on its own, so a `withTaskGroup` race plus
    /// `cancelAll()` would still hang the group's own implicit teardown on
    /// an unresponsive child. The watchdog below closes the connection on
    /// timeout instead, which is what makes `client.events()` finish
    /// (`ControlChannelClient.shutdown()`'s own documented behavior) and
    /// this function's loop return -- never an unresponsive child left
    /// behind. The watchdog is cancelled the instant this function returns
    /// for any other reason, so a preview that completes in time never has
    /// its own connection pulled out from under the rest of the walk.
    private static func waitForPreviewComplete(client: ControlChannelClient) async -> Bool {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            await client.shutdown()
        }
        defer { watchdog.cancel() }

        for await line in await client.events() {
            guard let snapshot = ControlChannelClient.decodeStatusSnapshot(fromEventLine: line) else { continue }
            if snapshot.previewComplete { return true }
        }
        return false
    }

    // MARK: - Finish (D-15's own output contract)

    /// Prints the receipt as the single JSON object on stdout -- always
    /// through `ControlCLIOutput.renderResult`, never `renderError`, even
    /// when a step refused: the receipt's own `steps` array is what names
    /// the refusal, and the run's own success/failure is the exit code
    /// alone (D-15: "the failing step's code, else 0"). When a project
    /// directory was reached, also writes the receipt beside the manifest;
    /// a failed write is a stderr warning only and never changes the exit
    /// code (SAFE-03) -- losing the on-disk copy must never be mistaken
    /// for a failed scan.
    private static func finish(
        receipt: ControlRunReceipt,
        exitCode: Int32,
        command: String,
        options: GlobalOptions,
        client: ControlChannelClient
    ) async throws {
        var receipt = receipt
        if let directory = receipt.project?.directory {
            do {
                receipt.receiptPath = try receipt.write(toProjectDirectory: directory, timestamp: Date())
            } catch {
                FileHandle.standardError.write(Data("roll run: could not write the run receipt beside the manifest: \(error)\n".utf8))
            }
        }

        let object = (try? JSONSerialization.jsonObject(with: try receipt.encodedJSON())) as? [String: Any] ?? [:]
        let text = try ControlCLIOutput.renderResult(command: command, resultJSON: object, human: options.human, context: await client.cliEnvelopeContext)
        print(text, terminator: "")
        await client.shutdown()

        guard exitCode == 0 else {
            throw ExitCode(exitCode)
        }
    }
}
