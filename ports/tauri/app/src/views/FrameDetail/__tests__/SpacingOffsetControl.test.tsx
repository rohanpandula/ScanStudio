/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { EngineError, ScanProject, ScannerStatus } from "../../../session/wire/types";
import SpacingOffsetControl from "../SpacingOffsetControl";

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
  id: "proj-offset",
  name: "Offset Roll",
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

interface OffsetFixture {
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
  calls: Call[];
  operationId: string;
}

async function offsetFixture(options: {
  setOffset?: (
    method: string,
    params: unknown,
  ) => { result?: unknown; error?: EngineError } | undefined;
} = {}): Promise<OffsetFixture> {
  const calls: Call[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      const custom = options.setOffset?.(method, params);
      if (custom !== undefined) return custom;
      if (method === "sim.loadMedia") return { result: LOADED_ROLL36 };
      if (method === "project.create") {
        return { result: { project: PROJECT, directory: "/tmp/proj" } };
      }
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [] } };
      }
      if (method === "roll.approve") return { result: {} };
      if (method === "roll.setSpacingOffset") {
        const requested = params as { frameIndex: number; offsetRows: number };
        return {
          result: {
            thumbnail: {
              brightness: 0.5,
              imagePath: "/scans/replaced/frame.png",
              spacingOffset: requested.offsetRows,
              needsApproval: true,
              warnings: [],
            },
          },
        };
      }
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.loadMedia("roll36");
  await store.createProject("Offset Roll", "roll36", 36, "positive");
  await store.acquireThumbnails();
  const acquire = calls.find((c) => c.method === "scanner.acquireThumbnails");
  if (acquire === undefined) throw new Error("no acquireThumbnails call recorded");
  const operationId = acquire.params.operationId as string;
  return { store, emitEvent: (raw) => handle.emitEvent(raw), calls, operationId };
}

