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

    @Flag(name: .customLong("allow-unverified-hardware"), help: "Allow connecting to a recognized but unverified scanner for this command.")
    var allowUnverifiedHardware = false

    func run() async throws {
        try await CommandRunner.run(
            command: "scanner.connect",
            method: "scanner.connect",
            params: ControlScannerConnectParams(deviceId: device, allowUnverifiedHardware: allowUnverifiedHardware),
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

    @Flag(name: .customLong("watch"), help: "Stream film and registration changes from events.subscribe. Does not refresh or poll the scanner.")
    var watch = false

    mutating func validate() throws {
        if watch, job != nil {
            throw ValidationError("\"status --watch\" cannot be combined with --job.")
        }
        if watch, refresh {
            throw ValidationError("\"status --watch\" cannot be combined with --refresh.")
        }
    }

    func run() async throws {
        let client = try await CommandRunner.openConnection(command: "status", options: options)
        if watch {
            do {
                try await watchStatus(client: client)
            } catch {
                await client.shutdown()
                throw error
            }
            return
        }
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

    /// Watches the aggregate event stream without opening a second status
    /// request, refreshing the scanner, or polling. The subscribe result is
    /// the baseline; later snapshots are emitted only when the typed film or
    /// registration identity changes. Other control events remain available
    /// through `events --follow`, which deliberately has no filtering.
    private func watchStatus(client: ControlChannelClient) async throws {
        let response = try await CommandRunner.request(
            command: "status",
            method: "events.subscribe",
            params: EmptyParams(),
            options: options,
            client: client
        )
        guard case .result(let data) = response else {
            try await CommandRunner.finish(command: "status", options: options, client: client, response: response)
            return
        }
        let subscribed = try JSONDecoder().decode(ControlEventsSubscribeResult.self, from: data)
        var previous = subscribed.snapshot
        try await printWatchedSnapshot(subscribed.snapshot, eventName: "control.snapshot", client: client)

        for await line in await client.events() {
            guard let snapshot = ControlChannelClient.decodeStatusSnapshot(fromEventLine: line) else {
                guard let eventName = Self.eventName(from: line),
                      eventName == "control.dropped" || eventName == "control.hostExited"
                else { continue }
                try await printWatchEvent(line, client: client)
                if eventName == "control.hostExited" {
                    await client.shutdown()
                    throw ExitCode(ControlCLIExitCode.hostExited.rawValue)
                }
                continue
            }
            guard Self.watchIdentity(for: snapshot) != Self.watchIdentity(for: previous) else {
                continue
            }
            previous = snapshot
            let eventObject = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any]) ?? [:]
            let text = try ControlCLIOutput.renderEvent(
                command: "status",
                eventJSON: eventObject,
                human: options.human,
                context: await client.cliEnvelopeContext
            )
            print(text, terminator: "")
            fflush(stdout)
        }
        await client.shutdown()
    }

    private static func eventName(from line: Data) -> String? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return event["event"] as? String
    }

    private func printWatchEvent(_ line: Data, client: ControlChannelClient) async throws {
        guard let eventJSON = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let text = try ControlCLIOutput.renderEvent(
            command: "status",
            eventJSON: eventJSON,
            human: options.human,
            context: await client.cliEnvelopeContext
        )
        print(text, terminator: "")
        fflush(stdout)
    }

    /// The watch contract concerns physical presence and the logical
    /// registration, rather than job progress or diagnostic text. Keeping
    /// this key local means a scan-progress update cannot turn a status watch
    /// into an unbounded duplicate stream.
    private static func watchIdentity(for status: ControlStatusResult) -> WatchIdentity {
        WatchIdentity(
            filmPresent: status.scanner?.filmPresent,
            mediaLoaded: status.scanner?.mediaLoaded,
            carrier: status.scanner?.carrier,
            frameCount: status.scanner?.frameCount,
            previewComplete: status.previewComplete,
            previewOperationId: status.previewOperationId,
            projectName: status.projectName,
            projectDirectory: status.projectDirectory,
            selectedFrames: status.selectedFrames,
            scanReadiness: status.scanReadiness,
            scanReadinessReason: status.scanReadinessReason,
            pendingFrames: status.pendingFrames,
            refeedRequired: status.refeedRequired
        )
    }

    private func printWatchedSnapshot(_ snapshot: ControlStatusResult, eventName: String, client: ControlChannelClient) async throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let payload = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let text = try ControlCLIOutput.renderEvent(
            command: "status",
            eventJSON: ["event": eventName, "payload": payload],
            human: options.human,
            context: await client.cliEnvelopeContext
        )
        print(text, terminator: "")
        fflush(stdout)
    }

    private struct WatchIdentity: Equatable {
        let filmPresent: Bool?
        let mediaLoaded: Bool?
        let carrier: String?
        let frameCount: Int?
        let previewComplete: Bool
        let previewOperationId: String?
        let projectName: String?
        let projectDirectory: String?
        let selectedFrames: [Int]
        let scanReadiness: String
        let scanReadinessReason: String?
        let pendingFrames: [Int]
        let refeedRequired: Bool
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
            params: ControlScannerConnectParams(allowUnverifiedHardware: false),
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
        let text = try ControlCLIOutput.renderResult(command: "status", resultJSON: object, human: options.human, context: await client.cliEnvelopeContext)
        print(text, terminator: "")
        await client.shutdown()
    }
}
