/// User-facing interpretation of the bridge's live, read-only hardware
/// movement check. This type never changes readiness; it only reports
/// whether a real-device movement may be offered.
public enum HardwareMotionReadiness: Equatable, Sendable {
    case notApplicable
    case ready
    case notEnabled
    case unknown

    public static func evaluate(
        isRealDevice: Bool,
        motionArmed: Bool?
    ) -> HardwareMotionReadiness {
        guard isRealDevice else { return .notApplicable }
        switch motionArmed {
        case .some(true): return .ready
        case .some(false): return .notEnabled
        case .none: return .unknown
        }
    }

    public var allowsMotion: Bool {
        switch self {
        case .notApplicable, .ready: true
        case .notEnabled, .unknown: false
        }
    }

    public var needsCheck: Bool {
        self == .notEnabled || self == .unknown
    }

    public var statusRefreshTitle: String {
        needsCheck ? "Check scanner" : "Refresh status"
    }

    public var title: String {
        switch self {
        case .notApplicable: ""
        case .ready: "Scanner is ready"
        case .notEnabled: "Scanner isn’t ready yet"
        case .unknown: "Scanner status hasn’t been checked"
        }
    }

    public var guidance: String {
        switch self {
        case .notApplicable: ""
        case .ready: "The scanner can accept preview, scan, and eject commands."
        case .notEnabled:
            "Restart ScanStudio, then check the scanner again."
        case .unknown:
            "Check the scanner before previewing, scanning, or ejecting film."
        }
    }
}

/// User-facing scanner state derived from the separate command, film, and
/// workflow gates. Keeping these facts separate prevents the UI from claiming
/// that a loaded strip is ready to scan before it has previews, a project, and
/// a valid selection.
public struct ScannerReadinessPresentation: Equatable, Sendable {
    public let title: String
    public let guidance: String

    public static func evaluate(
        hardwareReadiness: HardwareMotionReadiness,
        filmStatus: HardwareFilmStatus,
        hasPreviewedMedia: Bool,
        scanReadiness: ScanReadinessPolicy.Decision
    ) -> ScannerReadinessPresentation {
        switch hardwareReadiness {
        case .notApplicable:
            return .init(title: "", guidance: "")
        case .notEnabled:
            return .init(
                title: hardwareReadiness.title,
                guidance: hardwareReadiness.guidance
            )
        case .unknown:
            return .init(
                title: hardwareReadiness.title,
                guidance: hardwareReadiness.guidance
            )
        case .ready:
            switch filmStatus {
            case .notDetected:
                return .init(
                    title: "Scanner is ready for film",
                    guidance: "Insert film to preview or scan."
                )
            case .unknown:
                return .init(
                    title: "Scanner is ready",
                    guidance: "Refresh status to check whether film is loaded."
                )
            case .loaded:
                guard hasPreviewedMedia else {
                    return .init(
                        title: "Film is loaded",
                        guidance: "Preview the film before scanning."
                    )
                }
                guard scanReadiness.isReady else {
                    return .init(
                        title: "Film is loaded",
                        guidance: scanReadiness.reason
                            ?? "Complete the remaining scan setup."
                    )
                }
                return .init(
                    title: "Scanner is ready to scan",
                    guidance: "The selected frames are ready."
                )
            }
        }
    }
}
