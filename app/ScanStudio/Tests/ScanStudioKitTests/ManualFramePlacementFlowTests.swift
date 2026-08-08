import Foundation
import Testing

@testable import ScanStudioKit

private enum ManualPlacementStubError: Error {
    case unexpectedMethod(String)
    case unexpectedParams(String)
    case unexpectedResultType
}

private struct ApprovalCall: Equatable, Sendable {
    let frameIndex: Int
    let operationId: String
}

/// Minimal `EngineClientProtocol` double covering exactly the methods
/// `SessionModel`'s manual-placement flow touches
/// (FEEDING-UX-LADDER-OVERNIGHT-20260807.md, Rung 4): `scanner.list`/
/// `scanner.connect` (`SessionModel.init` and `connect(deviceId:)` need
/// them regardless of what's under test -- same shape as
/// `ManualReviewApprovalEngineStub` in `ManualReviewApprovalTests.swift`),
/// `roll.previewStrip`, `roll.manualFrames`, and `roll.approve` (to prove
/// the frames a placement returns are approvable through the pre-existing,
/// separately-tested approval path with no further wiring).
private actor ManualPlacementEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "manual-placement-stub"

    private let device = DeviceInfo(
        deviceId: "real-ls5000-manual-placement-test",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supported: true, supportedMultisamplePasses: [4]
    )
    /// `scanReadiness` requires an open project before it will even compute
    /// manual-review requirements -- only needed by tests that drive
    /// `startMockScan()` all the way through (S2's regression test).
    private let project = ScanProject(
        schemaVersion: 1,
        id: "manual-placement-project",
        name: "Manual placement flow",
        carrier: .roll36,
        frameCount: 36,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/manual-placement-flow/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/manual-placement-flow/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/manual-placement-flow/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-08-08T00:00:00Z",
        frames: (1...36).map { ProjectFrame(index: $0, excluded: false, receipts: []) }
    )
    private let previewStripResult: PreviewStripResult
    private let previewStripError: EngineRequestError?
    private let manualFramesError: EngineRequestError?
    /// Successive `roll.manualFrames` results, one consumed per successful
    /// call -- lets a single test drive two materially different
    /// placements (S2's own "placement A, then placement B" regression
    /// scenario) without needing a second stub instance. A single-result
    /// test can keep using the `manualFramesResult:` init param below.
    private var manualFramesResultQueue: [RollManualFramesResult]
    private(set) var manualFramesRowsRequested: [[Int]] = []
    private(set) var previewStripRequestCount = 0
    private(set) var approvals: [ApprovalCall] = []
    private(set) var scanStartCallCount = 0

    init(
        previewStripResult: PreviewStripResult = PreviewStripResult(
            imagePath: "/tmp/manual-placement-strip.tif",
            rowCount: 4_800,
            pixelsPerRow: 1
        ),
        previewStripError: EngineRequestError? = nil,
        manualFramesResult: RollManualFramesResult? = nil,
        manualFramesResults: [RollManualFramesResult] = [],
        manualFramesError: EngineRequestError? = nil
    ) {
        self.previewStripResult = previewStripResult
        self.previewStripError = previewStripError
        self.manualFramesResultQueue =
            manualFramesResults.isEmpty ? [manualFramesResult].compactMap { $0 } : manualFramesResults
        self.manualFramesError = manualFramesError
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
                    frameCount: 36,
                    lamp: "stable",
                    transport: "idle",
                    activeJobId: nil,
                    filmPresent: true,
                    motionArmed: true
                )
            )
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: [1, 2, 3])
        case "project.open":
            value = ProjectOpenResult(project: project, directory: "/tmp/manual-placement-flow")
        case "roll.previewStrip":
            previewStripRequestCount += 1
            if let previewStripError { throw previewStripError }
            value = previewStripResult
        case "roll.manualFrames":
            guard let params = params as? RollManualFramesParams else {
                throw ManualPlacementStubError.unexpectedParams(method)
            }
            manualFramesRowsRequested.append(params.rows)
            if let manualFramesError { throw manualFramesError }
            guard !manualFramesResultQueue.isEmpty else {
                throw ManualPlacementStubError.unexpectedMethod(
                    "roll.manualFrames result not configured for this test"
                )
            }
            value = manualFramesResultQueue.removeFirst()
        case "roll.approve":
            guard let params = params as? RollApproveParams else {
                throw ManualPlacementStubError.unexpectedParams(method)
            }
            approvals.append(ApprovalCall(frameIndex: params.frameIndex, operationId: params.operationId))
            value = EmptyResult()
        case "scan.start":
            scanStartCallCount += 1
            value = ScanStartResult(jobId: "should-never-be-reached")
        default:
            throw ManualPlacementStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw ManualPlacementStubError.unexpectedResultType
        }
        return result
    }
}

