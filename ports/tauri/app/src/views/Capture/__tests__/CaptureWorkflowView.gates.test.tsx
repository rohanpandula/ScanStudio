/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { ScanProject } from "../../../session/wire/types";
import CaptureWorkflowView from "../CaptureWorkflowView";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../../session", () => mocks);

const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-gates",
  name: "Gate Roll",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "c41ColorNegative",
  recipes: {
    archive: { enabled: true, filenameTemplate: "IMG_####.tiff", destination: "/a", fullCapturePackage: true },
    positive: {
      enabled: true,
      fileFormat: "tiff",
      colorProfile: "sRgb",
      filenameTemplate: "POS_####.tiff",
      destination: "/p",
    },
    preview: {
      enabled: true,
      fileFormat: "jpeg",
      maxLongEdgePx: 2048,
      filenameTemplate: "PRE_####.jpg",
      destination: "/v",
    },
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00.000Z",
  frames: [],
};

interface Fixture {
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
  calls: Array<{ method: string; params: Record<string, unknown> }>;
  operationId: string;
}

async function gatesFixture(options?: {
  scanStart?: { result?: unknown; error?: unknown };
}): Promise<Fixture> {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      if (method === "scanner.connect") {
        return {
          result: {
            device: {
              deviceId: "sim-ls5000-0",
              model: "LS-5000 (simulated)",
              kind: "simulated" as const,
              firmware: "sim-fw-1",
              connection: "usb",
            },
            status: {
              connected: true,
              adapter: null,
              mediaLoaded: true,
              carrier: "roll36",
              frameCount: 36,
              lamp: "stable",
              transport: "idle",
              activeJobId: null,
            },
          },
        };
      }
      if (method === "sim.loadMedia") {
        return {
          result: {
            connected: true,
            adapter: null,
            mediaLoaded: true,
            carrier: "roll36",
            frameCount: 36,
            lamp: "stable",
            transport: "idle",
            activeJobId: null,
          },
        };
      }
      if (method === "project.create") return { result: { project: PROJECT, directory: "/tmp/gates" } };
      if (method === "scanner.acquireThumbnails") return { result: { accepted: true, frames: [] } };
      if (method === "roll.approve") return { result: {} };
      if (method === "roll.setSpacingOffset") {
        // A changed offset returns the server-confirmed replacement tile; the
        // replacement keeps needsApproval true so the invalidated approval
        // cannot silently authorize.
        return {
          result: { thumbnail: { brightness: 0.4, needsApproval: true } },
        };
      }
      if (method === "project.pendingFrames") {
        return { result: { frames: [2, 3], totalFrames: 36, completedCount: 34, excludedCount: 0 } };
      }
      if (method === "scan.start") {
        if (options?.scanStart?.error) throw options.scanStart.error;
        return { result: options?.scanStart?.result ?? { jobId: "job-1" } };
      }
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.connect("sim-ls5000-0");
  await store.loadMedia("roll36");
  await store.createProject("Gate Roll", "roll36", 36, "c41ColorNegative");
  await store.acquireThumbnails(undefined, "c41ColorNegative");
  const acquire = calls.find((c) => c.method === "scanner.acquireThumbnails");
  const operationId = (acquire?.params.operationId as string) ?? "op";
  return { store, emitEvent: (raw) => handle.emitEvent(raw), calls, operationId };
}

function completePreview(fixture: Fixture, flags: Record<number, boolean>): void {
  fixture.emitEvent({
    event: "scanner.status",
    payload: {
      status: {
        connected: true,
        adapter: null,
        mediaLoaded: true,
        carrier: "roll36",
        frameCount: 36,
        lamp: "stable",
        transport: "idle",
        activeJobId: null,
      },
    },
  });
  for (const frame of Object.keys(flags).map(Number)) {
    fixture.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: frame,
        thumbnail: { brightness: 0.5, needsApproval: flags[frame] },
        operationId: fixture.operationId,
      },
    });
  }
  fixture.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: Object.keys(flags).length, operationId: fixture.operationId },
  });
}

