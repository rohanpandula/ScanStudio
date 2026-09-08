// Unit proofs for `ControlRunReceipt` (D-15/HEAD-09,
// ScanStudioKit/ControlCLISupport.swift): stop-at-first-failure's own
// data-shape contract, byte-stable JSON, and the SAFE-03 no-overwrite
// write -- all pure, no subprocess, no socket. `RollRun.run()` itself
// (the composition, scanstudio-cli/Commands/RunCommands.swift) lives in
// the CLI executable target, which `ScanStudioKitTests` never depends on
// (Package.swift) -- exactly why `ControlRunReceipt` was factored into
// `ScanStudioKit` in the first place. Its two parse-time gates are proven
// here instead as CLI smoke through the real built binary, mirroring
// `ScanstudioCLIConfirmationTests.swift`'s own precedent for a
// file-private locator/runner pair when the shared one in
// `ScanstudioCLIProcessTests.swift` is outside this plan's own
// `files_modified`.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Control run receipt")
struct RollRunReceiptTests {
    // MARK: - Stop-at-first-failure (SAFE-02's own data-shape contract)

    @Test("a refusal recorded mid-walk leaves nothing after it, and its own exit code is what a caller reads back")
    func stopsAtFirstFailure() {
        var receipt = ControlRunReceipt()
        receipt.record(step: "refresh", command: "scanner.refresh", exitCode: 0, outcome: "ok", startedAt: "2026-01-01T00:00:00.000Z", endedAt: "2026-01-01T00:00:00.100Z")
        receipt.record(step: "status", command: "status", exitCode: 0, outcome: "ok", startedAt: "2026-01-01T00:00:00.100Z", endedAt: "2026-01-01T00:00:00.200Z")
        // A real walk stops the instant a step refuses (SAFE-02) -- nothing
        // is ever recorded after this one.
        receipt.record(step: "preview", command: "preview.acquire", exitCode: 75, outcome: "refused", startedAt: "2026-01-01T00:00:00.200Z", endedAt: "2026-01-01T00:00:00.300Z")

        #expect(receipt.steps.count == 3)
        #expect(receipt.steps.last?.step == "preview")
        #expect(receipt.steps.last?.outcome == "refused")
        #expect(receipt.steps.last?.exitCode == 75)
        #expect(receipt.steps.dropLast().allSatisfy { $0.outcome == "ok" })
    }

    // MARK: - Byte-stable JSON (OUT-01)

    @Test("encodedJSON is byte-identical across repeated encodes, with sorted keys")
    func encodedJSONIsStable() throws {
        var receipt = ControlRunReceipt()
        receipt.record(step: "refresh", command: "scanner.refresh", exitCode: 0, outcome: "ok", startedAt: "2026-01-01T00:00:00.000Z", endedAt: "2026-01-01T00:00:00.100Z")
        receipt.project = ControlRunReceipt.Project(name: "roll", directory: "/tmp/roll")
        receipt.jobId = "job-1"
        receipt.jobState = "completed"
        receipt.frames = ControlRunReceipt.Frames(selected: [1, 2, 3], skipped: [4], autoApproved: [])

        let first = try receipt.encodedJSON()
        let second = try receipt.encodedJSON()
        #expect(first == second)

        let text = try #require(String(data: first, encoding: .utf8))
        let framesRange = try #require(text.range(of: "\"frames\""))
        let jobIdRange = try #require(text.range(of: "\"jobId\""))
        let jobStateRange = try #require(text.range(of: "\"jobState\""))
        let projectRange = try #require(text.range(of: "\"project\""))
        let stepsRange = try #require(text.range(of: "\"steps\""))
        #expect(framesRange.lowerBound < jobIdRange.lowerBound)
        #expect(jobIdRange.lowerBound < jobStateRange.lowerBound)
        #expect(jobStateRange.lowerBound < projectRange.lowerBound)
        #expect(projectRange.lowerBound < stepsRange.lowerBound)
    }

    // MARK: - SAFE-03: never an overwrite

    @Test("a second write to the same path throws, and the original file's bytes are unchanged")
    func writeRefusesToOverwrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("run-receipt-overwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var first = ControlRunReceipt()
        first.jobId = "first"
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let path = try first.write(toProjectDirectory: tempDir.path, timestamp: timestamp)
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path))

        var second = ControlRunReceipt()
        second.jobId = "second"
        #expect(throws: ControlRunReceipt.WriteError.self) {
            try second.write(toProjectDirectory: tempDir.path, timestamp: timestamp)
        }

        let bytesAfter = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(bytesAfter == originalBytes)
    }

    @Test("write refuses a directory that does not exist")
    func writeRefusesMissingDirectory() {
        let missingDirectory = "/tmp/run-receipt-missing-\(UUID().uuidString)"
        let receipt = ControlRunReceipt()
        #expect(throws: ControlRunReceipt.WriteError.self) {
            try receipt.write(toProjectDirectory: missingDirectory, timestamp: Date())
        }
    }

    // MARK: - Lands beside the manifest, never touching it

    @Test("the receipt lands beside an existing manifest.json without touching it, named cli-run-<timestamp>.json")
    func writeLandsBesideTheManifest() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("run-receipt-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let manifestBytes = Data("{\"schemaVersion\":1}".utf8)
        try manifestBytes.write(to: manifestURL)
        let mtimeBefore = try #require(FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date)

        var receipt = ControlRunReceipt()
        receipt.jobId = "job-1"
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let path = try receipt.write(toProjectDirectory: tempDir.path, timestamp: timestamp)

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == tempDir.path)

        let filename = URL(fileURLWithPath: path).lastPathComponent
        let regex = try NSRegularExpression(pattern: "^cli-run-\\d{8}T\\d{6}Z\\.json$")
        let fullRange = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        #expect(regex.firstMatch(in: filename, range: fullRange) != nil)

        let manifestBytesAfter = try Data(contentsOf: manifestURL)
        #expect(manifestBytesAfter == manifestBytes)
        let mtimeAfter = try #require(FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date)
        #expect(mtimeAfter == mtimeBefore)
    }

    // MARK: - Timestamps

    @Test("isoTimestamp renders ISO-8601 with fractional seconds in UTC, round-tripping to the same instant")
    func timestampsAreISO8601UTC() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let text = ControlRunReceipt.isoTimestamp(date)

        #expect(text.hasSuffix("Z"))
        #expect(text.contains("."))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let roundTripped = try #require(formatter.date(from: text))
        #expect(abs(roundTripped.timeIntervalSince(date)) < 0.001)
    }
}

