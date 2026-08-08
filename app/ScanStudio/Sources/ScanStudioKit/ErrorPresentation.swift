import Foundation

/// Optional, explicitly supplied context for a user-initiated issue report.
///
/// The policy has no attachment inputs, so it cannot silently add thumbnails,
/// receipts, or logs. Values that may identify the user's work are accepted
/// only so they can be removed from the report body.
public struct ErrorPresentationContext: Equatable, Sendable {
    public let scanStudioVersion: String?
    public let operatingSystemVersion: String?
    /// CPU architecture of the host running ScanStudio (e.g. `"arm64"`).
    public let cpuArchitecture: String?
    /// The connected scanner's reported firmware revision, when a device is
    /// connected and the identity handshake has recorded one.
    public let scannerFirmware: String?
    /// `ScannerStatus.adapter`, when known.
    public let scannerAdapter: String?
    /// `ScannerStatus.carrier` (the loaded film holder), when known.
    public let scannerHolder: String?
    public let selectedPaths: [String]
    public let filmMetadataValues: [String]
    public let deviceIdentifiers: [String]
    public let diagnosticSessionId: String?
    public let engineVersion: String?
    public let connectionSummary: String?
    public let recentDiagnosticEvents: [String]
    /// Home-relative (`~/...`) diagnostic log location, safe to publish in a
    /// public issue draft -- never reveals the local account name.
    public let diagnosticLogRelativePath: String?
    /// The true absolute diagnostic log path, for the local-only technical
    /// details view. Never included in the public issue draft.
    public let diagnosticLogPath: String?

    public init(
        scanStudioVersion: String? = nil,
        operatingSystemVersion: String? = nil,
        cpuArchitecture: String? = nil,
        scannerFirmware: String? = nil,
        scannerAdapter: String? = nil,
        scannerHolder: String? = nil,
        selectedPaths: [String] = [],
        filmMetadataValues: [String] = [],
        deviceIdentifiers: [String] = [],
        diagnosticSessionId: String? = nil,
        engineVersion: String? = nil,
        connectionSummary: String? = nil,
        recentDiagnosticEvents: [String] = [],
        diagnosticLogRelativePath: String? = nil,
        diagnosticLogPath: String? = nil
    ) {
        self.scanStudioVersion = scanStudioVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.cpuArchitecture = cpuArchitecture
        self.scannerFirmware = scannerFirmware
        self.scannerAdapter = scannerAdapter
        self.scannerHolder = scannerHolder
        self.selectedPaths = selectedPaths
        self.filmMetadataValues = filmMetadataValues
        self.deviceIdentifiers = deviceIdentifiers
        self.diagnosticSessionId = diagnosticSessionId
        self.engineVersion = engineVersion
        self.connectionSummary = connectionSummary
        self.recentDiagnosticEvents = recentDiagnosticEvents
        self.diagnosticLogRelativePath = diagnosticLogRelativePath
        self.diagnosticLogPath = diagnosticLogPath
    }
}

/// User-facing error copy plus the complete local detail and a safe report URL.
public struct ErrorPresentation: Equatable, Sendable {
    public let title: String
    public let guidance: String
    public let technicalDetails: String
    public let issueURL: URL
    /// Rung 3 of the feeding UX ladder's plain-English diagnosis sentence
    /// (FEEDING-UX-LADDER-OVERNIGHT-20260807.md), extracted from the raw
    /// engine detail text by `ProbableCauseExtractor` -- never raw JSON,
    /// never the surrounding diagnostic prose. `nil` for the common case
    /// (most errors, including most REFEED_REQUIREDs, carry no Rung-3
    /// diagnosis). When present, the workspace error card shows it
    /// prominently and offers "Place frames manually" alongside it.
    public let probableCause: String?

    public init(
        title: String,
        guidance: String,
        technicalDetails: String,
        issueURL: URL,
        probableCause: String? = nil
    ) {
        self.title = title
        self.guidance = guidance
        self.technicalDetails = technicalDetails
        self.issueURL = issueURL
        self.probableCause = probableCause
    }
}

/// Converts raw engine text into calm user copy without discarding the local
/// diagnostic detail.
public enum ErrorPresentationPolicy {
    public static let maximumIssueBodyCharacters = 4_000
    /// Both report outputs show at most this many of the most recent
    /// diagnostic events. Matches `SessionDiagnosticTimeline`'s own retention
    /// cap (T-ERR-02), so raising one without the other cannot silently
    /// under-fill the report.
    public static let maximumRecentDiagnosticEvents = 40
    /// Rendered in place of any build-identifying header field ScanStudio
    /// could not determine, so a field is always present and never silently
    /// dropped from the report.
    private static let unknownFieldValue = "unknown"

    private struct Copy {
        let code: String
        let title: String
        let guidance: String
    }

