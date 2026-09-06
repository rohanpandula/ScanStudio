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
    private var viewportSize: CGSize = .zero

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
        constrainPan()
    }

    public mutating func updateMagnification(_ gestureScale: CGFloat) {
        scale = Self.clamp(steadyScale * gestureScale)
        constrainPan()
    }

    public mutating func finishMagnification() {
        steadyScale = scale
        if scale == Self.minimumScale {
            reset()
        }
    }

    public mutating func updatePan(translation: CGSize) {
        guard scale > Self.minimumScale else { return }
        panOffset = boundedPan(CGSize(
            width: steadyPanOffset.width + translation.width,
            height: steadyPanOffset.height + translation.height
        ))
    }

    public mutating func updateViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        viewportSize = CGSize(width: max(0, size.width), height: max(0, size.height))
        constrainPan()
    }

    /// Discrete movement shared by keyboard and accessibility actions.
    public mutating func pan(by delta: CGSize) {
        updatePan(translation: delta)
        finishPan()
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

    private func boundedPan(_ offset: CGSize) -> CGSize {
        let horizontalLimit = viewportSize.width * (scale - 1) / 2
        let verticalLimit = viewportSize.height * (scale - 1) / 2
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }

    private mutating func constrainPan() {
        panOffset = boundedPan(panOffset)
        steadyPanOffset = boundedPan(steadyPanOffset)
    }
}
