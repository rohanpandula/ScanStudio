import Darwin
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Control session transcript")
struct ControlSessionTranscriptTests {
    @Test("buffered hello, multiple requests, and events remain ordered and copy create-only")
    func orderedAppendAndCompleteLineSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-transcript-\(UUID().uuidString)", isDirectory: true)
        let spool = root.appendingPathComponent("sessions", isDirectory: true)
        let project = root.appendingPathComponent("roll", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var transcript = ControlSessionTranscript(options: .init(
            invocationID: "invocation-test",
            fallbackDirectory: spool
        ))
        try transcript.record(
            direction: "request",
            requestID: 1,
            method: "hello",
            hardwareVerification: "notConnected",
            originalJSON: Data(#"{"id":1,"method":"hello","params":{}}"#.utf8)
        )
        try transcript.record(
            direction: "response",
            requestID: 1,
            method: "hello",
            hardwareVerification: "notConnected",
            originalJSON: Data(#"{"id":1,"result":{"diagnosticSessionId":"diagnostic-test"}}"#.utf8)
        )
        #expect(transcript.fileURL == nil)

        try transcript.activate(diagnosticSessionID: "diagnostic-test", projectDirectory: nil)
        let path = try #require(transcript.fileURL)
        try transcript.record(
            direction: "event",
            requestID: nil,
            method: "control.changed",
            hardwareVerification: "unverified",
            originalJSON: Data(#"{"event":"control.changed","payload":{"jobState":"running"}}"#.utf8)
        )
        try transcript.record(
            direction: "request",
            requestID: 2,
            method: "status",
            hardwareVerification: "unverified",
            originalJSON: Data(#"{"id":2,"method":"status","params":{}}"#.utf8)
        )
        try transcript.record(
            direction: "response",
            requestID: 2,
            method: "status",
            hardwareVerification: "unverified",
            originalJSON: Data(#"{"id":2,"result":{"jobState":"running"}}"#.utf8)
        )
        try transcript.record(
            direction: "transportTerminal",
            requestID: nil,
            method: "connection",
            hardwareVerification: "unverified",
            originalJSON: Data(#"{"reason":"localShutdown"}"#.utf8)
        )

        let initialSnapshotValue = try transcript.snapshot()
        let initialSnapshot = try #require(initialSnapshotValue)
        let partial = try FileHandle(forWritingTo: path)
        try partial.seekToEnd()
        try partial.write(contentsOf: Data(#"{"partial":true}"#.utf8))
        try partial.close()
        let snapshotValue = try transcript.snapshot()
        let snapshot = try #require(snapshotValue)
        #expect(snapshot.data == initialSnapshot.data)
        #expect(snapshot.path == path.path)
        #expect(snapshot.byteCount == snapshot.data.count)
        #expect(snapshot.data.last == 0x0A)
        let records = try decodeLines(snapshot.data)
        #expect(records.compactMap { $0["direction"] as? String } == [
            "request", "response", "event", "request", "response", "transportTerminal",
        ])
        #expect(records.compactMap { $0["method"] as? String } == [
            "hello", "hello", "control.changed", "status", "status", "connection",
        ])
        #expect(records.allSatisfy { ($0["invocationId"] as? String) == "invocation-test" })
        #expect((records[2]["controlRequestId"] as? NSNull) != nil)
        #expect((records[4]["original"] as? [String: Any])?["id"] as? Int == 2)

        try transcript.close(copyToProjectDirectory: project.path)
        let copy = project.appendingPathComponent(path.lastPathComponent)
        #expect(try Data(contentsOf: path).starts(with: snapshot.data))
        #expect(try Data(contentsOf: copy) == snapshot.data)
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let copyPermissions = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(copyPermissions == 0o600)

        var replaced = ControlSessionTranscript(options: .init(
            invocationID: "namespace-swap",
            fallbackDirectory: spool
        ))
        try replaced.activate(diagnosticSessionID: "diagnostic-test", projectDirectory: nil)
        let replacedPath = try #require(replaced.fileURL)
        try replaced.record(
            direction: "request",
            requestID: 1,
            method: "status",
            hardwareVerification: "notConnected",
            originalJSON: Data(#"{"id":1,"method":"status","params":{}}"#.utf8)
        )
        let heldOriginal = root.appendingPathComponent("held-original.ndjson")
        try FileManager.default.moveItem(at: replacedPath, to: heldOriginal)
        try FileManager.default.createSymbolicLink(at: replacedPath, withDestinationURL: heldOriginal)
        #expect(throws: Error.self) {
            _ = try replaced.snapshot()
        }
        try replaced.close()
    }

    private func decodeLines(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map {
                try #require(
                    JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                )
            }
    }
}
