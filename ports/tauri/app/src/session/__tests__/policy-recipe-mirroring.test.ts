// Recipe mirroring policy tests (04-03 Task 2). Client-side pre-validation
// duplicating PROTOCOL.md's recipe constraints (defaults, bit depths, pass
// counts, channels, bwNegative forcing rgb + ICE off, retained outputs,
// fullCapturePackage/enabled combination, per-frame processingOverride
// material matching, excluded-frame refusals) so the UI can pre-validate --
// while the engine's own INVALID_PARAMS remains the authority and surfaces
// verbatim when the wire call itself fails.

import { describe, expect, it } from "vitest";
import {
  SessionStore,
  applyRecipeDefaults,
  coerceMultisamplePasses,
  multisampleOptionsForDevice,
  resolveEffectiveProcessing,
  validateRecipe,
} from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { CaptureRecipe, DeviceInfo, OutputRecipe, ProcessingRecipe } from "../wire/types";

const VALID_CAPTURE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
} satisfies CaptureRecipe;

const VALID_PROCESSING: ProcessingRecipe = {
  filmProcess: "positive",
  autofocusEachFrame: false,
  autoExposureEachFrame: false,
  digitalIceEnabled: true,
  digitalIceMode: "legacy",
};

const VALID_OUTPUT: OutputRecipe = {
  archive: {
    enabled: true,
    filenameTemplate: "a.tiff",
    destination: "/out",
    fullCapturePackage: true,
  },
  positive: {
    enabled: true,
    fileFormat: "tiff",
    colorProfile: "sRgb",
    filenameTemplate: "p.tiff",
    destination: "/out",
  },
  preview: {
    enabled: false,
    fileFormat: "jpeg",
    maxLongEdgePx: 1024,
    filenameTemplate: "v.jpg",
    destination: "/out",
  },
};

const EMPTY_CTX = { requestedFrames: [1] };

// Issue: the Tauri client hardcoded [1,2,4,8,16]/multisamplePasses:1 with
// zero device awareness, so a real LS-5000 scan.start got refused --
// real_backend.rs's scan_start: "multisamplePasses must be one of [4] for
// this device". These three DeviceInfo shapes are the exact ones
// multisampleOptionsForDevice branches on.
const REAL_DEVICE_NO_WIRE_FIELD: DeviceInfo = {
  deviceId: "bridge-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "real",
  firmware: "bridge 0.7.0",
  connection: "USB (bridge)",
};

const REAL_DEVICE_WITH_WIRE_FIELD: DeviceInfo = {
  ...REAL_DEVICE_NO_WIRE_FIELD,
  supportedMultisamplePasses: [4, 8],
};

const SIMULATED_DEVICE: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "simulated",
  firmware: "1.03-sim",
  connection: "USB (simulated)",
};

function expectInvalid(
  recipe: Parameters<typeof validateRecipe>[0],
  ctx: Parameters<typeof validateRecipe>[1],
  field: string,
  messagePattern?: RegExp,
): void {
  const result = validateRecipe(recipe, ctx);
  expect(result).toEqual({
    valid: false,
    field,
    message: messagePattern ? expect.stringMatching(messagePattern) : expect.any(String),
  });
}

