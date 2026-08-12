/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import type { AnalyzeFrameDefectsResult } from "../../session/wire/types";
import DefectOverlay from "../DefectOverlay";

afterEach(cleanup);

function result(overrides: Partial<AnalyzeFrameDefectsResult> = {}): AnalyzeFrameDefectsResult {
  return {
    frameIndex: 3,
    capture: { resolutionDpi: 4000, bitDepth: 16, multisamplePasses: 1, channels: "rgbi" },
    processing: {
      filmProcess: "positive",
      autofocusEachFrame: true,
      autoExposureEachFrame: true,
      digitalIceEnabled: true,
      digitalIceMode: "legacy",
      softwareDustRemovalBw: false,
    },
    defects: [],
    simulated: true,
    digitalIceEnabled: true,
    transportSmearFlagged: false,
    transportSmearReason: null,
    ...overrides,
  };
}

describe("DefectOverlay", () => {
  it("renders a red circle for a willCorrect dust defect, positioned from the response", () => {
    render(
      <DefectOverlay
        result={result({
          defects: [
            {
              id: 1,
              kind: "dust",
              severity: 0.9,
              classification: "willCorrect",
              centerX: 0.5,
              centerY: 0.4,
              radius: 0.03,
            },
          ],
        })}
      />,
    );
    const marker = screen.getByTestId("defect-marker-1");
    expect(marker).toHaveAttribute("data-kind", "dust");
    expect(marker).toHaveAttribute("data-classification", "willCorrect");
    expect(marker).toHaveAttribute("cx", "0.5");
    expect(marker).toHaveAttribute("cy", "0.4");
    expect(marker.getAttribute("stroke")).toBe("#dc2626");
  });

  it("renders an amber line for an uncertain scratch defect with endpoints", () => {
    render(
      <DefectOverlay
        result={result({
          defects: [
            {
              id: 2,
              kind: "scratch",
              severity: 0.4,
              classification: "uncertain",
              centerX: 0.1,
              centerY: 0.1,
              radius: 0,
              endX: 0.9,
              endY: 0.8,
            },
          ],
        })}
      />,
    );
    const marker = screen.getByTestId("defect-marker-2");
    expect(marker).toHaveAttribute("data-kind", "scratch");
    expect(marker).toHaveAttribute("x1", "0.1");
    expect(marker).toHaveAttribute("x2", "0.9");
    expect(marker).toHaveAttribute("data-classification", "uncertain");
    expect(marker.getAttribute("stroke")).toBe("#d97706");
  });

  it("always shows the Simulated badge when simulated is true, never when false", () => {
    const { rerender } = render(<DefectOverlay result={result({ simulated: true })} />);
    expect(screen.getByTestId("defect-simulated-badge")).toBeInTheDocument();
    expect(screen.queryByTestId("defect-real-badge")).toBeNull();

    rerender(<DefectOverlay result={result({ simulated: false })} />);
    expect(screen.queryByTestId("defect-simulated-badge")).toBeNull();
    expect(screen.getByTestId("defect-real-badge")).toBeInTheDocument();
  });

  it("renders distinct copy for ICE-off vs clean-empty (never ambiguous)", () => {
    render(<DefectOverlay result={result({ defects: [], digitalIceEnabled: false })} />);
    const iceOffText = screen.getByTestId("defect-ice-off-notice").textContent ?? "";
    expect(iceOffText).toContain("Digital ICE is off");

    cleanup();
    render(<DefectOverlay result={result({ defects: [], digitalIceEnabled: true })} />);
    const cleanText = screen.getByTestId("defect-clean-notice").textContent ?? "";
    expect(cleanText).toContain("No defects detected");
    // The two notices use different copy -- an empty defects array is never
    // ambiguous about whether ICE ran.
    expect(iceOffText).not.toBe(cleanText);
  });
});
