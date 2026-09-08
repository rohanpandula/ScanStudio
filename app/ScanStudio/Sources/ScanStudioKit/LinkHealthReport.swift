import Foundation

/// Observations in retained telemetry, never a live probe or a cable diagnosis.
public struct LinkHealthReport: Codable, Equatable, Sendable {
    public let status: String
    public let windowStart: String
    public let windowEnd: String
    public let recentRecordCount: Int
    public let bulkReadFailureCount: Int
    public let disconnectIndicatorCount: Int
    public let otherErrorCount: Int
    public let malformedRecordCount: Int
    public let lastOccurrence: String?
    public let guidance: String

    public static func summarize(_ data: Data?, now: Date = Date(), windowSeconds: TimeInterval = 900) -> Self {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        let start = now.addingTimeInterval(-windowSeconds)
        var recent = 0, bulk = 0, disconnect = 0, other = 0, malformed = 0
        var last: Date?
        if let data {
            var lines = data.split(separator: 0x0A)
            if !data.isEmpty && data.last != 0x0A {
                malformed += 1
                if !lines.isEmpty { lines.removeLast() }
            }
            for line in lines {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let timestamp = record["timestamp"] as? String,
                      let outcome = record["outcome"] as? String,
                      let date = formatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp) else {
                    malformed += 1
                    continue
                }
                guard date >= start, date <= now else { continue }
                recent += 1
                guard ["error", "failed", "halted"].contains(outcome) else { continue }
                let message = ((record["message"] as? String) ?? (record["reason"] as? String) ?? "").lowercased()
                let code = (record["code"] as? String) ?? ""
                let isBulk = message.contains("bulk") && message.contains("read")
                let isDisconnect = message.contains("libusb_error_no_device")
                    || message.contains("no such device") || message.contains("device disconnected")
                    || code == "DEVICE_NOT_FOUND"
                if isBulk { bulk += 1 }
                if isDisconnect { disconnect += 1 }
                if !isBulk && !isDisconnect { other += 1 }
                if last == nil || date > last! { last = date }
            }
        }
        let status: String
        let guidance: String
        if bulk > 0 || disconnect > 0 {
            status = "attention"
            guidance = "Recorded errors mention bulk reads or device loss. Inspect the retained telemetry and USB connection before an explicitly authorized run; do not retry automatically. These are log indicators, not a live diagnosis."
        } else if data == nil || recent == 0 || malformed > 0 {
            status = "unknown"
            guidance = "No complete recent telemetry coverage is available. This report does not establish link health."
        } else if other > 0 {
            status = "unknown"
            guidance = "Other failures were recorded without a specific USB link indicator. Inspect their retained details before deciding what to do."
        } else {
            status = "noErrorsObserved"
            guidance = "No link errors were recorded in this time window. No live scanner probe was performed."
        }
        return Self(
            status: status, windowStart: formatter.string(from: start), windowEnd: formatter.string(from: now),
            recentRecordCount: recent, bulkReadFailureCount: bulk, disconnectIndicatorCount: disconnect,
            otherErrorCount: other, malformedRecordCount: malformed,
            lastOccurrence: last.map(formatter.string(from:)), guidance: guidance
        )
    }
}
