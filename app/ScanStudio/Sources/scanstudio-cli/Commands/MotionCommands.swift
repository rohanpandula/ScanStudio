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

    @Option(name: .customLong("on-frame"), help: "Run a bounded shell command once for each durable completed-frame receipt. Requires --wait.")
    var onFrame: String?

    @Option(name: .customLong("on-fail"), help: "Run a bounded shell command once if the job fails. Requires --wait.")
    var onFail: String?

    @Option(name: .customLong("frames"), help: "Scan explicit frame indices or ranges, for example 20 or 1-6,9.")
    var frameRanges: String?

    @Option(name: .customLong("repeat"), help: "Run this exact scan sequentially 1...100 times. Repeats always wait for each job.")
    var repeatCount = 1

    @Option(name: .customLong("pass"), help: "Filename/receipt pass prefix. With repeats, TOKEN becomes TOKEN01, TOKEN02, and so on.")
    var passToken: String?

    @Option(name: .customLong("on-frame-failure"), help: "Frame failure policy: stop (default) or skip for explicitly allowed meter refusals.")
    var onFrameFailure = "stop"

    @Option(name: .customLong("allow-meter-refusal-slots"), help: "Known blank frame indices or ranges eligible for a metering-refusal skip.")
    var allowedMeterRefusalRanges: String?

    @Option(name: .customLong("preset"), help: "Apply a saved scan and output preset before starting the scan.")
    var presetName: String?

    @Flag(name: .customLong("dry-run"), help: "Report cached readiness and destination gates without starting a scan.")
    var dryRun = false

    private var repeatPlan = ScanRepeatPlan(
        frames: nil,
        passTokens: [nil],
        onFrameFailure: .stop,
        allowedMeterRefusalSlots: []
    )

    mutating func validate() throws {
        guard confirmMotion || dryRun else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"scan\" requires --confirm-motion.",
                guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
            )
            let text = try ControlCLIOutput.renderError(command: "scan.start", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
        if (onFrame != nil || onFail != nil), !wait {
            throw ValidationError("--on-frame and --on-fail require --wait.")
        }
        if (onFrame != nil || onFail != nil), repeatCount != 1 {
            throw ValidationError("Hooks currently require a single scan job; omit --repeat.")
        }
        if [onFrame, onFail].compactMap({ $0 }).contains(where: { $0.isEmpty || $0.utf8.count > 4_096 }) {
            throw ValidationError("Hook commands must contain 1...4096 UTF-8 bytes.")
        }
        if let presetName {
            do { _ = try ScanRecipePresetStore().load(named: presetName) }
            catch { try PresetCommandSupport.failLocal(command: "scan.start", options: options, error: error) }
            if dryRun { throw ValidationError("Apply the preset first, then run scan --dry-run to inspect the effective settings.") }
        }
        do {
            repeatPlan = try ScanRepeatPlan.make(
                frameRanges: frameRanges,
                repeatCount: repeatCount,
                passToken: passToken,
                onFrameFailure: onFrameFailure,
                allowedMeterRefusalRanges: allowedMeterRefusalRanges
            )
        } catch let error as ScanRepeatPlan.ValidationError {
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.invalidRange.rawValue,
                message: error.message,
                recoverable: false
            )
            let text = try ControlCLIOutput.renderError(command: "scan.start", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(64)
        } catch let error as ControlFrameRangeError {
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.invalidRange.rawValue,
                message: error.message,
                recoverable: false
            )
            let text = try ControlCLIOutput.renderError(command: "scan.start", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(64)
        }
    }

    func run() async throws {
        if dryRun {
            try await MotionStartRunner.runDryRun(frames: repeatPlan.frames, resume: false, options: options)
            return
        }
        if repeatPlan.passTokens.count > 1 {
            try await MotionStartRunner.runRepeatedScan(
                frames: repeatPlan.frames,
                passTokens: repeatPlan.passTokens.compactMap { $0 },
                onFrameFailure: repeatPlan.onFrameFailure,
                allowedMeterRefusalSlots: repeatPlan.allowedMeterRefusalSlots,
                options: options,
                quiet: options.quiet, presetName: presetName
            )
            return
        }
        try await MotionStartRunner.run(
            command: "scan.start",
            method: "scan.start",
            params: ControlScanStartParams(
                motionConfirmed: true,
                frames: repeatPlan.frames,
                passToken: repeatPlan.passTokens[0],
                onFrameFailure: repeatPlan.onFrameFailure,
                allowedMeterRefusalSlots: repeatPlan.allowedMeterRefusalSlots
            ),
            options: options,
            wait: wait,
            quiet: options.quiet, presetName: presetName,
            onFrame: onFrame,
            onFail: onFail
        )
    }
}

