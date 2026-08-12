// Defect-analysis wrapper policy tests (07-02 Task 2): analyzeFrameDefects
// forwards the exact request and returns the engine response unchanged --
// including the simulated/digitalIceEnabled flags the overlay's honesty
// require -- with no client-side re-derivation.

import { describe, expect, it } from "vitest";
import { analyzeFrameDefects, type DefectRequest } from "../store/defects";

describe("analyzeFrameDefects wrapper", () => {
  it("sends only frameIndex so the engine resolves recipes authoritatively", async () => {
    const calls: Array<{ method: string; params: unknown }> = [];
    const request: DefectRequest = async (method, params) => {
      calls.push({ method, params });
      return {
        frameIndex: 3,
        defects: [],
        simulated: true,
        digitalIceEnabled: true,
        transportSmearFlagged: false,
        transportSmearReason: null,
      };
    };
    const result = await analyzeFrameDefects(request, 3);
    expect(calls[0].method).toBe("project.analyzeFrameDefects");
    expect(calls[0].params).toEqual({ frameIndex: 3 });
    expect(result.frameIndex).toBe(3);
    expect(result.simulated).toBe(true);
  });

  it("returns the engine response unchanged, including an honest simulated flag", async () => {
    const request: DefectRequest = async () => ({
      frameIndex: 1,
      capture: { resolutionDpi: 2000, bitDepth: 16, multisamplePasses: 4, channels: "rgb" },
      processing: {
        filmProcess: "bwNegative",
        autofocusEachFrame: true,
        autoExposureEachFrame: false,
        digitalIceEnabled: false,
        digitalIceMode: "legacy",
        softwareDustRemovalBw: true,
      },
      defects: [
        {
          id: 1,
          kind: "dust",
          severity: 0.9,
          classification: "willCorrect",
          centerX: 0.5,
          centerY: 0.5,
          radius: 0.02,
        },
      ],
      simulated: false,
      digitalIceEnabled: true,
      transportSmearFlagged: true,
      transportSmearReason: "smear detected on transport",
    });
    const result = await analyzeFrameDefects(request, 1);
    // The response is passed through untouched -- the overlay reads
    // classification/simulated straight off it, never recomputing a
    // threshold or masking the flag.
    expect(result).toEqual({
      frameIndex: 1,
      capture: { resolutionDpi: 2000, bitDepth: 16, multisamplePasses: 4, channels: "rgb" },
      processing: {
        filmProcess: "bwNegative",
        autofocusEachFrame: true,
        autoExposureEachFrame: false,
        digitalIceEnabled: false,
        digitalIceMode: "legacy",
        softwareDustRemovalBw: true,
      },
      defects: [
        {
          id: 1,
          kind: "dust",
          severity: 0.9,
          classification: "willCorrect",
          centerX: 0.5,
          centerY: 0.5,
          radius: 0.02,
        },
      ],
      simulated: false,
      digitalIceEnabled: true,
      transportSmearFlagged: true,
      transportSmearReason: "smear detected on transport",
    });
  });
});
