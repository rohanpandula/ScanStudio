import Testing

@testable import ScanStudioKit

@Suite("Pre-project preview presentation policy")
struct PreProjectPreviewPresentationPolicyTests {
    @Test("a complete preview without a saved roll keeps the contact sheet visible with Save Roll inline")
    func completeUnsavedPreviewUsesInlineSaveRoll() {
        #expect(
            PreProjectPreviewPresentationPolicy.presentation(
                hasOpenProject: false,
                hasCompletePreviewRegistration: true
            ) == .inlineSaveRollWithContactSheet
        )
    }

    @Test("an incomplete unsaved preview stays in the acquisition gate")
    func incompleteUnsavedPreviewUsesAcquisitionGate() {
        #expect(
            PreProjectPreviewPresentationPolicy.presentation(
                hasOpenProject: false,
                hasCompletePreviewRegistration: false
            ) == .acquisitionGate
        )
    }

    @Test("a saved roll keeps the normal contact sheet")
    func savedRollUsesNormalContactSheet() {
        #expect(
            PreProjectPreviewPresentationPolicy.presentation(
                hasOpenProject: true,
                hasCompletePreviewRegistration: false
            ) == .contactSheet
        )
    }
}
