// D-19..D-24 (HEAD-12): failed-batch recovery from the CLI alone, driven by
// the 2026-09-07 real-hardware incident
// (~/ScanStudio-QA/full-roll-20260907-cli/notes.md). This suite proves, on a
// fake engine, that a job stays queryable after it finishes, that a batch
// abort marks untouched frames `notAttempted` rather than `failed`, that
// `lastErrorMessage` carries the bridge's own text even after a partial
// success, that excluding a frame refreshes `pendingFrames` without
// reopening the roll, that `scan.resume`'s pre-check reads the engine's
// current set rather than a stale cache, and that an `EngineClient` request
// timeout is journaled with method/id/elapsed.

import Foundation
import Testing

@testable import ScanStudioKit

private enum BatchRecoveryStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

/// Modelled on `ControlChannelProjectRoutingTests.swift`'s
/// `ProjectRoutingEngineStub`. `events` is deliberately the fixed empty
/// stream every other model-level stub in this codebase uses: every test
/// here drives state through `model.handle(event:)` directly (synchronous,
/// no stream race) rather than through the async event-consumption loop --
/// the one exception, `engineRequestTimeoutIsJournaled`, exercises a real
/// `EngineClient` instead of this stub entirely.
private actor BatchRecoveryEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "batch-recovery-stub"

    private(set) var recordedMethods: [String] = []
    private var jobSequence = 0
    private var excludedFrames: Set<Int> = []
    /// When set, `project.pendingFrames` answers this exact list instead of
    /// deriving it from `excludedFrames` -- lets a test simulate the
    /// engine's authoritative set changing out from under the model's own
    /// cache, independent of anything this stub's own
    /// `project.setFrameExcluded` handler would compute.
    private var pendingFramesOverride: [Int]?

    private let device = DeviceInfo(
        deviceId: "batch-recovery-device",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supported: true,
        supportedMultisamplePasses: [4]
    )

    private func project() -> ScanProject {
        ScanProject(
            schemaVersion: 4,
            id: "batch-recovery-project",
            name: "Batch recovery",
            carrier: .roll36,
            frameCount: 10,
            filmProcess: .c41ColorNegative,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/tmp/batch-recovery/archive"),
                positive: PositiveRecipe(
                    enabled: true, fileFormat: .tiff, colorProfile: .adobeRgb1998,
                    filenameTemplate: "Positive_####", destination: "/tmp/batch-recovery/positive"
                ),
                preview: PreviewRecipe(
                    enabled: true, fileFormat: .jpeg, maxLongEdgePx: 1_024,
                    filenameTemplate: "Preview_####", destination: "/tmp/batch-recovery/preview"
                )
            ),
            rollMetadata: MetadataSet(),
            createdAt: "2026-09-07T00:00:00Z",
            frames: (1...10).map { ProjectFrame(index: $0, excluded: excludedFrames.contains($0), receipts: []) }
        )
    }

    /// Simulates the engine's own authoritative pending set changing
    /// independently of anything this stub's `project.setFrameExcluded`
    /// handler computed -- `scanResumePreCheckRefreshesPendingFramesBeforeReadiness`'s
    /// own scenario.
    func setPendingFramesOverride(_ frames: [Int]?) {
        pendingFramesOverride = frames
    }

    /// Clears the request log without touching `excludedFrames`/
    /// `pendingFramesOverride` -- called once setup's own incidental
    /// discovery/connect/open/preview calls have resolved, so they never
    /// pollute a "recorded exactly this method" assertion.
    func clearLogForTesting() {
        recordedMethods.removeAll()
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params
    ) async throws -> Result {
        recordedMethods.append(method)
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [device]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: device,
                status: ScannerStatus(
                    connected: true, adapter: "SA-30", mediaLoaded: true, carrier: "roll36",
                    frameCount: 10, lamp: "stable", transport: "idle", activeJobId: nil,
                    filmPresent: true, motionArmed: true
                )
            ), as: Result.self)
        case "project.open":
            return try cast(ProjectOpenResult(project: project(), directory: "/tmp/batch-recovery"), as: Result.self)
        case "scanner.acquireThumbnails":
            return try cast(AcquireThumbnailsAck(accepted: true, frames: Array(1...10)), as: Result.self)
        case "scan.start", "scan.resume":
            jobSequence += 1
            return try cast(ScanStartResult(jobId: "batch-recovery-job-\(jobSequence)"), as: Result.self)
        case "project.setFrameExcluded":
            if let excludedParams = params as? SetFrameExcludedParams {
                if excludedParams.excluded {
                    excludedFrames.insert(excludedParams.frameIndex)
                } else {
                    excludedFrames.remove(excludedParams.frameIndex)
                }
            }
            return try cast(SetFrameResult(project: project()), as: Result.self)
        case "project.pendingFrames":
            let frames = pendingFramesOverride ?? (1...10).filter { !excludedFrames.contains($0) }
            return try cast(
                PendingFramesResult(
                    frames: frames, totalFrames: 10, completedCount: 0, excludedCount: excludedFrames.count
                ),
                as: Result.self
            )
        default:
            throw BatchRecoveryStubError.unexpectedMethod(method)
        }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw BatchRecoveryStubError.unexpectedResultType }
        return result
    }
}

