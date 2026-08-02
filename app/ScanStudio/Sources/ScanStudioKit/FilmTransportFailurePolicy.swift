import Foundation

/// Recognizes the fail-closed scanner responses that prove the current film
/// registration can no longer be trusted. New medium-not-present failures
/// arrive as the typed `FILM_FEED_INTERRUPTED`; legacy builds and the other
/// transport-slip shapes may still carry their bridge code only inside an
/// `INTERNAL` diagnostic, so both forms remain recognized.
enum FilmTransportFailurePolicy {
    static func isFilmFeedInterrupted(
        errorCode: String? = nil,
        message: String
    ) -> Bool {
        let normalized = "\(errorCode ?? "") \(message)".uppercased()
        if normalized.contains("FILM_FEED_INTERRUPTED") {
            return true
        }
        let compact = normalized.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return normalized.contains("ROLL_MISMATCH")
            && compact.contains("SYNCHRONIZEDPROTOCOLERROR")
            && compact.contains("SENSE023A00")
    }

    static func requiresPhysicalRefeed(
        errorCode: String? = nil,
        message: String
    ) -> Bool {
        if isFilmFeedInterrupted(errorCode: errorCode, message: message) {
            return true
        }
        let normalized = "\(errorCode ?? "") \(message)".uppercased()
        let compactSense = normalized
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "-", with: "")

        let isRollMismatch = normalized.contains("ROLL_MISMATCH")
        let isFingerprintRefusal = normalized.contains("FINGERPRINT_REFUSED")
        let isMediaLoadFailure =
            normalized.contains("SYNCHRONIZEDPROTOCOLERROR")
                && compactSense.contains("SENSE045300")
        let isAnchorResidual = normalized.contains(
            "TRANSPORT ANCHOR RESIDUAL IS INCONSISTENT WITH ONE AFFINE PREVIEW TRAVERSAL"
        )
        let isSlotCountMismatch = normalized.contains("SLOT-COUNT-MISMATCH")

        return (isRollMismatch && (isMediaLoadFailure || isAnchorResidual))
            || (isFingerprintRefusal && isSlotCountMismatch)
    }
}
