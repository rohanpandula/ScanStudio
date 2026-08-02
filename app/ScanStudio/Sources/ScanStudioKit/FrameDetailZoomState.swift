import CoreGraphics

/// Testable viewport state shared by Frame Detail's native controls and
/// existing magnify/pan gestures.
public struct FrameDetailZoomState: Equatable, Sendable {
    public static let minimumScale: CGFloat = 1
    public static let maximumScale: CGFloat = 4
    public static let controlStep: CGFloat = 0.5

    public private(set) var scale: CGFloat = minimumScale
    public private(set) var panOffset: CGSize = .zero

    private var steadyScale: CGFloat = minimumScale
    private var steadyPanOffset: CGSize = .zero

    public init() {}

    public var canZoomOut: Bool { scale > Self.minimumScale }
    public var canZoomIn: Bool { scale < Self.maximumScale }
    public var isFitted: Bool {
        scale == Self.minimumScale && panOffset == .zero
    }

    public mutating func step(by delta: CGFloat) {
        scale = Self.clamp(scale + delta)
        steadyScale = scale
        if scale == Self.minimumScale {
            reset()
        }
    }

    public mutating func updateMagnification(_ gestureScale: CGFloat) {
        scale = Self.clamp(steadyScale * gestureScale)
    }

    public mutating func finishMagnification() {
        steadyScale = scale
        if scale == Self.minimumScale {
            reset()
        }
    }

    public mutating func updatePan(translation: CGSize) {
        guard scale > Self.minimumScale else { return }
        panOffset = CGSize(
            width: steadyPanOffset.width + translation.width,
            height: steadyPanOffset.height + translation.height
        )
    }

    public mutating func finishPan() {
        steadyPanOffset = panOffset
    }

    public mutating func reset() {
        scale = Self.minimumScale
        steadyScale = Self.minimumScale
        panOffset = .zero
        steadyPanOffset = .zero
    }

    private static func clamp(_ scale: CGFloat) -> CGFloat {
        min(Self.maximumScale, max(Self.minimumScale, scale))
    }
}
