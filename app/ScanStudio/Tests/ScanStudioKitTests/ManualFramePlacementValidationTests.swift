import Foundation
import Testing

@testable import ScanStudioKit

/// `ManualFramePlacementValidation` is the client-side pre-check
/// (FEEDING-UX-LADDER-OVERNIGHT-20260807.md, Rung 4) that gates the
/// editor's Confirm button before a `roll.manualFrames` round trip. The
/// floor mirrors coolscanpy's `manual_frames.py`
/// `MINIMUM_MANUAL_FRAME_HEIGHT_ROWS = 56`/`MANUAL_FRAME_HEIGHT_MM_PER_ROW
/// = 0.267` verbatim; the ceiling is deliberately tighter than that
/// module's own (still 280 today) -- adversarial review S7b (2026-08-08):
/// 145 rows is the scanner's real fixed single-pass fine-scan capture
/// window (see `ManualFramePlacementValidation`'s own doc comment for the
/// derivation), not `manual_frames.py`'s wider placement-time gate. The
/// server remains the actual authority for everything this client cannot
/// independently verify; these tests are pinning the client's own
/// pre-check, not re-deriving the server's.
struct ManualFramePlacementValidationTests {
    @Test("fewer than 2 rows blocks confirm")
    func fewerThanTwoRowsBlocks() {
        #expect(ManualFramePlacementValidation.blockingReason(for: []) != nil)
        #expect(ManualFramePlacementValidation.blockingReason(for: [100]) != nil)
    }

    @Test("2 rows at a standard 35mm spacing is valid")
    func standardFrameSpacingIsValid() {
        // 135 rows =~ 36.0mm, comfortably inside the accepted band.
        #expect(ManualFramePlacementValidation.blockingReason(for: [0, 135]) == nil)
    }

    @Test("frame height below 15mm is rejected with a plain-English film-height reason")
    func tooShortFrameIsRejected() {
        // 10 rows =~ 2.7mm.
        let reason = ManualFramePlacementValidation.blockingReason(for: [0, 10])
        #expect(reason != nil)
        #expect(reason!.contains("15 mm"))
        #expect(reason!.contains("real frames"))
    }

    @Test("frame height above the scanner's capture window is rejected with a hardware-framed reason")
    func tooTallFrameIsRejected() {
        // 400 rows =~ 106.8mm -- comfortably a real film frame, but far
        // past the scanner's fixed single-pass fine-scan capture window.
        let reason = ManualFramePlacementValidation.blockingReason(for: [0, 400])
        #expect(reason != nil)
        #expect(reason!.contains("the scanner captures about"))
        // S7b: the ceiling is now a hardware fact, never phrased as if it
        // were the same "real frames" film-physics claim the floor uses.
        #expect(!reason!.contains("real frames are at most"))
    }

