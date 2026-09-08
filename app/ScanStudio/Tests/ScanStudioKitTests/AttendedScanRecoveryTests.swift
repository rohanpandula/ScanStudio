import Foundation
import Testing

@testable import ScanStudioKit

private enum AttendedRecoveryStubError: Error {
    case unexpectedMethod(String)
    case unexpectedParams(String)
    case unexpectedResultType
}

private enum AttendedRecoveryCall: Equatable, Sendable {
    case approve(frameIndex: Int, attended: Bool)
    case scanStart(frames: [Int])
}

private actor AttendedRecoveryEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "attended-recovery-stub"

    private let holdFirstApproval: Bool
    private var didHoldApproval = false
    private var approvalContinuation: CheckedContinuation<Void, Never>?
    private var approvalWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedCalls: [AttendedRecoveryCall] = []
    private var scanStartCount = 0

    private let device = DeviceInfo(
        deviceId: "real-attended-recovery",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supported: true,
        supportedMultisamplePasses: [4]
    )

    private let project = ScanProject(
        schemaVersion: 4,
        id: "attended-recovery-project",
        name: "Attended recovery",
        carrier: .strip6,
        frameCount: 2,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/attended-recovery/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/attended-recovery/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/attended-recovery/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-08-23T00:00:00Z",
        frames: (1...2).map {
            ProjectFrame(index: $0, excluded: false, receipts: [])
        }
    )

    init(holdFirstApproval: Bool = false) {
        self.holdFirstApproval = holdFirstApproval
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        let value: any Sendable
        switch method {
        case "scanner.list":
            value = ScannerListResult(devices: [device])
        case "scanner.connect":
            value = ConnectResult(
                device: device,
                status: ScannerStatus(
                    connected: true,
                    adapter: "SA-21",
                    mediaLoaded: true,
                    carrier: "strip6",
                    frameCount: 2,
                    lamp: "stable",
                    transport: "idle",
                    activeJobId: nil,
                    filmPresent: true,
                    motionArmed: true
                )
            )
        case "project.open":
            value = ProjectOpenResult(
                project: project,
                directory: "/tmp/attended-recovery"
            )
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: [1, 2])
        case "roll.approve":
            guard let params = params as? RollApproveParams else {
                throw AttendedRecoveryStubError.unexpectedParams(method)
            }
            recordedCalls.append(.approve(
                frameIndex: params.frameIndex,
                attended: params.attended == true
            ))
            if approvalWaiters.isEmpty == false {
                let waiters = approvalWaiters
                approvalWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            if holdFirstApproval, !didHoldApproval {
                didHoldApproval = true
                await withCheckedContinuation { continuation in
                    approvalContinuation = continuation
                }
            }
            value = EmptyResult()
        case "scan.start":
            guard let params = params as? ScanStartParams else {
                throw AttendedRecoveryStubError.unexpectedParams(method)
            }
            scanStartCount += 1
            recordedCalls.append(.scanStart(frames: params.frames))
            value = ScanStartResult(jobId: "attended-job-\(scanStartCount)")
        default:
            throw AttendedRecoveryStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw AttendedRecoveryStubError.unexpectedResultType
        }
        return result
    }

    func calls() -> [AttendedRecoveryCall] { recordedCalls }

    func waitForApproval() async {
        if recordedCalls.contains(where: {
            if case .approve = $0 { true } else { false }
        }) {
            return
        }
        await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }

    func resumeApproval() {
        approvalContinuation?.resume()
        approvalContinuation = nil
    }
}