struct ScanRepeatPlan: Codable, Equatable {
    struct ValidationError: Error {
        let message: String
    }

    let frames: [Int]?
    let passTokens: [String?]
    let onFrameFailure: ScanFrameFailurePolicy
    let allowedMeterRefusalSlots: [Int]

    static func make(
        frameRanges: String?,
        repeatCount: Int,
        passToken: String?,
        onFrameFailure: String,
        allowedMeterRefusalRanges: String?
    ) throws -> Self {
        guard (1...100).contains(repeatCount) else {
            throw ValidationError(message: "--repeat must be within 1...100, got \(repeatCount).")
        }
        if repeatCount > 1, passToken == nil {
            throw ValidationError(message: "--pass is required when --repeat is greater than 1.")
        }
        let frames = try frameRanges.map(ControlFrameRangeParser.parse)
        guard let policy = ScanFrameFailurePolicy(rawValue: onFrameFailure) else {
            throw ValidationError(message: "--on-frame-failure must be stop or skip.")
        }
        let allowedSlots = try allowedMeterRefusalRanges.map(ControlFrameRangeParser.parse) ?? []
        if policy == .stop, !allowedSlots.isEmpty {
            throw ValidationError(message: "--allow-meter-refusal-slots requires --on-frame-failure skip.")
        }
        if policy == .skip {
            guard !allowedSlots.isEmpty else {
                throw ValidationError(message: "--on-frame-failure skip requires --allow-meter-refusal-slots.")
            }
            if let frames, !allowedSlots.allSatisfy(frames.contains) {
                throw ValidationError(message: "--allow-meter-refusal-slots must be a subset of --frames.")
            }
        }
        let tokens: [String?]
        if repeatCount == 1 {
            tokens = [passToken]
        } else {
            tokens = (1...repeatCount).map { "\(passToken!)\(String(format: "%02d", $0))" }
        }
        for token in tokens.compactMap({ $0 }) {
            guard validPassToken(token) else {
                throw ValidationError(
                    message: "--pass must produce 1...64 ASCII letters, digits, '.', '_', or '-' (and not '.' or '..')."
                )
            }
        }
        return Self(
            frames: frames,
            passTokens: tokens,
            onFrameFailure: policy,
            allowedMeterRefusalSlots: allowedSlots
        )
    }

