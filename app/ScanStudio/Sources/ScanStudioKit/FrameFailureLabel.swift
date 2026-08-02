import Foundation

public enum FrameFailureAction: Equatable, Sendable {
    case retry
    case approveAndRetry
}

/// Translates an engine error `code` (PROTOCOL.md) into copy a person running
/// the scanner can act on. The engine's own diagnostic text is written for
/// whoever is debugging the bridge/protocol layer -- full of terms like
/// "packed-stream", "manifest", "fingerprint", "counter train" -- and none of
/// that belongs in a tile tooltip. This table is the one place that
/// translation happens; every user-facing surface that needs failure copy
/// goes through `copy(forErrorCode:)` or `help(forErrorCode:)` rather than
/// improvising its own fallback onto the raw diagnostic.
public enum FrameFailureLabel {
    public static let manualReviewCode = "MANUAL_REVIEW_REQUIRED"

    private struct Copy {
        let title: String
        let body: String
    }

    private static let copyTable: [String: Copy] = [
        "UNKNOWN_METHOD": Copy(
            title: "Unexpected app error",
            body: "The app tried an operation this version does not understand. If this keeps happening, report it."
        ),
        "INVALID_PARAMS": Copy(
            title: "Invalid scan settings",
            body: "These scan settings are not valid for this scanner. Check the settings and try again."
        ),
        "UNKNOWN_DEVICE": Copy(
            title: "Scanner not recognized",
            body: "The connected device is not recognized as a supported scanner."
        ),
        "NOT_CONNECTED": Copy(
            title: "Scanner not connected",
            body: "The scanner is not connected or was disconnected. Check the cable and power."
        ),
        "ALREADY_CONNECTED": Copy(
            title: "Already connected",
            body: "The scanner is already connected. No action needed."
        ),
        "NO_MEDIA": Copy(
            title: "No film loaded",
            body: "No film is loaded in the scanner. Insert a strip to continue."
        ),
        "SCANNER_BUSY": Copy(
            title: "Scanner busy",
            body: "The scanner is busy with another operation. Wait for it to finish, then try again."
        ),
        "UNKNOWN_JOB": Copy(
            title: "Scan job missing",
            body: "This scan job no longer exists. Start the scan again."
        ),
        "FEED_JAM": Copy(
            title: "Film jammed",
            body: "The film strip jammed while feeding. Clear the strip before scanning again."
        ),
        "INTERNAL": Copy(
            title: "Unexpected error",
            body: "Something went wrong during scanning. Try again; if it keeps happening, report it."
        ),
        "PROJECT_NOT_FOUND": Copy(
            title: "Project not found",
            body: "The project folder could not be found on disk."
        ),
        "MANIFEST_INVALID": Copy(
            title: "Project file unreadable",
            body: "The project file could not be read. Reopen the project; if that fails, it may need recovery."
        ),
        "ARCHIVE_COLLISION": Copy(
            title: "File already exists",
            body: "Writing this scan would overwrite an existing archived file, so it was refused. Change the output name or location."
        ),
        manualReviewCode: Copy(
            title: "Needs review",
            body: "This frame needs its boundary confirmed before the scanner will move the film. Review the preview, then approve."
        ),
        "HW_MOTION_NOT_ARMED": Copy(
            title: "Motion not armed",
            body: "The safety latch that allows the scanner to move film is not armed, so the request was refused."
        ),
        "BATCH_INTEGRITY_ERROR": Copy(
            title: "Capture refused",
            body: "The image data arriving from the scanner was inconsistent, so the capture was refused to protect the archive. Removing and re-feeding the strip has cleared this before."
        ),
        "BRIDGE_STREAM_STALLED": Copy(
            title: "Transfer stalled",
            body: "The data transfer from the scanner stalled. Try the scan again; if it repeats, disconnect and reconnect the scanner."
        ),
        "DEVICE_BUSY": Copy(
            title: "Scanner busy",
            body: "The scanner is handling another operation. Wait a moment and try again."
        ),
        "DEVICE_NOT_FOUND": Copy(
            title: "Scanner not found",
            body: "The scanner could not be found. Check that it is plugged in and powered on."
        ),
        "EJECT_FAILED": Copy(
            title: "Eject failed",
            body: "The scanner did not eject the film strip when asked. Try ejecting again."
        ),
        "FEEDER_PARKED": Copy(
            title: "Feeder parked",
            body: "The film feeder is parked and cannot accept film right now."
        ),
        "FINGERPRINT_REFUSED": Copy(
            title: "Different film detected",
            body: "The film in the scanner does not match what this project scanned before. If you swapped strips, re-feed the one this project expects."
        ),
        "GEOMETRY_VALIDATION_ERROR": Copy(
            title: "Frame outline mismatch",
            body: "The detected frame outline does not match what was expected. Re-feeding the strip may fix it."
        ),
        "HARDWARE_LANE_BUSY": Copy(
            title: "Scanner in use",
            body: "The scanner is already in use by another operation. Wait for it to finish."
        ),
        "NO_PREVIEW": Copy(
            title: "No preview yet",
            body: "There is no preview for this frame yet. Run a preview first."
        ),
        "NOT_IMPLEMENTED": Copy(
            title: "Not supported",
            body: "This operation is not supported for this scanner."
        ),
        "REFEED_REQUIRED": Copy(
            title: "Re-feed the film",
            body: "The film strip needs to be removed and fed in again before scanning can continue."
        ),
        "ROLL_MISMATCH": Copy(
            title: "Wrong roll",
            body: "The film in the scanner does not look like the roll this project expects. Check that the right strip is loaded."
        ),
        "SPLIT_ALIGNMENT_ERROR": Copy(
            title: "Alignment error",
            body: "The frame boundaries do not line up with the expected scan area. Re-feeding the strip may fix it."
        ),
        "THUMBNAIL_DECODE_MISMATCH": Copy(
            title: "Preview mismatch",
            body: "The preview does not match the captured scan data. Rescanning this frame is the safe fix."
        ),
        "TRANSPORT_SMEAR_DETECTED": Copy(
            title: "Movement during scan",
            body: "The film appears to have moved during the scan. Rescan this frame."
        ),
    ]

    /// Curated title/body for a known engine error code, or `nil` for a code
    /// this table has not been taught yet. `nil` is a real answer, not an
    /// oversight -- callers need a generic, code-bearing fallback for that
    /// case rather than a fabricated explanation.
    public static func copy(forErrorCode errorCode: String) -> (title: String, body: String)? {
        guard let entry = copyTable[errorCode] else { return nil }
        return (title: entry.title, body: entry.body)
    }

    public static func label(forErrorCode errorCode: String?) -> String {
        action(forErrorCode: errorCode) == .approveAndRetry
            ? "Needs review"
            : "Failed"
    }

    public static func action(forErrorCode errorCode: String?) -> FrameFailureAction {
        errorCode == manualReviewCode ? .approveAndRetry : .retry
    }

    public static func help(forErrorCode errorCode: String?) -> String? {
        guard let errorCode else { return nil }
        return copy(forErrorCode: errorCode)?.body
    }
}