function previewThumbnail(
  fixture: OffsetFixture,
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

describe("SpacingOffsetControl", () => {
  it("clamps a frame-1 commit into [0, 144] and shows the legal range", async () => {
    const fixture = await offsetFixture();
    previewThumbnail(fixture, 1, { brightness: 0.5, spacingOffset: 0 });
    mocks.sessionStore = fixture.store;
    const setOffsetSpy = vi.spyOn(fixture.store, "setSpacingOffset");
    const user = userEvent.setup();
    render(<SpacingOffsetControl frameIndex={1} />);

    expect(screen.getByTestId("spacing-offset-range")).toHaveTextContent("0..144");
    const input = screen.getByTestId("spacing-offset-input");
    await user.clear(input);
    await user.type(input, "200");
    await act(async () => {
      await user.keyboard("{Enter}");
    });

    expect(setOffsetSpy).toHaveBeenCalledWith(1, 144);
  });

  it("clamps a non-frame-1 commit into [-144, 144] and shows the legal range", async () => {
    const fixture = await offsetFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5, spacingOffset: 0 });
    mocks.sessionStore = fixture.store;
    const setOffsetSpy = vi.spyOn(fixture.store, "setSpacingOffset");
    const user = userEvent.setup();
    render(<SpacingOffsetControl frameIndex={2} />);

    expect(screen.getByTestId("spacing-offset-range")).toHaveTextContent("-144..144");
    const input = screen.getByTestId("spacing-offset-input");
    await user.clear(input);
    await user.type(input, "-200");
    await act(async () => {
      await user.keyboard("{Enter}");
    });

    expect(setOffsetSpy).toHaveBeenCalledWith(2, -144);
  });

  it("swaps in the bridge-confirmed replacement tile's imagePath after a commit", async () => {
    const fixture = await offsetFixture();
    previewThumbnail(fixture, 2, {
      imagePath: "/scans/original/frame-0002.png",
      spacingOffset: 0,
    });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<SpacingOffsetControl frameIndex={2} />);

    const tile = screen.getByTestId("replacement-tile") as HTMLImageElement;
    expect(tile.src).toBe(
      "scanstudio-preview://localhost/?path=" +
        encodeURIComponent("/scans/original/frame-0002.png"),
    );

    const input = screen.getByTestId("spacing-offset-input");
    await user.clear(input);
    await user.type(input, "30");
    await act(async () => {
      await user.keyboard("{Enter}");
    });

    await waitFor(() => {
      const replaced = screen.getByTestId("replacement-tile") as HTMLImageElement;
      expect(replaced.src).toBe(
        "scanstudio-preview://localhost/?path=" +
          encodeURIComponent("/scans/replaced/frame.png"),
      );
    });
    const setCall = fixture.calls.find((c) => c.method === "roll.setSpacingOffset");
    expect(setCall?.params.offsetRows).toBe(30);
    // The store binds the operationId itself; the component never sends one.
    expect(setCall?.params.operationId).toBe(fixture.operationId);
  });

  it("commits a coarse adjustment from the horizontal drag handle", async () => {
    const fixture = await offsetFixture();
    previewThumbnail(fixture, 2, { brightness: 0.5, spacingOffset: 0 });
    mocks.sessionStore = fixture.store;
    const setOffsetSpy = vi.spyOn(fixture.store, "setSpacingOffset");
    render(<SpacingOffsetControl frameIndex={2} />);

    const drag = screen.getByTestId("spacing-offset-drag") as HTMLInputElement;
    fireEvent.change(drag, { target: { value: "50" } });
    expect(setOffsetSpy).toHaveBeenCalledWith(2, 50);
  });

  it("shows the approval-invalidated banner alongside the needsApproval badge when a previously-approved frame's offset changes", async () => {
    const fixture = await offsetFixture();
    previewThumbnail(fixture, 2, {
      imagePath: "/scans/original/frame-0002.png",
      spacingOffset: 10,
      needsApproval: true,
      warnings: ["manually reviewed"],
    });
    await fixture.store.approveFrame(2);
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<SpacingOffsetControl frameIndex={2} />);

    // Approved at first: no needsApproval badge, no invalidation banner.
    expect(screen.queryByTestId("spacing-needs-approval-badge")).toBeNull();
    expect(screen.queryByTestId("approval-invalidated-banner")).toBeNull();

    const input = screen.getByTestId("spacing-offset-input");
    await user.clear(input);
    await user.type(input, "30");
    await act(async () => {
      await user.keyboard("{Enter}");
    });

    // Changing the offset invalidates approval: the banner appears and the
    // needsApproval badge stays visible alongside it, never replacing it.
    expect(await screen.findByTestId("approval-invalidated-banner")).toBeInTheDocument();
    expect(screen.getByTestId("spacing-needs-approval-badge")).toBeInTheDocument();
  });

  it("renders a store INVALID_PARAMS rejection code and message verbatim", async () => {
    const fixture = await offsetFixture({
      setOffset: (method) => {
        if (method !== "roll.setSpacingOffset") return undefined;
        return {
          error: {
            code: "INVALID_PARAMS",
            message: "offsetRows 30 is outside the supported range for frame 2 (-144..144)",
            recoverable: false,
          },
        };
      },
    });
    previewThumbnail(fixture, 2, { brightness: 0.5, spacingOffset: 0 });
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<SpacingOffsetControl frameIndex={2} />);

    const input = screen.getByTestId("spacing-offset-input");
    await user.clear(input);
    await user.type(input, "30");
    await act(async () => {
      await user.keyboard("{Enter}");
    });

    expect(await screen.findByTestId("spacing-error")).toBeInTheDocument();
    expect(screen.getByTestId("spacing-error-code")).toHaveTextContent("INVALID_PARAMS");
    expect(screen.getByTestId("spacing-error-message")).toHaveTextContent(
      "offsetRows 30 is outside the supported range for frame 2 (-144..144)",
    );
  });
});
