import Foundation

/// Client-side pre-validation for manual frame boundary picks (Rung 4 of
/// the feeding UX ladder, FEEDING-UX-LADDER-OVERNIGHT-20260807.md).
///
/// Mirrors coolscanpy's `manual_frames.py` structural gates verbatim
/// (`MINIMUM_MANUAL_BOUNDARY_COUNT = 2`, `MAXIMUM_MANUAL_FRAMES = 40`,
/// `MINIMUM_MANUAL_FRAME_HEIGHT_ROWS = 56`,
/// `MANUAL_FRAME_HEIGHT_MM_PER_ROW = 0.267`) plus one deliberate
/// tightening on the CEILING (adversarial review S7b, 2026-08-08):
/// the driver's `manual_frames.py` enforces the same ceiling as
/// `FINE_CAPTURE_WINDOW_ROWS = 145`: the fixed single-pass fine capture
/// window is `FINE_NATIVE_HEIGHT = 5_959` native pixels (`worker.py`)
/// over the validated preview pitch of 41, exactly 145 preview rows.
/// Client and server are in deliberate lockstep at 145 (the driver's gate
/// was tightened the same night this validator was written -- both sides
/// refuse a frame the scanner cannot capture in one pass), so every
/// placement this validator accepts also passes the server's gate, and a
/// placement it refuses would have been refused there too.
///
/// This is a UX nicety, never the authority: the server still validates
/// every submitted `rows` array independently -- including the
/// same-traversal transport-table sanity check this client has no evidence
/// to run -- and a server `INVALID_PARAMS` rejection is what the editor
/// actually shows on a refusal. This type exists so the editor can disable
/// Confirm and explain why *before* a round trip, and so that logic has a
/// unit-testable home.
public enum ManualFramePlacementValidation {
    public static let minimumBoundaryCount = 2
    public static let maximumFrameCount = 40
    public static let minimumFrameHeightRows = 56
    /// The scanner's fixed single-pass fine capture window, expressed in
    /// preview rows (see this type's own doc comment for the derivation).
    public static let maximumFrameHeightRows = 145
    public static let mmPerRow: Double = 0.267
    /// `maximumFrameHeightRows` expressed in millimetres, for the editor's
    /// plain-English "the scanner captures about X mm per frame" copy.
    public static let maximumFrameHeightMillimeters: Double =
        Double(maximumFrameHeightRows) * mmPerRow

    /// One boundary-to-boundary span, expressed as its two rows and
    /// whether the frame it implies is inside the accepted height band.
    public struct Band: Equatable, Sendable {
        public let topRow: Int
        public let bottomRow: Int
        public let millimeters: Double
        public let isValid: Bool

        public init(topRow: Int, bottomRow: Int) {
            self.topRow = topRow
            self.bottomRow = bottomRow
            let heightRows = bottomRow - topRow
            self.millimeters = Double(heightRows) * ManualFramePlacementValidation.mmPerRow
            self.isValid =
                heightRows >= ManualFramePlacementValidation.minimumFrameHeightRows
                    && heightRows <= ManualFramePlacementValidation.maximumFrameHeightRows
        }
    }

    /// Every adjacent pair of sorted, deduplicated rows as a `Band`. Fewer
    /// than 2 rows produces no bands (there is no frame yet to describe).
    public static func bands(for rows: [Int]) -> [Band] {
        let sorted = normalize(rows)
        guard sorted.count >= 2 else { return [] }
        return zip(sorted, sorted.dropFirst()).map { Band(topRow: $0, bottomRow: $1) }
    }

    /// Sorted, deduplicated -- the exact transform the editor's own working
    /// set already keeps its rows under, exposed here so validation and the
    /// view agree on what "the current picks" means.
    public static func normalize(_ rows: [Int]) -> [Int] {
        Array(Set(rows)).sorted()
    }

    /// Replaces the boundary currently owned by an in-flight drag. The view
    /// passes the previous callback's destination as `currentRow`, never the
    /// gesture's original anchor, so repeated callbacks move one line rather
    /// than accumulating ghost boundaries. A collision is a no-op and never
    /// silently reduces the boundary count.
    public static func movingBoundary(
        in rows: [Int],
        currentRow: Int,
        to destinationRow: Int
    ) -> [Int] {
        let normalized = normalize(rows)
        guard normalized.contains(currentRow) else { return normalized }
        guard destinationRow == currentRow || !normalized.contains(destinationRow) else {
            return normalized
        }
        return normalize(normalized.map { $0 == currentRow ? destinationRow : $0 })
    }

    /// A plain-English reason `rows` cannot be submitted yet, or `nil` when
    /// they are ready to send. Checks gate order mirrors the server's own
    /// (structure, then frame count, then per-frame height) so a
    /// client-caught problem reads the same way a server rejection would.
    public static func blockingReason(for rows: [Int]) -> String? {
        let sorted = normalize(rows)
        guard sorted.count >= minimumBoundaryCount else {
            return "Place at least 2 boundary lines to define 1 frame."
        }
        let frameCount = sorted.count - 1
        guard frameCount <= maximumFrameCount else {
            return "Manual placement supports at most \(maximumFrameCount) frames; "
                + "\(sorted.count) boundary lines would create \(frameCount)."
        }
        for band in bands(for: sorted) where !band.isValid {
            return warning(forMillimeters: band.millimeters)
        }
        return nil
    }

    /// Plain-English warning for a band outside the accepted height range,
    /// in the voice the boundary-band overlay and the blocking reason both
    /// use. The floor is framed as a fact about film (a real frame is at
    /// least this tall); the ceiling is framed as a fact about the
    /// scanner's hardware (it can only capture about this much per frame
    /// in one pass) -- these are two different physical constraints, not
    /// the same rule stated twice, so the copy says so.
    public static func warning(forMillimeters millimeters: Double) -> String {
        let text = Self.millimeterText(millimeters)
        if millimeters < Double(minimumFrameHeightRows) * mmPerRow {
            return "this frame would be \(text) mm tall - real frames are at least 15 mm"
        }
        let ceilingText = Self.millimeterText(maximumFrameHeightMillimeters)
        return "this frame would be \(text) mm tall - the scanner captures about "
            + "\(ceilingText) mm per frame"
    }

    public static func millimeterText(_ millimeters: Double) -> String {
        String(format: "%.1f", millimeters)
    }
}
