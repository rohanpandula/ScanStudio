// Process-level proofs against the built `scanstudio-cli` binary and an
// in-process host (fake `EngineClientProtocol` + `SessionModel` +
// `ControlChannelServer` on a short `/tmp` path) -- no scanner motion, no
// GUI, no real engine binary. Mirrors `ControlChannelClientTests.swift`'s
// harness idioms (`shortSocketPath`, the fake-engine-stub/idle-model pair)
// one layer further out: these tests exec the real built CLI as a genuine
// subprocess, not `ControlChannelClient` in-process.
//
// Every test here passes `--socket` explicitly (a short `/tmp` test path)
// and never touches `~/.scanstudio/`.

import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

private enum CLIProcessStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint --
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`).
private let cliProcessDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

/// A minimal one-frame project fixture, modelled on
/// `ControlChannelProjectRoutingTests.swift`'s `projectRoutingProject(...)`.
private func cliProcessProject(frameIndex: Int = 1) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "cli-process-project",
        name: "CLI process test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/cli-process/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/cli-process/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/cli-process/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-09-07T00:00:00Z",
        frames: [ProjectFrame(index: frameIndex, excluded: false, receipts: [])]
    )
}

private let cliProcessProjectDirectory = "/tmp/cli-process-test-project"

/// Fake engine covering every wire method a process test in this file
/// drives, modelled on `ControlChannelProjectRoutingTests.swift`'s
/// `ProjectRoutingEngineStub`. `scanner.list`/`scanner.rescan` auto-
/// succeed (this suite never needs to hold them in flight).
private actor CLIProcessEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "cli-process-stub"

    private(set) var requestCounts: [String: Int] = [:]
    private(set) var recordedFrameExclusionFlags: [Bool] = []

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params
    ) async throws -> Result {
        requestCounts[method, default: 0] += 1
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [cliProcessDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: cliProcessDevice,
                status: ScannerStatus(
                    connected: true, adapter: "SA-21", mediaLoaded: false, carrier: nil,
                    frameCount: nil, lamp: "unknown", transport: "idle", activeJobId: nil,
                    filmPresent: nil, motionArmed: true
                )
            ), as: Result.self)
        case "project.open":
            let directory = (params as? ProjectOpenParams)?.directory ?? cliProcessProjectDirectory
            return try cast(
                ProjectOpenResult(project: cliProcessProject(), directory: directory),
                as: Result.self
            )
        case "project.setFrameExcluded":
            if let excludedParams = params as? SetFrameExcludedParams {
                recordedFrameExclusionFlags.append(excludedParams.excluded)
            }
            return try cast(SetFrameResult(project: cliProcessProject()), as: Result.self)
        default:
            throw CLIProcessStubError.unexpectedMethod(method)
        }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw CLIProcessStubError.unexpectedResultType }
        return result
    }
}

/// Bounded `Task.yield()` polling for `SessionModel.init`'s fire-and-forget
/// discovery call, per this codebase's established idiom (never a fixed
/// sleep).
@MainActor
private func makeIdleModel(_ stub: CLIProcessEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

/// A short `AF_UNIX` path under a per-test, per-label directory this suite
/// owns -- never the per-user temporary-directory API (its container path
/// is long enough to overflow `sun_path`), never anywhere under the real
/// home directory.
private func shortSocketPath(_ label: String) -> String {
    let directory = "/tmp/ss-cli-proc-\(label)-\(UInt32.random(in: 0..<UInt32.max))"
    let path = directory + "/s.sock"
    precondition(path.utf8.count < 104, "test socket path must be < 104 bytes, got \(path.utf8.count): \(path)")
    return path
}

private func removeSocketDirectory(for path: String) {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: directory)
}

/// An in-process host: a real `ControlChannelServer` bound to a short
/// `/tmp` path, feeding one shared `SessionModel` backed by a fake
/// `EngineClientProtocol`. The tests below exec the real built
/// `scanstudio-cli` binary against this host as a genuine subprocess --
/// what distinguishes this suite from `ControlChannelClientTests.swift`'s
/// in-process client tests.
@MainActor
private struct CLIProcessHost {
    let model: SessionModel
    let stub: CLIProcessEngineStub
    let server: ControlChannelServer
    let socketPath: String

    static func start(label: String) async throws -> CLIProcessHost {
        let stub = CLIProcessEngineStub()
        let model = await makeIdleModel(stub)
        let server = ControlChannelServer(sessionModel: model)
        let path = shortSocketPath(label)
        try await server.start(path: path)
        return CLIProcessHost(model: model, stub: stub, server: server, socketPath: path)
    }
}

private enum CLIProcessLocator {
    struct LocateError: Error, CustomStringConvertible {
        let description: String
    }

    /// Resolves `.build/debug/scanstudio-cli` from this file's own source
    /// path -- three `deletingLastPathComponent()` hops from
    /// `Tests/ScanStudioKitTests/…` to the package root, matching
    /// `EngineLocator`'s own source-relative idiom (never an absolute
    /// developer path).
    static func resolve() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ScanstudioCLIProcessTests.swift -> ScanStudioKitTests/
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

private struct CLIProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs the real built binary with `arguments` plus `--socket socketPath`
/// (when given), and returns its exit status, stdout, and stderr.
private func runCLI(_ arguments: [String], socketPath: String?) throws -> CLIProcessResult {
    let binary = try CLIProcessLocator.resolve()
    let process = Process()
    process.executableURL = binary
    var allArguments = arguments
    if let socketPath {
        allArguments += ["--socket", socketPath]
    }
    process.arguments = allArguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CLIProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

@Suite("scanstudio-cli process", .timeLimit(.minutes(1)))
struct ScanstudioCLIProcessTests {
    // MARK: Task 1 -- the shared runner, and connect/disconnect/rescan/status

    @Test("--help exits 0")
    func rootHelpExitsZero() throws {
        let result = try runCLI(["--help"], socketPath: shortSocketPath("root-help"))
        #expect(result.exitCode == 0)
    }

    @Test("status --help exits 0 and mentions --job")
    func statusHelpExitsZeroAndMentionsJob() throws {
        let result = try runCLI(["status", "--help"], socketPath: shortSocketPath("status-help"))
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--job"))
    }

    @Test("status with --socket pointing at a path with no listener exits 69 with a HOST_UNREACHABLE JSON body")
    func statusAgainstMissingListenerExitsHostUnreachable() throws {
        let result = try runCLI(["status"], socketPath: shortSocketPath("no-listener"))
        #expect(result.exitCode == 69)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "HOST_UNREACHABLE")
    }

    @Test("status against the in-process host exits 0 and its stdout parses as the JSON envelope")
    func statusAgainstHostReturnsJSONEnvelope() async throws {
        let host = try await CLIProcessHost.start(label: "status-json")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try runCLI(["status"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ControlSchema.version)
        #expect(object["command"] as? String == "status")
        #expect(object["mode"] as? String == "attach")
        #expect(object["result"] is [String: Any])

        await host.server.stop()
    }

    @Test("status --human against the host exits 0 and its stdout contains no {")
    func statusHumanAgainstHostContainsNoBrace() async throws {
        let host = try await CLIProcessHost.start(label: "status-human")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try runCLI(["status", "--human"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("{") == false)

        await host.server.stop()
    }

    @Test("connect against the host reaches the fake engine exactly once")
    func connectReachesEngineExactlyOnce() async throws {
        let host = try await CLIProcessHost.start(label: "connect")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try runCLI(["connect", "--device", cliProcessDevice.deviceId], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let connectCount = await host.stub.requestCounts["scanner.connect"]
        #expect(connectCount == 1)

        await host.server.stop()
    }

    @Test("OUT-04: running status three times against the host leaves the stub's request count unchanged")
    func statusIsRepeatableWithNoSideEffects() async throws {
        let host = try await CLIProcessHost.start(label: "out04")
        defer { removeSocketDirectory(for: host.socketPath) }

        let before = await host.stub.requestCounts
        for _ in 0..<3 {
            let result = try runCLI(["status"], socketPath: host.socketPath)
            #expect(result.exitCode == 0)
        }
        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    // MARK: Task 2 -- frames list/include/exclude, and diagnostics export

    @Test("frames include with a malformed range exits 64 with INVALID_RANGE, and the host's stub recorded zero new requests")
    func framesIncludeMalformedRangeExitsInvalidRangeBeforeAnyRequest() async throws {
        let host = try await CLIProcessHost.start(label: "frames-malformed")
        defer { removeSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try runCLI(["frames", "include", "5-2"], socketPath: host.socketPath)
        #expect(result.exitCode == 64)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_RANGE")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("frames list against a host with an open project fixture exits 0 and the JSON result carries a frames array")
    func framesListReturnsFramesArray() async throws {
        let host = try await CLIProcessHost.start(label: "frames-list")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.openProject(directory: cliProcessProjectDirectory)

        let result = try runCLI(["frames", "list"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["frames"] is [Any])

        await host.server.stop()
    }

    @Test("frames exclude with a valid index exits 0 and the fake engine saw exactly one project.setFrameExcluded")
    func framesExcludeValidIndexReachesEngineOnce() async throws {
        let host = try await CLIProcessHost.start(label: "frames-exclude")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.openProject(directory: cliProcessProjectDirectory)

        let result = try runCLI(["frames", "exclude", "1"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let excludeCount = await host.stub.requestCounts["project.setFrameExcluded"]
        #expect(excludeCount == 1)

        await host.server.stop()
    }

    @Test("frames include spanning one valid and one out-of-range index reports the host's refusal verbatim with an applied array naming the valid index")
    func framesIncludePartialRangeReportsAppliedIndices() async throws {
        let host = try await CLIProcessHost.start(label: "frames-partial")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.openProject(directory: cliProcessProjectDirectory)

        let result = try runCLI(["frames", "include", "1-2"], socketPath: host.socketPath)
        #expect(result.exitCode == 64)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_PARAMS")
        #expect((error["message"] as? String)?.isEmpty == false)
        #expect(error["recoverable"] as? Bool == false)
        let applied = try #require(object["applied"] as? [Int])
        #expect(applied == [1])

        await host.server.stop()
    }

    @Test("diagnostics export writes into the given temp directory and reports its path and entries")
    func diagnosticsExportWritesIntoTempDirectory() async throws {
        let host = try await CLIProcessHost.start(label: "diagnostics")
        defer { removeSocketDirectory(for: host.socketPath) }
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ss-cli-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = try runCLI(["diagnostics", "export", "--to", tempDirectory.path], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        let path = try #require(resultObject["path"] as? String)
        #expect(resultObject["entries"] is [Any])
        #expect(FileManager.default.fileExists(atPath: path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        #expect(contents == [(path as NSString).lastPathComponent])

        await host.server.stop()
    }
}
