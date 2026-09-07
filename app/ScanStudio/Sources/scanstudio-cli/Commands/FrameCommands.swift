// `frames list|include|exclude` (D-08). `List` is one read-only request;
// `Include`/`Exclude` validate the CUPS range client-side in `validate()`
// -- before any socket is opened (D-12) -- then send one
// frames.include/frames.exclude per index in ascending order over a
// single connection, stopping at the first refusal (SAFE-02: a partial
// application is reported, never retried or worked around).

import ArgumentParser
import Foundation
import ScanStudioKit

struct Frames: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frames",
        abstract: "List, include, or exclude project frames.",
        subcommands: [List.self, Include.self, Exclude.self]
    )

    /// `frames list` -> `frames.list`: one request, no state change.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List every frame and the current selection.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await CommandRunner.runWithoutParams(command: "frames.list", method: "frames.list", options: options)
        }
    }

    struct Include: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "include", abstract: "Include frames by a CUPS-syntax range, e.g. 1-36,38.")

        @OptionGroup var options: GlobalOptions

        @Argument(help: "A CUPS-syntax frame range, e.g. \"1-36,38\".")
        var ranges: String

        private var parsedIndices: [Int] = []

        /// D-12: the range's shape is validated here, before any
        /// connection is opened -- a malformed range never opens a
        /// socket. Refused with a typed INVALID_RANGE body, mirroring
        /// `roll save`'s parse-time CONFIRMATION_REQUIRED pattern (Task 3
        /// of this same plan).
        mutating func validate() throws {
            do {
                parsedIndices = try ControlFrameRangeParser.parse(ranges)
            } catch let error as ControlFrameRangeError {
                let payload = ControlErrorPayload(
                    code: ControlCLIErrorCode.invalidRange.rawValue,
                    message: error.message,
                    recoverable: false
                )
                let text = try ControlCLIOutput.renderError(command: "frames.include", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(64)
            }
        }

        func run() async throws {
            try await applyFrameSelection(
                command: "frames.include",
                method: "frames.include",
                action: "include",
                indices: parsedIndices,
                options: options
            )
        }
    }

    struct Exclude: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "exclude", abstract: "Exclude frames by a CUPS-syntax range, e.g. 1-36,38.")

        @OptionGroup var options: GlobalOptions

        @Argument(help: "A CUPS-syntax frame range, e.g. \"1-36,38\".")
        var ranges: String

        private var parsedIndices: [Int] = []

        /// D-12: see `Include.validate()` -- identical shape, only the
        /// command label differs.
        mutating func validate() throws {
            do {
                parsedIndices = try ControlFrameRangeParser.parse(ranges)
            } catch let error as ControlFrameRangeError {
                let payload = ControlErrorPayload(
                    code: ControlCLIErrorCode.invalidRange.rawValue,
                    message: error.message,
                    recoverable: false
                )
                let text = try ControlCLIOutput.renderError(command: "frames.exclude", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(64)
            }
        }

        func run() async throws {
            try await applyFrameSelection(
                command: "frames.exclude",
                method: "frames.exclude",
                action: "exclude",
                indices: parsedIndices,
                options: options
            )
        }
    }
}

/// D-08/SAFE-02: opens one connection, sends `method` once per index in
/// `indices` (already ascending -- `ControlFrameRangeParser.parse`'s own
/// contract) on that single connection, and stops at the first
/// `.failure`. On full success, synthesizes a result object naming the
/// action and every applied index -- no per-command wire result exists
/// for a whole range, only for one frame at a time. On a partial
/// failure, the host's own error body is printed verbatim (T-02-14) with
/// one `applied` array added alongside it, naming exactly the indices
/// that already succeeded before the refused one -- never retried, never
/// continued past (SAFE-02).
private func applyFrameSelection(
    command: String,
    method: String,
    action: String,
    indices: [Int],
    options: GlobalOptions
) async throws {
    let client = try await CommandRunner.openConnection(command: command, options: options)
    var applied: [Int] = []
    for index in indices {
        let response = try await CommandRunner.request(
            command: command,
            method: method,
            params: ControlFrameSelectionParams(frameIndex: index),
            options: options,
            client: client
        )
        switch response {
        case .result:
            applied.append(index)
        case .failure(let payload):
            let text = try renderFrameSelectionRefusal(command: command, payload: payload, applied: applied, human: options.human)
            print(text, terminator: "")
            await client.shutdown()
            throw ExitCode(ControlCLIExitCode.forErrorCode(payload.code).rawValue)
        }
    }
    let resultData = try JSONSerialization.data(withJSONObject: ["action": action, "applied": applied])
    try await CommandRunner.finish(command: command, options: options, client: client, response: .result(resultData))
}

/// Merges an `applied` array into `ControlCLIOutput.renderError`'s own
/// output -- exactly one JSON object still reaches stdout (D-09), never
/// two, and `ControlErrorPayload` itself has no room for a sixth field
/// (T-02-14: never add one it doesn't have). JSON mode re-parses and
/// re-serializes with the identical `.sortedKeys` policy `ControlCLIOutput`
/// uses internally, so repeated renders of the same refusal stay
/// byte-identical (OUT-01). `--human` mode appends one more top-level
/// `applied:` block, matching `ControlCLIOutput`'s own array-of-scalar
/// indentation.
private func renderFrameSelectionRefusal(
    command: String,
    payload: ControlErrorPayload,
    applied: [Int],
    human: Bool
) throws -> String {
    let base = try ControlCLIOutput.renderError(command: command, payload: payload, human: human)
    guard !human else {
        let appliedLines = applied.map { "  - \($0)" }.joined(separator: "\n")
        return base + "applied:\n" + appliedLines + "\n"
    }
    guard var object = try JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any] else {
        return base
    }
    object["applied"] = applied
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return (String(data: data, encoding: .utf8) ?? base) + "\n"
}
