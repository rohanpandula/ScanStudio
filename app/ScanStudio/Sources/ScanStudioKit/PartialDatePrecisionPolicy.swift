import Foundation

/// Precision transitions that are safe to commit without inventing a date
/// component. UI controls may show local draft values while this returns
/// `nil`; only an explicit picker/text edit may then construct a new value.
public enum PartialDatePrecisionPolicy {
    public static func monthCommitWhenSelectingPrecision(
        from date: PartialDate?
    ) -> PartialDate? {
        switch date {
        case .monthOnly:
            return date
        case .exact(let iso):
            let components = iso.split(separator: "-")
            guard
                components.count >= 2,
                let year = Int(components[0]),
                let month = Int(components[1]),
                (1...12).contains(month)
            else { return nil }
            return .monthOnly(year: year, month: month)
        case .yearOnly, .unknown, nil:
            return nil
        }
    }
}
