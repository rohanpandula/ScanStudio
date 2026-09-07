// Per-command SAFE-01 confirmation-gate proofs plus the `--wait`/stop/
// resume/recoverable-passthrough and SAFE-04 refusal-observability proofs
// (plan 02-06). Execs the real built `scanstudio-cli` binary as a genuine
// subprocess against an in-process host -- mirrors
// `ScanstudioCLIProcessTests.swift`'s harness idioms (binary locator,
// in-process host, async `runCLI`) one file over, since those helpers are
// file-private there and this plan's own `files_modified` does not touch
// that file.
//
// Every test here passes `--socket` explicitly (a short `/tmp` test path)
// and never touches `~/.scanstudio/`. No scanner motion, no GUI, no real
// engine binary -- every test drives a fake `EngineClientProtocol` actor.

import Foundation
import Testing

@testable import ScanStudioKit

private enum ConfirmationStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint --
/// `kind: "simulated"` keeps `hardwareMotionReadiness` at `.notApplicable`
/// (`allowsMotion == true`) even before any device is connected.
private let confirmationDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

private let confirmationProjectDirectory = "/tmp/confirmation-test-project"

/// A minimal one-frame project fixture whose frame has no draft alignment
/// or rotation, so `startMockScan()`'s `persistFrameGeometryBeforeScan`
/// step is a no-op and never issues an unscripted
/// `project.setFrameAlignment` request (mirrors
/// `ControlChannelMotionRoutingTests.swift`'s identical `motionRoutingProject`
/// fixture and its own documented rationale).
private func confirmationProject(frameIndex: Int = 1) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "confirmation-project",
        name: "Confirmation test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/confirmation-test/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/confirmation-test/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/confirmation-test/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-09-07T00:00:00Z",
        frames: [ProjectFrame(index: frameIndex, excluded: false, receipts: [])]
    )
}

/// Fake engine covering every wire method a test in this file drives,
/// modelled on `ControlChannelMotionRoutingTests.swift`'s
/// `MotionRoutingEngineStub` (scan.start/scan.stop) and
/// `ControlRecoverablePassthroughTests.swift`'s `RecoverablePassthroughEngineStub`
/// (`failNext`, for the SAFE-02 recoverable-error proof). Built as one
/// cohesive type covering all three tasks' needs up front, mirroring
/// `ControlChannelClient.swift`'s own precedent for a single-commit type
/// whose tests land incrementally.
private actor ConfirmationEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "confirmation-stub"

    /// The fixed job id every scripted `scan.start` answers with -- known
    /// ahead of time so a test can construct matching synthetic
    /// `scan.jobState`/`scan.frameState` events.
    static let jobId = "confirmation-scan-job"

    private(set) var requestCounts: [String: Int] = [:]
    private(set) var recordedScanStopModes: [String] = []
    private var scriptedFailures: [String: EngineRequestError] = [:]

    /// Scripts the next call to `method` to throw `error` instead of
    /// answering normally -- removed from the schedule once consumed, so a
    /// second call to the same method answers the fixed happy path.
    func failNext(_ method: String, with error: EngineRequestError) {
        scriptedFailures[method] = error
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params
    ) async throws -> Result {
        requestCounts[method, default: 0] += 1
        if let failure = scriptedFailures.removeValue(forKey: method) {
            throw failure
        }
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [confirmationDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: confirmationDevice,
                status: ScannerStatus(
                    connected: true, adapter: "SA-21", mediaLoaded: false, carrier: nil,
                    frameCount: nil, lamp: "unknown", transport: "idle", activeJobId: nil,
                    filmPresent: nil, motionArmed: true
                )
            ), as: Result.self)
        case "scanner.disconnect", "scanner.eject":
            return try cast(EmptyResult(), as: Result.self)
        case "scanner.acquireThumbnails":
            return try cast(AcquireThumbnailsAck(accepted: true, frames: []), as: Result.self)
        case "project.open":
            let directory = (params as? ProjectOpenParams)?.directory ?? confirmationProjectDirectory
            return try cast(
                ProjectOpenResult(project: confirmationProject(), directory: directory),
                as: Result.self
            )
        case "scan.start":
            return try cast(ScanStartResult(jobId: Self.jobId), as: Result.self)
        case "scan.stop":
            let mode = (params as? ScanStopParams)?.mode ?? "afterCurrentFrame"
            recordedScanStopModes.append(mode)
            return try cast(ScanStopResult(acknowledged: true, mode: mode), as: Result.self)
        default:
            throw ConfirmationStubError.unexpectedMethod(method)
        }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw ConfirmationStubError.unexpectedResultType }
        return result
    }
}

/// Bounded `Task.yield()` polling for `SessionModel.init`'s fire-and-forget
/// discovery call, per this codebase's established idiom (never a fixed
/// sleep).
@MainActor
private func makeConfirmationIdleModel(_ stub: ConfirmationEngineStub) async -> SessionModel {
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
private func confirmationSocketPath(_ label: String) -> String {
    let directory = "/tmp/ss-cli-confirm-\(label)-\(UInt32.random(in: 0..<UInt32.max))"
    let path = directory + "/s.sock"
    precondition(path.utf8.count < 104, "test socket path must be < 104 bytes, got \(path.utf8.count): \(path)")
    return path
}

private func removeConfirmationSocketDirectory(for path: String) {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: directory)
}

