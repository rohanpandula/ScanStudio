// Opt-in process tests for D-03. They require a built CLI and simulator
// engine, never connect to a scanner, and clean up every host they start.
import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

@Suite(
    "Headless host process",
    .enabled(if: ProcessInfo.processInfo.environment["SCANSTUDIO_CLI_E2E"] == "1"),
    .timeLimit(.minutes(5)),
    .serialized
)
struct HostProcessTests {
    @Test("detached host answers headless hello, refuses a competitor, and stops safely")
    func detachedLifecycle() async throws {
        guard let engine = ProcessInfo.processInfo.environment["SCANSTUDIO_ENGINE_PATH"] else {
            Issue.record("SCANSTUDIO_ENGINE_PATH is required for the opt-in host process suite")
            return
        }
        let root = URL(fileURLWithPath: "/tmp/ss-host-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("s.sock").path
        let log = root.appendingPathComponent("host.log").path
        #expect(socket.utf8.count < 104)

        let environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "TMPDIR": root.path,
            "SCANSTUDIO_TIMESCALE": "0.1"
        ]
        let start = try runCLI(["host", "--detach", "--simulator", "--socket", socket, "--engine", engine, "--log", log], environment: environment)
        #expect(start.status == 0, Comment(rawValue: start.stdout + start.stderr))
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(start.stdout.utf8)) as? [String: Any])
        let result = try #require(envelope["result"] as? [String: Any])
        let pid = Int32(try #require(result["hostPid"] as? Int))
        #expect(result["detached"] as? Bool == true)
        #expect(result["socketPath"] as? String == socket)
        #expect(result["logPath"] as? String == log)
        defer {
            _ = try? runCLI(["host", "stop", "--socket", socket], environment: environment)
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }

        let client = try await ControlChannelClient.open(path: socket, clientName: "host-process-test")
        let hello = try #require(await client.helloResult)
        #expect(hello.host == .headless)
        #expect(hello.hostPid == pid)
        await client.shutdown()
        #expect(FileManager.default.fileExists(atPath: log))
        #expect((try? Data(contentsOf: URL(fileURLWithPath: log)).isEmpty) == false)

        let pidfile = ControlHostPaths.pidfilePath(forSocket: socket)
        #expect(try ControlHostPidfile.read(at: pidfile) == pid)
        var info = stat()
        #expect(lstat(pidfile, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let competitor = try runCLI(["host", "--simulator", "--socket", socket, "--engine", engine, "--log", root.appendingPathComponent("other.log").path], environment: environment)
        #expect(competitor.status == 75, Comment(rawValue: competitor.stdout + competitor.stderr))
        #expect(competitor.stdout.contains("HOST_ALREADY_RUNNING"))

        try ControlHostPidfile.write(pid: ProcessInfo.processInfo.processIdentifier, at: pidfile)
        let refused = try runCLI(["host", "stop", "--socket", socket], environment: environment)
        #expect(refused.status == 69)
        #expect(refused.stdout.contains("Stale pidfile"))
        let stillRunning = try await ControlChannelClient.open(path: socket, clientName: "host-process-test")
        await stillRunning.shutdown()

        try ControlHostPidfile.write(pid: pid, at: pidfile)
        let stopped = try runCLI(["host", "stop", "--socket", socket], environment: environment)
        #expect(stopped.status == 0, Comment(rawValue: stopped.stdout + stopped.stderr))
        #expect(!FileManager.default.fileExists(atPath: socket))
        #expect(!FileManager.default.fileExists(atPath: pidfile))
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runCLI(_ arguments: [String], environment: [String: String]) throws -> CLIResult {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = packageRoot.appendingPathComponent(".build/debug/scanstudio-cli")
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            _ = kill(process.processIdentifier, SIGKILL)
            throw NSError(domain: "HostProcessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "CLI timed out: \(arguments)"])
        }
        return CLIResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
