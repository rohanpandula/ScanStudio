/// Pure carrier and validation rules for the project launcher.
///
/// A carrier is optional until the session has actually established one.
/// Holder identity and actual frame count are separate facts: a real SA-21
/// or SA-30 holder is known from its mechanical capability, while its film
/// length is known only after a successful preview status.
public enum ProjectLaunchPolicy {
    public static func initialCarrier(loadedCarrier: SimulatedFilmCarrier?) -> SimulatedFilmCarrier? {
        loadedCarrier
    }

    /// Returns the completed preview's authoritative frame count only when all
    /// registration evidence agrees: media status, exact 1...N tile indices,
    /// status count, and the committed film process. This is the sole count the
    /// post-preview project-confirmation flow may save.
    public static func registeredPreviewFrameCount<Indices: Sequence>(
        mediaLoaded: Bool,
        previewFrameIndices: Indices,
        statusFrameCount: Int?,
        committedFilmProcess: FilmProcess?
    ) -> Int? where Indices.Element == Int {
        guard PreviewRegistrationPolicy.isComplete(
            mediaLoaded: mediaLoaded,
            previewFrameIndices: previewFrameIndices,
            statusFrameCount: statusFrameCount,
            committedFilmProcess: committedFilmProcess
        ) else { return nil }
        return statusFrameCount
    }

    /// Confirms only holder compatibility. It never substitutes a holder
    /// default for the frame count established by the completed preview.
    public static func confirmedFrameCount(
        carrier: SimulatedFilmCarrier?,
        registeredPreviewFrameCount: Int?
    ) -> Int? {
        guard let carrier, let registeredPreviewFrameCount,
              ProjectCarrierRules.validFrameCountRange(carrier).contains(registeredPreviewFrameCount)
        else { return nil }
        return registeredPreviewFrameCount
    }

    public static func createDisabledReason(
        name: String,
        carrier: SimulatedFilmCarrier?,
        registeredPreviewFrameCount: Int?
    ) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a roll name to save it."
        }
        guard let carrier else {
            return "Confirm which film holder is loaded."
        }
        guard let registeredPreviewFrameCount else {
            return "Finish previewing the film before saving so every frame and its film process are registered."
        }
        if !ProjectCarrierRules.validFrameCountRange(carrier).contains(registeredPreviewFrameCount) {
            return "Choose a valid frame count for this film holder."
        }
        return nil
    }
}