@Suite("Typed attended scan recovery")
struct AttendedScanRecoveryTests {
    @MainActor
    private func preparedModel(
        client: AttendedRecoveryEngineStub = AttendedRecoveryEngineStub()
    ) async -> (SessionModel, AttendedRecoveryEngineStub) {
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-attended-recovery")
        await model.openProject(directory: "/tmp/attended-recovery")

        let token = PreviewIntentToken()
        _ = await model.requestPreview(.refreshSavedProject(token: token))
        for frameIndex in 1...2 {
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/attended-preview-\#(frameIndex).tif"}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":2}}"#.utf8
            )
        ))
        model.selectAllFrames()
        return (model, client)
    }

    @MainActor
    private func emitFailure(
        _ model: SessionModel,
        frameIndex: Int,
        code: String,
        message: String,
        jobId: String = "attended-job-1"
    ) {
        model.handle(event: EngineEvent(
            name: "scan.frameState",
            rawLine: Data(
                #"{"event":"scan.frameState","payload":{"jobId":"\#(jobId)","frameIndex":\#(frameIndex),"state":"failed","attempt":1,"error":{"code":"\#(code)","message":"\#(message)","recoverable":false}}}"#.utf8
            )
        ))
    }

    @MainActor
    private func emitCompletion(
        _ model: SessionModel,
        completed: [Int],
        failed: [Int],
        stopped: Bool = false,
        jobId: String = "attended-job-1"
    ) {
        let completedJSON = completed.map(String.init).joined(separator: ",")
        let failedJSON = failed.map(String.init).joined(separator: ",")
        model.handle(event: EngineEvent(
            name: "scan.completed",
            rawLine: Data(
                #"{"event":"scan.completed","payload":{"jobId":"\#(jobId)","summary":{"completed":[\#(completedJSON)],"failed":[\#(failedJSON)],"skipped":[],"stopped":\#(stopped)}}}"#.utf8
            )
        ))
    }

    @Test("accepted scan to typed all-frame refusal surfaces a prominent error and retries the original ordered batch once")
    @MainActor
    func typedZeroCompletedRecoveryUsesSnapshot() async {
        let (model, client) = await preparedModel()

        await model.startMockScan()
        emitFailure(
            model,
            frameIndex: 1,
            code: ScanFailureCode.attendedBindingRequired,
            message: "driver wording version A"
        )
        emitFailure(
            model,
            frameIndex: 2,
            code: ScanFailureCode.attendedBindingRequired,
            message: "completely different human wording"
        )
        emitCompletion(model, completed: [], failed: [1, 2])

        #expect(model.lastErrorMessage != nil)
        #expect(model.errorPresentation?.title == "This roll needs you to confirm the frames")
        #expect(model.canApproveEveryFrameAndScan)

        // The failed run's immutable frame order, not mutable live selection,
        // is the retry authority.
        model.clearFrameSelection()
        model.selectFrame(2, extendingSelectionIfShiftHeld: false)

        #expect(await model.approveEveryFrameAndScan())
        #expect(await client.calls() == [
            .scanStart(frames: [1, 2]),
            .approve(frameIndex: 1, attended: true),
            .approve(frameIndex: 2, attended: true),
            .scanStart(frames: [1, 2]),
        ])
        #expect(model.jobId == "attended-job-2")
        #expect(!model.canApproveEveryFrameAndScan)

        #expect(await model.approveEveryFrameAndScan() == false)
        #expect(await client.calls().count == 4)

        // The explicit attended retry cannot mint another attended retry
        // from this same preview if it reaches the same terminal refusal.
        for frameIndex in 1...2 {
            emitFailure(
                model,
                frameIndex: frameIndex,
                code: ScanFailureCode.attendedBindingRequired,
                message: "retry also refused",
                jobId: "attended-job-2"
            )
        }
        emitCompletion(
            model,
            completed: [],
            failed: [1, 2],
            jobId: "attended-job-2"
        )
        #expect(!model.canApproveEveryFrameAndScan)
        #expect(await model.approveEveryFrameAndScan() == false)
        await model.startMockScan()
        #expect(model.lastErrorMessage?.hasPrefix("ATTENDED_RETRY_CONSUMED:") == true)
        #expect(await client.calls().count == 4)
    }

    @Test("mixed or generic zero-completed failures stay prominent but never offer attended recovery")
    @MainActor
    func mixedFailureIsVisibleButIneligible() async {
        let (model, _) = await preparedModel()

        await model.startMockScan()
        emitFailure(
            model,
            frameIndex: 1,
            code: ScanFailureCode.attendedBindingRequired,
            message: "eligible typed refusal"
        )
        emitFailure(
            model,
            frameIndex: 2,
            code: "MANUAL_REVIEW_REQUIRED",
            message: "generic manual review"
        )
        emitCompletion(model, completed: [], failed: [1, 2])

        #expect(model.lastErrorMessage != nil)
        #expect(!model.canApproveEveryFrameAndScan)
        #expect(await model.approveEveryFrameAndScan() == false)
    }

    @Test("partial success remains partial success and never enters zero-completed retry policy")
    @MainActor
    func partialSuccessNeverOffersAttendedRecovery() async {
        let (model, _) = await preparedModel()

        await model.startMockScan()
        emitFailure(
            model,
            frameIndex: 2,
            code: ScanFailureCode.attendedBindingRequired,
            message: "typed but only one frame failed"
        )
        emitCompletion(model, completed: [1], failed: [2])

        // D-20/HEAD-12 (the 2026-09-07 batch abort): a partial success must
        // still surface the bridge's own text -- this is the exact bug
        // (9 frames completed, lastErrorMessage stayed null) D-20 exists to
        // fix. It must never, however, be treated as the zero-completed
        // attended-recovery case (the very next assertion).
        #expect(model.lastErrorMessage == "ATTENDED_BINDING_REQUIRED: typed but only one frame failed")
        #expect(!model.canApproveEveryFrameAndScan)
    }

    @Test("a replacement preview retires the failed-run authorization before any approval")
    @MainActor
    func stalePreviewCannotRetry() async {
        let (model, client) = await preparedModel()

        await model.startMockScan()
        for frameIndex in 1...2 {
            emitFailure(
                model,
                frameIndex: frameIndex,
                code: ScanFailureCode.attendedBindingRequired,
                message: "typed refusal"
            )
        }
        emitCompletion(model, completed: [], failed: [1, 2])
        #expect(model.canApproveEveryFrameAndScan)

        _ = await model.requestPreview(
            .refreshSavedProject(token: PreviewIntentToken())
        )

        #expect(!model.canApproveEveryFrameAndScan)
        #expect(await model.approveEveryFrameAndScan() == false)
        #expect(await client.calls() == [.scanStart(frames: [1, 2])])
    }

    @Test("reopening a project retires the failed run even when frame indices are unchanged")
    @MainActor
    func projectLifecycleChangeCannotRetry() async {
        let (model, client) = await preparedModel()

        await model.startMockScan()
        for frameIndex in 1...2 {
            emitFailure(
                model,
                frameIndex: frameIndex,
                code: ScanFailureCode.attendedBindingRequired,
                message: "typed refusal"
            )
        }
        emitCompletion(model, completed: [], failed: [1, 2])
        #expect(model.canApproveEveryFrameAndScan)

        await model.openProject(directory: "/tmp/attended-recovery")

        #expect(!model.canApproveEveryFrameAndScan)
        #expect(await model.approveEveryFrameAndScan() == false)
        #expect(await client.calls() == [.scanStart(frames: [1, 2])])
    }

    @Test("repeated clicks while approval is suspended cause one approval sequence and one retry")
    @MainActor
    func repeatedClicksAreOneShot() async {
        let client = AttendedRecoveryEngineStub(holdFirstApproval: true)
        let (model, _) = await preparedModel(client: client)

        await model.startMockScan()
        for frameIndex in 1...2 {
            emitFailure(
                model,
                frameIndex: frameIndex,
                code: ScanFailureCode.attendedBindingRequired,
                message: "typed refusal"
            )
        }
        emitCompletion(model, completed: [], failed: [1, 2])

        let first = Task { @MainActor in
            await model.approveEveryFrameAndScan()
        }
        await client.waitForApproval()
        let second = Task { @MainActor in
            await model.approveEveryFrameAndScan()
        }
        for _ in 0..<20 { await Task.yield() }

        #expect(await client.calls() == [
            .scanStart(frames: [1, 2]),
            .approve(frameIndex: 1, attended: true),
        ])

        // The ordinary Scan path cannot bypass a suspended attended approval.
        await model.startMockScan()
        #expect(await client.calls() == [
            .scanStart(frames: [1, 2]),
            .approve(frameIndex: 1, attended: true),
        ])

        await client.resumeApproval()
        #expect(await first.value)
        #expect(await second.value == false)
        #expect(await client.calls() == [
            .scanStart(frames: [1, 2]),
            .approve(frameIndex: 1, attended: true),
            .approve(frameIndex: 2, attended: true),
            .scanStart(frames: [1, 2]),
        ])
    }

    @Test("CR-01: scan.start is refused CONTROLLER_BUSY, not a silent typed success, while an attended-scan-recovery approval is in flight")
    @MainActor
    func scanStartIsRefusedWhileAttendedApprovalInFlight() async {
        let client = AttendedRecoveryEngineStub(holdFirstApproval: true)
        let (model, _) = await preparedModel(client: client)
        let dispatcher = ControlChannelDispatcher(sessionModel: model)
        _ = await dispatcher.handle(.hello(
            id: 0,
            params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "attended-recovery-tests")
        ))

        await model.startMockScan()
        for frameIndex in 1...2 {
            emitFailure(
                model,
                frameIndex: frameIndex,
                code: ScanFailureCode.attendedBindingRequired,
                message: "typed refusal"
            )
        }
        emitCompletion(model, completed: [], failed: [1, 2])
        #expect(model.canApproveEveryFrameAndScan)

        // `approveEveryFrameAndScan()` now sets the D-07 busy indicator, so
        // the dispatcher's own generic preamble refuses `scan.start` before
        // ever routing to `SessionModel` -- not a typed success for a
        // request that started nothing (the exact bug CR-01 reports).
        let approval = Task { @MainActor in
            await model.approveEveryFrameAndScan()
        }
        await client.waitForApproval()
        #expect(model.mutatingOperationInFlight == "review.approve.attended")

        let response = await dispatcher.handle(.scanStart(id: 99, params: ControlScanStartParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected CONTROLLER_BUSY, got \(response)")
            await client.resumeApproval()
            _ = await approval.value
            return
        }
        #expect(id == 99)
        #expect(error.code == ControlErrorCode.controllerBusy.rawValue)
        // Zero engine requests beyond the two already recorded before this
        // dispatch (the original scan.start and the held first approval) --
        // the refusal never reached `SessionModel`, let alone the engine.
        #expect(await client.calls() == [
            .scanStart(frames: [1, 2]),
            .approve(frameIndex: 1, attended: true),
        ])

        await client.resumeApproval()
        #expect(await approval.value)
    }

    @Test("WR-01: resumeBatch reports a typed refusal instead of a silent no-op while an attended-scan-recovery approval is in flight")
    @MainActor
    func resumeBatchRefusesWhileAttendedApprovalInFlight() async {
        let client = AttendedRecoveryEngineStub(holdFirstApproval: true)
        let (model, _) = await preparedModel(client: client)

        await model.startMockScan()
        for frameIndex in 1...2 {
            emitFailure(
                model,
                frameIndex: frameIndex,
                code: ScanFailureCode.attendedBindingRequired,
                message: "typed refusal"
            )
        }
        emitCompletion(model, completed: [], failed: [1, 2])
        #expect(model.canApproveEveryFrameAndScan)

        let approval = Task { @MainActor in
            await model.approveEveryFrameAndScan()
        }
        await client.waitForApproval()

        // A direct `SessionModel` call (IN-01: not gated by the dispatcher's
        // own busy preamble) used to return silently here with
        // `lastErrorMessage` untouched.
        await model.resumeBatch()
        #expect(model.lastErrorMessage == "An attended-scan-recovery approval is already in progress.")

        await client.resumeApproval()
        #expect(await approval.value)
    }
}
