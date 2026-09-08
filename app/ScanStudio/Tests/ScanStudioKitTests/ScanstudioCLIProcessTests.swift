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
private func cliProcessProject(
    frameIndex: Int = 1,
    alignment: FrameAlignment? = nil
) -> ScanProject {
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
        frames: [ProjectFrame(
            index: frameIndex,
            excluded: false,
            alignment: alignment,
            receipts: []
        )]
    )
}

private let cliProcessProjectDirectory = "/tmp/cli-process-test-project"

/// `roll.list`'s scripted `project.list` response -- `ProjectSummary` is
/// `Decodable`-only with no custom `public init`, so the compiler's
/// synthesized `internal` memberwise initializer is what this fixture
/// uses, visible via `@testable import` (mirrors
/// `ControlChannelProjectRoutingTests.swift`'s identical fixture).
private let cliProcessRecentProject = ProjectSummary(
    id: "cli-process-recent",
    name: "Recent roll",
    carrier: .mounted,
    frameCount: 1,
    filmProcess: .c41ColorNegative,
    createdAt: "2026-09-01T00:00:00Z",
    directory: "/tmp/cli-process/recent"
)

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
        case "roll.manualFrames":
            return try cast(
                RollManualFramesResult(
                    count: 1,
                    fingerprint: "cli-placement",
                    operationId: "cli-placement-operation",
                    thumbnails: [ManualFrameThumbnail(
                        frameIndex: 1,
                        thumbnail: Thumbnail(
                            brightness: nil,
                            tint: nil,
                            imagePath: "/tmp/cli-placement-frame-1.tif",
                            boundaryRows: [0, 100],
                            spacingOffset: 0,
                            needsApproval: true,
                            warnings: ["user-picked"]
                        )
                    )],
                    snaps: []
                ),
                as: Result.self
            )
        case "roll.setSpacingOffset":
            guard let placement = params as? RollSetSpacingOffsetParams else {
                throw CLIProcessStubError.unexpectedMethod(method)
            }
            return try cast(
                RollSetSpacingOffsetResult(thumbnail: Thumbnail(
                    brightness: nil,
                    tint: nil,
                    imagePath: "/tmp/cli-placement-frame-1-offset.tif",
                    boundaryRows: [0, 100],
                    spacingOffset: placement.offsetRows,
                    needsApproval: true,
                    warnings: ["user-picked"]
                )),
                as: Result.self
            )
        case "project.setFrameAlignment":
            guard let placement = params as? SetFrameAlignmentParams else {
                throw CLIProcessStubError.unexpectedMethod(method)
            }
            return try cast(
                SetFrameResult(project: cliProcessProject(alignment: placement.alignment)),
                as: Result.self
            )
        case "project.pendingFrames":
            // D-22/HEAD-12: setFrameExcluded now refreshes pendingFrames
            // before returning -- this fixture's single-frame project has
            // nothing pending once excluded, but these tests only assert
            // the exclude call itself, not this read's own result.
            return try cast(
                PendingFramesResult(frames: [], totalFrames: 1, completedCount: 0, excludedCount: 1),
                as: Result.self
            )
        case "project.list":
            return try cast(ProjectListResult(projects: [cliProcessRecentProject]), as: Result.self)
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
///
/// The actual blocking `Process` spawn/read/wait sequence runs on a
/// dedicated background queue via a continuation -- never inline on
/// Swift's cooperative thread pool. This mirrors
/// `ControlChannelServer.write(fd:bytes:)`'s own pattern and, more to the
/// point, is the identical fix plan 02-02's `ControlChannelServerTests.swift`
/// needed for the same reason: blocking I/O called directly inside an
/// `async` test function occupies a cooperative-pool thread for the whole
/// blocking duration, and with several tests' hosts all needing
/// actor/`@MainActor` hops concurrently, the pool is exhausted and every
/// connection -- including the one this very call is waiting on -- stops
/// making progress until the blocked call gives up. A hang reproduced
/// directly during this suite's own development confirmed it.
private func runCLI(
    _ arguments: [String],
    socketPath: String?,
    homeDirectory: String? = nil
) async throws -> CLIProcessResult {
    let binary = try CLIProcessLocator.resolve()
    let allArguments: [String] = if let socketPath {
        arguments + ["--socket", socketPath]
    } else {
        arguments
    }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIProcessResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                process.executableURL = binary
                process.arguments = allArguments
                if let homeDirectory {
                    var environment = ProcessInfo.processInfo.environment
                    environment["HOME"] = homeDirectory
                    environment["CFFIXED_USER_HOME"] = homeDirectory
                    process.environment = environment
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: CLIProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@Suite("scanstudio-cli process", .timeLimit(.minutes(1)))
struct ScanstudioCLIProcessTests {
    // MARK: Task 1 -- the shared runner, and connect/disconnect/rescan/status

    @Test("--help exits 0")
    func rootHelpExitsZero() async throws {
        let result = try await runCLI(["--help"], socketPath: shortSocketPath("root-help"))
        #expect(result.exitCode == 0)
    }

    @Test("status --help exits 0 and mentions --job")
    func statusHelpExitsZeroAndMentionsJob() async throws {
        let result = try await runCLI(["status", "--help"], socketPath: shortSocketPath("status-help"))
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--job"))
    }

    @Test("status with --socket pointing at a path with no listener exits 69 with a HOST_UNREACHABLE JSON body")
    func statusAgainstMissingListenerExitsHostUnreachable() async throws {
        let result = try await runCLI(["status"], socketPath: shortSocketPath("no-listener"))
        #expect(result.exitCode == 69)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "HOST_UNREACHABLE")
    }

    @Test("status against the in-process host exits 0 and its stdout parses as the JSON envelope")
    func statusAgainstHostReturnsJSONEnvelope() async throws {
        let host = try await CLIProcessHost.start(label: "status-json")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(["status"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ControlSchema.version)
        #expect(object["command"] as? String == "status")
        #expect(object["mode"] as? String == "attach-gui")
        #expect(object["result"] is [String: Any])

        await host.server.stop()
    }

    @Test("status --human against the host exits 0 and its stdout contains no {")
    func statusHumanAgainstHostContainsNoBrace() async throws {
        let host = try await CLIProcessHost.start(label: "status-human")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(["status", "--human"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("{") == false)

        await host.server.stop()
    }

    @Test("connect against the host reaches the fake engine exactly once")
    func connectReachesEngineExactlyOnce() async throws {
        let host = try await CLIProcessHost.start(label: "connect")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(["connect", "--device", cliProcessDevice.deviceId], socketPath: host.socketPath)
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
            let result = try await runCLI(["status"], socketPath: host.socketPath)
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

        let result = try await runCLI(["frames", "include", "5-2"], socketPath: host.socketPath)
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

        let result = try await runCLI(["frames", "list"], socketPath: host.socketPath)
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

        let result = try await runCLI(["frames", "exclude", "1"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let excludeCount = await host.stub.requestCounts["project.setFrameExcluded"]
        #expect(excludeCount == 1)

        await host.server.stop()
    }

    @Test("frames include spanning one valid and one out-of-range index reports the host's refusal verbatim with applied and failed")
    func framesIncludePartialRangeReportsAppliedIndices() async throws {
        let host = try await CLIProcessHost.start(label: "frames-partial")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.openProject(directory: cliProcessProjectDirectory)

        let result = try await runCLI(["frames", "include", "1-2"], socketPath: host.socketPath)
        // D-24/HEAD-12 (CF-14, the 2026-09-07 batch abort): a partial
        // application always exits 65, regardless of the refused index's
        // own code -- the caller's whole range did not apply, which is a
        // different fact than what a single INVALID_PARAMS refusal
        // normally maps to (64).
        #expect(result.exitCode == 65)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_PARAMS")
        #expect((error["message"] as? String)?.isEmpty == false)
        #expect(error["recoverable"] as? Bool == false)
        let applied = try #require(object["applied"] as? [Int])
        #expect(applied == [1])
        let failed = try #require(object["failed"] as? [[String: Any]])
        #expect(failed.count == 1)
        #expect(failed.first?["index"] as? Int == 2)
        #expect(failed.first?["code"] as? String == "INVALID_PARAMS")

        await host.server.stop()
    }

    @Test("frames select with no range/--all/--none exits 64 client-side with INVALID_RANGE, and the host's stub recorded zero new requests")
    func framesSelectWithNoSelectorExitsInvalidRangeBeforeAnyRequest() async throws {
        let host = try await CLIProcessHost.start(label: "frames-select-none-given")
        defer { removeSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runCLI(["frames", "select"], socketPath: host.socketPath)
        #expect(result.exitCode == 64)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_RANGE")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("frames select --all --none (both given) exits 64 client-side with INVALID_RANGE, and the host's stub recorded zero new requests")
    func framesSelectWithBothAllAndNoneExitsInvalidRangeBeforeAnyRequest() async throws {
        let host = try await CLIProcessHost.start(label: "frames-select-both-given")
        defer { removeSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runCLI(["frames", "select", "--all", "--none"], socketPath: host.socketPath)
        #expect(result.exitCode == 64)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_RANGE")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("CR-02: frames select --all reaches the host over the real socket and selects every previewed frame before any project exists")
    func framesSelectAllReachesHostBeforeProjectExists() async throws {
        let host = try await CLIProcessHost.start(label: "frames-select-all")
        defer { removeSocketDirectory(for: host.socketPath) }
        // A completed preview's own `scanner.status` event -- frames.select
        // validates indices against `status.frameCount`, never a project's
        // frame list, since none exists yet (that's the whole point of this
        // command). No project is opened in this test.
        await host.model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":6,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
                """#.utf8
            )
        ))
        let projectBeforeSelect = await host.model.project
        #expect(projectBeforeSelect == nil)

        let result = try await runCLI(["frames", "select", "--all"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let selected = await host.model.selectedFrames
        #expect(selected == [1, 2, 3, 4, 5, 6])

        await host.server.stop()
    }

    @Test("CR-02: frames select <range> reaches the host over the real socket and selects exactly that subset")
    func framesSelectRangeReachesHostBeforeProjectExists() async throws {
        let host = try await CLIProcessHost.start(label: "frames-select-range")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"""
                {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":6,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
                """#.utf8
            )
        ))

        let result = try await runCLI(["frames", "select", "2-3"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let selected = await host.model.selectedFrames
        #expect(selected == [2, 3])

        await host.server.stop()
    }

    @Test("CR-02: frames select --all after a project already exists selects the project's own frames")
    func framesSelectAllAfterProjectExistsSelectsProjectFrames() async throws {
        // D-23/HEAD-12 (CF-12, the 2026-09-07 batch abort): the blanket
        // "a project already exists" GATE_REFUSED is lifted in favor of
        // project-aware validation -- see ControlChannelDispatcher.swift's
        // .framesSelect arm and ControlChannelProjectRoutingTests.swift's
        // dispatcher-level coverage of the excluded/completed refusals.
        let host = try await CLIProcessHost.start(label: "frames-select-post-project")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.openProject(directory: cliProcessProjectDirectory)

        let result = try await runCLI(["frames", "select", "--all"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["result"] != nil)
        #expect(await host.model.selectedFrames == [1])

        await host.server.stop()
    }

    @Test("frames place --from applies manual rows and an absolute offset through the real CLI socket")
    func framesPlaceFromFileAppliesRowsAndOffset() async throws {
        let host = try await CLIProcessHost.start(label: "frames-place-file")
        defer { removeSocketDirectory(for: host.socketPath) }
        await host.model.openProject(directory: cliProcessProjectDirectory)
        await host.model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":true,"carrier":"mounted","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}"#.utf8
            )
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-cli-placement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let placement = directory.appendingPathComponent("placement.json")
        try Data(
            #"{"rows":[0,100],"placements":[{"slot":1,"rowOffset":4}]}"#.utf8
        ).write(to: placement)

        let result = try await runCLI(
            ["frames", "place", "--from", placement.path],
            socketPath: host.socketPath,
            homeDirectory: directory.path
        )
        #expect(result.exitCode == 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                as? [String: Any]
        )
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["operationId"] as? String == "cli-placement-operation")
        #expect(resultObject["replayed"] as? Bool == false)
        #expect(await host.stub.requestCounts["roll.manualFrames"] == 1)
        #expect(await host.stub.requestCounts["roll.setSpacingOffset"] == 1)
        #expect(await host.stub.requestCounts["project.setFrameAlignment"] == 1)

        await host.server.stop()
    }

    @Test("frames place rejects conflicting modes, invalid offsets, and malformed placement rows before opening the socket")
    func framesPlaceValidationIsClientSide() async throws {
        let host = try await CLIProcessHost.start(label: "frames-place-invalid")
        defer { removeSocketDirectory(for: host.socketPath) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-cli-placement-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let placement = directory.appendingPathComponent("placement.json")
        try Data(#"{"rows":[0,100,90]}"#.utf8).write(to: placement)
        let before = await host.stub.requestCounts

        let cases = [
            ["frames", "place", "1", "--row-offset", "-1"],
            ["frames", "place", "1", "--row-offset", "4", "--replay"],
            ["frames", "place", "--from", placement.path],
        ]
        for arguments in cases {
            let result = try await runCLI(
                arguments,
                socketPath: host.socketPath,
                homeDirectory: directory.path
            )
            #expect(result.exitCode == 64)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                    as? [String: Any]
            )
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "INVALID_RANGE")
        }
        #expect(await host.stub.requestCounts == before)

        await host.server.stop()
    }

    @Test("diagnostics export writes into the given temp directory and reports its path and entries")
    func diagnosticsExportWritesIntoTempDirectory() async throws {
        let host = try await CLIProcessHost.start(label: "diagnostics")
        defer { removeSocketDirectory(for: host.socketPath) }
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ss-cli-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = try await runCLI(["diagnostics", "export", "--to", tempDirectory.path], socketPath: host.socketPath)
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

    // MARK: Task 3 -- settings get/set, outputs get/set, roll save/open/list

    @Test("settings get exits 0 and its result carries capture and processing")
    func settingsGetReturnsCaptureAndProcessing() async throws {
        let host = try await CLIProcessHost.start(label: "settings-get")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(["settings", "get"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["capture"] is [String: Any])
        #expect(resultObject["processing"] is [String: Any])

        await host.server.stop()
    }

    @Test("settings set --resolution overwrites only resolutionDpi, proving read-modify-write not a wholesale overwrite")
    func settingsSetOverwritesOnlyResolution() async throws {
        let host = try await CLIProcessHost.start(label: "settings-set")
        defer { removeSocketDirectory(for: host.socketPath) }
        let before = await host.model.captureRecipe

        let result = try await runCLI(["settings", "set", "--resolution", "4000"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)

        let after = await host.model.captureRecipe
        let expected = CaptureRecipe(
            resolutionDpi: 4_000,
            bitDepth: before.bitDepth,
            multisamplePasses: before.multisamplePasses,
            channels: before.channels
        )
        #expect(after == expected)

        await host.server.stop()
    }

    @Test("outputs get exits 0 and its result carries outputs")
    func outputsGetReturnsOutputs() async throws {
        let host = try await CLIProcessHost.start(label: "outputs-get")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(["outputs", "get"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["outputs"] is [String: Any])

        await host.server.stop()
    }

    @Test("outputs set --preview-destination changes only that field")
    func outputsSetChangesOnlyPreviewDestination() async throws {
        let host = try await CLIProcessHost.start(label: "outputs-set")
        defer { removeSocketDirectory(for: host.socketPath) }
        let before = await host.model.outputRecipe
        let newDestination = "/tmp/cli-process-outputs-set-preview"

        let result = try await runCLI(["outputs", "set", "--preview-destination", newDestination], socketPath: host.socketPath)
        #expect(result.exitCode == 0)

        let after = await host.model.outputRecipe
        let expected = OutputRecipe(
            archive: before.archive,
            rawExport: before.rawExport,
            positive: before.positive,
            preview: PreviewRecipe(
                enabled: before.preview.enabled,
                fileFormat: before.preview.fileFormat,
                maxLongEdgePx: before.preview.maxLongEdgePx,
                filenameTemplate: before.preview.filenameTemplate,
                destination: newDestination
            ),
            autoCrop: before.autoCrop,
            c41Render: before.c41Render
        )
        #expect(after == expected)

        await host.server.stop()
    }

    @Test("roll save without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's stub recorded zero new requests")
    func rollSaveWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await CLIProcessHost.start(label: "roll-save-unconfirmed")
        defer { removeSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runCLI(
            ["roll", "save", "--name", "x", "--carrier", "roll36", "--frame-count", "36", "--film-process", "c41ColorNegative"],
            socketPath: host.socketPath
        )
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("roll save --confirm-motion against a host with no selected frames exits with the host's own typed refusal printed verbatim")
    func rollSaveConfirmedWithNoSelectedFramesReportsHostRefusal() async throws {
        let host = try await CLIProcessHost.start(label: "roll-save-no-frames")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(
            [
                "roll", "save", "--name", "x", "--carrier", "roll36", "--frame-count", "36",
                "--film-process", "c41ColorNegative", "--confirm-motion"
            ],
            socketPath: host.socketPath
        )
        #expect(result.exitCode != 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "GATE_REFUSED")
        #expect((error["message"] as? String)?.contains("Select at least one frame") == true)

        await host.server.stop()
    }

    @Test("roll list exits 0 and its result carries a projects array")
    func rollListReturnsProjectsArray() async throws {
        let host = try await CLIProcessHost.start(label: "roll-list")
        defer { removeSocketDirectory(for: host.socketPath) }

        let result = try await runCLI(["roll", "list"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["projects"] is [Any])

        await host.server.stop()
    }
}
