/// Truthful, compact media copy for the device bar. `filmPresent` is a live
/// hardware sensor read only when non-nil; absence means unknown, never
/// ejected or loaded.
public enum DeviceBarMediaPolicy {
    public static func label(
        isAcquiringPreviews: Bool,
        mediaLoaded: Bool,
        carrierDisplayName: String?,
        filmPresent: Bool?
    ) -> String {
        if isAcquiringPreviews { return "Detecting film" }
        if mediaLoaded { return carrierDisplayName ?? "Previewed film" }
        if filmPresent == true { return "Film present; preview needed" }
        if let carrierDisplayName { return "\(carrierDisplayName) identified" }
        return "Media unknown"
    }
}