describe("SessionStore recipe mirroring (pure helpers)", () => {
  it("applies documented defaults when recipe fields are omitted", () => {
    const outputWithOmittedArchiveDefaults: OutputRecipe = {
      archive: { filenameTemplate: "a.tiff", destination: "/out" },
      positive: VALID_OUTPUT.positive,
      preview: VALID_OUTPUT.preview,
    };
    const resolved = applyRecipeDefaults({}, undefined, outputWithOmittedArchiveDefaults);
    expect(resolved.capture).toEqual({
      resolutionDpi: 4000,
      bitDepth: 16,
      multisamplePasses: 1,
      channels: "rgbi",
    });
    // ArchiveRecipe.enabled defaults to true; fullCapturePackage defaults to
    // true (requires enabled). Preview/positive have no documented default
    // enabled value and are left as given.
    expect(resolved.output?.archive.enabled).toBe(true);
    expect(resolved.output?.archive.fullCapturePackage).toBe(true);
    expect(resolved.output?.autoCrop).toBe(false);
    expect(resolved.processing).toBeUndefined();
  });

  describe("device-aware multisamplePasses (Issue: real LS-5000 refused scan.start)", () => {
    it("defaults to [4] and coerces the PROTOCOL.md default of 1 to 4 for a real device with no wire field", () => {
      expect(multisampleOptionsForDevice(REAL_DEVICE_NO_WIRE_FIELD)).toEqual([4]);
      const resolved = applyRecipeDefaults(undefined, undefined, undefined, REAL_DEVICE_NO_WIRE_FIELD);
      expect(resolved.capture.multisamplePasses).toBe(4);
    });

    it("honors the device's own wire-reported set when present, sorted", () => {
      expect(multisampleOptionsForDevice(REAL_DEVICE_WITH_WIRE_FIELD)).toEqual([4, 8]);
      // A caller-supplied value already valid for THIS device's own list
      // (8) must be kept, not coerced away to the hardcoded [4] fallback --
      // proves the wire field is actually consulted, not just kind==="real".
      const resolved = applyRecipeDefaults(
        { multisamplePasses: 8 },
        undefined,
        undefined,
        REAL_DEVICE_WITH_WIRE_FIELD,
      );
      expect(resolved.capture.multisamplePasses).toBe(8);
    });

    it("keeps the simulator's fuller range and default of 1 unchanged", () => {
      expect(multisampleOptionsForDevice(SIMULATED_DEVICE)).toEqual([1, 2, 4, 8, 16]);
      expect(multisampleOptionsForDevice(null)).toEqual([1, 2, 4, 8, 16]);
      expect(multisampleOptionsForDevice(undefined)).toEqual([1, 2, 4, 8, 16]);
      const resolved = applyRecipeDefaults(undefined, undefined, undefined, SIMULATED_DEVICE);
      expect(resolved.capture.multisamplePasses).toBe(1);
    });

    it("coerce prefers keeping a still-valid current value, else the nearest option (ties toward lower)", () => {
      expect(coerceMultisamplePasses(4, [4])).toBe(4);
      expect(coerceMultisamplePasses(2, [4])).toBe(4);
      expect(coerceMultisamplePasses(6, [4, 8])).toBe(4);
      expect(coerceMultisamplePasses(9, [4, 8])).toBe(8);
      expect(coerceMultisamplePasses(2, [])).toBe(2);
    });
  });

  it("rejects bitDepth outside {8,16}", () => {
    expectInvalid(
      { capture: { ...VALID_CAPTURE, bitDepth: 12 }, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      EMPTY_CTX,
      "capture.bitDepth",
    );
  });

  it("rejects multisamplePasses outside {1,2,4,8,16}", () => {
    expectInvalid(
      { capture: { ...VALID_CAPTURE, multisamplePasses: 3 }, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      EMPTY_CTX,
      "capture.multisamplePasses",
    );
  });

  it("rejects a multisamplePasses value valid historically but outside ctx.supportedMultisamplePasses", () => {
    // 8 is a normal member of the historical {1,2,4,8,16} set (would pass
    // the bare EMPTY_CTX check above) but is not one of this device's own
    // accepted values -- validateRecipe must use the device-scoped bound
    // when the caller supplies one, not silently fall back to the full set.
    expectInvalid(
      { capture: { ...VALID_CAPTURE, multisamplePasses: 8 }, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      { requestedFrames: [1], supportedMultisamplePasses: [4] },
      "capture.multisamplePasses",
      /must be one of 4/,
    );
    // The same value is accepted once it IS one of the device's own options.
    expect(
      validateRecipe(
        { capture: { ...VALID_CAPTURE, multisamplePasses: 8 }, processing: VALID_PROCESSING, output: VALID_OUTPUT },
        { requestedFrames: [1], supportedMultisamplePasses: [4, 8] },
      ),
    ).toEqual({ valid: true });
  });

  it("intersects the device's set with the protocol invariant instead of replacing it", () => {
    // A device advertising a value outside {1,2,4,8,16} narrows nothing
    // for that value: 3 stays invalid even when the wire claims it, and a
    // protocol-valid value outside the (filtered) device set stays
    // rejected on the device bound.
    expectInvalid(
      { capture: { ...VALID_CAPTURE, multisamplePasses: 3 }, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      { requestedFrames: [1], supportedMultisamplePasses: [3, 4] },
      "capture.multisamplePasses",
      /must be one of 4/,
    );
    expect(
      validateRecipe(
        { capture: { ...VALID_CAPTURE, multisamplePasses: 4 }, processing: VALID_PROCESSING, output: VALID_OUTPUT },
        { requestedFrames: [1], supportedMultisamplePasses: [3, 4] },
      ),
    ).toEqual({ valid: true });
  });

  it("forces channels to rgb and digitalIceEnabled to false for bwNegative", () => {
    const effective = resolveEffectiveProcessing({
      ...VALID_PROCESSING,
      filmProcess: "bwNegative",
      digitalIceEnabled: true,
    });
    expect(effective.channels).toBe("rgb");
    expect(effective.digitalIceEnabled).toBe(false);
    // Non-B&W processing is untouched.
    const unchanged = resolveEffectiveProcessing(VALID_PROCESSING);
    expect(unchanged.channels).toBe("rgbi");
    expect(unchanged.digitalIceEnabled).toBe(true);
  });

  it("requires at least one retained output", () => {
    const bothDisabled: OutputRecipe = {
      ...VALID_OUTPUT,
      archive: { ...VALID_OUTPUT.archive, enabled: false },
      positive: { ...VALID_OUTPUT.positive, enabled: false },
    };
    expectInvalid(
      { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: bothDisabled },
      EMPTY_CTX,
      "output",
      /at least one retained output/,
    );
  });

  it("accepts a preview-only retained output, matching the current engine", () => {
    const previewOnly: OutputRecipe = {
      ...VALID_OUTPUT,
      archive: { ...VALID_OUTPUT.archive, enabled: false, fullCapturePackage: false },
      positive: { ...VALID_OUTPUT.positive, enabled: false },
      preview: { ...VALID_OUTPUT.preview, enabled: true },
    };
    expect(
      validateRecipe(
        { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: previewOnly },
        EMPTY_CTX,
      ),
    ).toEqual({ valid: true });
  });

  it("rejects fullCapturePackage true with archive enabled false", () => {
    const disabledArchiveWithFullPackage: OutputRecipe = {
      ...VALID_OUTPUT,
      archive: { ...VALID_OUTPUT.archive, enabled: false, fullCapturePackage: true },
    };
    expectInvalid(
      { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: disabledArchiveWithFullPackage },
      EMPTY_CTX,
      "output.archive.fullCapturePackage",
    );
  });

  it("rejects a per-frame processingOverride.filmProcess mismatched against the active project", () => {
    const result = validateRecipe(
      { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      {
        activeProjectFilmProcess: "positive",
        frameProcessingOverrides: {
          5: { ...VALID_PROCESSING, filmProcess: "bwNegative" },
        },
        requestedFrames: [1, 5],
      },
    );
    expect(result).toEqual({
      valid: false,
      field: "processingOverride.filmProcess",
      message: expect.stringMatching(/5/),
    });
    // A matching override passes.
    const matching = validateRecipe(
      { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      {
        activeProjectFilmProcess: "positive",
        frameProcessingOverrides: {
          5: { ...VALID_PROCESSING, filmProcess: "positive" },
        },
        requestedFrames: [1, 5],
      },
    );
    expect(matching).toEqual({ valid: true });
  });

  it("rejects a request naming an excluded frame", () => {
    const result = validateRecipe(
      { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      { excludedFrameIndices: new Set([3, 7]), requestedFrames: [1, 3] },
    );
    expect(result).toEqual({
      valid: false,
      field: "frames",
      message: expect.stringMatching(/excluded frame/),
    });
    // No excluded frame in the request: valid.
    const clean = validateRecipe(
      { capture: VALID_CAPTURE, processing: VALID_PROCESSING, output: VALID_OUTPUT },
      { excludedFrameIndices: new Set([3, 7]), requestedFrames: [1, 2] },
    );
    expect(clean).toEqual({ valid: true });
  });
});

describe("SessionStore recipe mirroring (wired into startScan)", () => {
  it("surfaces a wire-sourced INVALID_PARAMS message verbatim even after local validation passes", async () => {
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        if (method === "scan.start") {
          return {
            error: {
              code: "INVALID_PARAMS",
              message: "engine-side rule this local mirror does not model: frame 3 excluded in manifest",
              recoverable: false,
            },
          };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    let caught: unknown;
    try {
      await store.startScan([1], VALID_CAPTURE);
    } catch (error) {
      caught = error;
    }
    expect(caught).toEqual({
      code: "INVALID_PARAMS",
      message: "engine-side rule this local mirror does not model: frame 3 excluded in manifest",
      recoverable: false,
    });
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(1);
  });

  // Connects the store to `device` via a scripted scanner.connect response,
  // then asserts what multisamplePasses scan.start actually receives when
  // startScan is called with `requested`. Isolates the three scenarios the
  // defect fix must cover end to end, through the exact path a real UI
  // startScan call takes (SessionStore.startScan -> applyRecipeDefaults ->
  // validateRecipe -> transport.sendRequest("scan.start", ...)).
  async function multisamplePassesSentToScanStart(
    device: DeviceInfo,
    requested: number,
  ): Promise<unknown> {
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        if (method === "scanner.connect") {
          return {
            result: {
              device,
              status: {
                connected: true,
                adapter: null,
                mediaLoaded: false,
                carrier: null,
                frameCount: null,
                lamp: "off",
                transport: "idle",
                activeJobId: null,
              },
            },
          };
        }
        if (method === "scan.start") return { result: { jobId: "job-multisample" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(device.deviceId);
    await store.startScan([1], {
      ...VALID_CAPTURE,
      multisamplePasses: requested as CaptureRecipe["multisamplePasses"],
    });
    const scanCall = calls.find((call) => call.method === "scan.start");
    const recipe = scanCall?.params.recipe as CaptureRecipe;
    return recipe.multisamplePasses;
  }

  it("coerces multisamplePasses:1 to 4 for a real device reporting no wire field", async () => {
    await expect(
      multisamplePassesSentToScanStart(REAL_DEVICE_NO_WIRE_FIELD, 1),
    ).resolves.toBe(4);
  });

  it("honors an already-valid multisamplePasses against the device's own wire-reported set", async () => {
    await expect(
      multisamplePassesSentToScanStart(REAL_DEVICE_WITH_WIRE_FIELD, 8),
    ).resolves.toBe(8);
  });

  it("leaves multisamplePasses untouched for the simulator", async () => {
    await expect(multisamplePassesSentToScanStart(SIMULATED_DEVICE, 8)).resolves.toBe(8);
  });

  it("the bwNegative forcing reaches the wire call (channels rgb, digitalIceEnabled false)", async () => {
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        if (method === "scan.start") return { result: { jobId: "job-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    await store.startScan([1], { ...VALID_CAPTURE, channels: "rgbi" }, {
      ...VALID_PROCESSING,
      filmProcess: "bwNegative",
      digitalIceEnabled: true,
    });
    const scanCall = calls.find((call) => call.method === "scan.start");
    expect(scanCall).toBeDefined();
    const params = scanCall?.params as { recipe: CaptureRecipe; processing: ProcessingRecipe };
    expect(params.recipe.channels).toBe("rgb");
    expect((params.processing as ProcessingRecipe & { channels?: string }).channels).toBe("rgb");
    expect(params.processing.digitalIceEnabled).toBe(false);
  });
});
