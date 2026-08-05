/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../session/store/session";
import { createScriptedTransport } from "../../session/testing/harness";
import type {
  ApplyMetadataResult,
  ExifToolDetection,
  MetadataSet,
  PreviewMetadataCommandResult,
} from "../../session/wire/types";
import FrameMetadataOverride from "../FrameMetadataOverride";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../session", () => mocks);

const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));

const pathMocks = vi.hoisted(() => ({ homeDir: vi.fn() }));
vi.mock("@tauri-apps/api/path", () => ({ homeDir: pathMocks.homeDir }));

const DETECTED: ExifToolDetection = {
  available: true,
  path: "/usr/bin/exiftool",
  version: "12.76",
};

const EFFECTIVE: MetadataSet = {
  camera: "Nikon F6",
  filmStock: "Portra 400",
  keywords: [],
};

const PREVIEW_EMPTY: PreviewMetadataCommandResult = {
  available: true,
  exiftoolPath: "/usr/bin/exiftool",
  targets: [],
  arguments: ["-CameraModel=Nikon F6"],
};

const PREVIEW_TARGETS: PreviewMetadataCommandResult = {
  available: true,
  exiftoolPath: "/usr/bin/exiftool",
  targets: ["/out/IMG_0001.tiff"],
  arguments: [
    "-CameraModel=Nikon F6",
    "-overwrite_original",
    "/out/IMG_0001.tiff",
  ],
};

const APPLY_RESULT: ApplyMetadataResult = {
  success: false,
  exitCode: 1,
  stdout: "Warning: no file matching /out/IMG_0001.tiff",
  stderr: "Error: nothing to do",
  targets: ["/out/IMG_0001.tiff"],
};

async function fixture(): Promise<SessionStore> {
  const handle = createScriptedTransport();
  const store = new SessionStore(handle.transport);
  mocks.sessionStore = store;
  return store;
}

interface OverridePropsOverrides {
  exifToolDetection?: ExifToolDetection | null;
  metadataPreview?: PreviewMetadataCommandResult | null;
  onApply?: () => Promise<ApplyMetadataResult | null>;
  override?: MetadataSet | null;
  onSetOverride?: (next: MetadataSet | null) => void;
}

function renderOverride(overrides: OverridePropsOverrides = {}) {
  return (
    <FrameMetadataOverride
      frameIndex={1}
      effectiveMetadata={EFFECTIVE}
      override={overrides.override ?? null}
      onSetOverride={overrides.onSetOverride ?? vi.fn()}
      exifToolDetection={
        overrides.exifToolDetection === undefined ? DETECTED : overrides.exifToolDetection
      }
      metadataPreview={overrides.metadataPreview ?? null}
      onPreviewCommand={vi.fn()}
      onApply={overrides.onApply ?? (() => Promise.resolve(null))}
    />
  );
}

describe("FrameMetadataOverride", () => {
  it("renders the complete ExifTool argument array one per line before Apply is enabled", async () => {
    await fixture();
    render(renderOverride({ metadataPreview: PREVIEW_TARGETS }));
    const block = screen.getByTestId("exiftool-arguments");
    expect(block).toHaveTextContent("-CameraModel=Nikon F6");
    expect(block).toHaveTextContent("-overwrite_original");
    expect(block).toHaveTextContent("/out/IMG_0001.tiff");
    expect(screen.getByTestId("apply-metadata")).toBeEnabled();
  });

  it("disables Apply Metadata until metadataPreview.targets is non-empty", async () => {
    await fixture();
    const { rerender } = render(renderOverride({ metadataPreview: null }));
    expect(screen.getByTestId("apply-metadata")).toBeDisabled();
    rerender(renderOverride({ metadataPreview: PREVIEW_EMPTY }));
    expect(screen.getByTestId("apply-metadata")).toBeDisabled();
    rerender(renderOverride({ metadataPreview: PREVIEW_TARGETS }));
    expect(screen.getByTestId("apply-metadata")).toBeEnabled();
  });

  it("disables Preview Command when ExifTool is undetected or unavailable", async () => {
    await fixture();
    const { rerender } = render(renderOverride({ exifToolDetection: null }));
    expect(screen.getByTestId("preview-command")).toBeDisabled();
    rerender(
      renderOverride({
        exifToolDetection: { available: false, path: null, version: null },
      }),
    );
    expect(screen.getByTestId("preview-command")).toBeDisabled();
    rerender(renderOverride({ exifToolDetection: DETECTED }));
    expect(screen.getByTestId("preview-command")).toBeEnabled();
  });

  it("after onApply resolves, renders the literal exitCode/stdout/stderr, never an invented message", async () => {
    await fixture();
    const onApply = vi.fn().mockResolvedValue(APPLY_RESULT);
    const user = userEvent.setup();
    render(renderOverride({ metadataPreview: PREVIEW_TARGETS, onApply }));
    await user.click(screen.getByTestId("apply-metadata"));
    await waitFor(() => {
      expect(screen.getByTestId("exiftool-exit-code")).toHaveTextContent("1");
    });
    expect(screen.getByTestId("exiftool-stdout")).toHaveTextContent(
      "Warning: no file matching /out/IMG_0001.tiff",
    );
    expect(screen.getByTestId("exiftool-stderr")).toHaveTextContent("Error: nothing to do");
    expect(onApply).toHaveBeenCalledTimes(1);
  });

  it("calls onSetOverride(null) when turning the override toggle off after it had a value", async () => {
    await fixture();
    const onSetOverride = vi.fn();
    const user = userEvent.setup();
    render(
      renderOverride({
        override: { camera: "Nikon F6", keywords: [] },
        onSetOverride,
      }),
    );
    expect(screen.getByTestId("override-metadata-toggle")).toBeChecked();
    await user.click(screen.getByTestId("override-metadata-toggle"));
    expect(onSetOverride).toHaveBeenCalledWith(null);
  });

  it("shows effective metadata read-only when no override is set", async () => {
    await fixture();
    render(renderOverride());
    expect(screen.getByTestId("effective-metadata-readonly")).toHaveTextContent("Nikon F6");
    expect(screen.queryByTestId("metadata-save")).not.toBeInTheDocument();
  });
});
