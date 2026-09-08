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
    case hostExited = 76
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
        case ControlErrorCode.controllerBusy.rawValue,
             ControlCLIErrorCode.hostAlreadyRunning.rawValue:
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
    case hostAlreadyRunning = "HOST_ALREADY_RUNNING"
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

public struct ControlCLIEnvelopeContext: Sendable, Equatable {
    public let mode: ControlHostMode
    public let hostStarted: Bool
    public let hostPid: Int32?
    public let logPath: String?
    public let hardwareVerification: String

    public init(mode: ControlHostMode, hostStarted: Bool, hostPid: Int32?, logPath: String?, hardwareVerification: String = "notConnected") {
        self.mode = mode
        self.hostStarted = hostStarted
        self.hostPid = hostPid
        self.logPath = logPath
        self.hardwareVerification = hardwareVerification
    }

    public static let unreached = ControlCLIEnvelopeContext(
        mode: .unreached, hostStarted: false, hostPid: nil, logPath: nil, hardwareVerification: "notConnected"
    )
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
    public static func renderResult(command: String, resultJSON: [String: Any], human: Bool, context: ControlCLIEnvelopeContext = .unreached) throws -> String {
        try render(envelope(command: command, key: "result", value: resultJSON, context: context), human: human)
    }

    /// Renders a command failure. Carries `payload`'s `code`, `message`,
    /// `recoverable`, and -- only when non-nil -- `guidance` and `gate`,
    /// verbatim (D-14): never adds, renames, rewords, or drops a field, and
    /// never adds a field `ControlErrorPayload` does not have (T-02-14).
    public static func renderError(command: String, payload: ControlErrorPayload, human: Bool, context: ControlCLIEnvelopeContext = .unreached) throws -> String {
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
        return try render(envelope(command: command, key: "error", value: errorJSON, context: context), human: human)
    }

    /// Renders one event line, for `events --follow` (D-08). `eventJSON` is
    /// the already-decoded event payload -- this file has no per-event-type
    /// knowledge of its shape.
    public static func renderEvent(command: String, eventJSON: [String: Any], human: Bool, context: ControlCLIEnvelopeContext = .unreached) throws -> String {
        try render(envelope(command: command, key: "event", value: eventJSON, context: context), human: human)
    }

    private static func envelope(command: String, key: String, value: [String: Any], context: ControlCLIEnvelopeContext) -> [String: Any] {
        var envelope: [String: Any] = [
            "schemaVersion": ControlSchema.version,
            "command": command,
            "mode": context.mode.rawValue,
            key: value
        ]
        envelope["hostStarted"] = context.hostStarted
        envelope["hardwareVerification"] = context.hardwareVerification
        if let hostPid = context.hostPid { envelope["hostPid"] = hostPid }
        if let logPath = context.logPath { envelope["logPath"] = logPath }
        return envelope
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

// MARK: - CUPS frame-range parser (D-12)

/// A shape-invalid CUPS frame range (D-12). `token` is the specific
/// offending entry, not necessarily the whole input, so a caller can point
/// at what broke.
public struct ControlFrameRangeError: Error, Equatable, Sendable {
    public let token: String
    public let message: String

    public init(token: String, message: String) {
        self.token = token
        self.message = message
    }
}

/// Parses CUPS-syntax frame ranges (`"1-36,38"`) into the union of their
/// 1-based frame indices. Grammar: `\d+(-\d+)?(,\d+(-\d+)?)*`, trimmed once
/// at the ends -- no other whitespace tolerance.
///
/// This validates *shape only*: membership against the project's actual
/// detected frame count is the server's job (`ControlFrameSelectionParams`,
/// `frames.include`/`frames.exclude` -- `ControlWireProtocol.swift`), and
/// its refusal is a separate, typed `INVALID_PARAMS` response. A
/// shape-valid range may still be refused per index by the host.
public enum ControlFrameRangeParser {
    /// T-02-13/T-02-28: no single range, and no running total across the
    /// whole input, may select more than this many indices. Checked by
    /// pure arithmetic on a two-sided range's `lower`/`upper` bounds
    /// *before* any `Set` materialization -- `upper - lower + 1` is never
    /// iterated to find out how big a range is, so `"1-100000000"` is
    /// refused instantly rather than spending seconds (or exhausting
    /// memory) building a hundred-million-element `Set` no real project
    /// could ever contain. No real carrier this app supports has anywhere
    /// close to 1,000 frames.
    public static let maxIndexCount = 1_000

    /// Returns the deduplicated, ascending-sorted union of every index the
    /// range expands to. Frame indices are 1-based ordinals in this
    /// codebase (confirmed by every project fixture and Phase 1's own
    /// membership validation) -- `0` and negative values are rejected, as
    /// is a descending range (`"5-2"`) and any token that does not fit in
    /// `Int`.
    public static func parse(_ text: String) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlFrameRangeError(token: text, message: "Frame range must not be empty.")
        }

        var indices: Set<Int> = []
        for token in trimmed.components(separatedBy: ",") {
            guard !token.isEmpty else {
                throw ControlFrameRangeError(token: trimmed, message: "Frame range has an empty entry between commas.")
            }

            let parts = token.components(separatedBy: "-")
            switch parts.count {
            case 1:
                let index = try parseIndex(parts[0], token: token)
                try checkBudget(adding: 1, token: token, alreadySelected: indices.count)
                indices.insert(index)
            case 2:
                let lower = try parseIndex(parts[0], token: token)
                let upper = try parseIndex(parts[1], token: token)
                guard lower <= upper else {
                    throw ControlFrameRangeError(
                        token: token,
                        message: "Frame range \"\(token)\" is descending; the first index must be less than or equal to the second."
                    )
                }
                // Pure arithmetic -- never `lower...upper`'s own `.count`,
                // which would materialize the range to compute it.
                let span = upper - lower + 1
                try checkBudget(adding: span, token: token, alreadySelected: indices.count)
                indices.formUnion(lower...upper)
            default:
                throw ControlFrameRangeError(token: token, message: "Frame range entry \"\(token)\" is not a single index or a two-sided range.")
            }
        }
        return indices.sorted()
    }

