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

/// `status [--job <id>]` -> `status`, or `job.get {jobId}` when `--job` is
/// given. D-19/HEAD-12 (the 2026-09-07 batch abort): `job.get` now carries
/// an optional `jobId` on the wire and answers for the live job, one of the
/// host's last `SessionModel.maximumTerminalJobHistory` archived jobs, or
/// the host's own typed `JOB_NOT_FOUND` -- rendered verbatim here, never a
/// client-side comparison against a job.get response that carries no
/// filter of its own.
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
        var reconnected = false
        if refresh {
            reconnected = try await refreshOrReconnect(client: client)
        }
        guard let job else {
            let response = try await CommandRunner.requestWithoutParams(command: "status", method: "status", options: options, client: client)
            try await finishStatus(client: client, response: response, reconnected: reconnected)
            return
        }

        let response = try await CommandRunner.request(
            command: "status", method: "job.get", params: ControlJobGetParams(jobId: job), options: options, client: client
        )
        try await finishStatus(client: client, response: response, reconnected: reconnected)
    }

    /// D-16: the one permitted automatic reconnection in this whole tool.
    /// Sends `scanner.refresh`; only when that answer is a `.failure` whose
    /// `code` is `NOT_CONNECTED` does it send exactly one `scanner.connect`
    /// (no explicit device -- `DeviceSelectionPolicy` resolves it, same as
    /// a bare `connect`) followed by exactly one more `scanner.refresh`, on
    /// the same connection. `reconnectAttempted` is a plain `Bool`, not a
    /// counter: there is no loop and no second attempt at anything. A
    /// failure at any step -- the first refresh with a code other than
    /// `NOT_CONNECTED`, the reconnect's own `scanner.connect`, or the
    /// second refresh -- is rendered and exited on immediately by
    /// `CommandRunner.finish`, which always throws for a `.failure`
    /// response; the `return false` after each such call is never reached.
    private func refreshOrReconnect(client: ControlChannelClient) async throws -> Bool {
        let firstRefresh = try await CommandRunner.requestWithoutParams(
            command: "status", method: "scanner.refresh", options: options, client: client
        )
        guard case .failure(let payload) = firstRefresh else {
            return false
        }
        guard payload.code == "NOT_CONNECTED" else {
            try await CommandRunner.finish(command: "status", options: options, client: client, response: firstRefresh)
            return false
        }

        let connectResponse = try await CommandRunner.request(
            command: "status",
            method: "scanner.connect",
            params: ControlScannerConnectParams(),
            options: options,
            client: client
        )
        guard case .result = connectResponse else {
            try await CommandRunner.finish(command: "status", options: options, client: client, response: connectResponse)
            return false
        }

        let secondRefresh = try await CommandRunner.requestWithoutParams(
            command: "status", method: "scanner.refresh", options: options, client: client
        )
        guard case .result = secondRefresh else {
            try await CommandRunner.finish(command: "status", options: options, client: client, response: secondRefresh)
            return false
        }
        return true
    }

    /// Renders `response`'s success exactly as `CommandRunner.finish`
    /// always has, except that a `reconnected: true` key is merged into the
    /// result object first when the one permitted automatic reconnection
    /// above actually ran -- the same "merge one key into the object"
    /// technique `renderFrameSelectionRefusal` (`FrameCommands.swift`) uses
    /// for a refusal, applied here to a success so a script can see a
    /// reconnection happened rather than inferring it from timing. A
    /// `.failure` (or a call with `reconnected == false`) is untouched:
    /// `reconnected` is never merged into an error body.
    private func finishStatus(client: ControlChannelClient, response: ControlClientResponse, reconnected: Bool) async throws {
        guard reconnected, case .result(let data) = response else {
            try await CommandRunner.finish(command: "status", options: options, client: client, response: response)
            return
        }
        var object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        object["reconnected"] = true
        let text = try ControlCLIOutput.renderResult(command: "status", resultJSON: object, human: options.human)
        print(text, terminator: "")
        await client.shutdown()
    }
}