@Suite("Manual frame placement flow")
struct ManualFramePlacementFlowTests {
    private static func sampleResult(
        operationId: String = "manual-42",
        snaps: [BoundarySnap] = []
    ) -> RollManualFramesResult {
        RollManualFramesResult(
            count: 2,
            fingerprint: "manual-fp",
            operationId: operationId,
            thumbnails: [
                ManualFrameThumbnail(
                    frameIndex: 1,
                    thumbnail: Thumbnail(
                        brightness: nil,
                        tint: nil,
                        imagePath: "/tmp/manual-slot-0001.tif",
                        boundaryRows: [0, 200],
                        spacingOffset: 0,
                        needsApproval: true,
                        warnings: ["user-picked"]
                    )
                ),
                ManualFrameThumbnail(
                    frameIndex: 2,
                    thumbnail: Thumbnail(
                        brightness: nil,
                        tint: nil,
                        imagePath: "/tmp/manual-slot-0002.tif",
                        boundaryRows: [200, 400],
                        spacingOffset: 0,
                        needsApproval: true,
                        warnings: ["user-picked"]
                    )
                ),
            ],
            snaps: snaps
        )
    }

    @MainActor
    private func connectedModel(
        client: ManualPlacementEngineStub
    ) async -> SessionModel {
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-ls5000-manual-placement-test")
        return model
    }

