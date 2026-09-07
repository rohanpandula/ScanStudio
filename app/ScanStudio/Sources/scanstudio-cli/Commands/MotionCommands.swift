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

    @Option(name: .customLong("film-process"), help: "Required when --intent replaceFilmProcess is given. Passed through unvalidated -- the host reports an unrecognized value.")
    var filmProcess: String?

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
            params: PreviewAcquireWireParams(filmLoadedConfirmed: true, intent: intent, filmProcess: filmProcess),
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
            params: ReviewApproveWireParams(motionConfirmed: true),
            options: options
        )
    }
}

/// The `review` command group -- one subcommand today (`approve`), grouped
/// so the invocation reads `review approve`, matching D-08's tree.
struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Manual-review actions.",
        subcommands: [ReviewApprove.self]
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
            params: ScannerEjectWireParams(motionConfirmed: true),
            options: options
        )
    }
}

// MARK: - Wire mirrors

// `ControlPreviewAcquireParams`/`ControlReviewApproveParams`/
// `ControlScannerEjectParams` (ScanStudioKit/ControlWireProtocol.swift) each
// drop their own public initializer -- like every confirmation-bearing
// params struct (Plan 02-01's precedent), leaving only the compiler's
// memberwise one, which is `internal` and therefore invisible across this
// plain `import ScanStudioKit` module boundary. These mirrors are this
// file's own encode-direction twins, matching `RollCommands.swift`'s
// identical `RollSaveWireParams` precedent: same field names, so the
// synthesized `Encodable` conformance produces byte-identical wire JSON.

private struct PreviewAcquireWireParams: Encodable {
    let filmLoadedConfirmed: Bool
    let intent: String?
    let filmProcess: String?
}

private struct ReviewApproveWireParams: Encodable {
    let motionConfirmed: Bool
}

private struct ScannerEjectWireParams: Encodable {
    let motionConfirmed: Bool
}