    @Test("exactly at the 15mm floor is valid (56 rows =~ 14.95mm rounds to the accepted band)")
    func minimumRowBoundIsValid() {
        #expect(
            ManualFramePlacementValidation.blockingReason(
                for: [0, ManualFramePlacementValidation.minimumFrameHeightRows]
            ) == nil
        )
    }

    @Test("exactly at the 145-row scanner-capture-window ceiling is valid")
    func maximumRowBoundIsValid() {
        #expect(ManualFramePlacementValidation.maximumFrameHeightRows == 145)
        #expect(
            ManualFramePlacementValidation.blockingReason(
                for: [0, ManualFramePlacementValidation.maximumFrameHeightRows]
            ) == nil
        )
    }

    @Test("one row past the ceiling is rejected")
    func oneRowPastCeilingIsRejected() {
        let reason = ManualFramePlacementValidation.blockingReason(
            for: [0, ManualFramePlacementValidation.maximumFrameHeightRows + 1]
        )
        #expect(reason != nil)
        #expect(reason!.contains("the scanner captures about"))
    }

    @Test("a placement between the new 145-row ceiling and the driver's own wider 280-row gate is refused client-side")
    func placementBetweenNewAndServerCeilingIsRefused() {
        // S7b's whole point: this client must refuse something
        // both client and driver refuse past 145 rows (in lockstep since
        // the same-night driver tightening); this pins the client half.
        // placement the scanner cannot actually fine-scan in one pass.
        #expect(ManualFramePlacementValidation.maximumFrameHeightRows < 280)
        let reason = ManualFramePlacementValidation.blockingReason(for: [0, 200])
        #expect(reason != nil)
    }

    @Test("more than 40 frames is rejected")
    func tooManyFramesIsRejected() {
        let rows = (0...40).map { $0 * 135 } // 41 boundaries -> 40 frames: still valid
        #expect(rows.count == 41)
        #expect(ManualFramePlacementValidation.blockingReason(for: rows) == nil)

        let tooMany = (0...41).map { $0 * 135 } // 42 boundaries -> 41 frames: over the cap
        #expect(tooMany.count == 42)
        let reason = ManualFramePlacementValidation.blockingReason(for: tooMany)
        #expect(reason != nil)
        #expect(reason!.contains("40 frames"))
    }

    @Test("rows are sorted and deduplicated before validation, matching the editor's own working set")
    func rowsAreNormalizedBeforeValidation() {
        // Out of order and with a duplicate -- the editor's own state keeps
        // boundaryRows sorted+deduped by construction, so validation must
        // agree that the same set (regardless of insertion order) reads
        // identically.
        #expect(
            ManualFramePlacementValidation.blockingReason(for: [135, 0, 0])
                == ManualFramePlacementValidation.blockingReason(for: [0, 135])
        )
        #expect(ManualFramePlacementValidation.normalize([135, 0, 0]) == [0, 135])
    }

    @Test("bands report each adjacent pair with its own validity and mm height")
    func bandsReportPerFrameValidity() {
        let bands = ManualFramePlacementValidation.bands(for: [0, 135, 145])
        #expect(bands.count == 2)
        #expect(bands[0].isValid) // 135 rows =~ 36mm
        #expect(!bands[1].isValid) // 10 rows =~ 2.7mm
        #expect(bands[1].millimeters > 0)
    }

    @Test("a single row produces no bands")
    func singleRowProducesNoBands() {
        #expect(ManualFramePlacementValidation.bands(for: [42]).isEmpty)
    }

    @Test("warning text names the correct boundary (film floor vs scanner-hardware ceiling)")
    func warningTextMatchesDirection() {
        #expect(ManualFramePlacementValidation.warning(forMillimeters: 5).contains("at least 15 mm"))
        #expect(
            ManualFramePlacementValidation.warning(forMillimeters: 90)
                .contains("the scanner captures about")
        )
    }

    @Test("maximumFrameHeightMillimeters is derived from the row ceiling, never hardcoded")
    func maximumFrameHeightMillimetersIsDerived() {
        let expected =
            Double(ManualFramePlacementValidation.maximumFrameHeightRows)
                * ManualFramePlacementValidation.mmPerRow
        #expect(
            abs(ManualFramePlacementValidation.maximumFrameHeightMillimeters - expected) < 0.001
        )
    }

    @Test("three drag callbacks move exactly one boundary and preserve the count")
    func repeatedDragCallbacksDoNotCreateGhostBoundaries() {
        var rows = [0, 100, 200]
        var currentRow = 100
        for destination in [110, 120, 130] {
            rows = ManualFramePlacementValidation.movingBoundary(
                in: rows,
                currentRow: currentRow,
                to: destination
            )
            currentRow = destination
        }

        #expect(rows == [0, 130, 200])
        #expect(rows.count == 3)
    }

    @Test("dragging onto an existing boundary is a count-preserving no-op")
    func dragCollisionDoesNotDeleteABoundary() {
        let rows = ManualFramePlacementValidation.movingBoundary(
            in: [0, 100, 200],
            currentRow: 100,
            to: 200
        )

        #expect(rows == [0, 100, 200])
    }
}
