// `events --follow` (D-08/CLI-12): the one long-lived, read-only stream
// this tool offers, and the observer half of SAFE-04 -- every refusal any
// other invocation hits is also a `control.changed` this command can see.

import ArgumentParser
import Foundation
import ScanStudioKit

/// `events --follow` -> `events.subscribe`, then every event line the
/// connection receives afterward. `--follow` is required in this phase:
/// without it, this command is a usage error (exit 64) rather than a
/// one-shot command whose behaviour would need to change later once a
/// non-following mode is added.
struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Stream control-channel events as NDJSON. Requires --follow."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("follow"), help: "Required in this phase: stream events until the host closes the connection.")
    var follow = false

    mutating func validate() throws {
        guard follow else {
            throw ValidationError("\"events\" requires --follow.")
        }
    }

    /// Opens one connection, subscribes, prints the subscribe response's
    /// own snapshot as the first line (so a consumer that starts reading
    /// late still gets a baseline even if it raced the server's own
    /// pushed snapshot event), then prints one line per event afterward --
    /// including `control.dropped`, which passes through unmodified so a
    /// consumer can see it lost data rather than silently missing it. The
    /// host's own typed host-exited event and a distinct exit code for it
    /// are OPS-10 (Phase 5); this phase's contract is only that the stream
    /// ends and this command exits 0. This is the only connection this
    /// command ever opens.
    func run() async throws {
        let client = try await CommandRunner.openConnection(command: "events", options: options)
        let subscribeResponse = try await CommandRunner.request(
            command: "events", method: "events.subscribe", params: EmptyParams(), options: options, client: client
        )
        guard case .result(let data) = subscribeResponse else {
            try await CommandRunner.finish(command: "events", options: options, client: client, response: subscribeResponse)
            return
        }
        let subscribeObject = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let snapshot = subscribeObject["snapshot"] as? [String: Any] ?? [:]
        try await printEventLine(command: "events", eventName: "control.snapshot", payload: snapshot, human: options.human, context: await client.cliEnvelopeContext)

        for await line in await client.events() {
            let eventObject = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any]) ?? [:]
            let text = try ControlCLIOutput.renderEvent(command: "events", eventJSON: eventObject, human: options.human, context: await client.cliEnvelopeContext)
            print(text, terminator: "")
            fflush(stdout)
        }
        await client.shutdown()
    }

    private func printEventLine(command: String, eventName: String, payload: [String: Any], human: Bool, context: ControlCLIEnvelopeContext) throws {
        let eventJSON: [String: Any] = ["event": eventName, "payload": payload]
        let text = try ControlCLIOutput.renderEvent(command: command, eventJSON: eventJSON, human: human, context: context)
        print(text, terminator: "")
        fflush(stdout)
    }
}
