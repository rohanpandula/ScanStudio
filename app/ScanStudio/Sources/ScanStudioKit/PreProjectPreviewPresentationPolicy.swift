/// Chooses the center workspace immediately after a preview.
///
/// A completed preview is evidence the user needs to inspect before naming
/// the roll. Saving is still required before scanning, but it must not hide
/// the preview contact sheet that establishes the roll's frame count.
public enum PreProjectPreviewPresentationPolicy {
    public enum Presentation: Equatable, Sendable {
        /// No complete preview registration exists yet, so the workspace
        /// needs to lead with acquisition.
        case acquisitionGate
        /// Previewed frames remain visible while Save Roll is the next,
        /// compact action above the contact sheet.
        case inlineSaveRollWithContactSheet
        /// A saved project uses the normal contact-sheet workspace.
        case contactSheet
    }

    public static func presentation(
        hasOpenProject: Bool,
        hasCompletePreviewRegistration: Bool
    ) -> Presentation {
        if hasOpenProject {
            return .contactSheet
        }
        return hasCompletePreviewRegistration
            ? .inlineSaveRollWithContactSheet
            : .acquisitionGate
    }
}
