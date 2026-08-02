import Foundation

/// Column choice for the contact sheet and the roll-loading grid.
///
/// Both grids used to hardcode `min(frameCount, 6)` columns, which reads as
/// three different bugs depending on what is in the holder: a single mounted
/// slide became one tile in a full-width pane, a six-frame strip became one
/// row of small tiles above an empty half-screen, and a 40-frame roll became
/// seven rows of tiles too small to judge. The frame count is not knowable
/// until the holder is read, so the layout has to derive from it rather than
/// assume a shape.
///
/// The rule: pick the fewest columns — the largest tiles — that still fit the
/// whole sheet in the visible pane. When nothing fits, the sheet scrolls and
/// the choice falls back to the most columns that keep a tile legible, which
/// keeps the scroll distance sane on long rolls.
public enum ContactSheetLayout {
    /// Width in pixels of one frame in the roll-index preview.
    ///
    /// The index pass is pinned at 97 dpi because it is also Nikon's density
    /// source (`density.py`'s "proven-97dpi-seq564-611" binding), so this is
    /// not a knob the display side may turn: 3946 native columns sampled at
    /// 97/4000 gives ~96 px across a frame, which is what lands on disk.
    /// Raising preview sharpness therefore means adding a *separate*
    /// per-frame prescan, not re-sampling this pass — see `maxTileWidth`.
    public static let indexPreviewPixelWidth: Double = 96

    /// How far a preview may be enlarged before the sheet is showing
    /// interpolation rather than film. Points, not pixels — on a 2x display
    /// the physical upscale is twice this.
    public static let defaultMaxUpscale: Double = 2.5

    /// Widest a single tile is allowed to get, given the resolution actually
    /// behind it. Past this the sheet stops being a sheet and becomes a wall
    /// of blur, which is what a fixed 460 pt cap produced against a 96 px
    /// index preview.
    public static func maxTileWidth(
        sourcePixelWidth: Double = indexPreviewPixelWidth,
        maxUpscale: Double = defaultMaxUpscale
    ) -> Double {
        max(1, sourcePixelWidth * maxUpscale)
    }

    /// Cap used when the caller has no better information about the source.
    public static var defaultMaxTileWidth: Double { maxTileWidth() }

    /// Narrowest a tile may be before frame numbers and state chips stop
    /// being readable. Measured against the existing tile chrome, not chosen
    /// arbitrarily: the overlay label is 10 pt in a 5 pt inset.
    public static let defaultMinTileWidth: Double = 104

    /// Nominal tile aspect (3:2 film frame), matching the `aspectRatio`
    /// applied by both tile views.
    public static let defaultAspectRatio: Double = 3.0 / 2.0

    /// Number of columns to lay `frameCount` tiles out in.
    ///
    /// - Parameters:
    ///   - availableWidth: interior width of the grid, already excluding the
    ///     pane's horizontal padding.
    ///   - availableHeight: interior height the sheet may occupy without
    ///     scrolling. Pass whatever remains after fixed chrome (scrubber,
    ///     padding); `0` or less disables the fits-on-screen preference and
    ///     selects on width alone.
    /// - Returns: a column count in `1...frameCount`.
    ///
    /// Total over its domain: a degenerate `spacing`/`minTileWidth`/
    /// `maxTileWidth` (NaN, infinite, zero, negative) or a merely absurd
    /// `availableWidth` (a `1e300` pane is finite arithmetic, but its ratio
    /// against a normal tile width is not an `Int` anyone can hold) never
    /// traps -- see `safeColumnRatio`, which every `Int`-producing ratio in
    /// this function is routed through instead of calling `Int(_:)` directly.
    public static func columnCount(
        frameCount: Int,
        availableWidth: Double,
        availableHeight: Double,
        spacing: Double = 9,
        aspectRatio: Double = defaultAspectRatio,
        maxTileWidth: Double = defaultMaxTileWidth,
        minTileWidth: Double = defaultMinTileWidth
    ) -> Int {
        guard frameCount > 1 else { return 1 }
        guard availableWidth.isFinite, availableWidth > 0, aspectRatio > 0 else { return 1 }

        // Never so many columns that a tile drops below legibility, and never
        // more columns than there are frames to put in them.
        let widthCap = max(1, safeColumnRatio((availableWidth + spacing) / (minTileWidth + spacing)))
        let upperBound = min(frameCount, widthCap)

        // Fewer columns stops buying bigger tiles once `maxTileWidth` binds —
        // it only leaves the row half empty. So the search starts at the
        // widest row that still fills to the cap rather than at one column.
        let atCapColumns = max(1, safeColumnRatio((availableWidth + spacing) / (maxTileWidth + spacing)))
        let lowerBound = min(atCapColumns, upperBound)

        if availableHeight.isFinite, availableHeight > 0 {
            for candidate in lowerBound...upperBound {
                let tileWidth = min(tileWidth(columns: candidate, availableWidth: availableWidth, spacing: spacing), maxTileWidth)
                let rows = Int((Double(frameCount) / Double(candidate)).rounded(.up))
                let totalHeight = Double(rows) * (tileWidth / aspectRatio) + spacing * Double(rows - 1)
                if totalHeight <= availableHeight { return candidate }
            }
        }

        // Nothing fits vertically: the sheet scrolls either way, so prefer the
        // most columns that stay legible over the biggest possible tile.
        return upperBound
    }

    /// Floors a width/spacing ratio into a column count without ever
    /// trapping. `Int(_:)` crashes on NaN, on infinity, and on any finite
    /// `Double` outside `Int`'s representable range -- all reachable here
    /// from a degenerate `spacing`/`minTileWidth`/`maxTileWidth`, or simply
    /// an absurd `availableWidth`. Floor is `1` (never fewer than one
    /// column); ceiling is `1_000_000`, chosen only as an `Int`-safe rail --
    /// no real screen fits anywhere near that many legible columns, so
    /// callers only ever observe this ceiling on hostile input.
    private static func safeColumnRatio(_ ratio: Double) -> Int {
        guard ratio.isFinite else { return 1 }
        return Int(min(max(ratio.rounded(.down), 1), 1_000_000))
    }

    /// Width of one tile once `columns` share `availableWidth`.
    ///
    /// Total over its domain: a non-finite or negative `availableWidth`/
    /// `spacing` is treated as `0` rather than propagating a NaN or
    /// infinite result outward, and the return value is floored at `0` --
    /// this never reports a negative tile width, however degenerate the
    /// inputs.
    public static func tileWidth(columns: Int, availableWidth: Double, spacing: Double = 9) -> Double {
        let safeWidth = availableWidth.isFinite ? max(0, availableWidth) : 0
        guard columns > 0 else { return safeWidth }
        let safeSpacing = spacing.isFinite ? spacing : 0
        let raw = (safeWidth - safeSpacing * Double(columns - 1)) / Double(columns)
        return raw.isFinite ? max(0, raw) : 0
    }
}
