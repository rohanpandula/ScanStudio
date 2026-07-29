/// Scanner-position adjustment is a bridge-backed real-device capability.
/// Simulator thumbnails have no physical frame boundary to move, so their
/// workspaces omit the control rather than presenting an inert affordance.
public enum FrameAlignmentAvailabilityPolicy {
    public static func isVisible(deviceKind: String?) -> Bool {
        deviceKind == "real"
    }
}
