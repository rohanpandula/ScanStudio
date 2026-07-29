import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Preview film-process lifecycle")
struct PreviewProcessLifecyclePolicyTests {
    @Test("selected B&W process and operation ID are encoded in an additive preview request")
    func selectedBwIsEncoded() throws {
        let data = try JSONEncoder().encode(
            AcquireThumbnailsParams(
                frames: nil,
                filmProcess: .bwNegative,
                operationId: "preview-op-123"
            )
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["filmProcess"] as? String == "bwNegative")
        #expect(object?["operationId"] as? String == "preview-op-123")
    }

    @Test("preview event payloads decode their exact operation ID")
    func previewEventPayloadsDecodeOperationId() throws {
        let data = Data(
            """
            {
              "event": "scanner.thumbnailsComplete",
              "payload": {
                "count": 3,
                "operationId": "preview-op-456"
              }
            }
            """.utf8
        )
        let event = try JSONDecoder().decode(
            EventEnvelope<ThumbnailsCompletePayload>.self,
            from: data
        )

        #expect(event.payload.count == 3)
        #expect(event.payload.operationId == "preview-op-456")
    }

    @Test("only completion commits; failure or media reset leaves no established process")
    func completionAndFailureLifecycle() {
        let pending = PreviewProcessLifecyclePolicy.requestProcess(projectProcess: nil, selectedProcess: .bwNegative)
        #expect(PreviewProcessLifecyclePolicy.commitAfterCompletion(pending: pending) == .bwNegative)
        #expect(PreviewProcessLifecyclePolicy.clearAfterFailureOrMediaReset() == nil)
    }

    @Test("pending is chosen before completion, so an event arriving before request continuation is safe")
    func completionBeforeRequestContinuationIsSafe() {
        let pending = PreviewProcessLifecyclePolicy.requestProcess(projectProcess: nil, selectedProcess: .bwNegative)
        #expect(PreviewProcessLifecyclePolicy.commitAfterCompletion(pending: pending) == .bwNegative)
    }

    @Test("existing project remains authoritative for a refresh")
    func projectProcessWinsForRefresh() {
        #expect(PreviewProcessLifecyclePolicy.requestProcess(projectProcess: .positive, selectedProcess: .bwNegative) == .positive)
    }
}
