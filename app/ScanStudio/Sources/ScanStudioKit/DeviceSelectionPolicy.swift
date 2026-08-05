/// Pure connection-affordance and implicit-target policy.
///
/// Engine ordering is not a safety contract. In particular, the live engine
/// lists the simulator before a real LS-5000, so callers must never use
/// `devices.first` to resolve an unspecified connection target.
public enum DeviceSelectionPolicy {
    public enum State: Equatable, Sendable {
        case discovering
        case connecting
        case noDevices
        case directConnect(DeviceInfo)
        case explicitChoice([DeviceInfo])
        /// Only recognized-but-unsupported Nikon models (e.g. an LS-50) are
        /// present: they are named but have no connect affordance (Lane D, #14).
        case unsupported([DeviceInfo])

        public var progressText: String? {
            switch self {
            case .discovering:
                "Searching for scanner…"
            case .connecting:
                "Connecting to scanner…"
            case .noDevices, .directConnect, .explicitChoice, .unsupported:
                nil
            }
        }
    }

    public static func state(
        isDiscovering: Bool,
        isConnecting: Bool = false,
        devices: [DeviceInfo]
    ) -> State {
        if isDiscovering {
            return .discovering
        }
        if isConnecting {
            return .connecting
        }
        let unsupported = unsupportedDevices(from: devices)
        let visibleDevices = connectionCandidates(from: devices)
        switch visibleDevices.count {
        case 0:
            // No connectable device, but a recognized unsupported model is
            // present -- named card, no connect affordance (never the silent
            // empty-list confusion of #14).
            return unsupported.isEmpty ? .noDevices : .unsupported(unsupported)
        case 1:
            return .directConnect(visibleDevices[0])
        default:
            return .explicitChoice(rank(visibleDevices))
        }
    }

    /// Connection affordances prefer discovered hardware over the simulator,
    /// and never include a recognized-but-unsupported model (Lane D, #14).
    /// The underlying discovery list is intentionally left untouched: it is
    /// still the engine's authoritative inventory, but a simulator must not
    /// compete with an available real scanner at the decision point, and an
    /// unsupported unit is never connectable.
    public static func connectionCandidates(from devices: [DeviceInfo]) -> [DeviceInfo] {
        let supported = devices.filter { $0.supported }
        let realDevices = supported.filter { $0.kind == "real" }
        return realDevices.isEmpty ? supported : realDevices
    }

    /// Recognized-but-unsupported Nikon models present in discovery (Lane D).
    /// These are shown by name, grayed out, and are never connect candidates.
    public static func unsupportedDevices(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter { !$0.supported }
    }

    /// Stable-partitions real devices ahead of simulators while preserving
    /// discovery order inside each group.
    public static func rank(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        let real = devices.filter { $0.kind == "real" }
        let other = devices.filter { $0.kind != "real" }
        return real + other
    }

    /// An unspecified target is safe only when exactly one device exists.
    /// Multiple devices always require an explicit user choice.
    public static func resolveNilTarget(devices: [DeviceInfo]) -> String? {
        // A caller that omitted its target may not silently gain permission to
        // choose a real scanner merely because the UI filters a simulator out.
        // The UI always sends an explicit id from `state`'s visible candidate.
        guard devices.count == 1 else { return nil }
        return devices[0].deviceId
    }

    public static func connectLabel(for device: DeviceInfo) -> String {
        device.kind == "simulated" ? "Connect Simulator" : "Connect \(device.model)"
    }

    public static func menuLabel(for device: DeviceInfo) -> String {
        device.kind == "simulated" ? "Simulator — \(device.model)" : device.model
    }
}
