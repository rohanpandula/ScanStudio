import Foundation
import Testing

@testable import ScanStudioKit

private enum SaveRollScanStubError: Error {
    case unexpectedMethod(String)
    case unexpectedParams(String)
    case unexpectedResultType
}

private enum SaveRollScanCall: Equatable, Sendable {
    case createProject
    case approve(frameIndex: Int)
    case startScan(frames: [Int])
}

private actor SaveRollScanEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "save-roll-scan-stub"

    private let device = DeviceInfo(
        deviceId: "sim-save-roll",
        model: "LS-5000 simulator",
        kind: "simulated",
        firmware: "test",
        connection: "in-process",
        supportedMultisamplePasses: [1, 2, 4, 8, 16]
    )
    private let project = ScanProject(
        schemaVersion: 1,
        id: "saved-six-frame-roll",
        name: "Saved six-frame roll",
        carrier: .strip6,
        frameCount: 6,
        filmProcess: .positive,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/saved-six-frame-roll/Archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/saved-six-frame-roll/Positive"
            ),
            preview: PreviewRecipe(
                enabled: false,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/saved-six-frame-roll/Preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-08-02T00:00:00Z",
        frames: (1...6).map {
            ProjectFrame(index: $0, excluded: false, receipts: [])
        }
    )
    private var recordedCalls: [SaveRollScanCall] = []
    private let createError: EngineRequestError?
    private let scanStartError: EngineRequestError?

    init(
        createError: EngineRequestError? = nil,
        scanStartError: EngineRequestError? = nil
    ) {
        self.createError = createError
        self.scanStartError = scanStartError
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
                    adapter: nil,
                    mediaLoaded: false,
                    carrier: nil,
                    frameCount: nil,
                    lamp: "stable",
                    transport: "idle",
                    activeJobId: nil
                )
            )
        case "sim.loadMedia":
            value = ScannerStatus(
                connected: true,
                adapter: "SA-21 (simulated)",
                mediaLoaded: true,
                carrier: "strip6",
                frameCount: 6,
                lamp: "stable",
                transport: "idle",
                activeJobId: nil
            )
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: Array(1...6))
        case "project.create":
            recordedCalls.append(.createProject)
            if let createError { throw createError }
            value = ProjectCreateResult(
                project: project,
                directory: "/tmp/saved-six-frame-roll"
            )
        case "roll.approve":
            guard let params = params as? RollApproveParams else {
                throw SaveRollScanStubError.unexpectedParams(method)
            }
            recordedCalls.append(.approve(frameIndex: params.frameIndex))
            value = EmptyResult()
        case "scan.start":
            guard let params = params as? ScanStartParams else {
                throw SaveRollScanStubError.unexpectedParams(method)
            }
            recordedCalls.append(.startScan(frames: params.frames))
            if let scanStartError { throw scanStartError }
            value = ScanStartResult(jobId: "saved-roll-job")
        default:
            throw SaveRollScanStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw SaveRollScanStubError.unexpectedResultType
        }
        return result
    }

    func calls() -> [SaveRollScanCall] { recordedCalls }
}

@Suite("Save Roll and scan flow")
struct SaveRollScanFlowTests {
    @MainActor
    private func preparedModel(
        flaggedFrames: Set<Int> = [],
        client: SaveRollScanEngineStub = SaveRollScanEngineStub()
    ) async -> (SessionModel, SaveRollScanEngineStub) {
        let suiteName = "SaveRollScanFlowTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        let model = SessionModel(
            engineClient: client,
            preferences: preferences
        )

        await model.connect(deviceId: "sim-save-roll")
        await model.loadCarrier(.strip6)
        model.scanFilmProcess = .positive
        let token = PreviewIntentToken()
        #expect(await model.requestPreview(.initial(token: token)) == .started)
        for frameIndex in 1...6 {
            let reviewEvidence = flaggedFrames.contains(frameIndex)
                ? #","needsApproval":true,"warnings":["ambiguous-boundary"]"#
                : ""
            model.handle(event: EngineEvent(
                name: "scanner.thumbnail",
                rawLine: Data(
                    #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":\#(frameIndex),"thumbnail":{"brightness":0.5,"tint":0.0\#(reviewEvidence)}}}"#.utf8
                )
            ))
        }
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":6}}"#.utf8
            )
        ))
        model.selectAllFrames()
        return (model, client)
    }

    @Test("saving a completed six-frame preview starts the original selection exactly once")
    @MainActor
    func saveRollStartsSelectedFrames() async {
        let (model, client) = await preparedModel()

        let continued = await model.saveRollAndScanSelectedFrames(
            name: "Saved six-frame roll",
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )

        #expect(model.lastErrorMessage == nil)
        #expect(continued)
        #expect(await client.calls() == [
            .createProject,
            .startScan(frames: [1, 2, 3, 4, 5, 6]),
        ])
        #expect(model.jobId == "saved-roll-job")
    }

    @Test("Save Roll opens review for the original six before one scan")
    @MainActor
    func saveRollContinuesIntoBoundaryReview() async {
        let (model, client) = await preparedModel(flaggedFrames: [1, 6])

        let continued = await model.saveRollAndScanSelectedFrames(
            name: "Saved six-frame roll",
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )

        #expect(continued)
        #expect(await client.calls() == [.createProject])
        #expect(model.pendingManualReviewScan?.frames == [1, 2, 3, 4, 5, 6])
        #expect(
            model.pendingManualReviewScan?.requirements.map(\.frameIndex)
                == [1, 6]
        )
        #expect(model.jobId == nil)

        await model.approvePendingManualReviewAndStart()

        #expect(await client.calls() == [
            .createProject,
            .approve(frameIndex: 1),
            .approve(frameIndex: 6),
            .startScan(frames: [1, 2, 3, 4, 5, 6]),
        ])
        #expect(model.jobId == "saved-roll-job")
    }

    @Test("project creation failure never reaches scan.start")
    @MainActor
    func saveRollCreationFailureStopsBeforeScan() async {
        let client = SaveRollScanEngineStub(
            createError: EngineRequestError(
                code: "IO_ERROR",
                message: "cannot create project",
                recoverable: true
            )
        )
        let (model, _) = await preparedModel(client: client)

        let continued = await model.saveRollAndScanSelectedFrames(
            name: "Saved six-frame roll",
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )

        #expect(continued == false)
        #expect(model.project == nil)
        #expect(model.lastErrorMessage != nil)
        #expect(await client.calls() == [.createProject])
    }

    @Test("scan-start failure keeps the newly saved roll open for a retry")
    @MainActor
    func savedRollSurvivesScanStartFailure() async {
        let client = SaveRollScanEngineStub(
            scanStartError: EngineRequestError(
                code: "SCAN_REFUSED",
                message: "scan could not start",
                recoverable: true
            )
        )
        let (model, _) = await preparedModel(client: client)

        let continued = await model.saveRollAndScanSelectedFrames(
            name: "Saved six-frame roll",
            carrier: .strip6,
            frameCount: 6,
            filmProcess: .positive
        )

        #expect(continued == false)
        #expect(model.project?.id == "saved-six-frame-roll")
        #expect(model.lastErrorMessage != nil)
        #expect(await client.calls() == [
            .createProject,
            .startScan(frames: [1, 2, 3, 4, 5, 6]),
        ])
    }
}
