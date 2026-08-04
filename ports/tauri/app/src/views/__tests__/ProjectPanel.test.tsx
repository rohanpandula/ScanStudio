/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../session/store/session";
import { createScriptedTransport } from "../../session/testing/harness";
import type { EngineError, ProjectSummary, ScanProject } from "../../session/wire/types";
import ProjectPanel from "../ProjectPanel";

afterEach(cleanup);

// ProjectPanel imports the production `sessionStore` singleton from
// app/src/session/index.ts (Tauri invoke bridge, unusable under jsdom) and
// the native dialog plugin. Replace both modules with hoisted holders.
const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../session", () => mocks);

const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));
vi.mock("@tauri-apps/api/path", () => ({
  homeDir: () => Promise.resolve("/Users/test/"),
}));

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-1",
  name: "Summer Trip",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "positive",
  recipes: {
    archive: {
      enabled: false,
      filenameTemplate: "scan_{frame:04d}",
      destination: "/tmp",
    },
    positive: {
      enabled: true,
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
  createdAt: "2026-07-30T10:00:00Z",
  frames: [],
};

const SUMMARIES: ProjectSummary[] = [
  {
    id: "proj-2",
    name: "Old Roll",
    carrier: "strip6",
    frameCount: 6,
    filmProcess: "bwNegative",
    createdAt: "2026-07-01T08:00:00Z",
    directory: "/scans/old-roll",
  },
  {
    id: "proj-3",
    name: "Newest Roll",
    carrier: "mounted",
    frameCount: 1,
    filmProcess: "kodachrome",
    createdAt: "2026-07-20T12:00:00Z",
    directory: "/scans/newest-roll",
  },
];

const DEFAULT_PROJECT_DIRECTORY = "/scans/scanstudio-projects/summer-trip";

function projectFixture(
  script?: (method: string) => { result?: unknown; error?: EngineError } | undefined,
): SessionStore {
  const handle = createScriptedTransport({
    onRequest: (method) => {
      const custom = script?.(method);
      if (custom !== undefined) return custom;
      if (method === "project.list") return { result: { projects: SUMMARIES } };
      if (method === "project.create" || method === "project.open") {
        return { result: { project: PROJECT, directory: DEFAULT_PROJECT_DIRECTORY } };
      }
      return { result: undefined };
    },
  });
  return new SessionStore(handle.transport);
}

beforeEach(() => {
  dialogMocks.open.mockReset();
});

describe("ProjectPanel", () => {
  it("renders the new-project form and Open Recent list sorted newest-first when no project is active", async () => {
    mocks.sessionStore = projectFixture();
    render(<ProjectPanel />);
    await screen.findByText("Newest Roll");
    expect(screen.getByLabelText("Project name")).toBeInTheDocument();
    expect(screen.getByLabelText("Carrier")).toBeInTheDocument();
    expect(screen.getByLabelText("Frame count")).toBeInTheDocument();
    expect(screen.getByLabelText("Film process")).toBeInTheDocument();
    const rows = screen.getAllByTestId(/^recent-project-/);
    expect(rows).toHaveLength(2);
    expect(rows[0]).toHaveTextContent("Newest Roll");
    expect(rows[1]).toHaveTextContent("Old Roll");
    expect(screen.queryByTestId("active-project")).toBeNull();
  });

  it("disables Create and shows the carrier rule message when the frame count is out of range, without calling the store", async () => {
    const store = projectFixture();
    mocks.sessionStore = store;
    const createSpy = vi.spyOn(store, "createProject");
    const user = userEvent.setup();
    render(<ProjectPanel />);
    const nameInput = await screen.findByLabelText("Project name");
    await user.type(nameInput, "Trip");
    const countInput = screen.getByLabelText("Frame count");
    await user.clear(countInput);
    await user.type(countInput, "41");
    expect(screen.getByRole("button", { name: "Create" })).toBeDisabled();
    expect(screen.getByText(/requires between 1 and 40 frames/)).toBeInTheDocument();
    expect(createSpy).not.toHaveBeenCalled();
  });

  it("calls sessionStore.createProject with the form values when valid, then shows the active-project banner", async () => {
    const store = projectFixture((method) => {
      if (method !== "project.create") return undefined;
      return { result: { project: PROJECT, directory: DEFAULT_PROJECT_DIRECTORY } };
    });
    mocks.sessionStore = store;
    const createSpy = vi.spyOn(store, "createProject");
    const user = userEvent.setup();
    render(<ProjectPanel />);
    const nameInput = await screen.findByLabelText("Project name");
    await user.type(nameInput, "Trip");
    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Create" }));
    });
    expect(createSpy).toHaveBeenCalledWith("Trip", "roll36", 36, "positive", undefined);
    const banner = await screen.findByTestId("active-project");
    expect(banner).toHaveTextContent("Summer Trip");
    expect(banner).toHaveTextContent("roll36");
    expect(banner).toHaveTextContent("36 frames");
  });

  it("passes the native picker's returned directory to createProject when one is chosen", async () => {
    dialogMocks.open.mockResolvedValue("/Users/test/My Scans");
    const store = projectFixture((method) => {
      if (method !== "project.create") return undefined;
      return { result: { project: PROJECT, directory: "/Users/test/My Scans" } };
    });
    mocks.sessionStore = store;
    const createSpy = vi.spyOn(store, "createProject");
    const user = userEvent.setup();
    render(<ProjectPanel />);
    await user.type(await screen.findByLabelText("Project name"), "Trip");
    await user.click(screen.getByRole("button", { name: "Choose output folder" }));
    expect(dialogMocks.open).toHaveBeenCalledWith(
      expect.objectContaining({ directory: true, multiple: false }),
    );
    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Create" }));
    });
    expect(createSpy).toHaveBeenCalledWith(
      "Trip",
      "roll36",
      36,
      "positive",
      "/Users/test/My Scans",
    );
  });

  it("treats a cancelled picker as no directory override", async () => {
    dialogMocks.open.mockResolvedValue(null);
    const store = projectFixture((method) => {
      if (method !== "project.create") return undefined;
      return { result: { project: PROJECT, directory: DEFAULT_PROJECT_DIRECTORY } };
    });
    mocks.sessionStore = store;
    const createSpy = vi.spyOn(store, "createProject");
    const user = userEvent.setup();
    render(<ProjectPanel />);
    await user.type(await screen.findByLabelText("Project name"), "Trip");
    await user.click(screen.getByRole("button", { name: "Choose output folder" }));
    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Create" }));
    });
    expect(createSpy).toHaveBeenCalledWith("Trip", "roll36", 36, "positive", undefined);
  });

  it("renders an active-project banner with name, carrier, and frame count when a project is active", async () => {
    const store = projectFixture();
    await store.openProject("/scans/old-roll");
    mocks.sessionStore = store;
    render(<ProjectPanel />);
    const banner = await screen.findByTestId("active-project");
    expect(within(banner).getByText("Summer Trip")).toBeInTheDocument();
    expect(within(banner).getByText("roll36")).toBeInTheDocument();
    expect(within(banner).getByText("36 frames")).toBeInTheDocument();
  });

  it("calls sessionStore.openProject with the row's directory when a recent project is clicked", async () => {
    const store = projectFixture();
    mocks.sessionStore = store;
    const openSpy = vi.spyOn(store, "openProject");
    const user = userEvent.setup();
    render(<ProjectPanel />);
    const row = await screen.findByTestId("recent-project-proj-2");
    await act(async () => {
      await user.click(row);
    });
    expect(openSpy).toHaveBeenCalledWith("/scans/old-roll");
  });

  it("displays a rejected create's error message verbatim", async () => {
    const store = projectFixture((method) => {
      if (method === "project.create") {
        return {
          error: {
            code: "INVALID_PARAMS",
            message: "frameCount 41 exceeds roll36 capacity of 40",
            recoverable: false,
          },
        };
      }
      return undefined;
    });
    mocks.sessionStore = store;
    const user = userEvent.setup();
    render(<ProjectPanel />);
    await user.type(await screen.findByLabelText("Project name"), "Trip");
    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Create" }));
    });
    expect(
      await screen.findByText("frameCount 41 exceeds roll36 capacity of 40"),
    ).toBeInTheDocument();
  });
});
