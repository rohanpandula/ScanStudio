import Testing

@testable import ScanStudioKit

struct PartialDatePrecisionPolicyTests {
    @Test("year-only to month precision does not fabricate January")
    func yearOnlyMonthSelectionStaysPending() {
        let original: PartialDate = .yearOnly(year: 1999)

        let immediateCommit = PartialDatePrecisionPolicy.monthCommitWhenSelectingPrecision(
            from: original
        )

        #expect(immediateCommit == nil)
        // A deliberate month control change is the first valid commit.
        let afterExplicitMonthChoice: PartialDate = .monthOnly(year: 1999, month: 6)
        #expect(afterExplicitMonthChoice == .monthOnly(year: 1999, month: 6))
    }

    @Test("existing month and exact values carry only already-known components")
    func knownMonthCanBeCarried() {
        #expect(
            PartialDatePrecisionPolicy.monthCommitWhenSelectingPrecision(
                from: .monthOnly(year: 1985, month: 11)
            ) == .monthOnly(year: 1985, month: 11)
        )
        #expect(
            PartialDatePrecisionPolicy.monthCommitWhenSelectingPrecision(
                from: .exact(date: "2024-05-06")
            ) == .monthOnly(year: 2024, month: 5)
        )
    }
}
