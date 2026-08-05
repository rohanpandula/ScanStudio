import Foundation
import Testing

@testable import ScanStudioKit

private enum BWFineScanStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private actor BWFineScanEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "bw-fine-scan-stub"

    let device: DeviceInfo
    let project: ScanProject
    private var scanStarts = 0

    init(kind: String, process: FilmProcess) {
        device = DeviceInfo(
            deviceId: "\(kind)-ls5000-0",
            model: "SUPER COOLSCAN 5000 ED",
            kind: kind,
            firmware: "test",
            connection: "USB",
            supported: true, supportedMultisamplePasses: kind == "real" ? [4] : nil
        )
        project = ScanProject(
            schemaVersion: 1,
            id: "\(kind)-\(process.rawValue)",
            name: "Fine scan capability",
            carrier: .mounted,
            frameCount: 1,
            filmProcess: process,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(
                    filenameTemplate: "Archive_####",
                    destination: "/tmp/bw-readiness/archive"
                ),
                positive: PositiveRecipe(
                    enabled: true,
                    fileFormat: .tiff,
                    colorProfile: .adobeRgb1998,
                    filenameTemplate: "Positive_####",
                    destination: "/tmp/bw-readiness/positive"
                ),
                preview: PreviewRecipe(
                    enabled: true,
                    fileFormat: .jpeg,
                    maxLongEdgePx: 1024,
                    filenameTemplate: "Preview_####",
                    destination: "/tmp/bw-readiness/preview"
                )
            ),
            rollMetadata: MetadataSet(),
            createdAt: "2026-07-27T00:00:00Z",
            frames: [ProjectFrame(index: 1, excluded: false, receipts: [])]
        )
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
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
                    frameCount: 1,
                    lamp: "stable",
                    transport: "idle",
                    activeJobId: nil,
                    filmPresent: true,
                    motionArmed: true
                )
            )
        case "project.open":
            value = ProjectOpenResult(project: project, directory: "/tmp/bw-readiness")
        case "project.pendingFrames":
            value = PendingFramesResult(
                frames: [1],
                totalFrames: 1,
                completedCount: 0,
                excludedCount: 0
            )
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: [1])
        case "scan.start":
            scanStarts += 1
            value = ScanStartResult(jobId: "unexpected-job")
        default:
            throw BWFineScanStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw BWFineScanStubError.unexpectedResultType
        }
        return result
    }

    func scanStartCount() -> Int { scanStarts }
}

@Suite("Live B&W fine-scan readiness")
struct BWFineScanReadinessTests {
    @MainActor
    private func preparedModel(
        kind: String,
        process: FilmProcess
    ) async -> (SessionModel, BWFineScanEngineStub) {
        let client = BWFineScanEngineStub(kind: kind, process: process)
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "\(kind)-ls5000-0")
        await model.openProject(directory: "/tmp/bw-readiness")
        let token = PreviewIntentToken()
        _ = await model.requestPreview(.refreshSavedProject(token: token))
        model.handle(event: EngineEvent(
            name: "scanner.thumbnail",
            rawLine: Data(
                #"{"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":{"imagePath":"/tmp/bw-readiness-thumb.tif"}}}"#.utf8
            )
        ))
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsComplete",
            rawLine: Data(
                #"{"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":1}}"#.utf8
            )
        ))
        return (model, client)
    }

    @Test("real B&W is blocked while real color and simulated B&W remain ready")
    @MainActor
    func capabilityMatrix() async {
        let (realBW, _) = await preparedModel(kind: "real", process: .bwNegative)
        #expect(realBW.scanReadiness(for: [1]) == .fineScanUnsupported)

        let (realColor, _) = await preparedModel(
            kind: "real",
            process: .c41ColorNegative
        )
        #expect(realColor.scanReadiness(for: [1]) == .ready)

        let (simulatedBW, _) = await preparedModel(
            kind: "simulated",
            process: .bwNegative
        )
        #expect(simulatedBW.scanReadiness(for: [1]) == .ready)
    }

    @Test("batch, single-frame, retry path, and resume never send scan.start for real B&W")
    @MainActor
    func everyScanEntryPointHasASecondGuard() async {
        let (model, client) = await preparedModel(kind: "real", process: .bwNegative)
        model.toggleFrameSelection(1)

        await model.startMockScan()
        #expect(await client.scanStartCount() == 0)
        #expect(model.lastErrorMessage == ScanReadinessPolicy.Decision.fineScanUnsupported.reason)

        await model.scanSingleFrame(1)
        #expect(await client.scanStartCount() == 0)

        await model.resumeBatch()
        #expect(await client.scanStartCount() == 0)
        #expect(model.lastErrorMessage == ScanReadinessPolicy.Decision.fineScanUnsupported.reason)
    }
}
