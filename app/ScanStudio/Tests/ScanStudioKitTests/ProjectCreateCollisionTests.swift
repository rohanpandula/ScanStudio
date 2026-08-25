import Foundation
import Testing

@testable import ScanStudioKit

private enum ProjectCollisionStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private actor ProjectCollisionEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "project-collision-stub"
    private var methods: [String] = []

    private let existing = ScanProject(
        schemaVersion: 4,
        id: "existing-zero-receipt-project",
        name: "Existing roll",
        carrier: .strip6,
        frameCount: 3,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/existing/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/existing/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/existing/preview"
            )
        ),
        rollMetadata: MetadataSet(filmStock: "Existing metadata"),
        createdAt: "2026-08-23T00:00:00Z",
        frames: [
            ProjectFrame(index: 1, excluded: false, receipts: []),
            ProjectFrame(index: 2, excluded: true, receipts: []),
            ProjectFrame(index: 3, excluded: false, receipts: []),
        ]
    )

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        methods.append(method)
        let value: any Sendable
        switch method {
        case "scanner.list":
            value = ScannerListResult(devices: [])
        case "project.open":
            value = ProjectOpenResult(
                project: existing,
                directory: "/tmp/existing"
            )
        case "project.create":
            throw EngineRequestError(
                code: "PROJECT_ALREADY_EXISTS",
                message: "manifest.json already exists; open the existing roll or choose a new name",
                recoverable: false
            )
        default:
            throw ProjectCollisionStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw ProjectCollisionStubError.unexpectedResultType
        }
        return result
    }

    func calledMethods() -> [String] { methods }
}

@Suite("Create versus open project behavior")
struct ProjectCreateCollisionTests {
    @Test("typed create collision leaves the open zero-receipt project intact and gives an actionable open-existing remedy")
    @MainActor
    func createCollisionPreservesOpenProject() async {
        let client = ProjectCollisionEngineStub()
        let model = SessionModel(engineClient: client)
        await model.openProject(directory: "/tmp/existing")
        let before = model.project

        await model.createProject(
            name: "Replacement roll",
            carrier: .strip6,
            frameCount: 3,
            filmProcess: .c41ColorNegative
        )

        #expect(model.project == before)
        #expect(model.projectDirectory == "/tmp/existing")
        #expect(model.project?.frames[1].excluded == true)
        #expect(model.lastErrorMessage?.hasPrefix("PROJECT_ALREADY_EXISTS:") == true)
        #expect(model.errorPresentation?.title == "That folder already has a project")
        #expect(model.errorPresentation?.guidance.contains("Open Recent") == true)
        #expect(await client.calledMethods().filter { $0 == "project.open" }.count == 1)
        #expect(await client.calledMethods().filter { $0 == "project.create" }.count == 1)
    }
}
