import Testing

@testable import ScanStudioKit

@Suite("Preview registration routing")
struct PreviewRegistrationPolicyTests {
    @Test("stale media status without a completed preview routes back to preview")
    func staleMediaIsNotARegistration() {
        #expect(!PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: [],
            statusFrameCount: 39,
            committedFilmProcess: nil
        ))
    }

    @Test("project creation requires tiles and committed material as well as media")
    func completeRegistrationNeedsAllEvidence() {
        #expect(!PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: [1, 2, 3],
            statusFrameCount: 3,
            committedFilmProcess: nil
        ))
        #expect(!PreviewRegistrationPolicy.isComplete(
            mediaLoaded: false,
            previewFrameIndices: [1, 2, 3],
            statusFrameCount: 3,
            committedFilmProcess: .bwNegative
        ))
        #expect(PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: [1, 2, 3],
            statusFrameCount: 3,
            committedFilmProcess: .bwNegative
        ))
    }

    @Test("a completed six-frame preview routes to saving even when holder confirmation is separate")
    func completedPreviewWithUnknownHolderStillRegistersTheActualFrames() {
        // Holder identity is deliberately not an input to this policy. The
        // engine may leave it unknown, but a successful bridge preview has
        // still established the actual scanner-addressable frame count; the
        // UI can retain the previews and ask for holder confirmation only
        // when the user saves the roll.
        #expect(PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: 1...6,
            statusFrameCount: 6,
            committedFilmProcess: .c41ColorNegative
        ))
    }

    @Test("partial, shifted, or duplicate thumbnail streams cannot register a roll")
    func previewIndicesMustExactlyMatchTheAuthoritativeFrameRange() {
        #expect(!PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: Array(1...38),
            statusFrameCount: 39,
            committedFilmProcess: .bwNegative
        ))
        #expect(!PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: Array(2...40),
            statusFrameCount: 39,
            committedFilmProcess: .bwNegative
        ))
        #expect(!PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: Array(1...38) + [38],
            statusFrameCount: 39,
            committedFilmProcess: .bwNegative
        ))
        #expect(PreviewRegistrationPolicy.isComplete(
            mediaLoaded: true,
            previewFrameIndices: Array(1...39),
            statusFrameCount: 39,
            committedFilmProcess: .bwNegative
        ))
    }
}