/// An in-process host: a real `ControlChannelServer` bound to a short
/// `/tmp` path, feeding one shared `SessionModel` backed by a fake
/// `EngineClientProtocol`. Every test execs the real built `scanstudio-cli`
/// binary against this host as a genuine subprocess.
@MainActor
private struct ConfirmationHost {
    let model: SessionModel
    let stub: ConfirmationEngineStub
    let server: ControlChannelServer
    let socketPath: String

    static func start(label: String) async throws -> ConfirmationHost {
        let stub = ConfirmationEngineStub()
        let model = await makeConfirmationIdleModel(stub)
        let server = ControlChannelServer(sessionModel: model)
        let path = confirmationSocketPath(label)
        try await server.start(path: path)
        return ConfirmationHost(model: model, stub: stub, server: server, socketPath: path)
    }
}

private enum ConfirmationCLILocator {
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
            .deletingLastPathComponent() // ScanstudioCLIConfirmationTests.swift -> ScanStudioKitTests/
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

private struct ConfirmationCLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs the real built binary with `arguments` plus `--socket socketPath`,
/// returning its exit status, stdout, and stderr. The blocking `Process`
/// spawn/read/wait sequence runs on a dedicated background queue via a
/// continuation -- never inline on Swift's cooperative thread pool. This is
/// the identical fix `ScanstudioCLIProcessTests.swift`'s `runCLI` needed
/// (02-05-SUMMARY.md deviation #2): blocking I/O called directly inside an
/// `async` test function occupies a cooperative-pool thread for the whole
/// blocking duration, and with several tests' hosts all needing
/// actor/`@MainActor` hops concurrently, the pool is exhausted and every
/// connection -- including the one this very call is waiting on -- stops
/// making progress.
private func runConfirmationCLI(_ arguments: [String], socketPath: String) async throws -> ConfirmationCLIResult {
    let binary = try ConfirmationCLILocator.resolve()
    let allArguments = arguments + ["--socket", socketPath]
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ConfirmationCLIResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let process = Process()
                process.executableURL = binary
                process.arguments = allArguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: ConfirmationCLIResult(
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

@Suite("scanstudio-cli confirmation", .timeLimit(.minutes(1)))
struct ScanstudioCLIConfirmationTests {
    // MARK: Task 1 -- preview / review approve / eject confirmation gates (SAFE-01)

    @Test("preview without --film-loaded exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func previewWithoutFilmLoadedExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "preview-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["preview"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("review approve without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func reviewApproveWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "review-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["review", "approve"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("eject without --confirm-motion exits 77 with CONFIRMATION_REQUIRED, and the host's fake engine recorded zero new requests")
    func ejectWithoutConfirmMotionExitsConfirmationRequired() async throws {
        let host = try await ConfirmationHost.start(label: "eject-unconfirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }
        let before = await host.stub.requestCounts

        let result = try await runConfirmationCLI(["eject"], socketPath: host.socketPath)
        #expect(result.exitCode == 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "CONFIRMATION_REQUIRED")

        let after = await host.stub.requestCounts
        #expect(before == after)

        await host.server.stop()
    }

    @Test("preview --film-loaded against a live host exits 0 and the result carries an outcome, proving the request reached the host")
    func previewWithFilmLoadedReachesHost() async throws {
        let host = try await ConfirmationHost.start(label: "preview-confirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["preview", "--film-loaded"], socketPath: host.socketPath)
        #expect(result.exitCode == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])
        #expect(resultObject["outcome"] is String)

        await host.server.stop()
    }

    @Test("review approve --confirm-motion against a live host with nothing pending reports the host's own GATE_REFUSED, not CONFIRMATION_REQUIRED -- proving the request reached the host")
    func reviewApproveWithConfirmMotionReachesHost() async throws {
        let host = try await ConfirmationHost.start(label: "review-confirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["review", "approve", "--confirm-motion"], socketPath: host.socketPath)
        #expect(result.exitCode != 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "GATE_REFUSED")

        await host.server.stop()
    }

    @Test("eject --confirm-motion against a live but disconnected host reports the host's own GATE_REFUSED, not CONFIRMATION_REQUIRED -- proving the request reached the host")
    func ejectWithConfirmMotionReachesHost() async throws {
        let host = try await ConfirmationHost.start(label: "eject-confirmed")
        defer { removeConfirmationSocketDirectory(for: host.socketPath) }

        let result = try await runConfirmationCLI(["eject", "--confirm-motion"], socketPath: host.socketPath)
        #expect(result.exitCode != 77)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "GATE_REFUSED")

        await host.server.stop()
    }

    @Test("eject --confirm-motion against a socket path with no listener exits 69 (HOST_UNREACHABLE), proving the 77 path above is not simply a connection failure")
    func ejectAgainstMissingListenerExitsHostUnreachable() async throws {
        let result = try await runConfirmationCLI(["eject", "--confirm-motion"], socketPath: confirmationSocketPath("eject-no-listener"))
        #expect(result.exitCode == 69)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "HOST_UNREACHABLE")
    }
}
