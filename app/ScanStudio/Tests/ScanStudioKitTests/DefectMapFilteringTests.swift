// Unit tests for DefectMapFiltering's pure filter/navigation functions
// (DEF-02) — no SwiftUI, no engine round trip, exactly the standalone
// functions DefectMapView's filter chips and Previous/Next buttons call.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Defect map filtering")
struct DefectMapFilteringTests {
    /// Five hand-built defects spanning both kinds and both classifications:
    /// dust/willCorrect, dust/uncertain, scratch/willCorrect,
    /// scratch/uncertain, and a second dust/willCorrect — the extra entry
    /// keeps the wrap-around and not-found cases unambiguous, with more than
    /// one element on each side of whichever entry a test removes/targets.
    private func fixture() -> [DefectInstance] {
        [
            defect(id: 1, kind: .dust, classification: .willCorrect),
            defect(id: 2, kind: .dust, classification: .uncertain),
            defect(id: 3, kind: .scratch, classification: .willCorrect),
            defect(id: 4, kind: .scratch, classification: .uncertain),
            defect(id: 5, kind: .dust, classification: .willCorrect),
        ]
    }

    private func defect(id: Int, kind: DefectKind, classification: DefectClassification) -> DefectInstance {
        DefectInstance(
            id: id,
            kind: kind,
            severity: 0.5,
            classification: classification,
            centerX: 0.5,
            centerY: 0.5,
            radius: 0.02,
            endX: kind == .scratch ? 0.6 : nil,
            endY: kind == .scratch ? 0.6 : nil
        )
    }

    @Test("with all three filters true, every input defect is returned in the same order")
    func allFiltersTrueReturnsEverything() {
        let all = fixture()
        let visible = visibleDefects(all, filters: DefectMapFilters())
        #expect(visible.map(\.id) == all.map(\.id))
    }

    @Test("showDust false excludes every dust instance and leaves scratch instances unaffected")
    func showDustFalseExcludesDust() {
        let visible = visibleDefects(fixture(), filters: DefectMapFilters(showDust: false))
        #expect(visible.map(\.id) == [3, 4])
        #expect(visible.allSatisfy { $0.kind == .scratch })
    }

    @Test("showScratches false excludes every scratch instance and leaves dust instances unaffected")
    func showScratchesFalseExcludesScratches() {
        let visible = visibleDefects(fixture(), filters: DefectMapFilters(showScratches: false))
        #expect(visible.map(\.id) == [1, 2, 5])
        #expect(visible.allSatisfy { $0.kind == .dust })
    }

    @Test("showUncertain false excludes every instance classified uncertain regardless of kind, leaving willCorrect instances of both kinds")
    func showUncertainFalseExcludesUncertainRegardlessOfKind() {
        let visible = visibleDefects(fixture(), filters: DefectMapFilters(showUncertain: false))
        #expect(visible.map(\.id) == [1, 3, 5])
        #expect(visible.allSatisfy { $0.classification == .willCorrect })
        #expect(visible.contains { $0.kind == .dust })
        #expect(visible.contains { $0.kind == .scratch })
    }

    @Test("combining showDust false and showUncertain false leaves only scratch + willCorrect instances")
    func combiningDustFalseAndUncertainFalse() {
        let visible = visibleDefects(fixture(), filters: DefectMapFilters(showDust: false, showUncertain: false))
        #expect(visible.map(\.id) == [3])
        #expect(visible.allSatisfy { $0.kind == .scratch && $0.classification == .willCorrect })
    }

    @Test("stepDefectSelection with a nil current returns the first id going forward and the last id going backward")
    func stepFromNilCurrent() {
        let visible = fixture()
        #expect(stepDefectSelection(current: nil, in: visible, forward: true) == visible.first?.id)
        #expect(stepDefectSelection(current: nil, in: visible, forward: false) == visible.last?.id)
    }

    @Test("stepDefectSelection on a current id present in visible steps to the next/previous element and wraps at both ends")
    func stepWrapsAtBothEnds() {
        let visible = fixture() // ids in order: 1, 2, 3, 4, 5

        // Middle: steps to the immediate neighbor, no wrap involved.
        #expect(stepDefectSelection(current: 2, in: visible, forward: true) == 3)
        #expect(stepDefectSelection(current: 2, in: visible, forward: false) == 1)

        // Forward wrap: last -> first.
        #expect(stepDefectSelection(current: 5, in: visible, forward: true) == 1)
        // Backward wrap: first -> last.
        #expect(stepDefectSelection(current: 1, in: visible, forward: false) == 5)
    }

    @Test("stepDefectSelection on a current id not present in visible falls back to the nil-current behavior instead of crashing or returning current unchanged")
    func stepFallsBackWhenCurrentIsHidden() {
        // id 2 was just hidden by a showDust:false filter change — only 3
        // and 4 remain visible.
        let visible = visibleDefects(fixture(), filters: DefectMapFilters(showDust: false))
        #expect(stepDefectSelection(current: 2, in: visible, forward: true) == visible.first?.id)
        #expect(stepDefectSelection(current: 2, in: visible, forward: false) == visible.last?.id)
        #expect(stepDefectSelection(current: 2, in: visible, forward: true) != 2)
    }

    @Test("stepDefectSelection on an empty visible array returns nil regardless of current or direction")
    func stepOnEmptyVisibleReturnsNil() {
        #expect(stepDefectSelection(current: nil, in: [], forward: true) == nil)
        #expect(stepDefectSelection(current: nil, in: [], forward: false) == nil)
        #expect(stepDefectSelection(current: 3, in: [], forward: true) == nil)
        #expect(stepDefectSelection(current: 3, in: [], forward: false) == nil)
    }
}
