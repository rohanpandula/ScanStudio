import Foundation

/// Optional, explicitly supplied context for a user-initiated issue report.
///
/// The policy has no attachment inputs, so it cannot silently add thumbnails,
/// receipts, or logs. Values that may identify the user's work are accepted
/// only so they can be removed from the report body.
public struct ErrorPresentationContext: Equatable, Sendable {
    public let scanStudioVersion: String?
    public let operatingSystemVersion: String?
    public let selectedPaths: [String]
    public let filmMetadataValues: [String]
    public let deviceIdentifiers: [String]
    public let diagnosticSessionId: String?
    public let engineVersion: String?
    public let connectionSummary: String?
    public let recentDiagnosticEvents: [String]
    public let diagnosticLogRelativePath: String?

    public init(
        scanStudioVersion: String? = nil,
        operatingSystemVersion: String? = nil,
        selectedPaths: [String] = [],
        filmMetadataValues: [String] = [],
        deviceIdentifiers: [String] = [],
        diagnosticSessionId: String? = nil,
        engineVersion: String? = nil,
        connectionSummary: String? = nil,
        recentDiagnosticEvents: [String] = [],
        diagnosticLogRelativePath: String? = nil
    ) {
        self.scanStudioVersion = scanStudioVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.selectedPaths = selectedPaths
        self.filmMetadataValues = filmMetadataValues
        self.deviceIdentifiers = deviceIdentifiers
        self.diagnosticSessionId = diagnosticSessionId
        self.engineVersion = engineVersion
        self.connectionSummary = connectionSummary
        self.recentDiagnosticEvents = recentDiagnosticEvents
        self.diagnosticLogRelativePath = diagnosticLogRelativePath
    }
}

/// User-facing error copy plus the complete local detail and a safe report URL.
public struct ErrorPresentation: Equatable, Sendable {
    public let title: String
    public let guidance: String
    public let technicalDetails: String
    public let issueURL: URL

    public init(
        title: String,
        guidance: String,
        technicalDetails: String,
        issueURL: URL
    ) {
        self.title = title
        self.guidance = guidance
        self.technicalDetails = technicalDetails
        self.issueURL = issueURL
    }
}

/// Converts raw engine text into calm user copy without discarding the local
/// diagnostic detail.
public enum ErrorPresentationPolicy {
    public static let maximumIssueBodyCharacters = 4_000

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
            )
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
        if let version = context.scanStudioVersion, !version.isEmpty {
            bodyLines.append("ScanStudio version: \(version)")
        }
        if let operatingSystem = context.operatingSystemVersion, !operatingSystem.isEmpty {
            bodyLines.append("Operating system: \(operatingSystem)")
        }
        appendDiagnosticContext(
            to: &bodyLines,
            context: context,
            includeLocalLogPath: false
        )
        bodyLines.append("Error code: \(copy.code)")
        bodyLines.append("")
        bodyLines.append("Message:")
        bodyLines.append(safeMessage)
        if !context.recentDiagnosticEvents.isEmpty {
            bodyLines.append("")
            bodyLines.append("Recent diagnostic events:")
            bodyLines.append(
                contentsOf: context.recentDiagnosticEvents.suffix(12).map {
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
            context.diagnosticSessionId != nil
            || context.engineVersion != nil
            || context.connectionSummary != nil
            || !context.recentDiagnosticEvents.isEmpty
            || context.diagnosticLogRelativePath != nil
        guard hasDiagnostics else { return lastErrorMessage }

        var lines = [lastErrorMessage, "", "Diagnostic context"]
        appendDiagnosticContext(
            to: &lines,
            context: context,
            includeLocalLogPath: true
        )
        if !context.recentDiagnosticEvents.isEmpty {
            lines.append("Recent events:")
            lines.append(contentsOf: context.recentDiagnosticEvents.suffix(20).map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func appendDiagnosticContext(
        to lines: inout [String],
        context: ErrorPresentationContext,
        includeLocalLogPath: Bool
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
        if includeLocalLogPath,
           let logPath = context.diagnosticLogRelativePath,
           !logPath.isEmpty {
            lines.append("Local log: \(logPath)")
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
