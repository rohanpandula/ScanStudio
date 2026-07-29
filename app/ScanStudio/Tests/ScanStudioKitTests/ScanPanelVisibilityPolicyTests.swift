import Testing

@testable import ScanStudioKit

@Suite("Scan panel visibility policy")
struct ScanPanelVisibilityPolicyTests {
    @Test("the footer is hidden until a roll project exists")
    func footerRequiresProject() {
        #expect(!ScanPanelVisibilityPolicy.isVisible(hasOpenProject: false))
        #expect(ScanPanelVisibilityPolicy.isVisible(hasOpenProject: true))
    }

    @Test("the center preview gate owns the first preview action")
    func firstPreviewIsCenterOwned() {
        #expect(!ScanPanelVisibilityPolicy.showsFooterPreviewAction(hasThumbnails: false))
        #expect(ScanPanelVisibilityPolicy.showsFooterPreviewAction(hasThumbnails: true))
    }
}