    /// Rejects before any `Set` mutation: either `adding` alone already
    /// exceeds `maxIndexCount` (one oversized range, e.g. `"1-100000000"`),
    /// or `alreadySelected + adding` would push the running total across
    /// the whole input over it (many individually-small ranges that sum
    /// past the ceiling, e.g. `"1-500,501-1000,1001-1500"`).
    /// `alreadySelected` can undercount the real post-union size by
    /// whatever overlap `adding` shares with the indices already collected
    /// (`indices` is a `Set`, so duplicates collapse) -- a deliberately
    /// conservative approximation: it can only reject a request that would
    /// have stayed at or under the real count, never admit one that
    /// exceeds it.
    private static func checkBudget(adding: Int, token: String, alreadySelected: Int) throws {
        guard adding <= maxIndexCount, alreadySelected + adding <= maxIndexCount else {
            throw ControlFrameRangeError(
                token: token,
                message: "Frame range \"\(token)\" would select more than \(maxIndexCount) indices in total; reduce the range."
            )
        }
    }

    private static func parseIndex(_ text: String, token: String) throws -> Int {
        guard !text.isEmpty, let value = Int(text) else {
            throw ControlFrameRangeError(token: token, message: "\"\(text)\" in \"\(token)\" is not a valid frame index.")
        }
        guard value >= 1 else {
            throw ControlFrameRangeError(token: token, message: "Frame index \(value) in \"\(token)\" must be 1 or greater.")
        }
        return value
    }
}

// MARK: - Manual-review auto-approve predicate (D-14)

/// The pure "should this pending review auto-approve" decision behind
/// `roll save --auto-approve` (`RollCommands.swift`), factored out here --
/// not into the `scanstudio-cli` executable target -- so it is directly
/// unit-testable from `ScanStudioKitTests`: that target depends only on
/// `ScanStudioKit` (`Package.swift`), never on the CLI executable target,
/// the same reason this file's other CLI-adjacent pure helpers
/// (`ControlProgressLine`, `ControlFrameRangeParser`) live here instead of
/// alongside the commands that call them.
public enum ManualReviewAutoApproval {
    /// Approves only when `frames` is non-empty and **every** frame's
    /// `contentConfidence` is non-`nil` and at or above
    /// `BlankFrameHint.defaultSkipThreshold` -- a single `nil` or a single
    /// lower score refuses the whole batch (SAFE-02: no partial
    /// auto-approval, and never a second attempt at a different threshold).
    /// Threshold value is the same `0.8` `frames select --skip-blank`
    /// defaults to, for the same underlying reason (D-14), but is read
    /// from `BlankFrameHint` directly rather than duplicated here.
    public static func shouldAutoApprove(_ frames: [ControlManualReviewFrame]) -> Bool {
        !frames.isEmpty && frames.allSatisfy {
            ($0.contentConfidence ?? -1) >= BlankFrameHint.defaultSkipThreshold
        }
    }
}

