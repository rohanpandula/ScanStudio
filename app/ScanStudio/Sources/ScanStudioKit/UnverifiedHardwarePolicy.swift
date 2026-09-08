import Foundation

public enum UnverifiedHardwarePolicy {
    public static func connectCandidates(from devices: [DeviceInfo], allowUnverified: Bool) -> [DeviceInfo] {
        guard allowUnverified else { return DeviceSelectionPolicy.connectionCandidates(from: devices) }
        let supported = devices.filter { $0.supported || $0.unverifiedAllowed }
        let real = supported.filter { $0.kind == "real" }
        return real.isEmpty ? supported : real
    }

    public static func badge(model: String?, verification: String?) -> String? {
        guard verification == "unverified", let model, !model.isEmpty else { return nil }
        return "Unverified scanner — \(model)"
    }

    /// A per-command opt-in must be checked after status, including when the
    /// scanner was opened by the GUI and refresh therefore needed no connect.
    public static func shouldRefuseConnectedUnverified(verification: String?, allowUnverified: Bool) -> Bool {
        verification == "unverified" && !allowUnverified
    }

    public static func shouldOfferDiagnosticBundle(errorCode: String?, verification: String?, alreadyOffered: Bool) -> Bool {
        errorCode != nil && verification == "unverified" && !alreadyOffered
    }
}
