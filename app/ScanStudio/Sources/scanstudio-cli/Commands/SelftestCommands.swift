import ArgumentParser
import Darwin
import Foundation
import ScanStudioKit

struct Selftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Exercise stall, feed-jam recovery, and observer reattachment using only an isolated simulator.")
    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("engine"), help: "Development engine override; packaged CLI requires its bundled sibling.") var enginePath: String?

    func run() async throws {
        let cli = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let engine = try BundledEnginePolicy.resolve(cliExecutableURL: cli, environment: [:], engineOverride: enginePath, fileExists: FileManager.default.fileExists(atPath:))
        var results: [[String: Any]] = []
        for name in ["stall", "feed-jam", "reattach"] {
            let scenario = try SelftestScenario(name: name, cli: cli, engine: engine)
            do {
                try await scenario.exercise()
                results.append(["scenario": name, "passed": true, "evidence": scenario.root.path])
            } catch {
                results.append(["scenario": name, "passed": false, "evidence": scenario.root.path, "error": String(describing: error)])
            }
            await scenario.cleanup()
        }
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        print(try ControlCLIOutput.renderResult(command: "selftest", resultJSON: ["passed": passed, "simulated": true, "scenarios": results], human: options.human), terminator: "")
        if !passed { throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue) }
    }
}

private final class SelftestScenario {
    let name: String
    let root: URL
    private let cli: URL
    private let engine: URL
    private let socket: String
    private var children: [Child] = []
    private var environment: [String: String]

    private struct Child {
        let process: Process
        let output: URL
        let error: URL
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(name: String, cli: URL, engine: URL) throws {
        self.name = name
        self.cli = cli
        self.engine = engine
        root = URL(fileURLWithPath: "/tmp/ss-selftest-\(UUID().uuidString.prefix(8))-\(name)")
        socket = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SCANSTUDIO_") && $0.key != "CFFIXED_USER_HOME" }
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        environment["SCANSTUDIO_BRIDGE_BASE_DIR"] = root.appendingPathComponent("bridge").path
        environment["SCANSTUDIO_TIMESCALE"] = name == "reattach" ? "1" : "0.02"
    }

