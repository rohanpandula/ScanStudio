import Foundation

/// Recognizes the fail-closed scanner responses that prove the current film
/// registration can no longer be trusted. The engine's public error enum is
/// intentionally smaller than the bridge vocabulary, so live bridge codes
/// can arrive as `INTERNAL` while their original code and message remain in
/// the diagnostic text.
enum FilmTransportFailurePolicy {
    static func requiresPhysicalRefeed(
        errorCode: String? = nil,
        message: String
    ) -> Bool {
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
