import Foundation

/// A generic, JSON-shaped diagnostic field value. Event authors may record a
/// string, a number, a boolean, or a nested array/object without the report
/// renderer ever needing per-event or per-key knowledge of the shape --
/// future instrumentation (e.g. detector confidence scores) starts rendering
/// into reports the moment it starts recording a field, with zero coupling
/// to `SessionDiagnosticEntry.summaryLine` or the error-report builder.
public enum DiagnosticFieldValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([DiagnosticFieldValue])
    case object([String: DiagnosticFieldValue])

    /// Compact, single-line rendering used by `SessionDiagnosticEntry
    /// .summaryLine` and, transitively, every generated error report. Never
    /// multi-line and never pretty-printed JSON -- nested values still
    /// collapse into one `key=value` diagnostic line.
    public var compactDescription: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return DiagnosticFieldValue.formatNumber(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return "[" + values.map(\.compactDescription).joined(separator: ",") + "]"
        case .object(let fields):
            let rendered = fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.compactDescription)" }
                .joined(separator: ",")
            return "{\(rendered)}"
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

extension DiagnosticFieldValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension DiagnosticFieldValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension DiagnosticFieldValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension DiagnosticFieldValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension DiagnosticFieldValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: DiagnosticFieldValue...) { self = .array(elements) }
}

extension DiagnosticFieldValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, DiagnosticFieldValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

/// Round-trips through the timeline's durable JSONL log as plain JSON --
/// a string field stays a JSON string, a number stays a JSON number, and so
/// on -- so the on-disk log and the in-memory value never diverge in shape.
extension DiagnosticFieldValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DiagnosticFieldValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DiagnosticFieldValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported DiagnosticFieldValue payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One privacy-safe, structured decision or state transition from the current
/// ScanStudio session. Callers supply only operational fields; paths, film
/// metadata, image names, receipts, and device identifiers do not belong here.
public struct SessionDiagnosticEntry: Codable, Equatable, Sendable {
    public let timestamp: String
    public let sessionId: String
    public let event: String
    public let fields: [String: DiagnosticFieldValue]

    public init(
        timestamp: String,
        sessionId: String,
        event: String,
        fields: [String: DiagnosticFieldValue]
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.event = event
        self.fields = fields
    }

    public var summaryLine: String {
        let details = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.compactDescription)" }
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
        fields: [String: DiagnosticFieldValue] = [:]
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
