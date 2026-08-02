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
}
