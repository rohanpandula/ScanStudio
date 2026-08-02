import Foundation
import Testing

@testable import ScanStudioKit

private enum ManualReviewApprovalStubError: Error {
    case unexpectedMethod(String)
    case unexpectedParams(String)
    case unexpectedResultType
}

private enum ManualReviewApprovalCall: Equatable, Sendable {
    case approve(frameIndex: Int)
    case scanStart(frames: [Int])
}

private actor ManualReviewApprovalEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "manual-review-approval-stub"

    private let device = DeviceInfo(
        deviceId: "real-ls5000-approval-test",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supportedMultisamplePasses: [4]
    )
    private var project = ScanProject(
        schemaVersion: 1,
        id: "manual-review-project",
        name: "Manual review approval",
        carrier: .mounted,
        frameCount: 3,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/manual-review/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/manual-review/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/manual-review/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-07-28T00:00:00Z",
        frames: (1...3).map {
            ProjectFrame(index: $0, excluded: false, receipts: [])
        }
    )
    private var recordedCalls: [ManualReviewApprovalCall] = []
    private var approvedPreviewOperationIds: [String] = []
    private let holdApprovalResponse: Bool
    private let holdScanStartResponse: Bool
    private let approvalError: EngineRequestError?
    private var approvalContinuations: [CheckedContinuation<Void, Never>] = []
    private var approvalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var scanStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var scanStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        holdApprovalResponse: Bool = false,
        holdScanStartResponse: Bool = false,
        approvalError: EngineRequestError? = nil
    ) {
        self.holdApprovalResponse = holdApprovalResponse
        self.holdScanStartResponse = holdScanStartResponse
        self.approvalError = approvalError
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
                    adapter: "MA-21",
                    mediaLoaded: true,
                    carrier: "mounted",
                    frameCount: 3,
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
                directory: "/tmp/manual-review"
            )
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: [1, 2, 3])
        case "project.pendingFrames":
            value = PendingFramesResult(
                frames: [1, 2, 3],
                totalFrames: 3,
                completedCount: 0,
                excludedCount: 0
            )
        case "roll.setSpacingOffset":
            guard let params = params as? RollSetSpacingOffsetParams else {
                throw ManualReviewApprovalStubError.unexpectedParams(method)
            }
            value = RollSetSpacingOffsetResult(
                thumbnail: Thumbnail(
                    brightness: nil,
                    tint: nil,
                    imagePath:
                        "/tmp/manual-review-adjusted-\(params.frameIndex).tif",
                    boundaryRows: [20, 892],
                    spacingOffset: params.offsetRows,
                    needsApproval: true,
                    warnings: ["adjusted-boundary-needs-review"]
                )
            )
        case "project.setFrameAlignment":
            guard let params = params as? SetFrameAlignmentParams else {
                throw ManualReviewApprovalStubError.unexpectedParams(method)
            }
            project = ScanProject(
                schemaVersion: project.schemaVersion,
                id: project.id,
                name: project.name,
                carrier: project.carrier,
                frameCount: project.frameCount,
                filmProcess: project.filmProcess,
                recipes: project.recipes,
                rollMetadata: project.rollMetadata,
                createdAt: project.createdAt,
                frames: project.frames.map { frame in
                    guard frame.index == params.frameIndex else { return frame }
                    return ProjectFrame(
                        index: frame.index,
                        excluded: frame.excluded,
                        captureOverride: frame.captureOverride,
                        processingOverride: frame.processingOverride,
                        outputOverride: frame.outputOverride,
                        alignment: params.alignment,
                        metadataOverride: frame.metadataOverride,
                        receipts: frame.receipts
                    )
                }
            )
            value = SetFrameResult(project: project)
        case "roll.approve":
            guard let params = params as? RollApproveParams else {
                throw ManualReviewApprovalStubError.unexpectedParams(method)
            }
            recordedCalls.append(.approve(frameIndex: params.frameIndex))
            approvedPreviewOperationIds.append(params.operationId)
            resumeSatisfiedApprovalWaiters()
            if let approvalError {
                throw approvalError
            }
            if holdApprovalResponse {
                await withCheckedContinuation { continuation in
                    approvalContinuations.append(continuation)
                }
            }
            value = EmptyResult()
        case "scan.start":
            guard let params = params as? ScanStartParams else {
                throw ManualReviewApprovalStubError.unexpectedParams(method)
            }
            recordedCalls.append(.scanStart(frames: params.frames))
            resumeSatisfiedScanStartWaiters()
            if holdScanStartResponse {
                await withCheckedContinuation { continuation in
                    scanStartContinuations.append(continuation)
                }
            }
            value = ScanStartResult(jobId: "approved-job")
        default:
            throw ManualReviewApprovalStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw ManualReviewApprovalStubError.unexpectedResultType
        }
        return result
    }

    func calls() -> [ManualReviewApprovalCall] {
        recordedCalls
    }

    func approvedPreviewOperations() -> [String] {
        approvedPreviewOperationIds
    }

    func waitForApprovalRequestCount(_ count: Int) async {
        guard approvalRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            approvalWaiters.append((count, continuation))
        }
    }

    func resumeApprovals() {
        let continuations = approvalContinuations
        approvalContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForScanStartRequestCount(_ count: Int) async {
        guard scanStartRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            scanStartWaiters.append((count, continuation))
        }
    }

    func resumeScanStarts() {
        let continuations = scanStartContinuations
        scanStartContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private var approvalRequestCount: Int {
        recordedCalls.filter {
            if case .approve = $0 { true } else { false }
        }.count
    }

    private func resumeSatisfiedApprovalWaiters() {
        let satisfied = approvalWaiters.filter {
            approvalRequestCount >= $0.count
        }
        approvalWaiters.removeAll {
            approvalRequestCount >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private var scanStartRequestCount: Int {
        recordedCalls.filter {
            if case .scanStart = $0 { true } else { false }
        }.count
    }

    private func resumeSatisfiedScanStartWaiters() {
        let satisfied = scanStartWaiters.filter {
            scanStartRequestCount >= $0.count
        }
        scanStartWaiters.removeAll {
            scanStartRequestCount >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

@Suite("Manual review approval")
struct ManualReviewApprovalTests {
    @MainActor
    private func preparedModel(
        client: ManualReviewApprovalEngineStub = ManualReviewApprovalEngineStub(),
        flaggedFrames: Set<Int> = [3]
    ) async -> (SessionModel, ManualReviewApprovalEngineStub) {
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-approval-test")
        await model.openProject(directory: "/tmp/manual-review")

        let token = PreviewIntentToken()
        _ = await model.requestPreview(.refreshSavedProject(token: token))
        for frameIndex in 1...3 {
            let reviewEvidence = flaggedFrames.contains(frameIndex)
                ? #","needsApproval":true,"warnings":["ambiguous-content-tail-boundary"]"#
                : ""
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/manual-review-preview-\#(frameIndex).tif"\#(reviewEvidence)}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":3}}"#.utf8
            )
        ))
        model.selectAllFrames()
        return (model, client)
    }

    @Test("a flagged preview blocks the whole selected batch before scan.start")
    @MainActor
    func flaggedPreviewBlocksBeforeMotion() async {
        let (model, client) = await preparedModel()

        await model.startMockScan()

        #expect(await client.calls().isEmpty)
        #expect(model.pendingManualReviewScan?.frames == [1, 2, 3])
        #expect(model.pendingManualReviewScan?.requirements.map(\.frameIndex) == [3])
        #expect(model.jobId == nil)
    }

    @Test("explicit approval precedes exactly one scan.start for the original full batch")
    @MainActor
    func approveThenStartsOriginalBatch() async {
        let (model, client) = await preparedModel()
        let completedPreviewOperation = model.latestCompletedPreviewOperationId

        await model.startMockScan()
        await model.approvePendingManualReviewAndStart()

        #expect(await client.calls() == [
            .approve(frameIndex: 3),
            .scanStart(frames: [1, 2, 3]),
        ])
        #expect(
            await client.approvedPreviewOperations()
                == [completedPreviewOperation].compactMap { $0 }
        )
        #expect(model.pendingManualReviewScan == nil)
        #expect(model.jobId == "approved-job")
    }

    @Test("an adjusted tile that needs approval is gated before the original batch continues")
    @MainActor
    func adjustedTileComposesWithManualReviewGate() async {
        let (model, client) = await preparedModel(flaggedFrames: [])

        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        #expect(model.thumbnails[2]?.needsApproval == true)

        await model.startMockScan()

        #expect(await client.calls().isEmpty)
        #expect(
            model.pendingManualReviewScan?.requirements.map(\.frameIndex)
                == [2]
        )

        await model.approvePendingManualReviewAndStart()

        #expect(await client.calls() == [
            .approve(frameIndex: 2),
            .scanStart(frames: [1, 2, 3]),
        ])
        #expect(model.jobId == "approved-job")
    }

    @Test("Use Frame Anyway resolves the badge and starts the original batch without asking twice")
    @MainActor
    func useFrameAnywayIsRememberedForTheCurrentPreview() async {
        let (model, client) = await preparedModel()

        model.decideManualReview(
            .useFrameAnyway,
            for: 3,
            previewOperationId: model.latestCompletedPreviewOperationId!
        )

        #expect(model.manualReviewDecision(for: 3) == .useFrameAnyway)
        #expect(model.selectedFrameIndices.contains(3))

        await model.startMockScan()

        #expect(model.pendingManualReviewScan == nil)
        #expect(await client.calls() == [
            .approve(frameIndex: 3),
            .scanStart(frames: [1, 2, 3]),
        ])
    }

    @Test("Don't Scan keeps a flagged frame out of the batch, including Select All")
    @MainActor
    func dontScanPersistsForTheCurrentPreview() async {
        let (model, client) = await preparedModel()

        model.decideManualReview(
            .dontScan,
            for: 3,
            previewOperationId: model.latestCompletedPreviewOperationId!
        )
        model.selectAllFrames()

        #expect(model.manualReviewDecision(for: 3) == .dontScan)
        #expect(!model.selectedFrameIndices.contains(3))

        await model.startMockScan()

        #expect(model.pendingManualReviewScan == nil)
        #expect(await client.calls() == [
            .scanStart(frames: [1, 2]),
        ])
    }

    @Test("reselecting a Don't Scan frame makes its Review decision unresolved again")
    @MainActor
    func reselectingSkippedFrameRequiresReviewAgain() async {
        let (model, client) = await preparedModel()

        model.decideManualReview(
            .dontScan,
            for: 3,
            previewOperationId: model.latestCompletedPreviewOperationId!
        )
        model.toggleFrameSelection(3)

        #expect(model.manualReviewDecision(for: 3) == nil)
        #expect(model.selectedFrameIndices.contains(3))

        await model.startMockScan()

        #expect(await client.calls().isEmpty)
        #expect(model.pendingManualReviewScan?.requirements.map(\.frameIndex) == [3])
    }

    @Test("range selection preserves an explicit Don't Scan decision")
    @MainActor
    func rangeSelectionDoesNotReincludeSkippedReviewFrame() async {
        let (model, _) = await preparedModel()

        model.clearFrameSelection()
        model.selectFrame(1, extendingSelectionIfShiftHeld: false)
        model.decideManualReview(
            .dontScan,
            for: 3,
            previewOperationId: model.latestCompletedPreviewOperationId!
        )
        model.selectFrame(3, extendingSelectionIfShiftHeld: true)

        #expect(model.selectedFrameIndices == [1, 2])
        #expect(model.manualReviewDecision(for: 3) == .dontScan)
    }

    @Test("Invert preserves an explicit Don't Scan decision")
    @MainActor
    func invertDoesNotReincludeSkippedReviewFrame() async {
        let (model, _) = await preparedModel()

        model.decideManualReview(
            .dontScan,
            for: 3,
            previewOperationId: model.latestCompletedPreviewOperationId!
        )
        model.clearFrameSelection()
        model.invertFrameSelection()

        #expect(model.selectedFrameIndices == [1, 2])
        #expect(model.manualReviewDecision(for: 3) == .dontScan)
    }

    @Test("a Review sheet from an older preview cannot decide a newer preview")
    @MainActor
    func stalePreviewCannotAcceptReviewDecision() async {
        let (model, _) = await preparedModel()
        let oldPreviewOperation = model.latestCompletedPreviewOperationId!
        let replacementToken = PreviewIntentToken()

        _ = await model.requestPreview(
            .refreshSavedProject(token: replacementToken)
        )
        for frameIndex in 1...3 {
            let reviewEvidence = frameIndex == 3
                ? #","needsApproval":true,"warnings":["ambiguous-content-tail-boundary"]"#
                : ""
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(replacementToken.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/replacement-preview-\#(frameIndex).tif"\#(reviewEvidence)}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(replacementToken.id.uuidString)","count":3}}"#.utf8
            )
        ))

        let accepted = model.decideManualReview(
            .useFrameAnyway,
            for: 3,
            previewOperationId: oldPreviewOperation
        )

        #expect(!accepted)
        #expect(model.manualReviewDecision(for: 3) == nil)
    }

    @Test("a rejected Preview Again keeps the current preview and Review choices usable")
    @MainActor
    func rejectedReplacementPreservesCurrentReviewEvidence() async {
        let (model, _) = await preparedModel()
        let currentPreviewOperation = model.latestCompletedPreviewOperationId!
        model.decideManualReview(
            .dontScan,
            for: 3,
            previewOperationId: currentPreviewOperation
        )
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":3,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":false}}}"#.utf8
            )
        ))

        let outcome = await model.requestPreview(
            .refreshSavedProject(token: PreviewIntentToken())
        )

        #expect(outcome == .rejected)
        #expect(
            model.latestCompletedPreviewOperationId
                == currentPreviewOperation
        )
        #expect(model.manualReviewDecision(for: 3) == .dontScan)
        #expect(model.thumbnails.count == 3)
        #expect(model.decideManualReview(
            .useFrameAnyway,
            for: 3,
            previewOperationId: currentPreviewOperation
        ))
    }

    @Test("every flagged frame is approved before one full-batch scan.start")
    @MainActor
    func multipleApprovalsPrecedeOneBatch() async {
        let (model, client) = await preparedModel(flaggedFrames: [2, 3])

        await model.startMockScan()
        await model.approvePendingManualReviewAndStart()

        #expect(await client.calls() == [
            .approve(frameIndex: 2),
            .approve(frameIndex: 3),
            .scanStart(frames: [1, 2, 3]),
        ])
    }

    @Test("a second confirmation cannot duplicate approval or scan while the first is pending")
    @MainActor
    func approvalIsOneShotWhilePending() async {
        let client = ManualReviewApprovalEngineStub(holdApprovalResponse: true)
        let (model, _) = await preparedModel(client: client)
        await model.startMockScan()

        let first = Task { @MainActor in
            await model.approvePendingManualReviewAndStart()
        }
        await client.waitForApprovalRequestCount(1)
        let second = Task { @MainActor in
            await model.approvePendingManualReviewAndStart()
        }
        for _ in 0..<20 { await Task.yield() }

        #expect(await client.calls() == [.approve(frameIndex: 3)])

        await client.resumeApprovals()
        await first.value
        await second.value
        #expect(await client.calls() == [
            .approve(frameIndex: 3),
            .scanStart(frames: [1, 2, 3]),
        ])
    }

    @Test("an approval error is surfaced and never followed by scan.start")
    @MainActor
    func approvalFailureDoesNotScan() async {
        let client = ManualReviewApprovalEngineStub(
            approvalError: EngineRequestError(
                code: "APPROVAL_REJECTED",
                message: "the preview boundary changed",
                recoverable: true
            )
        )
        let (model, _) = await preparedModel(client: client)

        await model.startMockScan()
        await model.approvePendingManualReviewAndStart()

        #expect(await client.calls() == [.approve(frameIndex: 3)])
        #expect(
            model.lastErrorMessage
                == "APPROVAL_REJECTED: the preview boundary changed"
        )
        #expect(model.pendingManualReviewScan != nil)
    }

    @Test("a batch with no flagged previews starts without approval")
    @MainActor
    func ordinaryBatchStartsDirectly() async {
        let (model, client) = await preparedModel(flaggedFrames: [])

        await model.startMockScan()

        #expect(await client.calls() == [.scanStart(frames: [1, 2, 3])])
        #expect(model.pendingManualReviewScan == nil)
    }

    @Test("an approval response from a replaced scanner session cannot start a scan")
    @MainActor
    func changedSessionDiscardsApprovalResponse() async {
        let client = ManualReviewApprovalEngineStub(holdApprovalResponse: true)
        let (model, _) = await preparedModel(client: client)
        await model.startMockScan()
        let approval = Task { @MainActor in
            await model.approvePendingManualReviewAndStart()
        }
        await client.waitForApprovalRequestCount(1)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":false,"adapter":null,"mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"off","transport":"idle","activeJobId":null,"filmPresent":null}}}"#.utf8
            )
        ))
        await model.connect(deviceId: "real-ls5000-approval-test")
        #expect(model.latestCompletedPreviewOperationId == nil)
        await client.resumeApprovals()
        await approval.value

        #expect(await client.calls() == [.approve(frameIndex: 3)])
        #expect(model.jobId == nil)
    }

    @Test("an auto-approved batch can retry after readiness changes before scan.start")
    @MainActor
    func autoApprovalReadinessFailureCanRetry() async {
        let client = ManualReviewApprovalEngineStub(holdApprovalResponse: true)
        let (model, _) = await preparedModel(client: client)
        model.decideManualReview(
            .useFrameAnyway,
            for: 3,
            previewOperationId: model.latestCompletedPreviewOperationId!
        )

        let firstAttempt = Task { @MainActor in
            await model.startMockScan()
        }
        await client.waitForApprovalRequestCount(1)
        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":3,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":false}}}"#.utf8
            )
        ))
        await client.resumeApprovals()
        await firstAttempt.value

        #expect(await client.calls() == [.approve(frameIndex: 3)])
        #expect(model.jobId == nil)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":3,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}"#.utf8
            )
        ))
        let retry = Task { @MainActor in
            await model.startMockScan()
        }
        await client.waitForApprovalRequestCount(2)
        await client.resumeApprovals()
        await retry.value

        #expect(await client.calls() == [
            .approve(frameIndex: 3),
            .approve(frameIndex: 3),
            .scanStart(frames: [1, 2, 3]),
        ])
        #expect(model.jobId == "approved-job")
    }

    @Test("a new preview invalidates an in-flight confirmation bound to the old preview")
    @MainActor
    func replacementPreviewInvalidatesApproval() async {
        let client = ManualReviewApprovalEngineStub(holdApprovalResponse: true)
        let (model, _) = await preparedModel(client: client)
        let oldPreviewOperation = model.latestCompletedPreviewOperationId
        await model.startMockScan()
        let approval = Task { @MainActor in
            await model.approvePendingManualReviewAndStart()
        }
        await client.waitForApprovalRequestCount(1)

        let replacement = await model.requestPreview(
            .refreshSavedProject(token: PreviewIntentToken())
        )
        #expect(replacement == .started)
        #expect(model.latestCompletedPreviewOperationId == nil)

        await client.resumeApprovals()
        await approval.value

        #expect(await client.calls() == [.approve(frameIndex: 3)])
        #expect(
            await client.approvedPreviewOperations()
                == [oldPreviewOperation].compactMap { $0 }
        )
        #expect(model.jobId == nil)
    }

    @Test("a single-frame scan is also gated by that frame's preview evidence")
    @MainActor
    func singleFrameScanIsGated() async {
        let (model, client) = await preparedModel()

        await model.scanSingleFrame(3)
        #expect(await client.calls().isEmpty)
        #expect(model.pendingManualReviewScan?.frames == [3])
        #expect(model.pendingManualReviewScan?.requirements.map(\.frameIndex) == [3])
    }

    @Test("resume is gated before scan.start and preserves its complete pending set")
    @MainActor
    func resumeIsGated() async {
        let (model, client) = await preparedModel()

        await model.resumeBatch()

        #expect(await client.calls().isEmpty)
        #expect(model.pendingManualReviewScan?.frames == [1, 2, 3])
        #expect(model.selectedFrames == [1, 2, 3])
    }

    @Test("cancelling review sends neither approval nor scan.start")
    @MainActor
    func cancellationIsNonMotion() async {
        let (model, client) = await preparedModel()

        await model.startMockScan()
        model.cancelPendingManualReviewScan()

        #expect(model.pendingManualReviewScan == nil)
        #expect(await client.calls().isEmpty)
    }

    @Test("an accepted confirmed scan is adopted even if a late media status clears the review sheet")
    @MainActor
    func acceptedScanCannotBecomeOrphaned() async {
        let client = ManualReviewApprovalEngineStub(
            holdScanStartResponse: true
        )
        let (model, _) = await preparedModel(client: client)
        await model.startMockScan()
        let confirmation = Task { @MainActor in
            await model.approvePendingManualReviewAndStart()
        }
        await client.waitForScanStartRequestCount(1)

        model.handle(event: EngineEvent(
            name: "scanner.status",
            rawLine: Data(
                #"{"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":false,"carrier":"mounted","frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":false,"motionArmed":true}}}"#.utf8
            )
        ))
        #expect(model.pendingManualReviewScan == nil)

        await client.resumeScanStarts()
        await confirmation.value

        #expect(model.jobId == "approved-job")
        #expect(model.isJobActive)
        #expect(await client.calls() == [
            .approve(frameIndex: 3),
            .scanStart(frames: [1, 2, 3]),
        ])
    }

    @Test("a scan already awaiting its response blocks review before roll.approve")
    @MainActor
    func pendingScanStartBlocksApproval() async {
        let client = ManualReviewApprovalEngineStub(
            holdScanStartResponse: true
        )
        let (model, _) = await preparedModel(client: client)

        let firstScan = Task { @MainActor in
            await model.scanSingleFrame(1)
        }
        await client.waitForScanStartRequestCount(1)
        await model.startMockScan()

        #expect(model.pendingManualReviewScan == nil)
        #expect(model.lastErrorMessage == "A scan is already starting.")
        #expect(await client.calls() == [.scanStart(frames: [1])])

        await client.resumeScanStarts()
        await firstScan.value
    }
}
