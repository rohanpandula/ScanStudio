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
                == "This frame needs its boundary confirmed before the scanner will move the film. Review the preview, then approve."
        )
    }

    /// Every code the engine can actually send (PROTOCOL.md), reviewed and
    /// signed off with curated copy. Kept as an explicit list rather than
    /// reflecting the table's own keys back at itself, so a typo'd or
    /// accidentally-deleted table entry fails this test instead of silently
    /// shrinking the covered set.
    private static let allKnownCodes = [
        "UNKNOWN_METHOD", "INVALID_PARAMS", "UNKNOWN_DEVICE", "NOT_CONNECTED",
        "ALREADY_CONNECTED", "NO_MEDIA", "SCANNER_BUSY", "UNKNOWN_JOB",
        "FEED_JAM", "INTERNAL", "PROJECT_NOT_FOUND", "MANIFEST_INVALID",
        "ARCHIVE_COLLISION", "MANUAL_REVIEW_REQUIRED", "HW_MOTION_NOT_ARMED",
        "BATCH_INTEGRITY_ERROR", "BRIDGE_STREAM_STALLED", "DEVICE_BUSY",
        "DEVICE_NOT_FOUND", "EJECT_FAILED", "FEEDER_PARKED",
        "FINGERPRINT_REFUSED", "GEOMETRY_VALIDATION_ERROR",
        "HARDWARE_LANE_BUSY", "NO_PREVIEW", "NOT_IMPLEMENTED",
        "REFEED_REQUIRED", "ROLL_MISMATCH", "SPLIT_ALIGNMENT_ERROR",
        "THUMBNAIL_DECODE_MISMATCH", "TRANSPORT_SMEAR_DETECTED",
    ]

    @Test("every curated code has a non-empty title and body")
    func everyEntryIsNonEmpty() {
        for code in Self.allKnownCodes {
            let copy = FrameFailureLabel.copy(forErrorCode: code)
            #expect(copy != nil, "missing curated copy for \(code)")
            #expect(!(copy?.title.isEmpty ?? true), "empty title for \(code)")
            #expect(!(copy?.body.isEmpty ?? true), "empty body for \(code)")
        }
    }

    @Test("curated copy never leaks bridge/protocol vocabulary into user-facing text")
    func noEntryLeaksBridgeVocabulary() {
        let forbidden = ["bridge", "engine", "manifest", "fingerprint", "packed-stream", "lane"]
        for code in Self.allKnownCodes {
            guard let copy = FrameFailureLabel.copy(forErrorCode: code) else { continue }
            let text = "\(copy.title) \(copy.body)".lowercased()
            for word in forbidden {
                #expect(!text.contains(word), "\(code) copy leaks '\(word)': \(text)")
            }
        }
    }

    @Test("an unrecognized code has no curated copy")
    func unknownCodeHasNoCopy() {
        #expect(FrameFailureLabel.copy(forErrorCode: "SOME_FUTURE_CODE_NOT_YET_TAUGHT") == nil)
    }

    @Test("help returns nil, not a fallback string, for a code this table does not know")
    func helpIsNilForUnknownCode() {
        #expect(FrameFailureLabel.help(forErrorCode: "SOME_FUTURE_CODE_NOT_YET_TAUGHT") == nil)
    }

    @Test("help returns the curated body for every known code")
    func helpMatchesCuratedBodyForEveryCode() {
        for code in Self.allKnownCodes {
            #expect(FrameFailureLabel.help(forErrorCode: code) == FrameFailureLabel.copy(forErrorCode: code)?.body)
        }
    }
}
