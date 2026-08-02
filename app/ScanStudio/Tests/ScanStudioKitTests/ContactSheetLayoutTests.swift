import Testing
@testable import ScanStudioKit

/// The three holders this app actually sees — one mounted slide, a six-frame
/// strip, a 36-40 exposure roll — laid out in a typical workspace pane
/// (1100 x 700 interior, the pane size on the owner's display with both
/// sidebars open).
@Suite("Contact sheet layout")
struct ContactSheetLayoutTests {
    private let paneWidth: Double = 1100
    private let paneHeight: Double = 700

    @Test("A single frame takes one column")
    func singleFrame() {
        #expect(ContactSheetLayout.columnCount(
            frameCount: 1, availableWidth: paneWidth, availableHeight: paneHeight
        ) == 1)
    }

    @Test("A six-frame strip fills the pane instead of sitting in one thin row")
    func sixFrameStrip() {
        let columns = ContactSheetLayout.columnCount(
            frameCount: 6, availableWidth: paneWidth, availableHeight: paneHeight
        )
        // The old hardcoded rule put all six in a single row of ~180 pt tiles
        // above an empty half-pane. Anything that wraps to more than one row
        // is the fix; the exact count is width-dependent and not pinned here.
        #expect(columns < 6)
        #expect(columns >= 2)

        let rows = Int((6.0 / Double(columns)).rounded(.up))
        // Tiles are capped at the preview's honest resolution, so the height
        // budget has to be measured against the capped width, not the raw
        // share of the pane.
        let tile = min(
            ContactSheetLayout.tileWidth(columns: columns, availableWidth: paneWidth),
            ContactSheetLayout.defaultMaxTileWidth
        )
        let used = Double(rows) * (tile / ContactSheetLayout.defaultAspectRatio) + 9 * Double(rows - 1)
        #expect(used <= paneHeight)
    }

    @Test("A 40-frame roll stays legible and never exceeds the frame count")
    func fortyFrameRoll() {
        let columns = ContactSheetLayout.columnCount(
            frameCount: 40, availableWidth: paneWidth, availableHeight: paneHeight
        )
        #expect(columns <= 40)
        let tile = ContactSheetLayout.tileWidth(columns: columns, availableWidth: paneWidth)
        #expect(tile >= ContactSheetLayout.defaultMinTileWidth)
    }

    @Test("Fewer frames never get more columns than more frames")
    func monotonic() {
        var previous = 0
        for count in [1, 2, 4, 6, 12, 24, 40] {
            let columns = ContactSheetLayout.columnCount(
                frameCount: count, availableWidth: paneWidth, availableHeight: paneHeight
            )
            #expect(columns >= previous)
            previous = columns
        }
    }

    @Test("A tile never drops below the legibility floor, however narrow the pane")
    func narrowPaneKeepsTilesLegible() {
        for width in [320.0, 480.0, 700.0, 1100.0, 2400.0] {
            let columns = ContactSheetLayout.columnCount(
                frameCount: 40, availableWidth: width, availableHeight: 400
            )
            let tile = ContactSheetLayout.tileWidth(columns: columns, availableWidth: width)
            #expect(columns >= 1)
            #expect(tile >= ContactSheetLayout.defaultMinTileWidth || columns == 1)
        }
    }

    @Test("Degenerate pane sizes fall back to one column instead of dividing by zero")
    func degenerateSizes() {
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: 0, availableHeight: 0
        ) == 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: .nan, availableHeight: 700
        ) == 1)
    }

    @Test("Zero or negative frameCount falls back to one column instead of an inverted range")
    func nonPositiveFrameCount() {
        #expect(ContactSheetLayout.columnCount(
            frameCount: 0, availableWidth: paneWidth, availableHeight: paneHeight
        ) == 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: -3, availableWidth: paneWidth, availableHeight: paneHeight
        ) == 1)
    }

    @Test("With no height budget the choice is made on width alone")
    func widthOnlySelection() {
        let columns = ContactSheetLayout.columnCount(
            frameCount: 40, availableWidth: paneWidth, availableHeight: 0
        )
        let tile = ContactSheetLayout.tileWidth(columns: columns, availableWidth: paneWidth)
        #expect(tile >= ContactSheetLayout.defaultMinTileWidth)
    }

    // MARK: - Absurd input, never a trap

    /// An astronomically large but still finite pane. `.isFinite` alone does
    /// not save `Int(_:)` from this: the width/tile-width ratio blows past
    /// `Int.max` long before it reaches `Int(_:)`, which is exactly what
    /// `safeColumnRatio` exists to intercept.
    @Test("An astronomically large but finite width never traps")
    func hugeFiniteWidthNeverTraps() {
        let columns = ContactSheetLayout.columnCount(
            frameCount: 40, availableWidth: 1e300, availableHeight: paneHeight
        )
        #expect(columns >= 1)
        #expect(columns <= 40)

        let tile = ContactSheetLayout.tileWidth(columns: columns, availableWidth: 1e300)
        #expect(tile.isFinite)
        #expect(tile >= 0)
    }

    @Test("NaN spacing never traps, in columnCount or tileWidth")
    func nanSpacingNeverTraps() {
        let columns = ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight, spacing: .nan
        )
        #expect(columns >= 1)
        #expect(columns <= 12)

        let tile = ContactSheetLayout.tileWidth(columns: 4, availableWidth: paneWidth, spacing: .nan)
        #expect(tile.isFinite)
        #expect(tile >= 0)
    }

    @Test("Infinite spacing, minTileWidth, or maxTileWidth never traps")
    func infiniteGeometryNeverTraps() {
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight, spacing: .infinity
        ) >= 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight,
            maxTileWidth: .infinity
        ) >= 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight,
            minTileWidth: .infinity
        ) >= 1)

        let tile = ContactSheetLayout.tileWidth(columns: 4, availableWidth: paneWidth, spacing: .infinity)
        #expect(tile.isFinite)
        #expect(tile >= 0)
    }

    @Test("Negative or zero spacing/tile-width bounds never trap")
    func negativeOrZeroGeometryNeverTraps() {
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight, spacing: -1e300
        ) >= 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight,
            maxTileWidth: 0
        ) >= 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight,
            maxTileWidth: -240
        ) >= 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight,
            minTileWidth: 0
        ) >= 1)
        #expect(ContactSheetLayout.columnCount(
            frameCount: 12, availableWidth: paneWidth, availableHeight: paneHeight,
            minTileWidth: -104
        ) >= 1)

        let tile = ContactSheetLayout.tileWidth(columns: 4, availableWidth: paneWidth, spacing: -1e300)
        #expect(tile.isFinite)
        #expect(tile >= 0)
    }

    @Test("tileWidth is total: negative or non-finite availableWidth never produces NaN, infinity, or a negative width")
    func tileWidthIsTotal() {
        for width in [Double.nan, .infinity, -.infinity, -500, 1e300, -1e300] {
            for spacing in [Double.nan, .infinity, -.infinity, -9, 9.0] {
                let tile = ContactSheetLayout.tileWidth(columns: 4, availableWidth: width, spacing: spacing)
                #expect(tile.isFinite, "columns>0 width=\(width) spacing=\(spacing)")
                #expect(tile >= 0, "columns>0 width=\(width) spacing=\(spacing)")
            }
            // `columns <= 0` takes the early-return branch instead.
            for columns in [0, -4] {
                let tile = ContactSheetLayout.tileWidth(columns: columns, availableWidth: width, spacing: 9)
                #expect(tile.isFinite, "columns=\(columns) width=\(width)")
                #expect(tile >= 0, "columns=\(columns) width=\(width)")
            }
        }
    }
}
