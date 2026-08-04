/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../session/store/session";
import { createScriptedTransport } from "../../session/testing/harness";
import type { MetadataSet } from "../../session/wire/types";
import MetadataPanel from "../MetadataPanel";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../session", () => mocks);

const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));

const pathMocks = vi.hoisted(() => ({ homeDir: vi.fn() }));
vi.mock("@tauri-apps/api/path", () => ({ homeDir: pathMocks.homeDir }));

const DETECTED = { available: true, path: "/usr/bin/exiftool", version: "12.76" };

const ROLL: MetadataSet = {
  camera: "Nikon F6",
  lens: "Nikkor 50mm f/1.4",
  filmStock: "Portra 400",
  iso: 400,
  location: "Portland",
  photographer: "Rohan",
  copyright: "2026 Rohan",
  rollId: "R-001",
  notes: "Push +1",
  keywords: ["street", "color"],
};

async function fixture(): Promise<SessionStore> {
  const handle = createScriptedTransport();
  const store = new SessionStore(handle.transport);
  mocks.sessionStore = store;
  return store;
}

describe("MetadataPanel", () => {
  it("calls onDetectExifTool exactly once on mount when exifToolDetection is null", async () => {
    await fixture();
    const onDetectExifTool = vi.fn();
    const { rerender } = render(
      <MetadataPanel
        rollMetadata={ROLL}
        onSave={vi.fn()}
        exifToolDetection={null}
        onDetectExifTool={onDetectExifTool}
      />,
    );
    expect(onDetectExifTool).toHaveBeenCalledTimes(1);
    rerender(
      <MetadataPanel
        rollMetadata={ROLL}
        onSave={vi.fn()}
        exifToolDetection={null}
        onDetectExifTool={onDetectExifTool}
      />,
    );
    expect(onDetectExifTool).toHaveBeenCalledTimes(1);
  });

  it("does not call onDetectExifTool when a detection is already provided", async () => {
    await fixture();
    const onDetectExifTool = vi.fn();
    render(
      <MetadataPanel
        rollMetadata={ROLL}
        onSave={vi.fn()}
        exifToolDetection={DETECTED}
        onDetectExifTool={onDetectExifTool}
      />,
    );
    expect(onDetectExifTool).not.toHaveBeenCalled();
    expect(screen.getByTestId("exiftool-status")).toBeInTheDocument();
  });

  it("saving calls onSave with the complete MetadataSet object, never a partial diff", async () => {
    await fixture();
    const onSave = vi.fn();
    const user = userEvent.setup();
    render(
      <MetadataPanel
        rollMetadata={ROLL}
        onSave={onSave}
        exifToolDetection={DETECTED}
        onDetectExifTool={vi.fn()}
      />,
    );
    await user.clear(screen.getByTestId("metadata-camera"));
    await user.type(screen.getByTestId("metadata-camera"), "Fujica GW690");
    await user.click(screen.getByTestId("metadata-save"));
    expect(onSave).toHaveBeenCalledTimes(1);
    const saved = onSave.mock.calls[0][0] as MetadataSet;
    expect(saved.camera).toBe("Fujica GW690");
    // Every editable field survives the swap -- the complete object, not a diff.
    expect(saved.lens).toBe("Nikkor 50mm f/1.4");
    expect(saved.filmStock).toBe("Portra 400");
    expect(saved.iso).toBe(400);
    expect(saved.location).toBe("Portland");
    expect(saved.photographer).toBe("Rohan");
    expect(saved.copyright).toBe("2026 Rohan");
    expect(saved.rollId).toBe("R-001");
    expect(saved.notes).toBe("Push +1");
    expect(saved.keywords).toEqual(["street", "color"]);
  });

  it("splits a typed comma-separated keywords field on save", async () => {
    await fixture();
    const onSave = vi.fn();
    const user = userEvent.setup();
    render(
      <MetadataPanel
        rollMetadata={{ keywords: [] }}
        onSave={onSave}
        exifToolDetection={DETECTED}
        onDetectExifTool={vi.fn()}
      />,
    );
    await user.type(screen.getByTestId("metadata-keywords"), "street, color,  portland ");
    await user.click(screen.getByTestId("metadata-save"));
    expect((onSave.mock.calls[0][0] as MetadataSet).keywords).toEqual(["street", "color", "portland"]);
  });
});

describe("MetadataPanel PartialDate editing (never fabricates precision)", () => {
  async function renderPanel(onSave: (next: MetadataSet) => void): Promise<void> {
    await fixture();
    render(
      <MetadataPanel
        rollMetadata={{ keywords: [] }}
        onSave={onSave}
        exifToolDetection={DETECTED}
        onDetectExifTool={vi.fn()}
      />,
    );
  }

  it("selecting Exact never fabricates a date; only a picked date commits {kind:'exact'}", async () => {
    const onSave = vi.fn();
    await renderPanel(onSave);
    const user = userEvent.setup();
    await user.click(screen.getByTestId("date-precision-exact"));
    // No complete value yet: saving sends no date at all (no fabricated day).
    await user.click(screen.getByTestId("metadata-save"));
    expect(onSave).toHaveBeenCalledTimes(1);
    expect((onSave.mock.calls[0][0] as MetadataSet).date).toBeUndefined();
    // The user actually picks a real date -> the only path to a commit.
    fireEvent.change(screen.getByTestId("date-exact-input"), { target: { value: "2024-05-06" } });
    await user.click(screen.getByTestId("metadata-save"));
    expect(onSave).toHaveBeenCalledTimes(2);
    expect((onSave.mock.calls[1][0] as MetadataSet).date).toEqual({
      kind: "exact",
      date: "2024-05-06",
    });
  });

  it("Month precision with no year shows the year editor and never invents a year", async () => {
    const onSave = vi.fn();
    await renderPanel(onSave);
    const user = userEvent.setup();
    await user.click(screen.getByTestId("date-precision-month"));
    fireEvent.change(screen.getByTestId("date-month-select"), { target: { value: "6" } });
    // Choosing a month alone is not enough: no fabricated year is committed.
    await user.click(screen.getByTestId("metadata-save"));
    expect((onSave.mock.calls[0][0] as MetadataSet).date).toBeUndefined();
    await user.type(screen.getByTestId("date-year-input"), "2024");
    await user.click(screen.getByTestId("metadata-save"));
    expect(onSave).toHaveBeenCalledTimes(2);
    expect((onSave.mock.calls[1][0] as MetadataSet).date).toEqual({
      kind: "monthOnly",
      year: 2024,
      month: 6,
    });
  });

  it("a date of null and a date of {kind:'unknown'} both render identically as Unknown", async () => {
    await fixture();
    const onSaveNull = vi.fn();
    const { unmount } = render(
      <MetadataPanel
        rollMetadata={{ keywords: [] }}
        onSave={onSaveNull}
        exifToolDetection={DETECTED}
        onDetectExifTool={vi.fn()}
      />,
    );
    expect(screen.getByTestId("date-precision-unknown")).toBeChecked();
    expect(screen.queryByTestId("date-exact-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-year-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-month-select")).not.toBeInTheDocument();
    unmount();

    render(
      <MetadataPanel
        rollMetadata={{ keywords: [], date: { kind: "unknown" } }}
        onSave={vi.fn()}
        exifToolDetection={DETECTED}
        onDetectExifTool={vi.fn()}
      />,
    );
    expect(screen.getByTestId("date-precision-unknown")).toBeChecked();
    expect(screen.queryByTestId("date-exact-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-year-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-month-select")).not.toBeInTheDocument();
  });
});
