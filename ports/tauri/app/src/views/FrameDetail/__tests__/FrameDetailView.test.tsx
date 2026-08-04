/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { ScanProject, ScannerStatus } from "../../../session/wire/types";
import FrameDetailView from "../FrameDetailView";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../../session", () => mocks);

const LOADED_ROLL36: ScannerStatus = {
  connected: true,
  adapter: null,
  mediaLoaded: true,
  carrier: "roll36",
  frameCount: 36,
  lamp: "stable",
  transport: "idle",
  activeJobId: null,
};

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-framedetail",
  name: "Detail Roll",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "positive",
  recipes: {
    archive: {
      enabled: true,
      filenameTemplate: "scan_{frame:04d}",
      destination: "/tmp",
    },
    positive: {
      enabled: false,
      fileFormat: "tiff",
      colorProfile: "adobeRgb1998",
      filenameTemplate: "scan_{frame:04d}",
      destination: "/tmp",
    },
    preview: {
      enabled: false,
      fileFormat: "jpeg",
      maxLongEdgePx: 1024,
      filenameTemplate: "preview_{frame:04d}",
      destination: "/tmp",
    },
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00Z",
  frames: [],
};

interface Call {
  method: string;
  params: Record<string, unknown>;
}

interface DetailFixture {
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
  calls: Call[];
  operationId: string;
}

async function detailFixture(): Promise<DetailFixture> {
  const calls: Call[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      if (method === "sim.loadMedia") return { result: LOADED_ROLL36 };
      if (method === "project.create") {
        return { result: { project: PROJECT, directory: "/tmp/proj" } };
      }
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [] } };
      }
      if (method === "project.analyzeFrameDefects") {
        return {
          result: {
            frameIndex: 2,
            defects: [
              {
                id: 7,
                kind: "dust",
                severity: 0.8,
                classification: "willCorrect",
                centerX: 0.35,
                centerY: 0.45,
                radius: 0.025,
              },
            ],
            simulated: false,
            digitalIceEnabled: true,
            transportSmearFlagged: false,
            transportSmearReason: null,
          },
        };
      }
      if (method === "roll.approve") return { result: {} };
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.loadMedia("roll36");
  await store.createProject("Detail Roll", "roll36", 36, "positive");
  await store.acquireThumbnails();
  const acquire = calls.find((c) => c.method === "scanner.acquireThumbnails");
  if (acquire === undefined) throw new Error("no acquireThumbnails call recorded");
  const operationId = acquire.params.operationId as string;
  return { store, emitEvent: (raw) => handle.emitEvent(raw), calls, operationId };
}

function previewThumbnail(
  fixture: DetailFixture,
  frameIndex: number,
  thumbnail: Record<string, unknown>,
): void {
  fixture.emitEvent({
    event: "scanner.thumbnail",
    payload: { frameIndex, thumbnail, operationId: fixture.operationId },
  });
  fixture.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: 36, operationId: fixture.operationId },
  });
}

describe("FrameDetailView", () => {
  it("renders a neutral loading state instead of crashing when the store has no data for the frame", async () => {
    const fixture = await detailFixture();
    mocks.sessionStore = fixture.store;
    render(<FrameDetailView frameIndex={5} />);
    expect(screen.getByTestId("frame-detail-loading")).toBeInTheDocument();
    expect(screen.queryByTestId("zoom-pan-image")).toBeNull();
    expect(screen.queryByTestId("spacing-offset-input")).toBeNull();
    expect(screen.queryByTestId("approval-panel")).toBeNull();
  });

  it("composes the zoom viewer, offset control, and approval panel for a previewed frame", async () => {
    const fixture = await detailFixture();
    previewThumbnail(fixture, 2, {
      imagePath: "/scans/frames/frame-0002.png",
      spacingOffset: 12,
      needsApproval: true,
      warnings: ["IR channel saturated"],
    });
    mocks.sessionStore = fixture.store;
    render(<FrameDetailView frameIndex={2} />);

    await screen.findByTestId("frame-detail-view");
    expect(screen.getByText("Frame 2")).toBeInTheDocument();
    const img = screen.getByTestId("zoom-pan-image") as HTMLImageElement;
    expect(img.src).toBe(
      "scanstudio-preview://localhost/?path=" +
        encodeURIComponent("/scans/frames/frame-0002.png"),
    );
    expect(screen.getByTestId("spacing-offset-input")).toBeInTheDocument();
    expect(screen.getByTestId("approval-panel")).toBeInTheDocument();
    expect(screen.getByTestId("approval-needs-badge")).toBeInTheDocument();
    expect(screen.getByText("IR channel saturated")).toBeInTheDocument();
  });

  it("invokes the onClose callback when provided", async () => {
    const fixture = await detailFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5, needsApproval: true });
    mocks.sessionStore = fixture.store;
    const onClose = vi.fn();
    const user = userEvent.setup();
    render(<FrameDetailView frameIndex={2} onClose={onClose} />);

    await act(async () => {
      await user.click(await screen.findByTestId("frame-detail-close"));
    });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("edits the persisted derivative transform and previews it in frame detail", async () => {
    const fixture = await detailFixture();
    previewThumbnail(fixture, 2, { imagePath: "/scans/frames/frame-0002.png" });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<FrameDetailView frameIndex={2} />);

    await user.click(await screen.findByRole("button", { name: "Rotate right" }));
    await user.click(screen.getByRole("button", { name: "Flip top/bottom" }));
    const image = screen.getByTestId("zoom-pan-image");
    expect(image).toHaveAttribute("data-rotation", "90");
    expect(image).toHaveAttribute("data-vertical-mirror", "true");
    expect(screen.getByTestId("detail-transform-summary")).toHaveTextContent("90°");
    expect(screen.getByTestId("detail-transform-summary")).toHaveTextContent("top/bottom flip");
    const derivativeLayer = screen.getByTestId("derivative-layer");
    const overlay = await screen.findByTestId("defect-overlay");
    expect(derivativeLayer).toHaveAttribute("data-axis-swapped", "true");
    expect(derivativeLayer).toHaveStyle({
      width: "150%",
      height: "66.6667%",
      transform: "translate(-50%, -50%) rotate(90deg) scaleX(1) scaleY(-1)",
    });
    expect(derivativeLayer).toContainElement(image);
    expect(derivativeLayer).toContainElement(overlay);
    expect(screen.getByTestId("defect-marker-7")).toBeInTheDocument();
  });
});
