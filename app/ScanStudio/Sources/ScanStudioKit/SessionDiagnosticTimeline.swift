import Foundation

/// One privacy-safe, structured decision or state transition from the current
/// ScanStudio session. Callers supply only operational fields; paths, film
/// metadata, image names, receipts, and device identifiers do not belong here.
public struct SessionDiagnosticEntry: Codable, Equatable, Sendable {
    public let timestamp: String
    public let sessionId: String
    public let event: String
    public let fields: [String: String]

    public init(
        timestamp: String,
        sessionId: String,
        event: String,
        fields: [String: String]
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.event = event
        self.fields = fields
    }

    public var summaryLine: String {
        let details = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return details.isEmpty
            ? "\(timestamp) \(event)"
            : "\(timestamp) \(event) \(details)"
    }
}

/// A bounded in-memory timeline with optional durable JSONL persistence.
///
/// Production passes `~/.scanstudio/diagnostics`; tests and other library
/// clients default to memory-only so constructing a `SessionModel` never
/// writes outside a caller-selected directory.
public struct SessionDiagnosticTimeline: Sendable {
    public let sessionID: String
    public let maximumEntries: Int
    public let maximumLogFiles: Int
    public private(set) var entries: [SessionDiagnosticEntry] = []
    public private(set) var logURL: URL?
    public private(set) var persistenceError: String?

    public init(
        sessionID: String,
        maximumEntries: Int = 40,
        maximumLogFiles: Int = 20,
        directory: URL? = nil
    ) {
        self.sessionID = sessionID
        self.maximumEntries = max(maximumEntries, 1)
        self.maximumLogFiles = max(maximumLogFiles, 1)

        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let safeSessionID = sessionID.filter {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
            let filename = safeSessionID.isEmpty
                ? "session.jsonl"
                : "\(safeSessionID).jsonl"
            let newLogURL = directory.appendingPathComponent(
                filename,
                isDirectory: false
            )
            logURL = newLogURL
            do {
                try Self.pruneOldLogs(
                    in: directory,
                    excluding: newLogURL,
                    maximumLogFiles: self.maximumLogFiles
                )
            } catch {
                // Retention failure must not disable current-session logging.
                persistenceError = "diagnostic retention: \(error)"
            }
        } catch {
            persistenceError = String(describing: error)
        }
    }

    public mutating func record(
        timestamp: String? = nil,
        event: String,
        fields: [String: String] = [:]
    ) {
        let entry = SessionDiagnosticEntry(
            timestamp: timestamp ?? SessionDiagnosticTimeline.currentTimestamp(),
            sessionId: sessionID,
            event: event,
            fields: fields
        )
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        persist()
    }

    public var summaryLines: [String] {
        entries.map(\.summaryLine)
    }

    private mutating func persist() {
        guard let logURL else { return }
        do {
            // Rewriting the bounded in-memory window keeps the durable log
            // bounded too and makes replacement atomic. A long-running app
            // therefore cannot grow one session file without limit.
            var data = Data()
            for retainedEntry in entries {
                data.append(try JSONEncoder().encode(retainedEntry))
                data.append(0x0A)
            }
            try data.write(to: logURL, options: .atomic)
        } catch {
            persistenceError = String(describing: error)
        }
    }

    private static func pruneOldLogs(
        in directory: URL,
        excluding currentLogURL: URL,
        maximumLogFiles: Int
    ) throws {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
        ]
        let candidates = try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.pathExtension.lowercased() == "jsonl"
                    && $0.standardizedFileURL != currentLogURL.standardizedFileURL
                    && (try? $0.resourceValues(
                        forKeys: resourceKeys
                    ).isRegularFile) == true
            }
            .sorted {
                let lhsDate = try? $0.resourceValues(
                    forKeys: resourceKeys
                ).contentModificationDate
                let rhsDate = try? $1.resourceValues(
                    forKeys: resourceKeys
                ).contentModificationDate
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }

        for expiredLog in candidates.dropFirst(maximumLogFiles - 1) {
            try FileManager.default.removeItem(at: expiredLog)
        }
    }

    private static func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