    @Test("beginManualFramePlacement populates the strip from roll.previewStrip")
    @MainActor
    func beginPopulatesStrip() async {
        let client = ManualPlacementEngineStub()
        let model = await connectedModel(client: client)

        await model.beginManualFramePlacement()

        #expect(
            model.manualPlacementStripState
                == .ready(
                    ManualPlacementStrip(
                        imagePath: "/tmp/manual-placement-strip.tif",
                        rowCount: 4_800,
                        pixelsPerRow: 1
                    )
                )
        )
        #expect(await client.previewStripRequestCount == 1)
    }

    @Test("a roll.previewStrip failure resets to idle and reports through lastErrorMessage")
    @MainActor
    func beginSurfacesPreviewStripFailure() async {
        let client = ManualPlacementEngineStub(
            previewStripError: EngineRequestError(
                code: "NO_PREVIEW",
                message: "roll.previewStrip requires a completed roll.preview attempt first",
                recoverable: false
            )
        )
        let model = await connectedModel(client: client)

        await model.beginManualFramePlacement()

        #expect(model.manualPlacementStripState == .idle)
        #expect(model.lastErrorMessage?.contains("NO_PREVIEW") == true)
    }

    @Test("a successful submit populates thumbnails, binds the operationId, and clears refeed/error state")
    @MainActor
    func submitPopulatesThumbnailsAndOperationId() async {
        let client = ManualPlacementEngineStub(manualFramesResult: Self.sampleResult())
        let model = await connectedModel(client: client)
        await model.beginManualFramePlacement()

        // Simulate the exact state a REFEED_REQUIRED preview failure would
        // have left behind -- the situation "Place frames manually" exists
        // to resolve. A real preview must be started first: `refeedRequired`
        // is only set inside `scanner.thumbnailsFailed`'s handler, which is
        // itself gated on the preview intent state machine recognizing a
        // currently-active operation for this exact `operationId`.
        let token = PreviewIntentToken()
        let outcome = await model.requestPreview(.initial(token: token))
        #expect(outcome == .started)
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsFailed","payload":{"code":"REFEED_REQUIRED","message":"eject or refeed","operationId":"\#(token.id.uuidString)"}}"#.utf8
            )
        ))
        #expect(model.refeedRequired == true)

        let succeeded = await model.submitManualFrames(rows: [0, 200, 400])

        #expect(succeeded)
        #expect(await client.manualFramesRowsRequested == [[0, 200, 400]])
        #expect(model.thumbnails[1]?.needsApproval == true)
        #expect(model.thumbnails[1]?.warnings == ["user-picked"])
        #expect(model.thumbnails[1]?.boundaryRows == [0, 200])
        #expect(model.thumbnails[2]?.needsApproval == true)
        #expect(model.latestCompletedPreviewOperationId == "manual-42")
        #expect(model.refeedRequired == false)
        #expect(model.lastErrorMessage == nil)
        #expect(model.manualPlacementStripState == .idle)
        #expect(model.manualPlacementSubmitError == nil)
    }

    @Test("snaps produce a subtle one-line note; no snaps produce none")
    @MainActor
    func snapNoteReflectsReturnedSnaps() async {
        let snap = BoundarySnap(boundaryIndex: 0, requestedRow: 100, snappedRow: 102, evidenceRun: [98, 106])
        let client = ManualPlacementEngineStub(
            manualFramesResult: Self.sampleResult(snaps: [snap])
        )
        let model = await connectedModel(client: client)
        await model.beginManualFramePlacement()

        _ = await model.submitManualFrames(rows: [0, 200, 400])

        #expect(model.manualPlacementSnapNote?.contains("1 boundary line") == true)

        // A second placement with no snaps must not leave the old note behind.
        let noSnapClient = ManualPlacementEngineStub(manualFramesResult: Self.sampleResult(snaps: []))
        let secondModel = await connectedModel(client: noSnapClient)
        await secondModel.beginManualFramePlacement()
        _ = await secondModel.submitManualFrames(rows: [0, 200, 400])
        #expect(secondModel.manualPlacementSnapNote == nil)
    }

    @Test("INVALID_PARAMS keeps the editor open and surfaces the message inline, never dismissing it")
    @MainActor
    func invalidParamsKeepsEditorOpen() async {
        let client = ManualPlacementEngineStub(
            manualFramesError: EngineRequestError(
                code: "INVALID_PARAMS",
                message: "the 1st frame you placed is about 8 mm tall (between rows 10 and 40), "
                    + "outside the 15-75 mm range this driver accepts for manual placement",
                recoverable: false
            )
        )
        let model = await connectedModel(client: client)
        await model.beginManualFramePlacement()
        guard case .ready = model.manualPlacementStripState else {
            Issue.record("expected the strip to be ready before submit")
            return
        }

        let succeeded = await model.submitManualFrames(rows: [10, 40])

        #expect(!succeeded)
        #expect(model.manualPlacementSubmitError?.contains("INVALID_PARAMS") == true)
        #expect(model.manualPlacementSubmitError?.contains("outside the 15-75 mm range") == true)
        // The whole point: a rejected submit must NOT dismiss the editor --
        // the strip stays `.ready` so the operator can adjust and retry.
        guard case .ready = model.manualPlacementStripState else {
            Issue.record("a rejected submit must not reset the editor to idle")
            return
        }
        #expect(model.thumbnails.isEmpty, "a rejected placement must never populate thumbnails")
    }

    @Test("S2: a 'Use anyway' decision from placement A never survives into placement B")
    @MainActor
    func useAnywayDecisionDoesNotSurviveAReplacementPlacement() async {
        let placementA = Self.sampleResult(operationId: "manual-A")
        let placementB = Self.sampleResult(operationId: "manual-B")
        let client = ManualPlacementEngineStub(manualFramesResults: [placementA, placementB])
        let model = await connectedModel(client: client)
        // `scanReadiness` (and therefore `startMockScan()` below) requires
        // an open project before it will compute manual-review
        // requirements at all.
        await model.openProject(directory: "/tmp/manual-placement-flow")

        // Placement A: submit, then the operator explicitly confirms BOTH
        // resulting frames (every manually-placed frame arrives
        // `needsApproval: true` per BRIDGE.md) with "Use anyway".
        await model.beginManualFramePlacement()
        let succeededA = await model.submitManualFrames(rows: [0, 200, 400])
        #expect(succeededA)
        #expect(model.latestCompletedPreviewOperationId == "manual-A")
        for frameIndex in [1, 2] {
            let decided = model.decideManualReview(
                .useFrameAnyway,
                for: frameIndex,
                previewOperationId: "manual-A"
            )
            #expect(decided)
        }
        #expect(model.manualReviewDecision(for: 1) == .useFrameAnyway)
        #expect(model.manualReviewDecision(for: 2) == .useFrameAnyway)

        // Placement B: a materially different placement (different rows,
        // different operationId) that happens to reuse the same slot
        // numbers -- both frames arrive needsApproval: true again here too.
        await model.beginManualFramePlacement()
        let succeededB = await model.submitManualFrames(rows: [0, 180, 420])
        #expect(succeededB)
        #expect(model.latestCompletedPreviewOperationId == "manual-B")

        // Neither decision from A survived onto B.
        #expect(model.manualReviewDecision(for: 1) == nil)
        #expect(model.manualReviewDecision(for: 2) == nil)

        // The proof that matters: starting a scan for B must require a
        // fresh confirmation for BOTH frames -- never auto-approving off
        // A's stale decisions, and never reaching scan.start without it.
        // Select exactly the two frames placement B actually produced
        // (`selectAllFrames()` would select the whole nominal 36-frame
        // roll, most of which has no thumbnail from this 2-frame manual
        // placement, and fail readiness for an unrelated reason).
        model.clearFrameSelection()
        model.selectFrame(1, extendingSelectionIfShiftHeld: false)
        model.selectFrame(2, extendingSelectionIfShiftHeld: true)
        await model.startMockScan()
        #expect(model.pendingManualReviewScan?.requirements.map(\.frameIndex) == [1, 2])
        #expect(model.jobId == nil)
        #expect(await client.scanStartCallCount == 0)
    }

    @Test("the frames a placement returns are approvable through the existing roll.approve path")
    @MainActor
    func resultingFramesAreApprovable() async {
        let client = ManualPlacementEngineStub(manualFramesResult: Self.sampleResult())
        let model = await connectedModel(client: client)
        await model.beginManualFramePlacement()
        _ = await model.submitManualFrames(rows: [0, 200, 400])

        #expect(model.latestCompletedPreviewOperationId == "manual-42")
    }
}
