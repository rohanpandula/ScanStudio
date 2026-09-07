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
        abstract: "List, select, include, or exclude project frames.",
        subcommands: [List.self, Select.self, Include.self, Exclude.self]
    )

    /// `frames list` -> `frames.list`: one request, no state change.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List every frame and the current selection.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await CommandRunner.runWithoutParams(command: "frames.list", method: "frames.list", options: options)
        }
    }

    /// `frames select <ranges> | --all | --none` -> `frames.select` (CR-02):
    /// the pre-project bulk selection command that unblocks a cold
    /// `connect -> preview -> select -> save` CLI-only session -- see
    /// `ControlFramesSelectParams`'s own doc comment. Not a motion command
    /// -- no confirmation flag. Exactly one of the range argument, `--all`,
    /// or `--none` is required; that shape is validated here, before any
    /// connection opens, mirroring `Include`/`Exclude`'s own D-12 range
    /// parse-time gate.
    struct Select: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select",
            abstract: "Select frames before a project exists: a CUPS-syntax range (e.g. 1-6), or --all, or --none."
        )

        @OptionGroup var options: GlobalOptions

        @Argument(help: "A CUPS-syntax frame range, e.g. \"1-6\". Omit when using --all or --none.")
        var ranges: String?

        @Flag(name: .customLong("all"), help: "Select every previewed frame.")
        var all = false

        @Flag(name: .customLong("none"), help: "Clear the selection.")
        var none = false

        /// D-12/HEAD-06: selects previewed frames whose `blankConfidence`
        /// is below `--blank-threshold` (default
        /// `BlankFrameHint.defaultSkipThreshold`). A frame with no
        /// `blankConfidence` at all (no decodable raster) is always kept --
        /// an unscored frame is never skipped on the strength of a hint
        /// that does not exist.
        @Flag(name: .customLong("skip-blank"), help: "Select previewed frames whose blank-frame confidence is below the threshold, printing what it skipped and why.")
        var skipBlank = false

        @Option(name: .customLong("blank-threshold"), help: "0..1, only with --skip-blank. Defaults to 0.8.")
        var blankThreshold: Double?

        private var parsedIndices: [Int] = []
        private var resolvedBlankThreshold = BlankFrameHint.defaultSkipThreshold

        mutating func validate() throws {
            guard [ranges != nil, all, none, skipBlank].filter({ $0 }).count == 1 else {
                let payload = ControlErrorPayload(
                    code: ControlCLIErrorCode.invalidRange.rawValue,
                    message: "\"frames select\" requires exactly one of a range argument, --all, --none, or --skip-blank.",
                    recoverable: false
                )
                let text = try ControlCLIOutput.renderError(command: "frames.select", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(64)
            }
            if let blankThreshold {
                guard skipBlank, (0...1).contains(blankThreshold) else {
                    let payload = ControlErrorPayload(
                        code: ControlCLIErrorCode.invalidRange.rawValue,
                        message: "--blank-threshold requires --skip-blank and must be within 0...1, got \(blankThreshold).",
                        recoverable: false
                    )
                    let text = try ControlCLIOutput.renderError(command: "frames.select", payload: payload, human: options.human)
                    print(text, terminator: "")
                    throw ExitCode(64)
                }
                resolvedBlankThreshold = blankThreshold
            }
            guard let ranges else { return }
            do {
                parsedIndices = try ControlFrameRangeParser.parse(ranges)
            } catch let error as ControlFrameRangeError {
                let payload = ControlErrorPayload(
                    code: ControlCLIErrorCode.invalidRange.rawValue,
                    message: error.message,
                    recoverable: false
                )
                let text = try ControlCLIOutput.renderError(command: "frames.select", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(64)
            }
        }

        func run() async throws {
            guard skipBlank else {
                let params: ControlFramesSelectParams
                if all {
                    params = ControlFramesSelectParams(all: true)
                } else if none {
                    params = ControlFramesSelectParams(none: true)
                } else {
                    params = ControlFramesSelectParams(indices: parsedIndices)
                }
                try await CommandRunner.run(command: "frames.select", method: "frames.select", params: params, options: options)
                return
            }
            try await runSkipBlank(threshold: resolvedBlankThreshold, options: options)
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

/// `--skip-blank`'s own request sequence (D-12/HEAD-06): `frames.list`
/// first, decoded as `ControlFramesListResult`; then, on the same
/// connection, `frames.select` with the computed indices. The selection
/// rule is literal: a frame is *kept* when it has no `blankConfidence` at
/// all (an unscored frame is never skipped on the strength of a hint that
/// does not exist) or its `blankConfidence` is below `threshold`; every
/// other frame is *skipped*. An empty `frames.list` or an all-skipped
/// result both refuse with a CLI-originated INVALID_RANGE-class payload,
/// exit 64 -- silently selecting nothing would look like success
/// (T-03-30). On success, `skipped` (index + score, the same one this
/// command prints before sending `frames.select`) is merged into the
/// rendered `frames.select` result so stdout stays exactly one JSON object
/// (D-09).
private func runSkipBlank(threshold: Double, options: GlobalOptions) async throws {
    let command = "frames.select"
    let client = try await CommandRunner.openConnection(command: command, options: options)
    let listResponse = try await CommandRunner.requestWithoutParams(
        command: command, method: "frames.list", options: options, client: client
    )
    guard case .result(let listData) = listResponse else {
        try await CommandRunner.finish(command: command, options: options, client: client, response: listResponse)
        return
    }
    guard let framesList = try? JSONDecoder().decode(ControlFramesListResult.self, from: listData) else {
        try await CommandRunner.fail(
            command: command,
            options: options,
            client: client,
            error: ControlChannelClientError.malformedResponse
        )
    }

    guard !framesList.frames.isEmpty else {
        await client.shutdown()
        try renderSkipBlankRefusal(
            command: command,
            message: "\"frames select --skip-blank\" found no previewed frames -- no preview has completed yet.",
            options: options
        )
        throw ExitCode(64)
    }

    let (kept, skipped) = SkipBlankSelection.select(from: framesList.frames, threshold: threshold)

    guard !kept.isEmpty else {
        await client.shutdown()
        let highestScore = skipped.compactMap(\.blankConfidence).max() ?? 0
        try renderSkipBlankRefusal(
            command: command,
            message: "\"frames select --skip-blank\" would select no frames: every previewed frame scored at or above the \(threshold) threshold (highest \(highestScore)).",
            options: options
        )
        throw ExitCode(64)
    }

    let selectResponse = try await CommandRunner.request(
        command: command,
        method: "frames.select",
        params: ControlFramesSelectParams(indices: kept),
        options: options,
        client: client
    )
    switch selectResponse {
    case .result(let data):
        let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let base = try ControlCLIOutput.renderResult(command: command, resultJSON: object, human: options.human)
        print(try mergeSkippedIntoRenderedOutput(base, skipped: skipped, human: options.human), terminator: "")
        await client.shutdown()
    case .failure(let payload):
        let base = try ControlCLIOutput.renderError(command: command, payload: payload, human: options.human)
        print(try mergeSkippedIntoRenderedOutput(base, skipped: skipped, human: options.human), terminator: "")
        await client.shutdown()
        throw ExitCode(ControlCLIExitCode.forErrorCode(payload.code).rawValue)
    }
}

private func renderSkipBlankRefusal(command: String, message: String, options: GlobalOptions) throws {
    let payload = ControlErrorPayload(code: ControlCLIErrorCode.invalidRange.rawValue, message: message, recoverable: false)
    let text = try ControlCLIOutput.renderError(command: command, payload: payload, human: options.human)
    print(text, terminator: "")
}

/// Same re-parse/re-serialize-with-`.sortedKeys` technique
/// `renderFrameSelectionRefusal` established for `applied`, generalized to
/// `--skip-blank`'s own `skipped: [{index, blankConfidence}]` array so
/// stdout stays exactly one JSON object either way.
private func mergeSkippedIntoRenderedOutput(_ base: String, skipped: [ControlFrameSummary], human: Bool) throws -> String {
    guard !human else {
        let lines = skipped.map { "  - \($0.index) (\($0.blankConfidence ?? 0))" }.joined(separator: "\n")
        return base + "skipped:\n" + lines + "\n"
    }
    guard var object = try JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any] else {
        return base
    }
    object["skipped"] = skipped.map { ["index": $0.index, "blankConfidence": $0.blankConfidence ?? 0] }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return (String(data: data, encoding: .utf8) ?? base) + "\n"
}
