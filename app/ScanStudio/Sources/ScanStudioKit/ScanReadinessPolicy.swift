/// The single, pure rule for whether a scan may start.
///
/// Both the batch and single-frame actions must answer this question the same
/// way. Keeping the prerequisites here prevents one surface from looking
/// available while another correctly refuses the same scan.
public enum ScanReadinessPolicy {
    public struct Input: Equatable, Sendable {
        public let isConnected: Bool
        public let hasPreviewedMedia: Bool
        public let hasOpenProject: Bool
        /// `.notApplicable` for simulation; real hardware must provide an
        /// affirmative live readiness result before any scan start.
        public let hardwareMotionReadiness: HardwareMotionReadiness
        /// An existing project's frame registration must match the current
        /// successful preview before any frame can scan.
        public let projectMatchesPreviewedMedia: Bool
        /// The connected backend can preview this material but cannot run
        /// the requested fine-scan route.
        public let fineScanUnsupported: Bool
        /// Nonempty; every requested frame is in-range and not excluded.
        public let hasValidTarget: Bool
        /// Every structurally valid requested frame has its own preview.
        public let hasTargetPreviews: Bool
        public let transportIsIdle: Bool
        public let isAcquiringPreviews: Bool
        public let hasActiveJob: Bool
        public let isAdjustingFrameAlignment: Bool

        public init(
            isConnected: Bool,
            hasPreviewedMedia: Bool,
            hasOpenProject: Bool,
            hardwareMotionReadiness: HardwareMotionReadiness = .notApplicable,
            projectMatchesPreviewedMedia: Bool = true,
            fineScanUnsupported: Bool = false,
            hasValidTarget: Bool,
            hasTargetPreviews: Bool,
            transportIsIdle: Bool,
            isAcquiringPreviews: Bool,
            hasActiveJob: Bool,
            isAdjustingFrameAlignment: Bool = false
        ) {
            self.isConnected = isConnected
            self.hasPreviewedMedia = hasPreviewedMedia
            self.hasOpenProject = hasOpenProject
            self.hardwareMotionReadiness = hardwareMotionReadiness
            self.projectMatchesPreviewedMedia = projectMatchesPreviewedMedia
            self.fineScanUnsupported = fineScanUnsupported
            self.hasValidTarget = hasValidTarget
            self.hasTargetPreviews = hasTargetPreviews
            self.transportIsIdle = transportIsIdle
            self.isAcquiringPreviews = isAcquiringPreviews
            self.hasActiveJob = hasActiveJob
            self.isAdjustingFrameAlignment = isAdjustingFrameAlignment
        }
    }

    public enum Decision: Equatable, Sendable {
        case ready
        case scannerDisconnected
        case hardwareMotionNotReady
        case previewsUnavailable
        case projectRequired
        case projectMediaMismatch
        case fineScanUnsupported
        case targetRequired
        case targetPreviewsUnavailable
        case previewsInProgress
        case alignmentInProgress
        case scanInProgress
        case transportBusy

        public var isReady: Bool { self == .ready }

        /// Short, operator-facing explanation intended to sit next to a
        /// disabled scan action. Protocol codes remain in engine logs.
        public var reason: String? {
            switch self {
            case .ready: nil
            case .scannerDisconnected: "Connect the scanner to scan."
            case .hardwareMotionNotReady: "Check the scanner before scanning."
            case .previewsUnavailable: "Preview the loaded film before scanning."
            case .projectRequired: "Save the roll before scanning."
            case .projectMediaMismatch: "This saved project does not match the previewed holder or frame count. Create or open a matching project."
            case .fineScanUnsupported: "Live B&W fine scanning is unsupported by the current scanner bridge. Preview remains available."
            case .targetRequired: "Select a frame to scan."
            case .targetPreviewsUnavailable: "Preview every selected frame before scanning."
            case .previewsInProgress: "Wait for previews to finish."
            case .alignmentInProgress: "Wait for the frame alignment to finish."
            case .scanInProgress: "A scan is already in progress."
            case .transportBusy: "Wait for the scanner to become idle."
            }
        }
    }

    public static func evaluate(_ input: Input) -> Decision {
        guard input.isConnected else { return .scannerDisconnected }
        guard input.hardwareMotionReadiness.allowsMotion else {
            return .hardwareMotionNotReady
        }
        guard input.hasOpenProject else { return .projectRequired }
        guard input.hasPreviewedMedia else { return .previewsUnavailable }
        guard input.projectMatchesPreviewedMedia else { return .projectMediaMismatch }
        guard !input.fineScanUnsupported else { return .fineScanUnsupported }
        guard input.hasValidTarget else { return .targetRequired }
        guard input.hasTargetPreviews else { return .targetPreviewsUnavailable }
        guard !input.isAcquiringPreviews else { return .previewsInProgress }
        guard !input.isAdjustingFrameAlignment else {
            return .alignmentInProgress
        }
        guard !input.hasActiveJob else { return .scanInProgress }
        guard input.transportIsIdle else { return .transportBusy }
        return .ready
    }

    /// A target set must be nonempty and every requested frame must still be
    /// part of the loaded roll and not excluded.
    public static func allTargetsAreStructurallyValid(
        _ requestedFrames: [Int],
        validFrameIndices: Set<Int>,
        excludedFrameIndices: Set<Int>
    ) -> Bool {
        guard !requestedFrames.isEmpty else { return false }
        return requestedFrames.allSatisfy {
            validFrameIndices.contains($0)
                && !excludedFrameIndices.contains($0)
        }
    }

    /// Structural validity and per-frame preview availability are distinct:
    /// a selected, valid frame without a preview needs a preview instruction,
    /// not the misleading "Select a frame" instruction.
    public static func allTargetPreviewsAreAvailable(
        _ requestedFrames: [Int],
        previewedFrameIndices: Set<Int>
    ) -> Bool {
        !requestedFrames.isEmpty && requestedFrames.allSatisfy(previewedFrameIndices.contains)
    }
}