    private static let issueRoot = URL(
        string: "https://github.com/rohanpandula/ScanStudio/issues/new"
    )!

    private static let knownCopy: [Copy] = [
        Copy(
            code: "CAPTURE_WORKER_BOOTSTRAP_FAILED",
            title: "ScanStudio’s scanning components need repair",
            guidance: "The scanner was not moved. Update or reinstall ScanStudio, then try again."
        ),
        Copy(
            code: "REFEED_REQUIRED",
            title: "Film needs to be reloaded",
            guidance: "Eject and reinsert the film, then preview it again."
        ),
        Copy(
            code: "FEEDER_PARKED",
            title: "Film transport needs a restart",
            guidance: "Power-cycle the scanner before trying another film movement."
        ),
        Copy(
            code: "HARDWARE_LANE_BUSY",
            title: "Scanner is finishing another task",
            guidance: "Wait for the current scanner operation to finish, then try again."
        ),
        Copy(
            code: "HW_MOTION_NOT_ARMED",
            title: "Scanner isn’t ready yet",
            guidance: "ScanStudio could not prepare the scanner for previewing or scanning. Quit and reopen the app. If it happens again, report the issue."
        ),
        Copy(
            code: "NOT_CONNECTED",
            title: "Scanner connection was lost",
            guidance: "Reconnect ScanStudio to the scanner, then try again. You do not need to power-cycle it."
        ),
        Copy(
            code: "NO_MEDIA",
            title: "No film is detected",
            guidance: "Insert film, preview it, then try again."
        ),
        Copy(
            code: "SCANNER_BUSY",
            title: "Scanner is busy",
            guidance: "Wait for the current scan or preview to finish, then try again."
        ),
        Copy(
            code: "INVALID_PARAMS",
            title: "These settings could not be used",
            guidance: "Review the selected frames and scan settings, then try again."
        ),
        Copy(
            code: "PROJECT_NOT_FOUND",
            title: "Save or open a roll first",
            guidance: "Save this roll or open its existing project, then try again."
        ),
        Copy(
            code: "ARCHIVE_COLLISION",
            title: "A master TIFF already exists",
            guidance: "Choose a different name or save location. ScanStudio will not overwrite an archive master."
        ),
        Copy(
            code: "METER_UNUSABLE",
            title: "This film could not be metered",
            guidance: "ScanStudio couldn't find usable image data to meter this frame — the film may be too dense, upside down, or the film adapter may be modified. Check the film's density and orientation, then try a different process setting."
        ),
    ]

    public static func make(
        lastErrorMessage: String,
        context: ErrorPresentationContext = .init()
    ) -> ErrorPresentation {
        let normalizedMessage = lastErrorMessage.uppercased()
        let copy = leadingFrameClippedCopy(in: lastErrorMessage)
            ?? filmFeedInterruptedCopy(in: lastErrorMessage)
            ?? filmTransportSlipCopy(in: lastErrorMessage)
            ?? previewReadinessTimeoutCopy(in: lastErrorMessage)
            ?? knownCopy.first { containsCode($0.code, in: normalizedMessage) }
            ?? Copy(
                code: leadingCode(in: normalizedMessage) ?? "UNKNOWN",
                title: "ScanStudio could not complete that action",
                guidance: "Review the technical details below. If the problem continues, report the issue."
            )

        return ErrorPresentation(
            title: copy.title,
            guidance: copy.guidance,
            technicalDetails: makeTechnicalDetails(
                lastErrorMessage: lastErrorMessage,
                context: context
            ),
            issueURL: makeIssueURL(
                copy: copy,
                lastErrorMessage: lastErrorMessage,
                context: context
            ),
            // Adversarial review S8 (2026-08-08): only ever extracted for
            // the outer TYPED error code this policy itself classified as
            // REFEED_REQUIRED -- never merely because the raw text happens
            // to contain a probable_cause-shaped fragment. An INTERNAL (or
            // any other) error carrying an embedded, coincidental, or
            // adversarial-looking fragment must never surface a sentence or
            // the "Place frames manually" action; `copy.code` is this
            // policy's own already-computed classification, not a second,
            // independent guess.
            probableCause: copy.code == "REFEED_REQUIRED"
                ? ProbableCauseExtractor.extract(from: lastErrorMessage)
                : nil
        )
    }

    private static func leadingFrameClippedCopy(in message: String) -> Copy? {
        guard
            message.range(
                of: "the first frame begins",
                options: .caseInsensitive
            ) != nil,
            message.range(
                of: "before the captured preview area",
                options: .caseInsensitive
            ) != nil
        else {
            return nil
        }
        return Copy(
            code: "REFEED_REQUIRED",
            title: "The first frame is not fully inside the scanner",
            guidance: "Reinsert the film a little farther into the adapter, then preview it again. "
                + "ScanStudio did not offer the cropped frame for scanning."
        )
    }