@Suite("Batch recovery (D-19..D-24)")
struct BatchRecoveryTests {
    @MainActor
    private func preparedModel(
        client: BatchRecoveryEngineStub = BatchRecoveryEngineStub()
    ) async -> (SessionModel, BatchRecoveryEngineStub) {
        let model = SessionModel(engineClient: client)
        for _ in 0..<30 where model.isDiscoveringDevices {
            await Task.yield()
        }
        await model.connect(deviceId: "batch-recovery-device")
        await model.openProject(directory: "/tmp/batch-recovery")

        let token = PreviewIntentToken()
        _ = await model.requestPreview(.refreshSavedProject(token: token))
        for frameIndex in 1...10 {
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/batch-recovery-preview-\#(frameIndex).tif"}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":10}}"#.utf8
            )
        ))
        model.selectAllFrames()
        return (model, client)
    }

    @MainActor
    private func emitFrameState(
        _ model: SessionModel,
        frameIndex: Int,
        state: String,
        code: String? = nil,
        message: String? = nil,
        jobId: String
    ) {
        let errorJSON = code.map { #","error":{"code":"\#($0)","message":"\#(message ?? "")","recoverable":false}"# } ?? ""
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"\#(jobId)","frameIndex":\#(frameIndex),"state":"\#(state)","attempt":1\#(errorJSON)}}"#.utf8
            )
        ))
    }

    @MainActor
    private func emitCompletion(
        _ model: SessionModel,
        completed: [Int],
        failed: [Int],
        notAttempted: [Int] = [],
        stopped: Bool = false,
        jobId: String
    ) {
        func jsonArray(_ values: [Int]) -> String { values.map(String.init).joined(separator: ",") }
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"\#(jobId)","summary":{"completed":[\#(jsonArray(completed))],"failed":[\#(jsonArray(failed))],"skipped":[],"notAttempted":[\#(jsonArray(notAttempted))],"stopped":\#(stopped)}}}"#.utf8
            )
        ))
    }

    /// Drives one full batch-abort sequence matching the 2026-09-07
    /// evidence shape: frames 1-3 complete, frame 4 raises a typed bridge
    /// failure, frames 5-10 are never reached.
    @MainActor
    @discardableResult
    private func driveOneBatchAbort(_ model: SessionModel, jobId: String) async -> String {
        await model.startMockScan()
        for frame in 1...3 {
            emitFrameState(model, frameIndex: frame, state: "completed", jobId: jobId)
        }
        emitFrameState(
            model, frameIndex: 4, state: "failed",
            code: "ROLL_MISMATCH",
            message: "meter pass 2 controller refused: low_correlation",
            jobId: jobId
        )
        for frame in 5...10 {
            emitFrameState(model, frameIndex: frame, state: "notAttempted", jobId: jobId)
        }
        // The real engine emits scan.jobState{failed} before scan.completed
        // (`emit_terminal_job_failure`) -- ScanCompletionPolicy.resolveJobState
        // only derives .completed/.stopped from the summary itself, so this
        // event is what actually makes the job Failed rather than Completed.
        // `queued -> failed` is not a legal transition
        // (SessionEventPolicy.allowsJobTransition), so `scanning` comes
        // first, exactly like a real job.
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(#"{"event":"scan.jobState","payload":{"jobId":"\#(jobId)","state":"scanning"}}"#.utf8)
        ))
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(#"{"event":"scan.jobState","payload":{"jobId":"\#(jobId)","state":"failed"}}"#.utf8)
        ))
        emitCompletion(model, completed: [1, 2, 3], failed: [4], notAttempted: [5, 6, 7, 8, 9, 10], jobId: jobId)
        return jobId
    }

    @MainActor
    @discardableResult
    private func greet(_ dispatcher: ControlChannelDispatcher) async -> ControlResponse {
        await dispatcher.handle(.hello(
            id: 0,
            params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "batch-recovery-tests")
        ))
    }

    // MARK: - D-19: terminal jobs stay queryable

    @Test("a job that finished seconds ago still answers job.get {jobId}")
    @MainActor
    func terminalJobStaysQueryableAfterItFinishes() async {
        let (model, stub) = await preparedModel()
        await driveOneBatchAbort(model, jobId: "batch-recovery-job-1")
        #expect(model.jobId == nil, "applyCompleted must clear jobId once the job is archived")

        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        _ = await dispatcher.handle(.hello(
            id: 0, params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "batch-recovery-tests")
        ))
        await stub.clearLogForTesting()

        let response = await dispatcher.handle(.jobGet(id: 1, params: ControlJobGetParams(jobId: "batch-recovery-job-1")))
        guard case .success(_, let result) = response, case .job(let job) = result else {
            Issue.record("expected a job success result, got \(response)")
            return
        }
        #expect(job.jobId == "batch-recovery-job-1")
        #expect(job.jobState == .failed)
        #expect(job.finishedAt != nil, "a terminal job must carry a finishedAt timestamp")
        #expect(job.notAttemptedFrames.sorted() == [5, 6, 7, 8, 9, 10])
        #expect(job.frameErrorCodes["4"] == "ROLL_MISMATCH")
        #expect(job.frameErrorMessages["4"] == "meter pass 2 controller refused: low_correlation")
        #expect(await stub.recordedMethods.isEmpty, "job.get for an archived job must never reach the engine")
    }

    @Test("job.get refuses an id this process never tracked")
    @MainActor
    func jobGetRefusesAnIdThisProcessNeverTracked() async {
        let (model, _) = await preparedModel()
        await driveOneBatchAbort(model, jobId: "batch-recovery-job-1")

        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)
        let response = await dispatcher.handle(.jobGet(id: 2, params: ControlJobGetParams(jobId: "no-such-job")))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected JOB_NOT_FOUND, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "JOB_NOT_FOUND")
    }

    @Test("terminal job history is bounded to the last 8 jobs")
    @MainActor
    func terminalJobHistoryIsBoundedToEightJobs() async {
        let (model, _) = await preparedModel()
        for index in 1...9 {
            let jobId = "batch-recovery-job-\(index)"
            await model.startMockScan()
            emitCompletion(model, completed: [1], failed: [], notAttempted: [], jobId: jobId)
        }

        #expect(model.trackedJobIds.count == 8)
        #expect(!model.trackedJobIds.contains("batch-recovery-job-1"), "the oldest job must be evicted at the 9th")
        #expect(model.trackedJobIds.contains("batch-recovery-job-9"))

        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)
        let response = await dispatcher.handle(.jobGet(id: 3, params: ControlJobGetParams(jobId: "batch-recovery-job-1")))
        guard case .failure(_, let error) = response else {
            Issue.record("expected the evicted job to be JOB_NOT_FOUND, got \(response)")
            return
        }
        #expect(error.code == "JOB_NOT_FOUND")
    }

    // MARK: - D-20: notAttempted vs failed, and lastErrorMessage

    @Test("notAttempted frames are never counted as scanned, in either direction")
    @MainActor
    func notAttemptedFramesAreNeverCountedAsScanned() async {
        let (model, _) = await preparedModel()
        await driveOneBatchAbort(model, jobId: "batch-recovery-job-1")

        for frame in 5...10 {
            #expect(model.frameStates[frame] == .notAttempted, "frame \(frame) must be notAttempted")
            #expect(model.frameErrors[frame] == nil, "a notAttempted frame must carry no error")
        }
        #expect(model.frameStates[4] == .failed)
        #expect(model.frameErrors[4]?.code == "ROLL_MISMATCH")
        // A notAttempted frame is still pending -- the existing
        // `!excluded && !completed` pendingFrames recomputation already
        // gives this for free; asserted here rather than re-derived.
        #expect(Set(5...10).isSubset(of: Set(model.pendingFrames)))
        #expect(model.completedFrameCount == 3)
    }

    @Test("lastErrorMessage carries the bridge's own text even when some frames completed")
    @MainActor
    func lastErrorMessageCarriesTheBridgeTextWhenSomeFramesCompleted() async {
        let (model, _) = await preparedModel()
        await driveOneBatchAbort(model, jobId: "batch-recovery-job-1")

        // The 2026-09-07 case: 9 (here, 3) frames completed and
        // lastErrorMessage stayed null on the unfixed code.
        #expect(model.lastErrorMessage == "ROLL_MISMATCH: meter pass 2 controller refused: low_correlation")
    }

    // MARK: - D-23: frames.select in project mode (CF-12)

    @Test("frames.select with an excluded index and a project open is refused INVALID_PARAMS naming that index")
    @MainActor
    func framesSelectExcludedIndexInProjectModeIsRefused() async {
        let (model, stub) = await preparedModel()
        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)
        _ = await dispatcher.handle(.framesExclude(id: 1, params: ControlFrameSelectionParams(frameIndex: 4)))
        #expect(model.excludedFrameIndices.contains(4))
        await stub.clearLogForTesting()

        let response = await dispatcher.handle(.framesSelect(id: 2, params: ControlFramesSelectParams(indices: [3, 4, 5])))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected INVALID_PARAMS naming the excluded index, got \(response)")
            return
        }
        #expect(id == 2)
        #expect(error.code == "INVALID_PARAMS")
        #expect(error.message.contains("4"))
        #expect(
            model.selectedFrames == Array(1...10),
            "a refused selection must never partially apply -- the prior (preparedModel's own selectAllFrames) selection must be untouched"
        )
        #expect(await stub.recordedMethods.isEmpty, "frames.select never reaches the engine")
    }

    @Test("a valid project-mode frames.select selection is applied")
    @MainActor
    func framesSelectValidIndicesInProjectModeAreApplied() async {
        let (model, stub) = await preparedModel()
        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)
        _ = await dispatcher.handle(.framesExclude(id: 1, params: ControlFrameSelectionParams(frameIndex: 4)))
        await stub.clearLogForTesting()

        let response = await dispatcher.handle(.framesSelect(id: 2, params: ControlFramesSelectParams(indices: [1, 2, 3])))
        guard case .success = response else {
            Issue.record("expected frames.select to succeed for non-excluded indices, got \(response)")
            return
        }
        #expect(model.selectedFrames == [1, 2, 3])
    }

    // MARK: - D-22: pendingFrames refresh

    @Test("excluding a frame refreshes pendingFrames without reopening the roll")
    @MainActor
    func excludingAFrameRefreshesPendingFramesWithoutReopeningTheRoll() async {
        let (model, stub) = await preparedModel()
        #expect(await model.refreshPendingFrames())
        #expect(model.pendingFrames.contains(4))

        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)
        await stub.clearLogForTesting()

        let response = await dispatcher.handle(.framesExclude(id: 4, params: ControlFrameSelectionParams(frameIndex: 4)))
        guard case .success = response else {
            Issue.record("expected frames.exclude to succeed, got \(response)")
            return
        }

        #expect(!model.pendingFrames.contains(4), "excluding frame 4 must be visible in pendingFrames immediately")
        let methods = await stub.recordedMethods
        #expect(methods == ["project.setFrameExcluded", "project.pendingFrames"])
        #expect(!methods.contains("project.open"), "recovery must never require reopening the roll")
    }

    @Test("scan.resume's pre-check refreshes pendingFrames before evaluating readiness, not a stale cache")
    @MainActor
    func scanResumePreCheckRefreshesPendingFramesBeforeReadiness() async {
        let (model, stub) = await preparedModel()
        #expect(await model.refreshPendingFrames())
        #expect(model.pendingFrames.sorted() == Array(1...10))

        // Simulate the engine's own authoritative set changing out from
        // under the model's cache -- e.g. every remaining frame was
        // excluded through a different client between this session's last
        // refresh and now. An empty fresh set makes the two possible
        // readings observably different: the stale [1...10] cache would
        // read as ready and let `resumeBatch()` start a job; the fresh []
        // must refuse `targetRequired` before any motion-capable call.
        await stub.setPendingFramesOverride([])

        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        await greet(dispatcher)
        await stub.clearLogForTesting()
        let response = await dispatcher.handle(.scanResume(id: 5, params: ControlScanResumeParams(motionConfirmed: true)))

        guard case .failure(let id, let error) = response else {
            Issue.record("expected GATE_REFUSED against the freshly-refreshed empty set, got \(response)")
            return
        }
        #expect(id == 5)
        #expect(error.code == "GATE_REFUSED")
        #expect(error.guidance == ScanReadinessPolicy.Decision.targetRequired.reason)
        #expect(
            model.pendingFrames.isEmpty,
            "the pre-check must have refreshed from the engine's current set, not the stale cache that still had 1-10"
        )
        #expect(
            await stub.recordedMethods == ["project.pendingFrames"],
            "a correctly-refused resume must never reach a motion-capable engine call"
        )
    }

    // MARK: - D-24: journaled engine request timeouts

    @Test("an EngineClient request timeout is journaled with method, id, and elapsed seconds")
    @MainActor
    func engineRequestTimeoutIsJournaled() async throws {
        let fixture = try SilentBatchRecoveryEngineFixture()
        defer { fixture.remove() }
        let diagnosticsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScanStudio-BatchRecoveryTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: diagnosticsDirectory) }

        // A silent fixture that reads and discards every line (never
        // echoes it back) -- unlike `/bin/cat`, this cannot race
        // `EngineClient`'s own read loop into a feedback cycle; every
        // request can only resolve via the timeout this test exists to
        // journal (`EngineClientDeadlineTests.swift`'s own precedent).
        let client = try EngineClient(
            engineURL: fixture.executableURL,
            configuration: EngineClientConfiguration(
                requestTimeout: .milliseconds(100),
                gracefulShutdownTimeout: .milliseconds(50),
                terminateTimeout: .milliseconds(50),
                forceKillTimeout: .milliseconds(500)
            )
        )
        // Retained for the test's whole duration: `SessionModel.deinit`
        // cancels the very `eventTask` that would otherwise consume this
        // synthetic event and record it.
        let model = SessionModel(engineClient: client, diagnosticsDirectory: diagnosticsDirectory)

        // A direct, deterministic trigger rather than relying on `init`'s
        // own uncontrolled background discovery task -- connect() reaches
        // ensureHandshake() first (engine.hello), which the silent fixture
        // can only ever answer via timeout.
        await model.connect(deviceId: "batch-recovery-device")

        var foundEntry: String?
        for _ in 0..<200 {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: diagnosticsDirectory.path) {
                for file in files where file.hasSuffix(".jsonl") {
                    let contents = (try? String(
                        contentsOf: diagnosticsDirectory.appendingPathComponent(file), encoding: .utf8
                    )) ?? ""
                    if let line = contents.split(separator: "\n").first(where: {
                        $0.contains(#""event":"engine.request.timeout""#)
                    }) {
                        foundEntry = String(line)
                        break
                    }
                }
            }
            if foundEntry != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let entry = try #require(foundEntry, "expected an engine.request.timeout diagnostic entry on disk")
        #expect(entry.contains(#""method":"#))
        #expect(entry.contains(#""elapsedSeconds":"#))
        #expect(entry.contains(#""id":"#))

        _ = model
        await client.terminate()
    }
}

/// A hardware-free executable that reads (and silently discards) every
/// NDJSON request, ignores SIGTERM, and remains alive after stdin closes --
/// mirrors `EngineClientDeadlineTests.swift`'s own `SilentEngineFixture`
/// (private to that file; duplicated here per this codebase's established
/// per-suite-fixture convention rather than shared across files).
private struct SilentBatchRecoveryEngineFixture {
    let directoryURL: URL
    let executableURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScanStudio-BatchRecoveryTests-silent-engine-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("silent-engine")
        let script = """
        #!/bin/sh
        trap '' TERM
        while IFS= read -r ignored; do
            :
        done
        exec /usr/bin/tail -f /dev/null
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        directoryURL = directory
        executableURL = executable
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
