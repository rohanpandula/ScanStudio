import Foundation
import Testing

@testable import ScanStudioKit

private enum FrameAlignmentStubError: Error {
    case unexpectedMethod(String)
    case unexpectedParams(String)
    case unexpectedResultType
}

private actor FrameAlignmentEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "frame-alignment-stub"

    private let device = DeviceInfo(
        deviceId: "real-ls5000-alignment-test",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supportedMultisamplePasses: [4]
    )
    private let holdSpacingResponses: Bool
    private let holdProjectResponses: Bool
    private let holdScanStartResponses: Bool
    private let spacingErrorAtRequestIndex: Int?
    private let alignmentPersistenceErrorAtRequestIndex: Int?
    private var spacingRequests: [RollSetSpacingOffsetParams] = []
    private var alignmentPersistenceRequests: [SetFrameAlignmentParams] = []
    private var scanStartRequests: [ScanStartParams] = []
    private var spacingContinuations: [CheckedContinuation<Void, Never>] = []
    private var projectContinuations: [CheckedContinuation<Void, Never>] = []
    private var scanStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var projectRequestCount = 0
    private var spacingWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var projectWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var scanStartWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var project = ScanProject(
        schemaVersion: 1,
        id: "frame-alignment-project",
        name: "Frame alignment",
        carrier: .roll36,
        frameCount: 4,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/frame-alignment/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/frame-alignment/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/frame-alignment/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-07-28T00:00:00Z",
        frames: (1...4).map {
            ProjectFrame(index: $0, excluded: false, receipts: [])
        }
    )

    init(
        holdSpacingResponses: Bool = false,
        holdProjectResponses: Bool = false,
        holdScanStartResponses: Bool = false,
        spacingErrorAtRequestIndex: Int? = nil,
        alignmentPersistenceErrorAtRequestIndex: Int? = nil
    ) {
        self.holdSpacingResponses = holdSpacingResponses
        self.holdProjectResponses = holdProjectResponses
        self.holdScanStartResponses = holdScanStartResponses
        self.spacingErrorAtRequestIndex = spacingErrorAtRequestIndex
        self.alignmentPersistenceErrorAtRequestIndex =
            alignmentPersistenceErrorAtRequestIndex
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
                    adapter: "SA-30",
                    mediaLoaded: true,
                    carrier: "roll36",
                    frameCount: 4,
                    lamp: "stable",
                    transport: "idle",
                    activeJobId: nil,
                    filmPresent: true,
                    motionArmed: true
                )
            )
        case "scanner.disconnect":
            value = EmptyResult()
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: [1, 2, 3, 4])
        case "roll.setSpacingOffset":
            guard let params = params as? RollSetSpacingOffsetParams else {
                throw FrameAlignmentStubError.unexpectedParams(method)
            }
            spacingRequests.append(params)
            resumeSatisfiedSpacingWaiters()
            if spacingRequests.count == spacingErrorAtRequestIndex {
                throw EngineRequestError(
                    code: "ALIGNMENT_RESTORE_FAILED",
                    message: "saved offset could not be restored",
                    recoverable: true
                )
            }
            if holdSpacingResponses {
                await withCheckedContinuation { continuation in
                    spacingContinuations.append(continuation)
                }
            }
            value = RollSetSpacingOffsetResult(
                thumbnail: Thumbnail(
                    brightness: nil,
                    tint: nil,
                    imagePath: "/tmp/frame-\(params.frameIndex)-offset-\(params.offsetRows).tif",
                    boundaryRows: [20, 892],
                    spacingOffset: params.offsetRows,
                    needsApproval: true,
                    warnings: ["adjusted-boundary"]
                )
            )
        case "project.create":
            projectRequestCount += 1
            resumeSatisfiedProjectWaiters()
            if holdProjectResponses {
                await withCheckedContinuation { continuation in
                    projectContinuations.append(continuation)
                }
            }
            value = ProjectCreateResult(
                project: project,
                directory: "/tmp/frame-alignment"
            )
        case "project.open":
            projectRequestCount += 1
            resumeSatisfiedProjectWaiters()
            if holdProjectResponses {
                await withCheckedContinuation { continuation in
                    projectContinuations.append(continuation)
                }
            }
            value = ProjectOpenResult(
                project: project,
                directory: "/tmp/frame-alignment"
            )
        case "project.setFrameAlignment":
            guard let params = params as? SetFrameAlignmentParams else {
                throw FrameAlignmentStubError.unexpectedParams(method)
            }
            alignmentPersistenceRequests.append(params)
            if alignmentPersistenceRequests.count
                == alignmentPersistenceErrorAtRequestIndex
            {
                throw EngineRequestError(
                    code: "ALIGNMENT_PERSIST_FAILED",
                    message: "alignment could not be saved",
                    recoverable: true
                )
            }
            project = replacingProjectAlignment(
                frameIndex: params.frameIndex,
                alignment: params.alignment
            )
            value = SetFrameResult(project: project)
        case "scan.start":
            guard let params = params as? ScanStartParams else {
                throw FrameAlignmentStubError.unexpectedParams(method)
            }
            scanStartRequests.append(params)
            resumeSatisfiedScanStartWaiters()
            if holdScanStartResponses {
                await withCheckedContinuation { continuation in
                    scanStartContinuations.append(continuation)
                }
            }
            value = ScanStartResult(jobId: "frame-alignment-job")
        default:
            throw FrameAlignmentStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw FrameAlignmentStubError.unexpectedResultType
        }
        return result
    }

    func recordedSpacingRequests() -> [RollSetSpacingOffsetParams] {
        spacingRequests
    }

    func recordedAlignmentPersistenceRequests() -> [SetFrameAlignmentParams] {
        alignmentPersistenceRequests
    }

    func recordedScanStartRequests() -> [ScanStartParams] {
        scanStartRequests
    }

    func seedProjectAlignment(
        frameIndex: Int,
        alignment: FrameAlignment?
    ) {
        project = replacingProjectAlignment(
            frameIndex: frameIndex,
            alignment: alignment
        )
    }

    func waitForSpacingRequestCount(_ count: Int) async {
        guard spacingRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            spacingWaiters.append((count, continuation))
        }
    }

    func waitForProjectRequestCount(_ count: Int) async {
        guard projectRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            projectWaiters.append((count, continuation))
        }
    }

    func waitForScanStartRequestCount(_ count: Int) async {
        guard scanStartRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            scanStartWaiters.append((count, continuation))
        }
    }

    func resumeSpacingResponses() {
        let continuations = spacingContinuations
        spacingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func resumeProjectResponses() {
        let continuations = projectContinuations
        projectContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func resumeScanStartResponses() {
        let continuations = scanStartContinuations
        scanStartContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeSatisfiedSpacingWaiters() {
        let satisfied = spacingWaiters.filter {
            spacingRequests.count >= $0.count
        }
        spacingWaiters.removeAll {
            spacingRequests.count >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func resumeSatisfiedProjectWaiters() {
        let satisfied = projectWaiters.filter {
            projectRequestCount >= $0.count
        }
        projectWaiters.removeAll {
            projectRequestCount >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func resumeSatisfiedScanStartWaiters() {
        let satisfied = scanStartWaiters.filter {
            scanStartRequests.count >= $0.count
        }
        scanStartWaiters.removeAll {
            scanStartRequests.count >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func replacingProjectAlignment(
        frameIndex: Int,
        alignment: FrameAlignment?
    ) -> ScanProject {
        ScanProject(
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
                guard frame.index == frameIndex else { return frame }
                return ProjectFrame(
                    index: frame.index,
                    excluded: frame.excluded,
                    captureOverride: frame.captureOverride,
                    processingOverride: frame.processingOverride,
                    outputOverride: frame.outputOverride,
                    alignment: alignment,
                    metadataOverride: frame.metadataOverride,
                    receipts: frame.receipts
                )
            }
        )
    }
}

@Suite("Frame alignment")
struct FrameAlignmentTests {
    @MainActor
    private func preparedPreProjectModel(
        client: FrameAlignmentEngineStub = FrameAlignmentEngineStub(),
        flaggedFrame: Int = 2
    ) async -> (SessionModel, FrameAlignmentEngineStub) {
        let preferences = UserDefaults(
            suiteName: "FrameAlignmentTests.\(UUID().uuidString)"
        )!
        let model = SessionModel(engineClient: client, preferences: preferences)
        await model.connect(deviceId: "real-ls5000-alignment-test")

        let token = PreviewIntentToken()
        _ = await model.requestPreview(.initial(token: token))
        for frameIndex in 1...4 {
            let needsApproval = frameIndex == flaggedFrame
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/frame-\#(frameIndex).tif","boundaryRows":[20,892],"spacingOffset":0,"needsApproval":\#(needsApproval),"warnings":\#(needsApproval ? "[\"ambiguous-boundary\"]" : "[]")}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":4}}"#.utf8
            )
        ))
        return (model, client)
    }

    @MainActor
    private func preparedSavedProjectModel(
        client: FrameAlignmentEngineStub = FrameAlignmentEngineStub(),
        alignments: [Int: FrameAlignment]
    ) async -> (SessionModel, FrameAlignmentEngineStub, PreviewIntentToken) {
        for (frameIndex, alignment) in alignments {
            await client.seedProjectAlignment(
                frameIndex: frameIndex,
                alignment: alignment
            )
        }
        let preferences = UserDefaults(
            suiteName: "FrameAlignmentTests.\(UUID().uuidString)"
        )!
        let model = SessionModel(engineClient: client, preferences: preferences)
        await model.connect(deviceId: "real-ls5000-alignment-test")
        await model.openProject(directory: "/tmp/frame-alignment")

        let token = PreviewIntentToken()
        _ = await model.requestPreview(.refreshSavedProject(token: token))
        for frameIndex in 1...4 {
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/fresh-frame-\#(frameIndex).tif","boundaryRows":[20,892],"spacingOffset":0,"needsApproval":false,"warnings":[]}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":4}}"#.utf8
            )
        ))
        return (model, client, token)
    }

    @Test("Thumbnail alignment evidence is additive and legacy thumbnails still decode")
    func thumbnailAlignmentEvidenceIsAdditive() throws {
        let real = try JSONDecoder().decode(
            Thumbnail.self,
            from: Data(
                #"{"imagePath":"/tmp/frame-01.tif","boundaryRows":[12,884],"spacingOffset":3,"needsApproval":true,"warnings":["boundary"]}"#.utf8
            )
        )
        let legacy = try JSONDecoder().decode(
            Thumbnail.self,
            from: Data(#"{"brightness":0.25,"tint":-0.1}"#.utf8)
        )

        #expect(real.boundaryRows == [12, 884])
        #expect(real.spacingOffset == 3)
        #expect(legacy.boundaryRows == nil)
        #expect(legacy.spacingOffset == nil)
    }

    @Test("Spacing-offset requests carry preview identity and return a replacement thumbnail")
    func spacingOffsetWireContract() throws {
        let paramsData = try JSONEncoder().encode(
            RollSetSpacingOffsetParams(
                frameIndex: 4,
                offsetRows: -7,
                operationId: "preview-operation-4"
            )
        )
        let params = try #require(
            JSONSerialization.jsonObject(with: paramsData) as? [String: Any]
        )
        let result = try JSONDecoder().decode(
            RollSetSpacingOffsetResult.self,
            from: Data(
                #"{"thumbnail":{"imagePath":"/tmp/frame-04-adjusted.tif","boundaryRows":[20,892],"spacingOffset":-7,"needsApproval":true,"warnings":["adjusted"]}}"#.utf8
            )
        )

        #expect(params["frameIndex"] as? Int == 4)
        #expect(params["offsetRows"] as? Int == -7)
        #expect(params["operationId"] as? String == "preview-operation-4")
        #expect(result.thumbnail.spacingOffset == -7)
        #expect(result.thumbnail.imagePath == "/tmp/frame-04-adjusted.tif")
    }

    @Test("Project frames persist an additive draft alignment")
    func projectFrameAlignmentIsAdditive() throws {
        let adjusted = try JSONDecoder().decode(
            ProjectFrame.self,
            from: Data(
                #"{"index":2,"excluded":false,"alignment":{"offsetRows":-3,"approved":false},"receipts":[]}"#.utf8
            )
        )
        let legacy = try JSONDecoder().decode(
            ProjectFrame.self,
            from: Data(#"{"index":2,"excluded":false,"receipts":[]}"#.utf8)
        )
        let paramsData = try JSONEncoder().encode(
            SetFrameAlignmentParams(
                frameIndex: 2,
                alignment: FrameAlignment(offsetRows: -3, approved: false)
            )
        )
        let params = try #require(
            JSONSerialization.jsonObject(with: paramsData) as? [String: Any]
        )
        let alignment = try #require(params["alignment"] as? [String: Any])

        #expect(adjusted.alignment == FrameAlignment(offsetRows: -3, approved: false))
        #expect(legacy.alignment == nil)
        #expect(params["frameIndex"] as? Int == 2)
        #expect(alignment["offsetRows"] as? Int == -3)
        #expect(alignment["approved"] as? Bool == false)
    }

    @Test("Nudging uses native row signs, replaces the tile, and invalidates review approval")
    @MainActor
    func nudgeUpdatesCurrentPreview() async throws {
        let (model, client) = await preparedPreProjectModel()
        let operationId = try #require(model.latestCompletedPreviewOperationId)
        #expect(
            model.decideManualReview(
                .useFrameAnyway,
                for: 2,
                previewOperationId: operationId
            )
        )

        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)

        let request = try #require(await client.recordedSpacingRequests().only)
        #expect(request.frameIndex == 2)
        #expect(request.offsetRows == 1)
        #expect(request.operationId == operationId)
        #expect(model.alignmentOffset(for: 2) == 1)
        #expect(model.thumbnails[2]?.imagePath == "/tmp/frame-2-offset-1.tif")
        #expect(model.manualReviewDecision(for: 2) == nil)
        #expect(!model.isAdjustingFrameAlignment(2))
    }

    @Test("A pre-Save alignment draft migrates into the created project as unapproved")
    @MainActor
    func preProjectDraftMigratesOnCreate() async throws {
        let (model, client) = await preparedPreProjectModel(flaggedFrame: -1)
        await model.nudgeFrameAlignment(frameIndex: 3, by: -1)

        await model.createProject(
            name: "Aligned roll",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )

        let request = try #require(
            await client.recordedAlignmentPersistenceRequests().only
        )
        #expect(request.frameIndex == 3)
        #expect(request.alignment == FrameAlignment(offsetRows: -1, approved: false))
        #expect(
            model.project?.frames.first(where: { $0.index == 3 })?.alignment
                == FrameAlignment(offsetRows: -1, approved: false)
        )
    }

    @Test("A failed pre-Save draft migration keeps the project open and scan blocked until retry")
    @MainActor
    func projectCreateMigrationFailureCanRetry() async {
        let client = FrameAlignmentEngineStub(
            alignmentPersistenceErrorAtRequestIndex: 1
        )
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)

        await model.createProject(
            name: "Migration retry",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )

        #expect(model.project != nil)
        #expect(model.alignmentOffset(for: 2) == 1)
        #expect(model.failedFrameAlignmentRestoreIndices == [2])
        #expect(!model.scanReadiness(for: [2]).isReady)

        await model.retryFrameAlignment(frameIndex: 2)

        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment
                == FrameAlignment(offsetRows: 1, approved: false)
        )
        #expect(model.scanReadiness(for: [2]).isReady)
    }

    @Test("A partial draft migration blocks the failed and still-unattempted frames")
    @MainActor
    func partialProjectCreateMigrationFailsClosed() async {
        let client = FrameAlignmentEngineStub(
            alignmentPersistenceErrorAtRequestIndex: 2
        )
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        await model.nudgeFrameAlignment(frameIndex: 3, by: -1)
        await model.nudgeFrameAlignment(frameIndex: 4, by: 1)

        await model.createProject(
            name: "Partial migration",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )

        #expect(model.failedFrameAlignmentRestoreIndices == [3, 4])
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment
                == FrameAlignment(offsetRows: 1, approved: false)
        )
        #expect(
            model.project?.frames.first(where: { $0.index == 3 })?.alignment
                == nil
        )
        #expect(
            model.project?.frames.first(where: { $0.index == 4 })?.alignment
                == nil
        )
        #expect(!model.scanReadiness(for: [2, 3]).isReady)
    }

    @Test("A nudge on an existing project persists immediately as unapproved")
    @MainActor
    func projectNudgePersistsImmediately() async throws {
        let (model, client) = await preparedPreProjectModel(flaggedFrame: -1)
        await model.createProject(
            name: "Aligned roll",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )

        await model.nudgeFrameAlignment(frameIndex: 4, by: 1)

        let request = try #require(
            await client.recordedAlignmentPersistenceRequests().only
        )
        #expect(request.frameIndex == 4)
        #expect(request.alignment == FrameAlignment(offsetRows: 1, approved: false))
        #expect(
            model.project?.frames.first(where: { $0.index == 4 })?.alignment
                == FrameAlignment(offsetRows: 1, approved: false)
        )
    }

    @Test("A project persistence failure after a live nudge blocks scanning")
    @MainActor
    func projectNudgePersistenceFailureBlocksScanning() async {
        let client = FrameAlignmentEngineStub(
            alignmentPersistenceErrorAtRequestIndex: 1
        )
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        await model.createProject(
            name: "Aligned roll",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )

        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)

        #expect(model.alignmentOffset(for: 2) == 1)
        #expect(
            model.frameAlignmentDrafts[2]
                == FrameAlignment(offsetRows: 1, approved: false)
        )
        #expect(model.failedFrameAlignmentRestoreIndices == [2])
        #expect(!model.scanReadiness(for: [2]).isReady)
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment
                == nil
        )
    }

    @Test("Retry saves an already-live alignment without forcing another nudge")
    @MainActor
    func retryPersistsAlreadyLiveAlignment() async {
        let client = FrameAlignmentEngineStub(
            alignmentPersistenceErrorAtRequestIndex: 1
        )
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        await model.createProject(
            name: "Aligned roll",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )
        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)

        await model.retryFrameAlignment(frameIndex: 2)

        #expect(await client.recordedSpacingRequests().count == 1)
        #expect(
            await client.recordedAlignmentPersistenceRequests().count == 2
        )
        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment
                == FrameAlignment(offsetRows: 1, approved: false)
        )
        #expect(model.lastErrorMessage == nil)
        #expect(model.scanReadiness(for: [2]).isReady)
    }

    @Test("Starting a replacement preview clears session alignment state")
    @MainActor
    func replacementPreviewClearsAlignmentState() async {
        let (model, _) = await preparedPreProjectModel(flaggedFrame: -1)
        await model.nudgeFrameAlignment(frameIndex: 3, by: -1)
        #expect(model.alignmentOffset(for: 3) == -1)

        let outcome = await model.requestPreview(
            .replaceFilmProcess(
                token: PreviewIntentToken(),
                filmProcess: .positive
            )
        )

        #expect(outcome == .started)
        #expect(model.frameAlignmentDrafts.isEmpty)
        #expect(model.alignmentOffset(for: 3) == 0)
        #expect(model.adjustingFrameAlignmentIndices.isEmpty)
    }

    @Test("Frame one cannot move negative and all frame offsets stop at native row bounds")
    @MainActor
    func nudgeBoundsMatchScannerContract() async {
        let (model, _) = await preparedPreProjectModel(flaggedFrame: -1)

        #expect(!model.canNudgeFrameAlignment(1, by: -1))
        #expect(model.canNudgeFrameAlignment(2, by: -144))
        #expect(!model.canNudgeFrameAlignment(2, by: -145))

        await model.nudgeFrameAlignment(frameIndex: 1, by: 144)
        #expect(model.alignmentOffset(for: 1) == 144)
        #expect(!model.canNudgeFrameAlignment(1, by: 1))
        #expect(model.canNudgeFrameAlignment(1, by: -144))
    }

    @Test("Pending state disables another nudge until the adjusted tile returns")
    @MainActor
    func pendingNudgeStateIsExposed() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )

        let nudge = Task {
            await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        }
        await client.waitForSpacingRequestCount(1)

        #expect(model.isAdjustingFrameAlignment(2))
        #expect(!model.canNudgeFrameAlignment(2, by: 1))

        await client.resumeSpacingResponses()
        await nudge.value
        #expect(!model.isAdjustingFrameAlignment(2))
    }

    @Test("A suspended nudge blocks scan.start until live alignment is saved")
    @MainActor
    func suspendedNudgeBlocksScanUntilPersistenceCompletes() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [:]
        )

        let nudge = Task {
            await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        }
        await client.waitForSpacingRequestCount(1)

        #expect(model.scanReadiness(for: [2]) == .alignmentInProgress)
        await model.scanSingleFrame(2)
        #expect(await client.recordedScanStartRequests().isEmpty)

        await client.resumeSpacingResponses()
        await nudge.value
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment
                == FrameAlignment(offsetRows: 1, approved: false)
        )
        #expect(model.scanReadiness(for: [2]).isReady)

        let result = try? await model.dispatchScanStart(frames: [2])
        #expect(result?.jobId == "frame-alignment-job")
        #expect(
            await client.recordedScanStartRequests().map(\.frames) == [[2]]
        )
    }

    @Test("A pending scan start blocks a new frame nudge")
    @MainActor
    func pendingScanStartBlocksFrameNudge() async {
        let client = FrameAlignmentEngineStub(holdScanStartResponses: true)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [:]
        )

        let start = Task {
            try? await model.dispatchScanStart(frames: [2])
        }
        await client.waitForScanStartRequestCount(1)

        #expect(!model.canNudgeFrameAlignment(2, by: 1))
        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        #expect(await client.recordedSpacingRequests().isEmpty)

        await client.resumeScanStartResponses()
        #expect(await start.value?.jobId == "frame-alignment-job")
    }

    @Test("An active scan blocks frame nudge and alignment retry")
    @MainActor
    func activeScanBlocksFrameAlignmentMutation() async {
        let client = FrameAlignmentEngineStub(
            spacingErrorAtRequestIndex: 1
        )
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if model.failedFrameAlignmentRestoreIndices == [2] { break }
            await Task.yield()
        }
        #expect(model.failedFrameAlignmentRestoreIndices == [2])
        #expect(await client.recordedSpacingRequests().count == 1)

        model.beginJob(id: "active-alignment-job", frames: [2])
        model.handle(event: EngineEvent(
            name: "scan.jobState",
            rawLine: Data(
                #"{"event":"scan.jobState","payload":{"jobId":"active-alignment-job","state":"scanning"}}"#.utf8
            )
        ))

        #expect(!model.canNudgeFrameAlignment(2, by: 1))
        await model.retryFrameAlignment(frameIndex: 2)
        #expect(await client.recordedSpacingRequests().count == 1)
    }

    @Test("Project creation is rejected while a frame alignment request is pending")
    @MainActor
    func pendingNudgeBlocksProjectCreation() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        let nudge = Task {
            await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        }
        await client.waitForSpacingRequestCount(1)

        await model.createProject(
            name: "Must wait",
            carrier: .roll36,
            frameCount: 4,
            filmProcess: .c41ColorNegative
        )

        #expect(model.project == nil)
        #expect(model.lastErrorMessage?.contains("alignment") == true)

        await client.resumeSpacingResponses()
        await nudge.value
    }

    @Test("A project lifecycle request disables frame alignment until it finishes")
    @MainActor
    func projectLifecycleDisablesNudging() async {
        let client = FrameAlignmentEngineStub(holdProjectResponses: true)
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        let creation = Task {
            await model.createProject(
                name: "In flight",
                carrier: .roll36,
                frameCount: 4,
                filmProcess: .c41ColorNegative
            )
        }
        await client.waitForProjectRequestCount(1)

        #expect(model.isChangingProject)
        #expect(!model.canNudgeFrameAlignment(2, by: 1))

        await client.resumeProjectResponses()
        await creation.value

        #expect(!model.isChangingProject)
        #expect(model.canNudgeFrameAlignment(2, by: 1))
    }

    @Test("Opening a saved project invalidates a prior live preview and its draft alignments")
    @MainActor
    func openingProjectInvalidatesPriorPreviewAlignmentState() async {
        let (model, client) = await preparedPreProjectModel(flaggedFrame: -1)
        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        await client.seedProjectAlignment(
            frameIndex: 3,
            alignment: FrameAlignment(offsetRows: -2, approved: false)
        )

        await model.openProject(directory: "/tmp/frame-alignment")

        #expect(model.project != nil)
        #expect(model.frameAlignmentDrafts.isEmpty)
        #expect(model.thumbnails.isEmpty)
        #expect(model.latestCompletedPreviewOperationId == nil)
        #expect(model.previewFilmProcess == nil)
        #expect(!model.hasCompletePreviewRegistration)
        #expect(!model.scanReadiness(for: [3]).isReady)
    }

    @Test("Media-session reset clears alignment drafts")
    @MainActor
    func mediaResetClearsAlignmentState() async {
        let (model, _) = await preparedPreProjectModel(flaggedFrame: -1)
        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        #expect(model.alignmentOffset(for: 2) == 1)

        await model.disconnect()

        #expect(model.frameAlignmentDrafts.isEmpty)
        #expect(model.adjustingFrameAlignmentIndices.isEmpty)
        #expect(model.alignmentOffset(for: 2) == 0)
    }

    @Test("An adjusted tile from an older preview cannot replace the new registration")
    @MainActor
    func staleNudgeResponseIsIgnored() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _) = await preparedPreProjectModel(
            client: client,
            flaggedFrame: -1
        )
        let nudge = Task {
            await model.nudgeFrameAlignment(frameIndex: 2, by: 1)
        }
        await client.waitForSpacingRequestCount(1)

        let replacement = await model.requestPreview(
            .replaceFilmProcess(
                token: PreviewIntentToken(),
                filmProcess: .positive
            )
        )
        await client.resumeSpacingResponses()
        await nudge.value

        #expect(replacement == .started)
        #expect(model.thumbnails.isEmpty)
        #expect(model.frameAlignmentDrafts.isEmpty)
        #expect(model.alignmentOffset(for: 2) == 0)
    }

    @Test("A saved offset is not reported as applied to a fresh zero-offset preview")
    @MainActor
    func persistedOffsetIsNotLiveBeforeBridgeResponse() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if await client.recordedSpacingRequests().count == 1 { break }
            await Task.yield()
        }

        #expect(model.thumbnails[2]?.spacingOffset == 0)
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment?.offsetRows
                == 5
        )
        #expect(model.alignmentOffset(for: 2) == 0)

        await client.resumeSpacingResponses()
        for _ in 0..<100 {
            if !model.isRestoringFrameAlignments { break }
            await Task.yield()
        }
    }

    @Test("Saved alignment is reapplied through the exact preview before scan or nudge can proceed")
    @MainActor
    func savedAlignmentRestoresBeforeReadiness() async throws {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _, token) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if await client.recordedSpacingRequests().count == 1 { break }
            await Task.yield()
        }

        let request = try #require(
            await client.recordedSpacingRequests().only
        )
        #expect(request.frameIndex == 2)
        #expect(request.offsetRows == 5)
        #expect(request.operationId == token.id.uuidString)
        #expect(model.isRestoringFrameAlignments)
        #expect(model.alignmentOffset(for: 2) == 0)
        #expect(model.frameAlignmentDrafts[2] == nil)
        #expect(!model.canNudgeFrameAlignment(2, by: 1))
        #expect(!model.scanReadiness(for: [2]).isReady)

        await client.resumeSpacingResponses()
        for _ in 0..<100 {
            if !model.isRestoringFrameAlignments { break }
            await Task.yield()
        }

        #expect(!model.isRestoringFrameAlignments)
        #expect(model.alignmentOffset(for: 2) == 5)
        #expect(model.thumbnails[2]?.imagePath == "/tmp/frame-2-offset-5.tif")
        #expect(
            model.frameAlignmentDrafts[2]
                == FrameAlignment(offsetRows: 5, approved: false)
        )
        #expect(model.scanReadiness(for: [2]).isReady)
    }

    @Test("A late saved-alignment response cannot wedge state after a session reset")
    @MainActor
    func staleRestoreResponseCannotWedgeBusyState() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        await client.waitForSpacingRequestCount(1)
        #expect(model.isRestoringFrameAlignments)
        #expect(model.isAcquiringThumbnails)

        await model.disconnect()
        await client.resumeSpacingResponses()
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(!model.isRestoringFrameAlignments)
        #expect(!model.isAcquiringThumbnails)
        #expect(model.frameAlignmentDrafts.isEmpty)
        #expect(model.adjustingFrameAlignmentIndices.isEmpty)
        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
    }

    @Test("Opening another project is rejected while saved alignments are restoring")
    @MainActor
    func pendingRestoreBlocksProjectOpen() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        await client.waitForSpacingRequestCount(1)

        await model.openProject(directory: "/tmp/another-project")

        #expect(model.isRestoringFrameAlignments)
        #expect(model.lastErrorMessage?.contains("alignment") == true)

        await client.resumeSpacingResponses()
        for _ in 0..<100 {
            if !model.isRestoringFrameAlignments { break }
            await Task.yield()
        }
        #expect(!model.isRestoringFrameAlignments)
    }

    @Test("A failed saved-alignment replay stays visible and blocks scan readiness")
    @MainActor
    func failedRestoreBlocksScanning() async {
        let client = FrameAlignmentEngineStub(spacingErrorAtRequestIndex: 1)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if await client.recordedSpacingRequests().count == 1,
               !model.isRestoringFrameAlignments {
                break
            }
            await Task.yield()
        }

        #expect(model.failedFrameAlignmentRestoreIndices == [2])
        #expect(model.alignmentOffset(for: 2) == 0)
        #expect(model.thumbnails[2]?.spacingOffset == 0)
        #expect(model.frameAlignmentDrafts[2] == nil)
        #expect(model.lastErrorMessage?.contains("frame 2") == true)
        #expect(!model.scanReadiness(for: [2]).isReady)
        #expect(model.canNudgeFrameAlignment(2, by: 1))
    }

    @Test("Only a failed alignment frame remains eligible for detail recovery on its current complete preview")
    @MainActor
    func failedAlignmentRemainsNavigableWithoutAdmittingOtherOrStaleFrames() async {
        let client = FrameAlignmentEngineStub(spacingErrorAtRequestIndex: 1)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if model.failedFrameAlignmentRestoreIndices == [2] { break }
            await Task.yield()
        }

        #expect(!model.hasCompletePreviewRegistration)
        #expect(model.canPresentFrameDetail(2))
        #expect(!model.canPresentFrameDetail(1))

        await model.disconnect()

        #expect(!model.canPresentFrameDetail(2))
    }

    @Test("Retry reapplies a saved target that failed to bind to the preview")
    @MainActor
    func retryReappliesFailedSavedTarget() async {
        let client = FrameAlignmentEngineStub(spacingErrorAtRequestIndex: 1)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if model.failedFrameAlignmentRestoreIndices == [2] { break }
            await Task.yield()
        }

        await model.retryFrameAlignment(frameIndex: 2)

        #expect(await client.recordedSpacingRequests().count == 2)
        #expect(model.alignmentOffset(for: 2) == 5)
        #expect(model.thumbnails[2]?.spacingOffset == 5)
        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
        #expect(model.lastErrorMessage == nil)
        #expect(model.scanReadiness(for: [2]).isReady)
    }

    @Test("A successful manual adjustment resolves a failed saved-alignment replay")
    @MainActor
    func manualAdjustmentRecoversFailedRestore() async {
        let client = FrameAlignmentEngineStub(spacingErrorAtRequestIndex: 1)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if model.failedFrameAlignmentRestoreIndices == [2] { break }
            await Task.yield()
        }

        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)

        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
        #expect(model.alignmentOffset(for: 2) == 1)
        #expect(
            model.project?.frames.first(where: { $0.index == 2 })?.alignment
                == FrameAlignment(offsetRows: 1, approved: false)
        )
        #expect(model.lastErrorMessage == nil)
        #expect(model.scanReadiness(for: [2]).isReady)
    }

    @Test("Multiple saved offsets restore sequentially in frame order")
    @MainActor
    func savedAlignmentsRestoreSequentially() async {
        let client = FrameAlignmentEngineStub(holdSpacingResponses: true)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                3: FrameAlignment(offsetRows: -2, approved: false),
                2: FrameAlignment(offsetRows: 4, approved: false),
            ]
        )
        for _ in 0..<100 {
            if await client.recordedSpacingRequests().count == 1 { break }
            await Task.yield()
        }

        #expect(
            await client.recordedSpacingRequests().map(\.frameIndex) == [2]
        )
        #expect(model.frameAlignmentDrafts[2] == nil)
        #expect(model.frameAlignmentDrafts[3] == nil)

        await client.resumeSpacingResponses()
        for _ in 0..<100 {
            if await client.recordedSpacingRequests().count == 2 { break }
            await Task.yield()
        }

        #expect(
            await client.recordedSpacingRequests().map(\.frameIndex) == [2, 3]
        )
        #expect(
            model.frameAlignmentDrafts[2]
                == FrameAlignment(offsetRows: 4, approved: false)
        )
        #expect(model.frameAlignmentDrafts[3] == nil)
        #expect(model.isRestoringFrameAlignments)

        await client.resumeSpacingResponses()
        for _ in 0..<100 {
            if !model.isRestoringFrameAlignments { break }
            await Task.yield()
        }

        #expect(
            model.frameAlignmentDrafts[3]
                == FrameAlignment(offsetRows: -2, approved: false)
        )
        #expect(!model.isRestoringFrameAlignments)
        #expect(model.scanReadiness(for: [2, 3]).isReady)
    }

    @Test("A fresh preview retries and can recover a failed saved offset")
    @MainActor
    func freshPreviewRetriesFailedRestore() async throws {
        let client = FrameAlignmentEngineStub(spacingErrorAtRequestIndex: 1)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false)
            ]
        )
        for _ in 0..<100 {
            if model.failedFrameAlignmentRestoreIndices == [2] { break }
            await Task.yield()
        }

        let retryToken = PreviewIntentToken()
        let retry = await model.requestPreview(
            .refreshSavedProject(token: retryToken)
        )
        for frameIndex in 1...4 {
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(retryToken.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"imagePath":"/tmp/retry-frame-\#(frameIndex).tif","boundaryRows":[20,892],"spacingOffset":0,"needsApproval":false,"warnings":[]}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(retryToken.id.uuidString)","count":4}}"#.utf8
            )
        ))
        for _ in 0..<100 {
            if await client.recordedSpacingRequests().count == 2,
               !model.isRestoringFrameAlignments {
                break
            }
            await Task.yield()
        }

        let retryRequest = try #require(
            await client.recordedSpacingRequests().last
        )
        #expect(retry == .started)
        #expect(retryRequest.operationId == retryToken.id.uuidString)
        #expect(retryRequest.frameIndex == 2)
        #expect(retryRequest.offsetRows == 5)
        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
        #expect(model.alignmentOffset(for: 2) == 5)
        #expect(model.scanReadiness(for: [2]).isReady)
    }

    @Test("Unattempted saved offsets remain scan blockers after an earlier replay fails")
    @MainActor
    func unattemptedOffsetsRemainBlocked() async {
        let client = FrameAlignmentEngineStub(spacingErrorAtRequestIndex: 1)
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                2: FrameAlignment(offsetRows: 5, approved: false),
                3: FrameAlignment(offsetRows: -2, approved: false),
            ]
        )
        for _ in 0..<100 {
            if !model.failedFrameAlignmentRestoreIndices.isEmpty { break }
            await Task.yield()
        }

        #expect(model.failedFrameAlignmentRestoreIndices == [2, 3])
        #expect(
            await client.recordedSpacingRequests().map(\.frameIndex) == [2]
        )

        await model.nudgeFrameAlignment(frameIndex: 2, by: 1)

        #expect(model.failedFrameAlignmentRestoreIndices == [3])
        #expect(model.lastErrorMessage?.contains("frame 3") == true)
        #expect(!model.scanReadiness(for: [2, 3]).isReady)

        await model.nudgeFrameAlignment(frameIndex: 3, by: -1)

        #expect(model.failedFrameAlignmentRestoreIndices.isEmpty)
        #expect(model.scanReadiness(for: [2, 3]).isReady)
    }

    @Test("An out-of-bounds persisted offset fails closed before a bridge request")
    @MainActor
    func invalidPersistedOffsetIsNotReplayed() async {
        let client = FrameAlignmentEngineStub()
        let (model, _, _) = await preparedSavedProjectModel(
            client: client,
            alignments: [
                1: FrameAlignment(offsetRows: -1, approved: false)
            ]
        )
        for _ in 0..<100 {
            if !model.isRestoringFrameAlignments { break }
            await Task.yield()
        }

        #expect(await client.recordedSpacingRequests().isEmpty)
        #expect(model.failedFrameAlignmentRestoreIndices == [1])
        #expect(model.alignmentOffset(for: 1) == 0)
        #expect(!model.scanReadiness(for: [1]).isReady)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