    private static func filmFeedInterruptedCopy(in message: String) -> Copy? {
        guard FilmTransportFailurePolicy.isFilmFeedInterrupted(message: message) else {
            return nil
        }
        return Copy(
            code: "FILM_FEED_INTERRUPTED",
            title: "Film feed interrupted",
            guidance: "The scanner stopped detecting the film while moving to the next frame. "
                + "Your finished frames are safe. Reinsert the film, acquire a fresh preview, "
                + "then resume the remaining frames."
        )
    }

    private static func filmTransportSlipCopy(in message: String) -> Copy? {
        guard FilmTransportFailurePolicy.requiresPhysicalRefeed(
            message: message
        ) else {
            return nil
        }
        return Copy(
            code: "REFEED_REQUIRED",
            title: "Film shifted—refeed required",
            guidance: "The scanner lost the film’s position. Remove and firmly reinsert "
                + "the strip, then acquire a fresh preview. Do not retry Capture with "
                + "the current preview."
        )
    }

    private static func previewReadinessTimeoutCopy(in message: String) -> Copy? {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"SynchronizedProtocolError:\s*ready group\s+51\s*-\s*60\s*:\s*terminal sense\s+000000\s+not reached after\s+(\d+)\s*s"#,
                options: .caseInsensitive
            ),
            let match = expression.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)
            ),
            let secondsRange = Range(match.range(at: 1), in: message),
            let seconds = Int(message[secondsRange])
        else {
            return nil
        }

        let duration: String
        if seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            duration = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        } else {
            duration = "\(seconds) \(seconds == 1 ? "second" : "seconds")"
        }

        return Copy(
            code: "PREVIEW_TIMEOUT",
            title: "The scanner did not detect the film",
            guidance: "ScanStudio waited \(duration) for the film to become ready, "
                + "but the scanner continued to report that no film was present. "
                + "No preview was created. The scanner may have ejected the film, "
                + "or the film may not be fully inserted. Check the scanner, reinsert the film "
                + "if it was ejected, then try Preview once. No power cycle is needed for this "
                + "error alone. If it happens again, stop and open an issue with the technical "
                + "details below."
        )
    }

    private static func containsCode(_ code: String, in normalizedMessage: String) -> Bool {
        let escapedCode = NSRegularExpression.escapedPattern(for: code)
        return normalizedMessage.range(
            of: #"(?<![A-Z0-9_])\#(escapedCode)(?![A-Z0-9_])"#,
            options: .regularExpression
        ) != nil
    }

    private static func leadingCode(in normalizedMessage: String) -> String? {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"^\s*([A-Z][A-Z0-9_]{2,})\s*:"#
            ),
            let match = expression.firstMatch(
                in: normalizedMessage,
                range: NSRange(normalizedMessage.startIndex..., in: normalizedMessage)
            ),
            let codeRange = Range(match.range(at: 1), in: normalizedMessage)
        else {
            return nil
        }
        return String(normalizedMessage[codeRange])
    }

    private static func makeIssueURL(
        copy: Copy,
        lastErrorMessage: String,
        context: ErrorPresentationContext
    ) -> URL {
        let safeMessage = redactIssueText(lastErrorMessage, context: context)
        var bodyLines = ["ScanStudio error report"]
        appendBuildHeader(to: &bodyLines, context: context)
        // Home-relative, never the true absolute path -- this line ships in a
        // public GitHub issue draft and must not disclose the local account
        // name (see `diagnosticLogPath` for the local-only absolute form).
        if let relativeLogPath = context.diagnosticLogRelativePath, !relativeLogPath.isEmpty {
            bodyLines.append("Local log: \(relativeLogPath)")
        }
        appendDiagnosticContext(to: &bodyLines, context: context)
        bodyLines.append("Error code: \(copy.code)")
        bodyLines.append("")
        bodyLines.append("Message:")
        bodyLines.append(safeMessage)
        if !context.recentDiagnosticEvents.isEmpty {
            bodyLines.append("")
            bodyLines.append("Recent diagnostic events:")
            bodyLines.append(
                contentsOf: context.recentDiagnosticEvents.suffix(maximumRecentDiagnosticEvents).map {
                    "- \(redactIssueText($0, context: context))"
                }
            )
        }
        bodyLines.append("")
        bodyLines.append("No images, receipts, or raw logs are attached automatically.")

        let issueBody = cappedIssueBody(bodyLines.joined(separator: "\n"))
        var components = URLComponents(url: issueRoot, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(
                name: "title",
                value: "ScanStudio: \(copy.title) (\(copy.code))"
            ),
            URLQueryItem(name: "body", value: issueBody),
        ]
        return components.url!
    }

    private static func makeTechnicalDetails(
        lastErrorMessage: String,
        context: ErrorPresentationContext
    ) -> String {
        let hasDiagnostics =
            context.scanStudioVersion != nil
            || context.operatingSystemVersion != nil
            || context.cpuArchitecture != nil
            || context.scannerFirmware != nil
            || context.scannerAdapter != nil
            || context.scannerHolder != nil
            || context.diagnosticSessionId != nil
            || context.engineVersion != nil
            || context.connectionSummary != nil
            || !context.recentDiagnosticEvents.isEmpty
            || context.diagnosticLogRelativePath != nil
            || context.diagnosticLogPath != nil
        guard hasDiagnostics else { return lastErrorMessage }

        var lines = [lastErrorMessage, "", "Diagnostic context"]
        appendBuildHeader(to: &lines, context: context)
        // The true absolute path -- safe here because this view is local-only
        // and never leaves the machine (contrast the public issue draft's
        // home-relative `diagnosticLogRelativePath` line).
        if let logPath = context.diagnosticLogPath, !logPath.isEmpty {
            lines.append("Local log: \(logPath)")
        }
        appendDiagnosticContext(to: &lines, context: context)
        if !context.recentDiagnosticEvents.isEmpty {
            lines.append("Recent events:")
            lines.append(
                contentsOf: context.recentDiagnosticEvents.suffix(maximumRecentDiagnosticEvents).map { "- \($0)" }
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Appends the build-identifying header (T-ERR-01): release stamp,
    /// OS name+version, CPU architecture, and -- when a scanner session has
    /// established them -- firmware revision and adapter/holder. Every field
    /// always renders, falling back to `unknownFieldValue` rather than being
    /// silently omitted, so a reader never has to wonder whether a value was
    /// dropped versus genuinely undetermined.
    private static func appendBuildHeader(
        to lines: inout [String],
        context: ErrorPresentationContext
    ) {
        lines.append("ScanStudio version: \(rendered(context.scanStudioVersion))")
        lines.append("Operating system: \(rendered(context.operatingSystemVersion))")
        lines.append("CPU architecture: \(rendered(context.cpuArchitecture))")
        lines.append("Scanner firmware: \(rendered(context.scannerFirmware))")
        lines.append("Adapter: \(rendered(context.scannerAdapter))")
        lines.append("Holder: \(rendered(context.scannerHolder))")
    }

    private static func rendered(_ value: String?) -> String {
        guard let value else { return unknownFieldValue }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? unknownFieldValue : trimmed
    }

    private static func appendDiagnosticContext(
        to lines: inout [String],
        context: ErrorPresentationContext
    ) {
        if let sessionID = context.diagnosticSessionId, !sessionID.isEmpty {
            lines.append("Diagnostic session: \(sessionID)")
        }
        if let engineVersion = context.engineVersion, !engineVersion.isEmpty {
            lines.append("Engine version: \(engineVersion)")
        }
        if let connectionSummary = context.connectionSummary, !connectionSummary.isEmpty {
            lines.append("Connection state: \(connectionSummary)")
        }
    }

    private static func cappedIssueBody(_ body: String) -> String {
        guard body.count > maximumIssueBodyCharacters else { return body }
        let suffix = "\n[technical message truncated]"
        return String(body.prefix(maximumIssueBodyCharacters - suffix.count)) + suffix
    }

    private static func redactIssueText(
        _ text: String,
        context: ErrorPresentationContext
    ) -> String {
        var redacted = replacing(
            context.selectedPaths,
            in: text,
            with: "<redacted path>"
        )
        redacted = replacing(
            context.filmMetadataValues + context.deviceIdentifiers,
            in: redacted,
            with: "<redacted>"
        )
        redacted = redacted.replacingOccurrences(
            of: #"(["'])(?:~|/(?:Users|Volumes|private/var/folders|var/folders|private/tmp|tmp))(?:/[^"']*)?\1"#,
            with: "<redacted path>",
            options: [.regularExpression, .caseInsensitive]
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?:~|/(?:Users|Volumes|private/var/folders|var/folders|private/tmp|tmp))/[^\n;,\]\[(){}<>"']+"#,
            with: "<redacted path>",
            options: [.regularExpression, .caseInsensitive]
        )
        redacted = redacted.replacingOccurrences(
            of: #"("?(?:film[_ -]?stock|stock|camera|lens|device[_ -]?id|serial(?:[_ -]?(?:number|no))?)"?\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\n;,]+)"#,
            with: "$1<redacted>",
            options: [.regularExpression, .caseInsensitive]
        )
        return redacted
    }

    private static func replacing(
        _ sensitiveValues: [String],
        in text: String,
        with replacement: String
    ) -> String {
        sensitiveValues
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { partial, sensitiveValue in
                partial.replacingOccurrences(
                    of: sensitiveValue,
                    with: replacement,
                    options: .caseInsensitive
                )
            }
    }
}