describe("CaptureWorkflowView gates", () => {
  beforeEach(() => {
    dialogMocks.open.mockReset();
    dialogMocks.open.mockResolvedValue(null);
  });

  it("Gate 1: blocks start when a selected frame needs approval", async () => {
    const fixture = await gatesFixture();
    completePreview(fixture, { 5: true });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<CaptureWorkflowView selectedFrames={[5]} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => {
      expect(screen.getByTestId("scan-start-error")).toHaveTextContent(
        "frame(s) [5] require operator approval",
      );
    });
    expect(fixture.calls.some((c) => c.method === "scan.start")).toBe(false);
  });

  it("Gate 2: re-blocks after a previously approved frame's approval is invalidated", async () => {
    const fixture = await gatesFixture();
    completePreview(fixture, { 5: true });
    await act(async () => {
      await fixture.store.approveFrame(5);
    });
    // Approval invalidation: the operator changes the spacing offset on the
    // approved frame; the store trusts ONLY the server-returned replacement
    // thumbnail (still needsApproval) and drops the frame's prior approval.
    await act(async () => {
      await fixture.store.setSpacingOffset(5, 3);
    });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<CaptureWorkflowView selectedFrames={[5]} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => {
      expect(screen.getByTestId("scan-start-error")).toHaveTextContent(
        "frame(s) [5] require operator approval",
      );
    });
    expect(fixture.calls.some((c) => c.method === "scan.start")).toBe(false);
  });

  it("Gate 3: stop marks unreached frames skipped, never failed", async () => {
    const fixture = await gatesFixture();
    completePreview(fixture, { 1: false, 2: false, 3: false });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<CaptureWorkflowView selectedFrames={[1, 2, 3]} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => expect(screen.getByTestId("scan-run-view")).toBeInTheDocument());

    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 1, state: "completed", attempt: 1 },
      });
      fixture.emitEvent({
        event: "scan.jobState",
        payload: { jobId: "job-1", state: "stoppingAfterCurrentFrame" },
      });
      fixture.emitEvent({
        event: "scan.completed",
        payload: {
          jobId: "job-1",
          summary: { completed: [1], failed: [], skipped: [2, 3], stopped: true },
        },
      });
    });

    await waitFor(() => {
      expect(screen.getByTestId("frame-row-2")).toHaveAttribute("data-state", "skipped");
      expect(screen.getByTestId("frame-row-3")).toHaveAttribute("data-state", "skipped");
    });
    for (const frame of [2, 3]) {
      expect(screen.getByTestId(`frame-row-${frame}`).textContent).not.toContain("failed");
    }
  });

  it("Gate 4: demo retry renders attempt 1 -> 2 -> completed with no operator action", async () => {
    const fixture = await gatesFixture();
    completePreview(fixture, { 13: false });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<CaptureWorkflowView selectedFrames={[13]} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => expect(screen.getByTestId("scan-run-view")).toBeInTheDocument());

    // Attempt 1 fails with FEED_JAM, then the engine auto-retries.
    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: {
          jobId: "job-1",
          frameIndex: 13,
          state: "active",
          attempt: 1,
          error: undefined,
        },
      });
      fixture.emitEvent({
        event: "scan.frameState",
        payload: {
          jobId: "job-1",
          frameIndex: 13,
          state: "failed",
          attempt: 1,
          error: { code: "FEED_JAM", message: "Frame did not advance (jam)", recoverable: true },
        },
      });
    });
    await waitFor(() => {
      expect(screen.getByTestId("frame-state-13").textContent).toContain("failed");
      expect(screen.getByTestId("frame-error-13")).toHaveTextContent("FEED_JAM");
    });
    // A NEW preview invalidates the approval token; acquire again so the
    // resumed batch has a current token. Simulate the engine's auto-retry by
    // re-acquiring preview for the same store (no operator action required).
    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 2 },
      });
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 13, state: "completed", attempt: 2 },
      });
    });
    await waitFor(() => {
      expect(screen.getByTestId("frame-state-13").textContent).toContain("completed");
      expect(screen.getByTestId("frame-state-13").textContent).toContain("attempt 2");
    });
    // The failed attempt's FEED_JAM line persists in the ticker: the retry
    // path rendered, with no button click between failure and completion.
    expect(screen.getByTestId("scan-run-ticker-list").textContent).toContain("FEED_JAM");
  });
});
