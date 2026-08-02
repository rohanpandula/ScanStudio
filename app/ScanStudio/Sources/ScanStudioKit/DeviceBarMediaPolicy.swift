/// Truthful, compact media copy for the device bar. `filmPresent` is a live
/// hardware sensor read only when non-nil; absence means unknown, never
/// ejected or loaded.
public enum DeviceBarMediaPolicy {
    public static func label(
        isAcquiringPreviews: Bool,
        mediaLoaded: Bool,
        carrierDisplayName: String?,
        filmPresent: Bool?,
        refeedRequired: Bool
    ) -> String {
        if isAcquiringPreviews { return "Detecting film" }
        if refeedRequired { return "Refeed required" }
        if filmPresent == false { return "No film detected" }
        if mediaLoaded { return carrierDisplayName ?? "Previewed film" }
        if filmPresent == true { return "Film present; preview needed" }
        if let carrierDisplayName { return "\(carrierDisplayName) identified" }
        return "Media unknown"
    }
}

/// Visibility policy for the destructive Eject action. A legacy
/// REFEED_REQUIRED refusal explicitly permits ejecting the still-held film,
/// while FILM_FEED_INTERRUPTED proves the scanner no longer detects film and
/// must never expose an eject action based on stale preview state. A fresh
/// hardware no-film reading is authoritative even after the error is dismissed.
public enum DeviceBarEjectPolicy {
    public static func canOffer(
        isConnected: Bool,
        transportIsIdle: Bool,
        isJobActive: Bool,
        mediaLoaded: Bool,
        filmPresent: Bool?,
        refeedRequired: Bool,
        lastErrorMessage: String?
    ) -> Bool {
        guard isConnected, transportIsIdle, !isJobActive else { return false }
        guard filmPresent != false else { return false }
        if FilmTransportFailurePolicy.isFilmFeedInterrupted(
            message: lastErrorMessage ?? ""
        ) {
            return false
        }
        return mediaLoaded || refeedRequired
    }
}
