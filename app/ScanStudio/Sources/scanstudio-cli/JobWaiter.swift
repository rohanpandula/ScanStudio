// The `--wait` terminal-state observer (D-13/CLI-08), shared identically by
// `scan --wait` and `resume --wait` (Commands/MotionCommands.swift).
//
// SAFE-02 is structural here: this file sends exactly two kinds of request
// on the wire -- one subscribe and, after a terminal state is observed, one
// final aggregate fetch -- and nothing else, ever. No poll, no timer, no
// re-issue of the caller's own start request. `subscribe(client:)` must be
// called BEFORE the caller sends its own scan.start/scan.resume request, so
// no event between the start and the first read is missed (D-13).

import Foundation
import ScanStudioKit

enum JobWaiter {
    /// Subscribes on `client` and returns the pre-start `jobId` from the
    /// subscribe result's own snapshot (`nil` if no job was active yet) --
    /// the id `waitForTerminalOutcome` compares against, so a *previous*
    /// job's already-terminal state can never satisfy this wait.
    ///
    /// Call this BEFORE sending the caller's own scan.start/scan.resume
    /// request -- the subscribe response's own snapshot and every
    /// `control.changed` after it are what this file reads; nothing here
    /// asks for a fresh snapshot on its own.
    static func subscribe(client: ControlChannelClient) async throws -> String? {
        let response = try await client.requestWithoutParams(method: "events.subscribe")
        switch response {
        case .result(let data):
            return try JSONDecoder().decode(ControlEventsSubscribeResult.self, from: data).snapshot.jobId
        case .failure(let payload):
            // Subscribing has no documented failure mode -- a `.failure`
            // here is an unexpected protocol condition, not a wait
            // outcome, so it is thrown rather than folded into this
            // function's own return value.
            throw JobWaiterUnexpectedRefusal(payload: payload)
        }
    }

    /// Reads `client.events()` until a snapshot's `jobId` differs from
    /// `preStartJobId` **and** its `jobState.isTerminal` is true, then
    /// issues exactly one final aggregate fetch and returns its raw
    /// result. Returns `nil` if the event stream ends first -- the host
    /// went away mid-wait (a HOST_UNREACHABLE-class outcome for the caller
    /// to report, not a hang). Sends nothing else in between: no snapshot
    /// polling, no timer, no re-issue of anything.
    ///
    /// No timeout in this phase (`--timeout` is Phase 6, AUTO-01) -- a real
    /// scan can run for as long as the film takes.
    static func waitForTerminalOutcome(
        client: ControlChannelClient,
        preStartJobId: String?
    ) async throws -> ControlClientResponse? {
        for await line in await client.events() {
            guard let snapshot = ControlChannelClient.decodeStatusSnapshot(fromEventLine: line) else {
                continue
            }
            guard let jobId = snapshot.jobId, jobId != preStartJobId else { continue }
            guard let jobState = snapshot.jobState, jobState.isTerminal else { continue }
            return try await client.requestWithoutParams(method: "job.get")
        }
        return nil
    }
}

/// See `JobWaiter.subscribe(client:)`'s doc comment.
struct JobWaiterUnexpectedRefusal: Error, Sendable {
    let payload: ControlErrorPayload
}
