/// Defines the minimum evidence required before an unsaved detected roll can
/// be offered for project creation. Holder/media status alone is not a film
/// registration: a successful preview must have produced exactly the
/// authoritative status frame indices and committed the selected process.
public enum PreviewRegistrationPolicy {
    public static func isComplete<Indices: Sequence>(
        mediaLoaded: Bool,
        previewFrameIndices: Indices,
        statusFrameCount: Int?,
        committedFilmProcess: FilmProcess?
    ) -> Bool where Indices.Element == Int {
        guard let statusFrameCount, statusFrameCount > 0 else { return false }
        let indices = Array(previewFrameIndices)
        let expected = Set(1...statusFrameCount)
        return mediaLoaded
            && indices.count == statusFrameCount
            && Set(indices) == expected
            && committedFilmProcess != nil
    }
}
