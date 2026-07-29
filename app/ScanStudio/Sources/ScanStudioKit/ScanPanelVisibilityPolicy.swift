/// Pure visibility rule for the bottom scan action bar.
///
/// Before a roll project exists, the center workspace owns the only next
/// action (connect, choose a film holder, or save the roll). Rendering a
/// disabled footer in those stages competes with that instruction.
public enum ScanPanelVisibilityPolicy {
    public static func isVisible(hasOpenProject: Bool) -> Bool {
        hasOpenProject
    }

    /// The center preview gate is the sole acquisition affordance until a
    /// first preview exists. After that, the footer offers refresh as a
    /// secondary action alongside scan controls.
    public static func showsFooterPreviewAction(hasThumbnails: Bool) -> Bool {
        hasThumbnails
    }
}