    func exercise() async throws {
        _ = try spawn(["host", "run", "--simulator", "--engine", engine.path])
        let startup = ContinuousClock.now + .seconds(10)
        while !ControlSocketDialer.probeIsLive(path: socket), ContinuousClock.now < startup {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(ControlSocketDialer.probeIsLive(path: socket), "isolated host did not start")
        let readyDeadline = ContinuousClock.now + .seconds(10)
        while true {
            let snapshot = try await execute(["status"])
            if snapshot["controller"] == nil { break }
            try require(ContinuousClock.now < readyDeadline, "host startup discovery did not finish")
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await execute(["connect", "--device", "sim-ls5000-0"])
        var media = ["sim", "load-media", "--carrier", "strip6"]
        if name == "stall" { media += ["--stall-at-frame", "1"] }
        if name == "feed-jam" { media += ["--abort-at-frame", "1", "--abort-code", "FEED_JAM"] }
        _ = try await execute(media)
        _ = try await execute(["settings", "set", "--resolution", "40", "--multisample", "4", "--film-process", "positive"])
        _ = try await execute(["preview", "--film-loaded"])
        _ = try await execute(["wait", "--for", "registered", "--timeout", "10"])
        _ = try await execute(["frames", "select", "1-2"])
        _ = try await execute(["roll", "save", "--name", "Selftest-\(name)", "--carrier", "strip6", "--frame-count", "6", "--film-process", "positive", "--no-scan"])

        if name == "feed-jam" {
            let failed = try await execute(["scan", "--frames", "1-2", "--confirm-motion", "--wait"], expected: 65)
            try require(failed["jobState"] as? String == "failed", "feed jam did not fail the job")
            let codes = failed["frameErrorCodes"] as? [String: String]
            try require(codes?["1"] == "FEED_JAM", "typed feed-jam evidence missing")
            let resumed = try await execute(["resume", "--confirm-motion", "--wait"])
            try require(resumed["jobState"] as? String == "completed", "feed-jam recovery did not complete")
            try require((resumed["receiptCount"] as? Int ?? 0) > 0, "recovery has no retained receipt")
            return
        }

        let first = try spawn(["scan", "--frames", "1-2", "--confirm-motion", "--wait"])
        let live = try await awaitProgress()
        let job = try unwrap(live["jobId"] as? String, "active job ID missing")
        if name == "stall" {
            try await Task.sleep(for: .milliseconds(200))
            let unchanged = try await execute(["status"])
            let before = try JSONSerialization.data(withJSONObject: live["progress"] ?? [:], options: [.sortedKeys])
            let after = try JSONSerialization.data(withJSONObject: unchanged["progress"] ?? [:], options: [.sortedKeys])
            try require(before == after && unchanged["jobId"] as? String == job, "stalled progress advanced")
            _ = try await execute(["stop", "--immediate"])
            let terminal = try await finish(first)
            try require(terminal["jobState"] as? String == "stopped", "stalled frame did not stop")
            try require(terminal["receiptCount"] as? Int == 0, "stalled frame produced a capture")
        } else {
            // Only the observer dies. The resident host and engine remain
            // owned by this scenario and continue the exact admitted job.
            first.process.terminate()
            await stop(first.process)
            let reattached = try spawn(["scan", "--frames", "1-2", "--confirm-motion", "--wait"])
            let terminal = try await finish(reattached)
            let returnedJob = terminal["jobId"] as? String ?? (terminal["progress"] as? [String: Any])?["jobId"] as? String
            try require(returnedJob == job, "observer attached to a different job")
            try require(terminal["jobState"] as? String == "completed", "reattached job did not complete")
            try require(try scanStartCount() == 1, "observer reattachment sent a second scan.start")
        }
    }

    private func spawn(_ arguments: [String]) throws -> Child {
        let prefix = String(format: "%03d", children.count)
        let output = root.appendingPathComponent(prefix + ".stdout.json")
        let error = root.appendingPathComponent(prefix + ".stderr.log")
        try Data().write(to: output, options: [.withoutOverwriting])
        try Data().write(to: error, options: [.withoutOverwriting])
        let out = try FileHandle(forWritingTo: output)
        let err = try FileHandle(forWritingTo: error)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments + ["--socket", socket] + (arguments.first == "host" ? [] : ["--attach"])
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try JSONSerialization.data(withJSONObject: process.arguments ?? []).write(to: root.appendingPathComponent(prefix + ".command.json"), options: [.withoutOverwriting])
        try process.run()
        let child = Child(process: process, output: output, error: error)
        children.append(child)
        return child
    }

    private func execute(_ arguments: [String], expected: Int32 = 0) async throws -> [String: Any] {
        try await finish(spawn(arguments), expected: expected)
    }

    private func finish(_ child: Child, expected: Int32 = 0) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(30)
        while child.process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if child.process.isRunning {
            await stop(child.process)
            throw Failure(description: "child timed out; inspect \(child.error.path)")
        }
        try require(child.process.terminationStatus == expected, "child exited \(child.process.terminationStatus), expected \(expected); inspect \(child.output.path) and \(child.error.path)")
        let handle = try FileHandle(forReadingFrom: child.output)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        try require(data.count <= 1_048_576, "child JSON exceeded 1 MiB")
        let envelope = try unwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "invalid child JSON")
        return try unwrap(envelope["result"] as? [String: Any], "child returned no result: \(child.output.path)")
    }

    private func awaitProgress() async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            let status = try await execute(["status"])
            if status["jobId"] is String, status["progress"] is [String: Any] { return status }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        throw Failure(description: "job produced no observable progress")
    }

    private func scanStartCount() throws -> Int {
        var keys: Set<String> = []
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        for case let file as URL in files where file.pathExtension == "jsonl" {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 8_388_609) ?? Data()
            try require(data.count <= 8_388_608, "selftest transcript exceeded 8 MiB")
            for line in data.split(separator: 0x0A) {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["event"] as? String == "control.request",
                      let fields = record["fields"] as? [String: Any], fields["command"] as? String == "scan.start",
                      let correlation = fields["correlationToken"] as? String else { continue }
                keys.insert(correlation)
            }
        }
        return keys.count
    }

    func cleanup() async {
        for child in children.reversed() { await stop(child.process) }
    }

    private func stop(_ process: Process) async {
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }
}
