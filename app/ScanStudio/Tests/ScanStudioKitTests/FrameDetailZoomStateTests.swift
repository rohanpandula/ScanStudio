import CoreGraphics
import Testing

@testable import ScanStudioKit

@Suite("Frame Detail zoom state")
struct FrameDetailZoomStateTests {
    @Test("native zoom steps clamp to 100–400 percent and expose correct control availability")
    func nativeControlLimits() {
        var state = FrameDetailZoomState()

        #expect(state.scale == 1)
        #expect(!state.canZoomOut)
        #expect(state.canZoomIn)
        #expect(state.isFitted)

        for _ in 0..<10 {
            state.step(by: FrameDetailZoomState.controlStep)
        }

        #expect(state.scale == 4)
        #expect(state.canZoomOut)
        #expect(!state.canZoomIn)
        #expect(!state.isFitted)
    }

    @Test("Zoom Out returning to fit resets both live and accumulated pan")
    func zoomOutToFitResetsPan() {
        var state = FrameDetailZoomState()
        state.updateViewportSize(CGSize(width: 400, height: 300))
        state.step(by: FrameDetailZoomState.controlStep)
        state.updatePan(translation: CGSize(width: 24, height: -12))
        state.finishPan()

        #expect(state.panOffset == CGSize(width: 24, height: -12))

        state.step(by: -FrameDetailZoomState.controlStep)

        #expect(state.scale == 1)
        #expect(state.panOffset == .zero)
        #expect(state.isFitted)
    }

    @Test("pinch magnification and panning share the same clamped viewport state")
    func gestureStateSharesLimits() {
        var state = FrameDetailZoomState()
        state.updateViewportSize(CGSize(width: 400, height: 300))
        state.updateMagnification(8)
        state.finishMagnification()

        #expect(state.scale == 4)

        state.updatePan(translation: CGSize(width: 10, height: 15))
        state.finishPan()
        state.updatePan(translation: CGSize(width: -4, height: 5))

        #expect(state.panOffset == CGSize(width: 6, height: 20))

        state.reset()

        #expect(state.scale == 1)
        #expect(state.panOffset == .zero)
        #expect(state.isFitted)
    }

    @Test("discrete pan clamps at every edge and the next drag starts from that position")
    func discretePanClampsAndAccumulates() {
        var state = FrameDetailZoomState()
        state.updateViewportSize(CGSize(width: 400, height: 300))
        state.pan(by: CGSize(width: 40, height: 40))
        #expect(state.panOffset == .zero)

        state.step(by: 1)
        state.pan(by: CGSize(width: 1_000, height: -1_000))
        #expect(state.panOffset == CGSize(width: 200, height: -150))
        state.updatePan(translation: CGSize(width: -40, height: 40))
        state.finishPan()
        #expect(state.panOffset == CGSize(width: 160, height: -110))
        state.pan(by: CGSize(width: -1_000, height: 1_000))
        #expect(state.panOffset == CGSize(width: -200, height: 150))
    }

    @Test("zooming out and resizing constrain both current and accumulated pan")
    func viewportChangesConstrainPan() {
        var state = FrameDetailZoomState()
        state.updateViewportSize(CGSize(width: 400, height: 300))
        state.step(by: 3)
        state.pan(by: CGSize(width: 1_000, height: 1_000))
        state.step(by: -2)
        #expect(state.panOffset == CGSize(width: 200, height: 150))

        state.updateViewportSize(CGSize(width: 200, height: 100))
        #expect(state.panOffset == CGSize(width: 100, height: 50))
        state.pan(by: CGSize(width: -40, height: -40))
        #expect(state.panOffset == CGSize(width: 60, height: 10))

        state.updateMagnification(0.75)
        state.finishMagnification()
        #expect(state.panOffset == CGSize(width: 50, height: 10))
        state.reset()
        state.step(by: 1)
        state.pan(by: CGSize(width: 40, height: 40))
        #expect(state.panOffset == CGSize(width: 40, height: 40))
    }
}