// MARK: - Skip-blank selection (D-12/D-15)

/// The pure "which previewed frames does `--skip-blank` keep vs. skip" rule
/// behind both `frames select --skip-blank` (`FrameCommands.swift`) and
/// `roll run --skip-blank` (`RunCommands.swift`), factored out here so the
/// two commands compute the identical decision from one place rather than
/// two copies that could drift (D-15's own reuse requirement). A frame
/// with no `blankConfidence` at all is always kept: an unscored frame is
/// never skipped on the strength of a hint that does not exist.
public enum SkipBlankSelection {
    /// `kept` is every frame index whose `blankConfidence` is below
    /// `threshold` (or absent); `skipped` is the full summary of every
    /// other frame, so a caller can report the score that skipped it.
    public static func select(
        from frames: [ControlFrameSummary],
        threshold: Double
    ) -> (kept: [Int], skipped: [ControlFrameSummary]) {
        let skipped = frames.filter { ($0.blankConfidence ?? -1) >= threshold }
        let skippedIndices = Set(skipped.map(\.index))
        let kept = frames.filter { !skippedIndices.contains($0.index) }.map(\.index)
        return (kept, skipped)
    }
}

// MARK: - Run receipt (D-15/HEAD-09)

/// The durable, per-step record `roll run` (`RunCommands.swift`) builds as
/// it walks D-15's composed sequence -- pure and `Codable` so its shape is
/// provable from `RollRunReceiptTests.swift` with no subprocess and no
/// socket. `roll run` prints exactly one of these on stdout and, when a
/// project directory was reached, writes exactly one new copy beside the
/// manifest (`write(toProjectDirectory:timestamp:)`) -- it never opens,
/// reads, or rewrites a manifest, receipt, journal, or original (SAFE-03).
public struct ControlRunReceipt: Codable, Equatable, Sendable {
    /// One step of the walk: one wire request (or, for `previewComplete`,
    /// one bounded local read of the event stream this run already
    /// subscribed to -- no request of its own). `exitCode`/`outcome`
    /// mirror the CLI's own D-10 exit-code table for that step alone,
    /// never the run's overall result.
    public struct Step: Codable, Equatable, Sendable {
        public let step: String
        public let command: String
        public let exitCode: Int32
        public let outcome: String
        public let startedAt: String
        public let endedAt: String

