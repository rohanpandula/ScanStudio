/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import ZoomPanViewer from "../ZoomPanViewer";

afterEach(cleanup);

const IMAGE_PATH = "/scans/frames/frame-0002.png";

function renderViewer() {
  return render(<ZoomPanViewer imagePath={IMAGE_PATH} alt="Frame 2 preview" />);
}

const viewport = (): HTMLElement => screen.getByTestId("zoom-pan-viewer");
const imageOf = (): HTMLImageElement => screen.getByTestId("zoom-pan-image") as HTMLImageElement;
const scaleOf = (): number => Number(imageOf().dataset.scale);
const translateOf = (): { x: number; y: number } => ({
  x: Number(imageOf().dataset.translateX),
  y: Number(imageOf().dataset.translateY),
});

describe("ZoomPanViewer", () => {
  it("renders the frame image via the Phase 3 scanstudio-preview protocol URL", () => {
    renderViewer();
    expect(imageOf().src).toBe(
      "scanstudio-preview://localhost/?id=" + encodeURIComponent(IMAGE_PATH),
    );
  });

  it("centers quarter-turn geometry and keeps the overlay in the same transform plane", () => {
    render(
      <ZoomPanViewer
        imagePath={IMAGE_PATH}
        derivativeTransform={{
          rotationDegrees: 90,
          horizontalMirror: true,
          verticalMirror: false,
        }}
        overlay={<span data-testid="test-overlay">Overlay</span>}
      />,
    );

    expect(viewport()).toHaveAttribute("data-axis-swapped", "true");
    expect(viewport()).toHaveStyle({ aspectRatio: "2 / 3" });
    const layer = screen.getByTestId("derivative-layer");
    expect(layer).toHaveStyle({
      width: "150%",
      height: "66.6667%",
      transform: "translate(-50%, -50%) rotate(90deg) scaleX(-1) scaleY(1)",
    });
    expect(layer).toContainElement(screen.getByTestId("zoom-pan-image"));
    expect(layer).toContainElement(screen.getByTestId("test-overlay"));
  });

  it("starts at scale 1 with zero translation", () => {
    renderViewer();
    expect(scaleOf()).toBe(1);
    expect(translateOf()).toEqual({ x: 0, y: 0 });
  });

  it("zooms in on wheel-up, zooms out on wheel-down, and clamps to [1, 8]", () => {
    renderViewer();
    fireEvent.wheel(viewport(), { deltaY: -100 });
    expect(scaleOf()).toBe(1.1);
    fireEvent.wheel(viewport(), { deltaY: -100 });
    fireEvent.wheel(viewport(), { deltaY: -100 });
    expect(scaleOf()).toBe(1.3);

    fireEvent.wheel(viewport(), { deltaY: 100 });
    expect(scaleOf()).toBe(1.2);

    for (let index = 0; index < 100; index += 1) {
      fireEvent.wheel(viewport(), { deltaY: -100 });
    }
    expect(scaleOf()).toBe(8);

    for (let index = 0; index < 100; index += 1) {
      fireEvent.wheel(viewport(), { deltaY: 100 });
    }
    expect(scaleOf()).toBe(1);
  });

  it("steps scale with the +/-/= keys and resets to scale 1, origin translate with the 0 key", () => {
    renderViewer();
    fireEvent.keyDown(viewport(), { key: "+" });
    expect(scaleOf()).toBe(1.1);
    fireEvent.keyDown(viewport(), { key: "=" });
    expect(scaleOf()).toBe(1.2);
    fireEvent.keyDown(viewport(), { key: "-" });
    expect(scaleOf()).toBe(1.1);

    for (let index = 0; index < 100; index += 1) {
      fireEvent.keyDown(viewport(), { key: "+" });
    }
    expect(scaleOf()).toBe(8);

    // Pan to a nonzero translate, then the 0 key must reset both.
    fireEvent.mouseDown(viewport(), { clientX: 100, clientY: 100 });
    fireEvent.mouseMove(viewport(), { clientX: 140, clientY: 160 });
    fireEvent.mouseUp(viewport());
    expect(translateOf()).not.toEqual({ x: 0, y: 0 });

    fireEvent.keyDown(viewport(), { key: "0" });
    expect(scaleOf()).toBe(1);
    expect(translateOf()).toEqual({ x: 0, y: 0 });
  });

  it("clamps keyboard zoom to [1, 8]", () => {
    renderViewer();
    for (let index = 0; index < 100; index += 1) {
      fireEvent.keyDown(viewport(), { key: "+" });
    }
    expect(scaleOf()).toBe(8);
    for (let index = 0; index < 100; index += 1) {
      fireEvent.keyDown(viewport(), { key: "-" });
    }
    expect(scaleOf()).toBe(1);
  });

  it("does not fire viewer keys when the keydown target is outside the component", () => {
    renderViewer();
    fireEvent.keyDown(document, { key: "+" });
    fireEvent.keyDown(document.body, { key: "-" });
    expect(scaleOf()).toBe(1);
    expect(translateOf()).toEqual({ x: 0, y: 0 });
  });

  it("pans via drag only when zoomed in past scale 1", () => {
    renderViewer();

    // At scale 1 a drag must not move the image.
    fireEvent.mouseDown(viewport(), { clientX: 100, clientY: 100 });
    fireEvent.mouseMove(viewport(), { clientX: 120, clientY: 130 });
    fireEvent.mouseUp(viewport());
    expect(translateOf()).toEqual({ x: 0, y: 0 });

    // Zoom in, then the same gesture pans by the exact mouse deltas.
    for (let index = 0; index < 5; index += 1) {
      fireEvent.wheel(viewport(), { deltaY: -100 });
    }
    expect(scaleOf()).toBe(1.5);
    fireEvent.mouseDown(viewport(), { clientX: 100, clientY: 100 });
    fireEvent.mouseMove(viewport(), { clientX: 122, clientY: 133 });
    fireEvent.mouseMove(viewport(), { clientX: 132, clientY: 138 });
    fireEvent.mouseUp(viewport());
    expect(translateOf()).toEqual({ x: 32, y: 38 });
  });

  it("renders a placeholder instead of an image when no imagePath is available", () => {
    render(<ZoomPanViewer />);
    expect(screen.getByTestId("zoom-pan-empty")).toBeInTheDocument();
    expect(screen.queryByTestId("zoom-pan-image")).toBeNull();
  });
});
