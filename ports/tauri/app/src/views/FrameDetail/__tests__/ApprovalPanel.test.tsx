/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { ScanProject, ScannerStatus } from "../../../session/wire/types";
import ApprovalPanel from "../ApprovalPanel";

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
  id: "proj-approval",
  name: "Approval Roll",
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

interface ApprovalFixture {
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
  calls: Call[];
  operationId: string;
}

async function approvalFixture(): Promise<ApprovalFixture> {
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
      if (method === "roll.approve") return { result: {} };
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.loadMedia("roll36");
  await store.createProject("Approval Roll", "roll36", 36, "positive");
  await store.acquireThumbnails();
  const acquire = calls.find((c) => c.method === "scanner.acquireThumbnails");
  if (acquire === undefined) throw new Error("no acquireThumbnails call recorded");
  const operationId = acquire.params.operationId as string;
  return { store, emitEvent: (raw) => handle.emitEvent(raw), calls, operationId };
}

function previewThumbnail(
  fixture: ApprovalFixture,
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

describe("ApprovalPanel", () => {
  it("renders the Needs approval badge only when the thumbnail is flagged", async () => {
    const fixture = await approvalFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5, needsApproval: true });
    mocks.sessionStore = fixture.store;
    render(<ApprovalPanel frameIndex={2} />);
    expect(await screen.findByTestId("approval-needs-badge")).toHaveTextContent(
      "Needs approval",
    );
  });

  it("does not render the badge for a thumbnail that was not flagged", async () => {
    const fixture = await approvalFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5 });
    mocks.sessionStore = fixture.store;
    render(<ApprovalPanel frameIndex={2} />);
    expect(screen.queryByTestId("approval-needs-badge")).toBeNull();
  });

  it("hides the badge once the store reports the frame approved", async () => {
    const fixture = await approvalFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5, needsApproval: true });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ApprovalPanel frameIndex={2} />);
    expect(await screen.findByTestId("approval-needs-badge")).toBeInTheDocument();

    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Approve" }));
    });

    expect(screen.queryByTestId("approval-needs-badge")).toBeNull();
  });

  it("approves through the store's own operationId, never a client-constructed value", async () => {
    const fixture = await approvalFixture();
    previewThumbnail(fixture, 7, { brightness: 0.5, needsApproval: true });
    mocks.sessionStore = fixture.store;
    const approveSpy = vi.spyOn(fixture.store, "approveFrame");
    const user = userEvent.setup();
    render(<ApprovalPanel frameIndex={7} />);
    await screen.findByTestId("approval-needs-badge");

    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Approve" }));
    });

    expect(approveSpy).toHaveBeenCalledWith(7);
    const approveCall = fixture.calls.find((c) => c.method === "roll.approve");
    expect(approveCall?.params.frameIndex).toBe(7);
    expect(approveCall?.params.operationId).toBe(fixture.operationId);
    expect(fixture.store.getState().latestCompletedPreviewOperationId).toBe(
      fixture.operationId,
    );
  });

  it("renders every warning string byte-for-byte as its own list item", async () => {
    const warnings = [
      "Underexposed center",
      "\n IR channel saturated. Lower the highlight. ",
      "OVEREXPOSED",
    ];
    const fixture = await approvalFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5, needsApproval: true, warnings });
    mocks.sessionStore = fixture.store;
    render(<ApprovalPanel frameIndex={2} />);

    await screen.findByTestId("approval-warnings");
    const items = screen.getAllByRole("listitem");
    expect(items.map((item) => item.textContent)).toEqual(warnings);
  });
});