        public init(step: String, command: String, exitCode: Int32, outcome: String, startedAt: String, endedAt: String) {
            self.step = step
            self.command = command
            self.exitCode = exitCode
            self.outcome = outcome
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    /// Mirrors the subset of `roll.save`'s own result this receipt needs --
    /// never a second copy of `ControlProjectSummary`'s full shape.
    public struct Project: Codable, Equatable, Sendable {
        public let name: String?
        public let directory: String?

        public init(name: String? = nil, directory: String? = nil) {
            self.name = name
            self.directory = directory
        }
    }

    public struct Frames: Codable, Equatable, Sendable {
        public var selected: [Int]
        public var skipped: [Int]
        public var autoApproved: [Int]

        public init(selected: [Int] = [], skipped: [Int] = [], autoApproved: [Int] = []) {
            self.selected = selected
            self.skipped = skipped
            self.autoApproved = autoApproved
        }
    }

    public private(set) var steps: [Step] = []
    public var project: Project?
    public var jobId: String?
    public var jobState: String?
    public var frames = Frames()
    /// Set only after a successful `write(toProjectDirectory:timestamp:)`
    /// -- omitted from the wire (via `encodeIfPresent`) when no write was
    /// attempted or the write failed, so a caller can tell "no project
    /// directory yet" and "write failed" apart from "here is the file."
    public var receiptPath: String?

    public init() {}

    /// Appends one step. Never mutates an existing entry -- the walk is
    /// append-only, matching SAFE-02's "one attempt per step" invariant.
    public mutating func record(step: String, command: String, exitCode: Int32, outcome: String, startedAt: String, endedAt: String) {
        steps.append(Step(step: step, command: command, exitCode: exitCode, outcome: outcome, startedAt: startedAt, endedAt: endedAt))
    }

    /// ISO-8601 with fractional seconds, always UTC -- never a
    /// locale-dependent description. A fresh formatter per call, matching
    /// this codebase's own established `ISO8601DateFormatter` idiom
    /// (`SessionModel.swift`, `ControlChannelDispatcher.swift`) rather than
    /// sharing one mutable instance across calls.
    public static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `.sortedKeys` so two encodes of an identical receipt render
    /// byte-identically (OUT-01) -- the same stability guarantee
    /// `ControlCLIOutput.renderResult` already gives every other command's
    /// output.
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Refuses to overwrite anything (SAFE-03): missing directory or an
    /// existing file at the computed path each throw this typed error --
    /// never an overwrite, never a guess at what already occupies the
    /// name.
    public enum WriteError: Error, Equatable, Sendable {
        case directoryMissing(String)
        case fileAlreadyExists(String)
    }

    /// Writes `cli-run-<yyyyMMdd'T'HHmmss'Z'>.json` into
    /// `directory` (the project directory beside `manifest.json`, never
    /// inside it) and returns the written path. `directory` must already
    /// exist; the filename itself must not -- both refuse via `WriteError`
    /// rather than silently overwriting.
    ///
    /// The actual write uses `.withoutOverwriting` alone, never combined
    /// with `.atomic` -- on this Foundation, `Data.write(to:options:)`
    /// treats `[.withoutOverwriting, .atomic]` together as a programmer
    /// error and traps (`Fatal error: withoutOverwriting is not supported
    /// with atomic`), found by this file's own `writeRefusesToOverwrite`
    /// test. `.withoutOverwriting` alone is `O_EXCL`-backed -- the
    /// existence check and the file's creation happen as one indivisible
    /// kernel operation, which is the exact TOCTOU-proof guarantee SAFE-03
    /// needs (never an overwrite); `.atomic`'s own benefit (no torn file
    /// if the process dies mid-write) does not apply to a receipt, which
    /// is neither a manifest nor a journal.
    public func write(toProjectDirectory directory: String, timestamp: Date = Date()) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WriteError.directoryMissing(directory)
        }
        let filenameFormatter = DateFormatter()
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.timeZone = TimeZone(identifier: "UTC")
        filenameFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let filename = "cli-run-\(filenameFormatter.string(from: timestamp)).json"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteError.fileAlreadyExists(url.path)
        }
        let data = try encodedJSON()
        do {
            try data.write(to: url, options: [.withoutOverwriting])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw WriteError.fileAlreadyExists(url.path)
        }
        return url.path
    }
}

// MARK: - Progress line (D-17)

/// Pure, unit-testable stderr progress-line formatter for `--wait`
/// (`scan`/`resume`/`roll save`, `MotionCommands.swift`/`RollCommands.swift`).
/// Kept in `ScanStudioKit` for the same reason as this file's other
/// helpers: a normal `ScanStudioKitTests` home, no new package surface.
public enum ControlProgressLine {
    /// `frame <frameOrdinal>/<totalFrames> pass <pass>/<totalPasses> eta
    /// <duration>` -- the literal shape D-17 specifies (for example
    /// `frame 3/36 pass 1/4 eta 1h52m`).
    public static func render(_ progress: ControlScanProgress) -> String {
        "frame \(progress.frameOrdinal)/\(progress.totalFrames) pass \(progress.pass)/\(progress.totalPasses) eta \(renderDuration(progress.etaSeconds))"
    }

    /// `<h>h<mm>m` at or above an hour, `<m>m<ss>s` at or above a minute,
    /// `<s>s` below a minute, and the literal `unknown` for a
    /// non-positive or non-finite value. Never fabricates: the engine's
    /// `eta_seconds_from_samples` (D-17) returns exactly `0.0` before the
    /// first frame of a job resolves, and `unknown` is what that
    /// "nothing measured yet" state renders as here, never a misleading
    /// `0s`.
    public static func renderDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "unknown" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))m"
        }
        if minutes > 0 {
            return "\(minutes)m\(String(format: "%02d", secs))s"
        }
        return "\(secs)s"
    }
}
