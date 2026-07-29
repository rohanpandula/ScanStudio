import Testing

@testable import ScanStudioKit

@Suite("Frame failure label")
struct FrameFailureLabelTests {
    @Test("a MANUAL_REVIEW_REQUIRED code reads as Needs review, not a failure")
    func manualReviewReadsNeedsReview() {
        #expect(FrameFailureLabel.label(forErrorCode: "MANUAL_REVIEW_REQUIRED") == "Needs review")
    }

    @Test("any other code reads as Failed")
    func otherCodeReadsFailed() {
        #expect(FrameFailureLabel.label(forErrorCode: "REFEED_REQUIRED") == "Failed")
        #expect(FrameFailureLabel.label(forErrorCode: "INTERNAL") == "Failed")
    }

    @Test("an absent error payload still reads as Failed, never Needs review")
    func absentCodeReadsFailed() {
        #expect(FrameFailureLabel.label(forErrorCode: nil) == "Failed")
    }

    @Test("only the exact typed manual-review code selects approval")
    func actionUsesExactTypedCode() {
        #expect(FrameFailureLabel.action(forErrorCode: "MANUAL_REVIEW_REQUIRED") == .approveAndRetry)
        #expect(FrameFailureLabel.action(forErrorCode: "REFEED_REQUIRED") == .retry)
        #expect(FrameFailureLabel.action(forErrorCode: nil) == .retry)
    }

    @Test("manual review help explains the before-motion boundary refusal")
    func manualReviewHelpIsHumanReadable() {
        #expect(
            FrameFailureLabel.help(forErrorCode: "MANUAL_REVIEW_REQUIRED")
                == "This frame was refused before scanner motion because its preview boundary needs confirmation."
        )
    }
}
