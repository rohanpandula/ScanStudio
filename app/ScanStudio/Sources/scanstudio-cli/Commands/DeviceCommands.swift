// `connect [--device <id>]` / `disconnect` / `rescan` / `status [--job
// <id>]` (D-08) -- device lifecycle and session status. Every `run()` body
// is params construction plus one `CommandRunner` call; nothing here
// dials a socket or constructs an exit code itself.

import ArgumentParser
import Foundation
import ScanStudioKit

/// `connect [--device <id>]` -> `scanner.connect`. An absent `--device` is
/// a legitimate "let the app choose" (CONTROL.md's own `scanner.connect`
/// entry, via `DeviceSelectionPolicy`), not an error.
struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect to a scanner. Omit --device to let the app choose."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("device"), help: "Device id to connect to. Omitted means let the app choose.")
    var device: String?

    func run() async throws {
        try await CommandRunner.run(
            command: "scanner.connect",
            method: "scanner.connect",
            params: ControlScannerConnectParams(deviceId: device),
            options: options
        )
    }
}

/// `disconnect` -> `scanner.disconnect`.
struct Disconnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disconnect", abstract: "Disconnect the connected scanner.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await CommandRunner.runWithoutParams(command: "scanner.disconnect", method: "scanner.disconnect", options: options)
    }
}

/// `rescan` -> `scanner.rescan`: one deliberate re-attempt of device
/// discovery.
struct Rescan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rescan", abstract: "Re-attempt scanner discovery.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await CommandRunner.runWithoutParams(command: "scanner.rescan", method: "scanner.rescan", options: options)
    }
}

/// `status [--job <id>]` -> `status`, or `job.get` when `--job` is given.
/// A `--job` id that does not match the currently tracked job is refused
/// with a CLI-originated JOB_NOT_FOUND rather than printing a mismatched
/// job -- `job.get` itself carries no job-id filter on the wire (CONTROL.md:
/// it always reports the one aggregate the session is currently tracking),
/// so this comparison is this command's own job to make.
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Report session status, or one job's status with --job.")

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("job"), help: "Report this job id's status instead of the full session snapshot.")
    var job: String?

    /// D-11: the one read-only-shaped flag that is not side-effect-free --
    /// it asks the scanner for its current state (`scanner.refresh`) before
    /// reporting. Still moves nothing: `scanner.refresh` is non-motion,
    /// exactly like the `status` command it augments.
    @Flag(name: .customLong("refresh"), help: "Ask the scanner for its live state (scanner.refresh) before reporting status. Not side-effect-free: it probes the scanner over the wire rather than reading only in-memory state. Moves nothing.")
    var refresh = false

    func run() async throws {
        let client = try await CommandRunner.openConnection(command: "status", options: options)
        if refresh {
            let refreshResponse = try await CommandRunner.requestWithoutParams(
                command: "status",
                method: "scanner.refresh",
                options: options,
                client: client
            )
            // A refresh failure is rendered and exited on immediately --
            // never swallowed, and never followed by a snapshot that would
            // hide it. A success is discarded here; the snapshot below
            // reports the now-current state, exactly as `--job` does after
            // a plain `status`.
            if case .failure = refreshResponse {
                try await CommandRunner.finish(command: "status", options: options, client: client, response: refreshResponse)
                return
            }
        }
        guard let job else {
            let response = try await CommandRunner.requestWithoutParams(command: "status", method: "status", options: options, client: client)
            try await CommandRunner.finish(command: "status", options: options, client: client, response: response)
            return
        }

        let response = try await CommandRunner.requestWithoutParams(command: "status", method: "job.get", options: options, client: client)
        guard case .result(let data) = response else {
            try await CommandRunner.finish(command: "status", options: options, client: client, response: response)
            return
        }

        let jobResult: ControlJobResult
        do {
            jobResult = try JSONDecoder().decode(ControlJobResult.self, from: data)
        } catch {
            try await CommandRunner.fail(command: "status", options: options, client: client, error: error)
        }

        guard jobResult.jobId == job else {
            // CLI-originated JOB_NOT_FOUND (ControlCLIErrorCode), distinct
            // from the channel's own vocabulary -- this comparison never
            // reaches the wire.
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.jobNotFound.rawValue,
                message: "No job with id \"\(job)\" is currently tracked.",
                recoverable: false
            )
            try await CommandRunner.finish(command: "status", options: options, client: client, response: .failure(payload))
            return
        }
        try await CommandRunner.finish(command: "status", options: options, client: client, response: response)
    }
}
