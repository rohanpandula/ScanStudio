/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { ScanProject } from "../../../session/wire/types";
import FrameOverrideEditor from "../FrameOverrideEditor";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../../session", () => mocks);

const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));

const CAPTURE = {
  resolutionDpi: 4000,
  bitDepth: 16 as const,
  multisamplePasses: 1 as const,
  channels: "rgbi" as const,
};

const PROCESSING = {
  filmProcess: "c41ColorNegative" as const,
  autofocusEachFrame: true,
  autoExposureEachFrame: false,
  digitalIceEnabled: true,
  digitalIceMode: "hybrid" as const,
  softwareDustRemovalBw: false,
};

const OUTPUT = {
  archive: {
    enabled: true,
    filenameTemplate: "IMG_####.tiff",
    destination: "/archive",
    fullCapturePackage: true,
  },
  positive: {
    enabled: true,
    fileFormat: "tiff" as const,
    colorProfile: "sRgb" as const,
    filenameTemplate: "POS_####.tiff",
    destination: "/positive",
  },
  preview: {
    enabled: true,
    fileFormat: "jpeg" as const,
    maxLongEdgePx: 2048,
    filenameTemplate: "PRE_####.jpg",
    destination: "/preview",
  },
};

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-1",
  name: "Override Roll",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "c41ColorNegative",
  recipes: OUTPUT,
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00.000Z",
  frames: [{ index: 1, excluded: false, receipts: [] }],
};

interface Call {
  method: string;
  params: Record<string, unknown>;
}

function fixture() {
  const calls: Call[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      return { result: { project: PROJECT } };
    },
  });
  const store = new SessionStore(handle.transport);
  mocks.sessionStore = store;
  return { calls, store };
}

describe("FrameOverrideEditor", () => {
  it("saves a whole-object capture override, never a merged payload", async () => {
    const { calls } = fixture();
    const user = userEvent.setup();
    render(
      <FrameOverrideEditor
        frameIndex={1}
        filmProcess="c41ColorNegative"
        rollCapture={CAPTURE}
        rollProcessing={PROCESSING}
        rollOutput={OUTPUT}
        project={PROJECT}
      />,
    );
    await user.click(screen.getByTestId("toggle-override-capture"));
    await user.clear(screen.getByTestId("capture-res-dpi"));
    await user.type(screen.getByTestId("capture-res-dpi"), "2000");
    await user.click(screen.getByTestId("save-override-capture"));
    const call = calls[0];
    expect(call.method).toBe("project.setFrameCaptureOverride");
    // The complete recipe object is sent -- including unchanged fields.
    expect(call.params.capture).toEqual({ ...CAPTURE, resolutionDpi: 2000 });
    expect(call.params.frameIndex).toBe(1);
  });

  it("clears an override with null when reverting to the roll default", async () => {
    const { calls } = fixture();
    const user = userEvent.setup();
    const projectWithOverride = {
      ...PROJECT,
      frames: [{ index: 1, excluded: false, receipts: [], captureOverride: CAPTURE }],
    };
    render(
      <FrameOverrideEditor
        frameIndex={1}
        filmProcess="c41ColorNegative"
        rollCapture={CAPTURE}
        rollProcessing={PROCESSING}
        rollOutput={OUTPUT}
        project={projectWithOverride}
      />,
    );
    await user.click(screen.getByTestId("clear-override-capture"));
    const call = calls[0];
    expect(call.method).toBe("project.setFrameCaptureOverride");
    expect(call.params.capture).toBeNull();
  });

  it("seeds the open editor from the frame's existing override when one is set", async () => {
    fixture();
    const user = userEvent.setup();
    const projectWithOverride = {
      ...PROJECT,
      frames: [
        {
          index: 1,
          excluded: false,
          receipts: [],
          captureOverride: { ...CAPTURE, resolutionDpi: 2000 },
        },
      ],
    };
    render(
      <FrameOverrideEditor
        frameIndex={1}
        filmProcess="c41ColorNegative"
        rollCapture={CAPTURE}
        rollProcessing={PROCESSING}
        rollOutput={OUTPUT}
        project={projectWithOverride}
      />,
    );
    await user.click(screen.getByTestId("toggle-override-capture"));
    expect(screen.getByTestId("capture-res-dpi")).toHaveValue(2000);
  });
});
