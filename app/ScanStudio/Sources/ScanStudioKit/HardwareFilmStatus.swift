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
            case true: return .loaded
            case false: return .notDetected
            case nil: return .unknown
            }
        }
        switch mediaLoaded {
        case true: return .loaded
        case false: return .notDetected
        case nil: return .unknown
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
