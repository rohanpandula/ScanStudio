// CLI-facing helpers for the scanstudio-cli executable target (D-07/D-09/
// D-10/D-12).
//
// Deliberately kept in ScanStudioKit, not the scanstudio-cli target itself:
// SwiftPM's testing of executable targets is fragile, and ScanStudioKit is
// already AppKit-free, so these pure helpers get a normal ScanStudioKitTests
// home with zero new package surface (02-03-PLAN.md, Claude's Discretion).
//
// Nothing in this file imports the argument-parsing library. The mapping
// here is to raw Int32 exit values (ControlCLIExitCode); the CLI target
// itself does the ExitCode wrapping at its own call sites.

import Foundation

// MARK: - Exit-code taxonomy (D-10)

/// D-10's exit-code table -- the one place that decides a CLI exit value
/// from an error `code` string (T-02-15). Both the channel's own
/// `ControlErrorCode` vocabulary and the CLI's own `ControlCLIErrorCode`
/// vocabulary funnel through `forErrorCode(_:)`; no command computes an
/// exit value inline.
public enum ControlCLIExitCode: Int32, Sendable {
    case success = 0
    case usage = 64
    case engineOrGateError = 65
    case noHostReachable = 69
    case internalError = 70
    case busy = 75
    case confirmationRequired = 77
    case schemaVersionMismatch = 78

    /// Maps a wire-level error `code` (either `ControlErrorPayload.code`
    /// from the channel, or one of `ControlCLIErrorCode`'s own strings) onto
    /// its D-10 exit value. `GATE_REFUSED`, `JOB_NOT_FOUND`, and every
    /// engine/bridge passthrough code this repository does not enumerate
    /// (T-02-12's supply-chain audit covers the one dependency this phase
    /// adds, not the open-ended engine error vocabulary) all fall through
    /// to the documented default of 65 -- that default *is* the passthrough
    /// rule, not a fallback for an unhandled case.
    public static func forErrorCode(_ code: String) -> ControlCLIExitCode {
        switch code {
        case ControlErrorCode.invalidParams.rawValue,
             ControlCLIErrorCode.invalidRange.rawValue:
            return .usage
        case ControlErrorCode.unknownCommand.rawValue,
             ControlCLIErrorCode.internalCode.rawValue:
            return .internalError
        case ControlCLIErrorCode.hostUnreachable.rawValue:
            return .noHostReachable
        case ControlErrorCode.controllerBusy.rawValue:
            return .busy
        case ControlErrorCode.confirmationRequired.rawValue:
            return .confirmationRequired
        case ControlErrorCode.schemaVersionMismatch.rawValue,
             ControlErrorCode.helloRequired.rawValue:
            return .schemaVersionMismatch
        default:
            // GATE_REFUSED, JOB_NOT_FOUND, and every engine/bridge
            // passthrough code land here (65) -- see the doc comment above.
            return .engineOrGateError
        }
    }
}

/// D-10/D-11: the CLI's own small, fixed error-code vocabulary, distinct
/// from the channel's `ControlErrorCode` -- decided client-side, before or
/// without ever opening a connection. Raw values are the wire-style
/// strings these codes render as in a JSON error envelope, so no command
/// spells one as a string literal.
public enum ControlCLIErrorCode: String, Sendable {
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case hostUnreachable = "HOST_UNREACHABLE"
    case invalidRange = "INVALID_RANGE"
    case jobNotFound = "JOB_NOT_FOUND"
    case internalCode = "INTERNAL"
}

// MARK: - Output envelope (D-09/OUT-01)

/// Thrown only if `JSONSerialization` cannot turn a constructed envelope
/// back into valid UTF-8 text. Not expected to fire for the well-formed
/// dictionaries this file builds; kept as a typed `throws` rather than
/// force-unwrapping `String(data:encoding:)` (project convention: no
/// force-unwrapping).
public struct ControlCLIOutputError: Error, Equatable, Sendable {
    public let reason: String
}

