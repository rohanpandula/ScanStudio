import Foundation

/// The Dust/Scratches/Uncertain filter-chip state (DEF-02). Pure state, no
/// UI dependency — `DefectMapView`'s `DefectFilterChip`s bind to three
/// `Bool`s that get wrapped into this on read, and `FrameDetailWorkspaceView`
/// passes it straight into `visibleDefects(_:filters:)`.
public struct DefectMapFilters: Equatable, Sendable {
    public var showDust: Bool
    public var showScratches: Bool
    public var showUncertain: Bool

    public init(showDust: Bool = true, showScratches: Bool = true, showUncertain: Bool = true) {
        self.showDust = showDust
        self.showScratches = showScratches
        self.showUncertain = showUncertain
    }
}

/// The single source of truth for which defects the Defect Map overlay,
/// the filter-chip counts, and Previous/Next navigation all agree are
/// currently "visible" — every one of those call sites must reuse this
/// function rather than re-deriving the same filter logic inline, or the
/// overlay and the navigation could disagree about what's actually shown.
public func visibleDefects(_ defects: [DefectInstance], filters: DefectMapFilters) -> [DefectInstance] {
    defects.filter { defect in
        let kindVisible = defect.kind == .dust ? filters.showDust : filters.showScratches
        let classificationVisible = defect.classification != .uncertain || filters.showUncertain
        return kindVisible && classificationVisible
    }
}

/// Steps the current defect selection through `visible` (the
/// already-filtered set — see `visibleDefects` above), wrapping at both
/// ends. `current == nil` (nothing selected yet) or `current` not present
/// in `visible` (e.g. a filter change just hid the previously-selected
/// defect) both fall back to the same edge behavior: `visible.first?.id`
/// going forward, `visible.last?.id` going backward — never a crash, and
/// never a silent no-op that leaves a hidden defect "selected".
public func stepDefectSelection(current: Int?, in visible: [DefectInstance], forward: Bool) -> Int? {
    guard !visible.isEmpty else { return nil }
    guard let current, let index = visible.firstIndex(where: { $0.id == current }) else {
        return forward ? visible.first?.id : visible.last?.id
    }
    let nextIndex = forward ? (index + 1) % visible.count : (index - 1 + visible.count) % visible.count
    return visible[nextIndex].id
}
