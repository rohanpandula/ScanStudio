/// Honest, read-only film-presence copy for the hardware readiness surface.
public enum HardwareFilmStatus: Equatable, Sendable {
    case loaded
    case notDetected
    case unknown

    public static func evaluate(
        isConnected: Bool,
        isRealDevice: Bool,
        mediaLoaded: Bool?,
        filmPresent: Bool?
    ) -> HardwareFilmStatus {
        guard isConnected else { return .unknown }
        if isRealDevice {
            switch filmPresent {
            case .some(true): return .loaded
            case .some(false): return .notDetected
            case .none: return .unknown
            }
        }
        switch mediaLoaded {
        case .some(true): return .loaded
        case .some(false): return .notDetected
        case .none: return .unknown
        }
    }

    public var title: String {
        switch self {
        case .loaded: "Loaded"
        case .notDetected: "Not detected"
        case .unknown: "Unknown"
        }
    }
}