// MARK: - CLI smoke through the built binary (no host)

private enum RunCLILocator {
    struct LocateError: Error, CustomStringConvertible {
        let description: String
    }

    /// Resolves `.build/debug/scanstudio-cli` from this file's own source
    /// path -- the identical three-hop, source-relative idiom
    /// `ScanstudioCLIProcessTests.swift`'s `CLIProcessLocator` and
    /// `ScanstudioCLIConfirmationTests.swift`'s `ConfirmationCLILocator`
    /// already use.
    static func resolve() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RollRunReceiptTests.swift -> ScanStudioKitTests/
            .deletingLastPathComponent() // ScanStudioKitTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> package root
        let binary = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("scanstudio-cli")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw LocateError(
                description: "scanstudio-cli binary not found at \(binary.path). Run `swift build --product scanstudio-cli` first."
            )
        }
        return binary
    }
}

/// Runs the real built binary and returns only its exit status -- these
/// two smoke tests care about the parse-time gate firing before any
/// connection, not about the printed body. The blocking `Process`
/// spawn/read/wait sequence runs on a dedicated background queue via a
/// continuation, never inline on Swift's cooperative thread pool --
/// `ScanstudioCLIProcessTests.swift`'s own header explains why a direct
/// inline call starves the suite under parallel execution.
private struct RunCLIResult {
    let exitCode: Int32
    let stdout: Data
}

private func runRunCLIResult(_ arguments: [String]) async throws -> RunCLIResult {
    let binary = try RunCLILocator.resolve()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunCLIResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: RunCLIResult(exitCode: process.terminationStatus, stdout: stdout))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func runRunCLI(_ arguments: [String]) async throws -> Int32 {
    try await runRunCLIResult(arguments).exitCode
}

@Suite("roll run CLI smoke (no host)", .timeLimit(.minutes(1)))
struct RollRunCLISmokeTests {
    @Test("schema is offline and its job example and command inventory match the executable")
    func schemaAndInvalidJobAreValidatedOffline() async throws {
        let socket = "/tmp/gsd-no-host-schema-\(UUID().uuidString).sock"
        let schema = try await runRunCLIResult(["schema", "--socket", socket])
        #expect(schema.exitCode == 0)
        let envelope = try #require(JSONSerialization.jsonObject(with: schema.stdout) as? [String: Any])
        let result = try #require(envelope["result"] as? [String: Any])
        let jobContract = try #require(result["job"] as? [String: Any])
        let example = try #require(jobContract["example"] as? [String: Any])
        _ = try ScanJobDocument.decode(JSONSerialization.data(withJSONObject: example))
        let exits = try #require(result["exitCodes"] as? [String: Any])
        #expect((exits["waitTimedOut"] as? NSNumber)?.intValue == 124)
        let commands = try #require(result["commands"] as? [[String: Any]])
        let names = Set(commands.compactMap { $0["command"] as? String })
        #expect(names.isSuperset(of: ["run", "scan"]))

        let validFile = FileManager.default.temporaryDirectory.appendingPathComponent("valid-job-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: validFile) }
        try JSONSerialization.data(withJSONObject: example).write(to: validFile)
        let dryRun = try await runRunCLIResult(["run", validFile.path, "--dry-run", "--socket", socket])
        #expect(dryRun.exitCode == 69)
        #expect(!FileManager.default.fileExists(atPath: socket))
        #expect(!FileManager.default.fileExists(atPath: socket + ".host.log"))

        var invalid = example
        invalid["schemaVersion"] = 2
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-job-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: invalid).write(to: file)
        let rejected = try await runRunCLIResult([
            "run", file.path, "--film-loaded", "--confirm-motion", "--socket", socket,
        ])
        #expect(rejected.exitCode == 64)
    }

    /// Points at a socket path nothing is listening on: if either gate
    /// below failed to fire before a connection attempt, the exit code
    /// would be 69 (HOST_UNREACHABLE), not 77 -- so this also proves
    /// neither gate opens a socket.
    @Test("roll run without --film-loaded exits 77 before any socket opens")
    func missingFilmLoadedExits77() async throws {
        let exitCode = try await runRunCLI([
            "roll", "run", "--name", "r", "--carrier", "strip6", "--film-process", "c41ColorNegative",
            "--confirm-motion", "--socket", "/tmp/gsd-no-host-run-smoke-1.sock"
        ])
        #expect(exitCode == 77)
    }

    @Test("roll run without --confirm-motion exits 77 before any socket opens")
    func missingConfirmMotionExits77() async throws {
        let exitCode = try await runRunCLI([
            "roll", "run", "--name", "r", "--carrier", "strip6", "--film-process", "c41ColorNegative",
            "--film-loaded", "--socket", "/tmp/gsd-no-host-run-smoke-2.sock"
        ])
        #expect(exitCode == 77)
    }
}
