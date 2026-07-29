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

        public var progressText: String? {
            switch self {
            case .discovering:
                "Searching for scanner…"
            case .connecting:
                "Connecting to scanner…"
            case .noDevices, .directConnect, .explicitChoice:
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
        let visibleDevices = connectionCandidates(from: devices)
        switch visibleDevices.count {
        case 0:
            return .noDevices
        case 1:
            return .directConnect(visibleDevices[0])
        default:
            return .explicitChoice(rank(visibleDevices))
        }
    }

    /// Connection affordances prefer discovered hardware over the simulator.
    /// The underlying discovery list is intentionally left untouched: it is
    /// still the engine's authoritative inventory, but a simulator must not
    /// compete with an available real scanner at the decision point.
    public static func connectionCandidates(from devices: [DeviceInfo]) -> [DeviceInfo] {
        let realDevices = devices.filter { $0.kind == "real" }
        return realDevices.isEmpty ? devices : realDevices
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