    private static func validPassToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 64 && token != "." && token != ".."
            && token.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 46 || $0 == 95 || $0 == 45
            }
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

    @Option(name: .customLong("on-frame"), help: "Run a bounded shell command once for each durable completed-frame receipt. Requires --wait.")
    var onFrame: String?

    @Option(name: .customLong("on-fail"), help: "Run a bounded shell command once if the job fails. Requires --wait.")
    var onFail: String?

    @Flag(name: .customLong("dry-run"), help: "Report cached pending-frame gates without resuming.")
    var dryRun = false

    mutating func validate() throws {
        guard confirmMotion || dryRun else {
            let payload = ControlErrorPayload(
                .confirmationRequired,
                message: "\"resume\" requires --confirm-motion.",
                guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
            )
            let text = try ControlCLIOutput.renderError(command: "scan.resume", payload: payload, human: options.human)
            print(text, terminator: "")
            throw ExitCode(77)
        }
        if (onFrame != nil || onFail != nil), !wait {
            throw ValidationError("--on-frame and --on-fail require --wait.")
        }
        if [onFrame, onFail].compactMap({ $0 }).contains(where: { $0.isEmpty || $0.utf8.count > 4_096 }) {
            throw ValidationError("Hook commands must contain 1...4096 UTF-8 bytes.")
        }
    }

    func run() async throws {
        if dryRun {
            try await MotionStartRunner.runDryRun(frames: nil, resume: true, options: options)
            return
        }
        try await MotionStartRunner.run(
            command: "scan.resume",
            method: "scan.resume",
            params: ControlScanResumeParams(motionConfirmed: true),
            options: options,
            wait: wait,
            quiet: options.quiet,
            onFrame: onFrame,
            onFail: onFail
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
    static func runDryRun(frames: [Int]?, resume: Bool, options: GlobalOptions) async throws {
        let command = "scan.preflight"
        let client = try await CommandRunner.openConnection(command: command, options: options)
        try await preflight(command: command, client: client, frames: frames, resume: resume, options: options, dryRun: true)
    }

    static func preflight(
        command: String, client: ControlChannelClient, frames: [Int]?, resume: Bool,
        options: GlobalOptions, dryRun: Bool = false
    ) async throws {
        let response = try await CommandRunner.request(
            command: command, method: "scan.preflight",
            params: ControlScanPreflightParams(frames: frames, resume: resume), options: options, client: client
        )
        guard case .result(let data) = response else {
            try await CommandRunner.finish(command: command, options: options, client: client, response: response)
            return
        }
        let report: ScanPreflightReport
        do { report = try JSONDecoder().decode(ScanPreflightReport.self, from: data) }
        catch { try await CommandRunner.fail(command: command, options: options, client: client, error: error) }
        if dryRun || !report.ready {
            try await CommandRunner.finish(command: command, options: options, client: client, response: response)
            if !report.ready { throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue) }
        }
    }

    static func runRepeatedScan(
        frames: [Int]?,
        passTokens: [String],
        onFrameFailure: ScanFrameFailurePolicy,
        allowedMeterRefusalSlots: [Int],
        options: GlobalOptions,
        quiet: Bool,
        presetName: String? = nil
    ) async throws {
        let command = "scan.start"
        let client = try await CommandRunner.openConnection(command: command, options: options)
        if let presetName {
            try await PresetCommandSupport.apply(name: presetName, options: options, command: command, emitResult: false, existingClient: client)
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
            let resolvedFrames: [Int]
            if let frames {
                resolvedFrames = frames
            } else {
                let response = try await CommandRunner.requestWithoutParams(
                    command: command,
                    method: "frames.list",
                    options: options,
                    client: client
                )
                guard case .result(let data) = response else {
                    try await CommandRunner.finish(command: command, options: options, client: client, response: response)
                    return
                }
                resolvedFrames = try JSONDecoder().decode(
                    ControlFramesListResult.self,
                    from: data
                ).selectedFrames
            }
            var previousJobId = try await JobWaiter.subscribe(client: client)
            var jobs: [[String: Any]] = []
            for passToken in passTokens {
                try await preflight(command: command, client: client, frames: resolvedFrames, resume: false, options: options)
                let response = try await CommandRunner.request(
                    command: command,
                    method: "scan.start",
                    params: ControlScanStartParams(
                        motionConfirmed: true,
                        frames: resolvedFrames,
                        passToken: passToken,
                        onFrameFailure: onFrameFailure,
                        allowedMeterRefusalSlots: allowedMeterRefusalSlots
                    ),
                    options: options,
                    client: client
                )
                guard case .result(let startData) = response else {
                    try await CommandRunner.finish(command: command, options: options, client: client, response: response)
                    return
                }
                let startObject = ((try? JSONSerialization.jsonObject(with: startData)) as? [String: Any]) ?? [:]
                if startObject["outcome"] as? String == "manualReviewPending" {
                    try await CommandRunner.finish(command: command, options: options, client: client, response: response)
                    return
                }
                guard let terminal = try await JobWaiter.waitForTerminalOutcome(
                    client: client,
                    preStartJobId: previousJobId,
                    onProgress: onProgress
                ) else {
                    await client.shutdown()
                    let payload = ControlErrorPayload(
                        code: ControlCLIErrorCode.hostUnreachable.rawValue,
                        message: "\"scan.start\" was waiting on the job's event stream, but the control host went away.",
                        recoverable: false
                    )
                    let text = try ControlCLIOutput.renderError(
                        command: command,
                        payload: payload,
                        human: options.human,
                        context: await client.cliEnvelopeContext
                    )
                    print(text, terminator: "")
                    throw ExitCode(ControlCLIExitCode.noHostReachable.rawValue)
                }
                guard case .result(let data) = terminal else {
                    try await CommandRunner.finish(command: command, options: options, client: client, response: terminal)
                    return
                }
                let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
                jobs.append(object)
                let result = try JSONDecoder().decode(ControlJobResult.self, from: data)
                previousJobId = result.jobId
                let skippedKeys = Set((result.skippedFrames ?? []).map(String.init))
                let fatalFrameErrors = result.frameErrorCodes.keys.contains {
                    !skippedKeys.contains($0)
                }
                if result.jobState != .completed || fatalFrameErrors {
                    try await renderRepeatedScanResult(
                        frames: resolvedFrames,
                        passTokens: passTokens,
                        jobs: jobs,
                        options: options,
                        client: client
                    )
                    throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue)
                }
            }
            try await renderRepeatedScanResult(
                frames: resolvedFrames,
                passTokens: passTokens,
                jobs: jobs,
                options: options,
                client: client
            )
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            try await CommandRunner.fail(command: command, options: options, client: client, error: error)
        }
    }

    private static func renderRepeatedScanResult(
        frames: [Int]?,
        passTokens: [String],
        jobs: [[String: Any]],
        options: GlobalOptions,
        client: ControlChannelClient
    ) async throws {
        var result: [String: Any] = [
            "repeatCount": passTokens.count,
            "completedRepeatCount": jobs.count,
            "passTokens": passTokens,
            "jobs": jobs,
        ]
        if let frames { result["frames"] = frames }
        let text = try ControlCLIOutput.renderResult(
            command: "scan.start",
            resultJSON: result,
            human: options.human,
            context: await client.cliEnvelopeContext
        )
        print(text, terminator: "")
        await client.shutdown()
    }

    static func run<Params: Encodable & Sendable>(
        command: String,
        method: String,
        params: Params,
        options: GlobalOptions,
        wait: Bool,
        quiet: Bool,
        presetName: String? = nil,
        onFrame: String? = nil,
        onFail: String? = nil
    ) async throws {
        let client = try await CommandRunner.openConnection(command: command, options: options)
        let usesMarker = method == "scan.start" || method == "scan.resume"

        var preStartJobId: String?
        var subscribedSnapshot: ControlStatusResult?
        if wait {
            do {
                let subscription = try await JobWaiter.subscribeSnapshot(client: client)
                preStartJobId = subscription.snapshot.jobId
                subscribedSnapshot = subscription.snapshot
            } catch {
                try await CommandRunner.fail(command: command, options: options, client: client, error: error)
            }
        }

        var markerContext: ActiveJobMarker.Context?
        var marker: ActiveJobMarker?
        if usesMarker {
            switch try await resolveMarker(command: command, options: options, client: client) {
            case .none(let context):
                markerContext = context
            case .refusal(let response):
                try await CommandRunner.finish(command: command, options: options, client: client, response: response)
                return
            case .active(let existing, let context, let response):
                marker = existing
                markerContext = context
                if !wait {
                    try await CommandRunner.finish(command: command, options: options, client: client, response: response)
                    return
                }
            }
        }

        if marker == nil {
            if let presetName {
                try await PresetCommandSupport.apply(name: presetName, options: options, command: command, emitResult: false, existingClient: client)
            }
            if usesMarker {
                try await preflight(command: command, client: client, frames: (params as? ControlScanStartParams)?.frames,
                                    resume: method == "scan.resume", options: options)
            }

            let startResponse = try await CommandRunner.request(
                command: command, method: method, params: params, options: options, client: client
            )
            guard case .result(let startData) = startResponse else {
                try await CommandRunner.finish(command: command, options: options, client: client, response: startResponse)
                return
            }

            let startObject = ((try? JSONSerialization.jsonObject(with: startData)) as? [String: Any]) ?? [:]
            if startObject["outcome"] as? String == "manualReviewPending" {
                try await CommandRunner.finish(command: command, options: options, client: client, response: startResponse)
                return
            }

            if usesMarker {
                guard let outcome = try? JSONDecoder().decode(ControlScanOutcomeResult.self, from: startData),
                      let jobId = outcome.jobId,
                      let context = markerContext else {
                    try await CommandRunner.fail(
                        command: command, options: options, client: client,
                        error: ControlChannelClientError.malformedResponse
                    )
                }
                let correlationToken = await client.lastCorrelationToken(for: method)
                do {
                    marker = try ActiveJobMarker.write(
                        jobId: jobId,
                        context: context,
                        correlationToken: correlationToken
                    )
                }
                catch { try await CommandRunner.fail(command: command, options: options, client: client, error: error) }
            }
        }

        let targetJobId = marker?.jobId
        let hooks = HookDeliveryCoordinator(
            onFrame: onFrame,
            onFail: onFail,
            marker: marker,
            context: markerContext
        )
        if let subscribedSnapshot { hooks?.observe(subscribedSnapshot) }
        guard wait else {
            let jobResponse = try await CommandRunner.request(
                command: command, method: "job.get",
                params: ControlJobGetParams(jobId: targetJobId),
                options: options, client: client
            )
            if let marker, let markerContext,
               case .result(let data) = jobResponse,
               (try? JSONDecoder().decode(ControlJobResult.self, from: data).jobState?.isTerminal) == true {
                try? ActiveJobMarker.retire(marker, from: markerContext)
            }
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
                targetJobId: targetJobId,
                initialSnapshot: subscribedSnapshot,
                onProgress: onProgress,
                onSnapshot: { hooks?.observe($0) }
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
            let finalJob = try? JSONDecoder().decode(ControlJobResult.self, from: data)
            if let finalJob { hooks?.observeFailure(finalJob) }
            if let marker, let markerContext {
                try ActiveJobMarker.retire(marker, from: markerContext)
            }
            let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            let text = try ControlCLIOutput.renderResult(command: command, resultJSON: object, human: options.human, context: await client.cliEnvelopeContext)
            print(text, terminator: "")
            await client.shutdown()
            let finalState = finalJob?.jobState
            if finalState == .failed {
                throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            try await CommandRunner.fail(command: command, options: options, client: client, error: error)
        }
    }

    private enum MarkerResolution {
        case none(ActiveJobMarker.Context?)
        case active(ActiveJobMarker, ActiveJobMarker.Context, ControlClientResponse)
        case refusal(ControlClientResponse)
    }

    private static func resolveMarker(
        command: String,
        options: GlobalOptions,
        client: ControlChannelClient
    ) async throws -> MarkerResolution {
        do {
            guard let context = try await ActiveJobMarker.context(
                client: client,
                socketPath: CommandRunner.socketPath(options)
            ) else { return .none(nil) }
            guard let marker = try ActiveJobMarker.load(from: context) else { return .none(context) }
            guard marker.matches(context) else {
                return .refusal(.failure(ControlErrorPayload(
                    .gateRefused,
                    message: "The active-job marker belongs to a different socket, host session, or project.",
                    guidance: "Inspect the recorded job and host identity before retiring the marker or starting new motion."
                )))
            }
            let response = try await CommandRunner.request(
                command: command,
                method: "job.get",
                params: ControlJobGetParams(jobId: marker.jobId),
                options: options,
                client: client
            )
            switch response {
            case .failure(let payload) where payload.code == "JOB_NOT_FOUND":
                try ActiveJobMarker.retire(marker, from: context)
                return .none(context)
            case .failure:
                return .refusal(response)
            case .result(let data):
                guard let job = try? JSONDecoder().decode(ControlJobResult.self, from: data),
                      job.jobId == marker.jobId,
                      let state = job.jobState else {
                    return .refusal(.failure(ControlErrorPayload(
                        .gateRefused,
                        message: "The host could not attribute the active-job marker to an exact live job.",
                        guidance: "Inspect job and host evidence before starting new motion."
                    )))
                }
                if state.isTerminal {
                    try ActiveJobMarker.retire(marker, from: context)
                    return .none(context)
                }
                return .active(marker, context, response)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            return .refusal(.failure(ControlErrorPayload(
                .gateRefused,
                message: "The active-job marker could not be validated: \(error.localizedDescription)",
                guidance: "Inspect the marker and host evidence before starting new motion."
            )))
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
