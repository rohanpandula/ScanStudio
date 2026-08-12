import Foundation
import Testing

@testable import ScanStudioKit

private enum MetadataAuthorizationStubError: Error {
    case unexpectedMethod(String)
    case unexpectedParams(String)
    case unexpectedResultType
}

private struct CapturedMetadataApply: Sendable {
    let frameIndex: Int
    let previewFingerprint: String
}

private actor MetadataAuthorizationEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent>
    var engineVersion: String? = "metadata-authorization-stub"

    private let project: ScanProject
    private let holdsPreview: Bool
    private var applyRequests: [CapturedMetadataApply] = []
    private var previewRequestStarted = false
    private var previewStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var previewReleaseContinuation: CheckedContinuation<Void, Never>?

    init(
        project: ScanProject = metadataAuthorizationProject(),
        holdsPreview: Bool = false
    ) {
        self.project = project
        self.holdsPreview = holdsPreview
        self.events = AsyncStream { _ in }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        let value: any Sendable
        switch method {
        case "project.previewMetadataCommand":
            guard let params = params as? PreviewMetadataCommandParams,
                  params.frameIndex == 2
            else {
                throw MetadataAuthorizationStubError.unexpectedParams(method)
            }
            await waitForPreviewReleaseIfNeeded()
            value = PreviewMetadataCommandResult(
                available: true,
                exiftoolPath: "/usr/bin/exiftool",
                targets: ["/tmp/metadata-preview/Preview_0002.jpg"],
                arguments: [
                    "-Title=First Project",
                    "-overwrite_original",
                    "/tmp/metadata-preview/Preview_0002.jpg",
                ],
                fingerprint: "metadata-preview-fingerprint"
            )
        case "project.applyMetadata":
            guard let params = params as? ApplyMetadataParams else {
                throw MetadataAuthorizationStubError.unexpectedParams(method)
            }
            applyRequests.append(
                CapturedMetadataApply(
                    frameIndex: params.frameIndex,
                    previewFingerprint: params.previewFingerprint
                )
            )
            value = ApplyMetadataResult(
                success: true,
                exitCode: 0,
                stdout: "1 image files updated",
                stderr: "",
                targets: ["/tmp/metadata-preview/Preview_0002.jpg"],
                arguments: [
                    "-Title=First Project",
                    "-overwrite_original",
                    "/tmp/metadata-preview/Preview_0002.jpg",
                ],
                fingerprint: "metadata-preview-fingerprint"
            )
        case "project.setRollMetadata",
             "project.setFrameMetadataOverride",
             "project.setFrameOutputOverride":
            value = SetFrameResult(project: project)
        default:
            throw MetadataAuthorizationStubError.unexpectedMethod(method)
        }

        guard let result = value as? Result else {
            throw MetadataAuthorizationStubError.unexpectedResultType
        }
        return result
    }

    func capturedApplyRequests() -> [CapturedMetadataApply] {
        applyRequests
    }

    func waitUntilPreviewRequestStarts() async {
        if previewRequestStarted {
            return
        }
        await withCheckedContinuation { continuation in
            previewStartWaiters.append(continuation)
        }
    }

    func releasePreviewRequest() {
        previewReleaseContinuation?.resume()
        previewReleaseContinuation = nil
    }

    private func waitForPreviewReleaseIfNeeded() async {
        guard holdsPreview else { return }
        previewRequestStarted = true
        let waiters = previewStartWaiters
        previewStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            previewReleaseContinuation = continuation
        }
    }
}

@Suite("Metadata preview authorization")
struct MetadataPreviewAuthorizationTests {
    @Test("wire models carry the engine-minted metadata preview fingerprint")
    func wireModelsCarryFingerprint() throws {
        let preview = try JSONDecoder().decode(
            PreviewMetadataCommandResult.self,
            from: Data(
                #"{"available":true,"exiftoolPath":"/usr/bin/exiftool","targets":["/tmp/Preview_0002.jpg"],"arguments":["-Title=First Project"],"fingerprint":"preview-fingerprint"}"#.utf8
            )
        )
        #expect(preview.fingerprint == "preview-fingerprint")

        let params = ApplyMetadataParams(
            frameIndex: 2,
            previewFingerprint: preview.fingerprint
        )
        let paramsObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(params)
        ) as? [String: Any]
        #expect(paramsObject?["frameIndex"] as? Int == 2)
        #expect(paramsObject?["previewFingerprint"] as? String == "preview-fingerprint")

