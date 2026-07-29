import Foundation

public enum FrameFailureAction: Equatable, Sendable {
    case retry
    case approveAndRetry
}

public enum FrameFailureLabel {
    public static let manualReviewCode = "MANUAL_REVIEW_REQUIRED"
    public static let manualReviewHelp =
        "This frame was refused before scanner motion because its preview boundary needs confirmation."

    public static func label(forErrorCode errorCode: String?) -> String {
        action(forErrorCode: errorCode) == .approveAndRetry
            ? "Needs review"
            : "Failed"
    }

    public static func action(forErrorCode errorCode: String?) -> FrameFailureAction {
        errorCode == manualReviewCode ? .approveAndRetry : .retry
    }

    public static func help(forErrorCode errorCode: String?) -> String? {
        action(forErrorCode: errorCode) == .approveAndRetry
            ? manualReviewHelp
            : nil
    }
}
