/// Plain-language device activity labels. Preview acquisition moves through
/// the same transport but is not a scan job, so it must not be labeled as
/// scanning.
public enum DeviceActivityPolicy {
    public static func statusWord(
        isJobActive: Bool,
        isAcquiringPreviews: Bool,
        deviceKind: String?,
        hardwareMotionReadiness: HardwareMotionReadiness
    ) -> String {
        if isJobActive { return "SCANNING" }
        if isAcquiringPreviews { return "PREVIEWING" }
        if deviceKind == "simulated" { return "IDLE" }
        guard deviceKind == "real" else { return "CONNECTED" }
        switch hardwareMotionReadiness {
        case .ready:
            return "READY"
        case .notEnabled:
            return "NOT READY"
        case .unknown, .notApplicable:
            return "CHECK SCANNER"
        }
    }
}