        let result = try JSONDecoder().decode(
            ApplyMetadataResult.self,
            from: Data(
                #"{"success":true,"exitCode":0,"stdout":"ok","stderr":"","targets":["/tmp/Preview_0002.jpg"],"arguments":["-Title=First Project"],"fingerprint":"preview-fingerprint"}"#.utf8
            )
        )
        #expect(result.arguments == ["-Title=First Project"])
        #expect(result.fingerprint == "preview-fingerprint")
    }

    @Test("preview then apply sends the exact displayed command fingerprint once")
    @MainActor
    func previewThenApplySendsExactFingerprintOnce() async {
        let client = MetadataAuthorizationEngineStub()
        let model = SessionModel(engineClient: client)

        await model.previewMetadataCommand(2)
        #expect(model.metadataPreview?.fingerprint == "metadata-preview-fingerprint")
        #expect(model.metadataPreview?.targets == ["/tmp/metadata-preview/Preview_0002.jpg"])

        let result = await model.applyMetadata(2)
        #expect(result?.success == true)
        #expect(result?.fingerprint == "metadata-preview-fingerprint")
        #expect(await client.capturedApplyRequests().count == 1)
        #expect(await client.capturedApplyRequests().first?.frameIndex == 2)
        #expect(
            await client.capturedApplyRequests().first?.previewFingerprint
                == "metadata-preview-fingerprint"
        )

        let replay = await model.applyMetadata(2)
        #expect(replay == nil)
        #expect(await client.capturedApplyRequests().count == 1)
        #expect(model.lastErrorMessage?.contains("Preview") == true)
    }

    @Test("apply without a preview fails closed before reaching the engine")
    @MainActor
    func applyWithoutPreviewFailsClosed() async {
        let client = MetadataAuthorizationEngineStub()
        let model = SessionModel(engineClient: client)

        let result = await model.applyMetadata(2)

        #expect(result == nil)
        #expect(await client.capturedApplyRequests().isEmpty)
        #expect(model.lastErrorMessage?.contains("Preview") == true)
    }

    @Test("roll metadata changes invalidate a displayed metadata preview")
    @MainActor
    func rollMetadataChangeInvalidatesPreview() async {
        let client = MetadataAuthorizationEngineStub()
        let model = SessionModel(engineClient: client)

        await model.previewMetadataCommand(2)
        await model.setRollMetadata(MetadataSet(camera: "Nikon F3"))
        let result = await model.applyMetadata(2)

        #expect(model.metadataPreview == nil)
        #expect(result == nil)
        #expect(await client.capturedApplyRequests().isEmpty)
    }

    @Test("frame metadata and output target changes invalidate the matching preview")
    @MainActor
    func frameMetadataAndTargetChangesInvalidatePreview() async {
        let client = MetadataAuthorizationEngineStub()
        let model = SessionModel(engineClient: client)

        await model.previewMetadataCommand(2)
        await model.setFrameMetadataOverride(2, to: MetadataSet(lens: "50mm f/1.4"))
        #expect(model.metadataPreview == nil)
        #expect(await model.applyMetadata(2) == nil)

        await model.previewMetadataCommand(2)
        await model.setFrameOutputOverride(2, to: metadataAuthorizationOutputRecipe())
        #expect(model.metadataPreview == nil)
        #expect(await model.applyMetadata(2) == nil)
        #expect(await client.capturedApplyRequests().isEmpty)
    }

    @Test("an in-flight preview cannot resurrect after metadata changes")
    @MainActor
    func inFlightPreviewCannotResurrectAfterMetadataChange() async {
        let client = MetadataAuthorizationEngineStub(holdsPreview: true)
        let model = SessionModel(engineClient: client)
        let previewTask = Task { @MainActor in
            await model.previewMetadataCommand(2)
        }

        await client.waitUntilPreviewRequestStarts()
        await model.setRollMetadata(MetadataSet(camera: "Nikon F3"))
        await client.releasePreviewRequest()
        await previewTask.value

        #expect(model.metadataPreview == nil)
        #expect(await model.applyMetadata(2) == nil)
        #expect(await client.capturedApplyRequests().isEmpty)
    }
}

private func metadataAuthorizationProject() -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "metadata-preview-project",
        name: "Metadata Preview",
        carrier: .strip6,
        frameCount: 6,
        filmProcess: .c41ColorNegative,
        recipes: metadataAuthorizationOutputRecipe(),
        rollMetadata: MetadataSet(camera: "Nikon F100"),
        createdAt: "2026-08-11T00:00:00Z",
        frames: (1...6).map {
            ProjectFrame(index: $0, excluded: false, receipts: [])
        }
    )
}

private func metadataAuthorizationOutputRecipe() -> OutputRecipe {
    OutputRecipe(
        archive: ArchiveRecipe(
            filenameTemplate: "Archive_####",
            destination: "/tmp/metadata-preview/Archive"
        ),
        positive: PositiveRecipe(
            enabled: true,
            fileFormat: .tiff,
            colorProfile: .adobeRgb1998,
            filenameTemplate: "Positive_####",
            destination: "/tmp/metadata-preview/Positive"
        ),
        preview: PreviewRecipe(
            enabled: true,
            fileFormat: .jpeg,
            maxLongEdgePx: 1_024,
            filenameTemplate: "Preview_####",
            destination: "/tmp/metadata-preview/Preview"
        )
    )
}