/// Renders every CLI command's output as one JSON envelope (`schemaVersion`,
/// `command`, `mode: "attach"`, plus the command's own payload nested under
/// `result`/`error`/`event`), or as indented human text when `--human` is
/// passed (OUT-01; the exact envelope shape is Claude's Discretion per
/// 02-CONTEXT.md). All three entry points are pure and synchronous: every
/// `[String: Any]` stays local to the function that builds it, so nothing
/// non-`Sendable` ever crosses an isolation boundary.
public enum ControlCLIOutput {
    /// Renders a successful command result. `resultJSON` is the
    /// already-decoded `result` payload for whichever command is running --
    /// this file has no per-command knowledge of its shape.
    public static func renderResult(command: String, resultJSON: [String: Any], human: Bool) throws -> String {
        try render(envelope(command: command, key: "result", value: resultJSON), human: human)
    }

    /// Renders a command failure. Carries `payload`'s `code`, `message`,
    /// `recoverable`, and -- only when non-nil -- `guidance` and `gate`,
    /// verbatim (D-14): never adds, renames, rewords, or drops a field, and
    /// never adds a field `ControlErrorPayload` does not have (T-02-14).
    public static func renderError(command: String, payload: ControlErrorPayload, human: Bool) throws -> String {
        var errorJSON: [String: Any] = [
            "code": payload.code,
            "message": payload.message,
            "recoverable": payload.recoverable
        ]
        if let guidance = payload.guidance {
            errorJSON["guidance"] = guidance
        }
        if let gate = payload.gate {
            errorJSON["gate"] = gate
        }
        return try render(envelope(command: command, key: "error", value: errorJSON), human: human)
    }

    /// Renders one event line, for `events --follow` (D-08). `eventJSON` is
    /// the already-decoded event payload -- this file has no per-event-type
    /// knowledge of its shape.
    public static func renderEvent(command: String, eventJSON: [String: Any], human: Bool) throws -> String {
        try render(envelope(command: command, key: "event", value: eventJSON), human: human)
    }

    private static func envelope(command: String, key: String, value: [String: Any]) -> [String: Any] {
        [
            "schemaVersion": ControlSchema.version,
            "command": command,
            "mode": "attach",
            key: value
        ]
    }

    private static func render(_ envelope: [String: Any], human: Bool) throws -> String {
        guard human else {
            // .sortedKeys: stable, field-order-independent output (OUT-01) --
            // two renders of the same input must produce identical bytes.
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                throw ControlCLIOutputError(reason: "JSONSerialization produced non-UTF8 output")
            }
            return json + "\n"
        }
        var lines: [String] = []
        appendHumanLines(envelope, indent: 0, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Walks a decoded JSON object and emits `key: value` lines with
    /// two-space-per-level indentation and sorted keys, recursing into
    /// nested objects and arrays.
    private static func appendHumanLines(_ dict: [String: Any], indent: Int, into lines: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)
        for key in dict.keys.sorted() {
            guard let value = dict[key] else { continue }
            switch value {
            case let nested as [String: Any]:
                lines.append("\(prefix)\(key):")
                appendHumanLines(nested, indent: indent + 1, into: &lines)
            case let array as [Any]:
                lines.append("\(prefix)\(key):")
                for element in array {
                    if let nestedDict = element as? [String: Any] {
                        appendHumanLines(nestedDict, indent: indent + 1, into: &lines)
                    } else {
                        lines.append("\(prefix)  - \(humanScalar(element))")
                    }
                }
            default:
                lines.append("\(prefix)\(key): \(humanScalar(value))")
            }
        }
    }

    private static func humanScalar(_ value: Any) -> String {
        // Bool is checked before Int: a JSONSerialization-sourced NSNumber
        // wrapping a boolean can also satisfy `as? Int`, misrendering
        // `true`/`false` as `1`/`0`.
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(double) }
        return String(describing: value)
    }
}
