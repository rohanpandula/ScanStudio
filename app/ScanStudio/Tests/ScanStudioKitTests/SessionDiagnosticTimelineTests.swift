import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Session diagnostic timeline")
struct SessionDiagnosticTimelineTests {
    @Test("The timeline is bounded and renders stable structured summaries")
    func boundedSummary() {
        var timeline = SessionDiagnosticTimeline(
            sessionID: "session-test",
            maximumEntries: 2
        )

        timeline.record(
            timestamp: "2026-07-28T00:08:18Z",
            event: "device.connect.succeeded",
            fields: ["connected": "true", "kind": "real"]
        )
        timeline.record(
            timestamp: "2026-07-28T00:09:00Z",
            event: "preview.requested",
            fields: ["uiConnected": "true"]
        )
        timeline.record(
            timestamp: "2026-07-28T00:09:01Z",
            event: "preview.failed",
            fields: ["code": "NOT_CONNECTED", "uiConnectedBefore": "true"]
        )

        #expect(timeline.entries.count == 2)
        #expect(
            timeline.summaryLines == [
                "2026-07-28T00:09:00Z preview.requested uiConnected=true",
                "2026-07-28T00:09:01Z preview.failed code=NOT_CONNECTED uiConnectedBefore=true",
            ]
        )
    }

    @Test("A configured timeline persists one JSON object per event")
    func jsonlPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanstudio-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var timeline = SessionDiagnosticTimeline(
            sessionID: "session-jsonl",
            maximumEntries: 10,
            directory: directory
        )
        timeline.record(
            timestamp: "2026-07-28T00:09:01Z",
            event: "preview.failed",
            fields: ["code": "NOT_CONNECTED", "uiConnectedBefore": "true"]
        )

        let logURL = try #require(timeline.logURL)
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        #expect(object["sessionId"] as? String == "session-jsonl")
        #expect(object["event"] as? String == "preview.failed")
        #expect((object["fields"] as? [String: String])?["code"] == "NOT_CONNECTED")
    }

    @Test("Durable diagnostics retain only the bounded in-memory window")
    func boundedJsonlPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanstudio-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var timeline = SessionDiagnosticTimeline(
            sessionID: "bounded-jsonl",
            maximumEntries: 2,
            directory: directory
        )
        for index in 1...3 {
            timeline.record(
                timestamp: "2026-07-28T00:09:0\(index)Z",
                event: "event-\(index)"
            )
        }

        let logURL = try #require(timeline.logURL)
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("event-2"))
        #expect(lines[1].contains("event-3"))
    }

    @Test("Starting a session prunes old JSONL files to the configured limit")
    func oldLogRetention() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanstudio-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        for index in 1...3 {
            let url = directory.appendingPathComponent("old-\(index).jsonl")
            try Data("old-\(index)\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: url.path
            )
        }

        var timeline = SessionDiagnosticTimeline(
            sessionID: "current",
            maximumLogFiles: 2,
            directory: directory
        )
        timeline.record(event: "session.started")

        let logs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
        #expect(logs.map(\.lastPathComponent).sorted() == [
            "current.jsonl",
            "old-3.jsonl",
        ])
    }
}
