/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import OutputRecipeForm, { previewFilename } from "../OutputRecipeForm";
import type { OutputRecipe } from "../../../session/wire/types";

afterEach(cleanup);

const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));

const OUTPUT: OutputRecipe = {
  archive: {
    enabled: true,
    filenameTemplate: "IMG_####.tiff",
    destination: "/archive",
    fullCapturePackage: true,
  },
  positive: {
    enabled: true,
    fileFormat: "tiff",
    colorProfile: "adobeRgb1998",
    filenameTemplate: "POS_####.tiff",
    destination: "/positive",
  },
  preview: {
    enabled: true,
    fileFormat: "jpeg",
    maxLongEdgePx: 2048,
    filenameTemplate: "PRE_####.jpg",
    destination: "/preview",
  },
  autoCrop: false,
};

describe("previewFilename", () => {
  it("substitutes the # run with a zero-padded frame number without touching width", () => {
    expect(previewFilename("IMG_####.tiff", 7)).toBe("IMG_0007.tiff");
  });

  it("leaves templates without a # run unchanged", () => {
    expect(previewFilename("scan.tiff", 7)).toBe("scan.tiff");
  });

  it("pads to the run width for double-digit frame numbers", () => {
    expect(previewFilename("IMG_####.tiff", 42)).toBe("IMG_0042.tiff");
  });
});

describe("OutputRecipeForm", () => {
  beforeEach(() => {
    dialogMocks.open.mockReset();
    dialogMocks.open.mockResolvedValue(null);
  });

  it("renders all three sections with their correct fields", () => {
    render(<OutputRecipeForm output={OUTPUT} onChange={() => undefined} />);
    expect(screen.getByTestId("archive-section")).toBeInTheDocument();
    expect(screen.getByTestId("positive-section")).toBeInTheDocument();
    expect(screen.getByTestId("preview-section")).toBeInTheDocument();
    expect(screen.getByTestId("archive-filename-template")).toHaveValue("IMG_####.tiff");
    expect(screen.getByTestId("positive-format")).toHaveValue("tiff");
    expect(screen.getByTestId("positive-color-profile")).toHaveValue("adobeRgb1998");
    expect(screen.getByTestId("preview-format")).toHaveValue("jpeg");
    expect(screen.getByTestId("preview-max-long-edge")).toHaveValue(2048);
    expect(screen.getByTestId("output-auto-crop")).not.toBeChecked();
  });

  it("enables non-destructive auto-crop without changing the archive recipe", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<OutputRecipeForm output={OUTPUT} onChange={onChange} />);
    await user.click(screen.getByTestId("output-auto-crop"));
    const last = onChange.mock.calls[onChange.mock.calls.length - 1]?.[0] as OutputRecipe;
    expect(last.autoCrop).toBe(true);
    expect(last.archive).toEqual(OUTPUT.archive);
    expect(screen.getByTestId("auto-crop-help")).toHaveTextContent(
      "archive master stays full-frame",
    );
  });

  it("gates fullCapturePackage on archive.enabled: disabling archive unchecks it", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<OutputRecipeForm output={OUTPUT} onChange={onChange} />);
    const fullPackage = screen.getByTestId("archive-full-capture-package");
    expect(fullPackage).toBeChecked();
    await user.click(screen.getByLabelText("Archive (create-only)"));
    const last = onChange.mock.calls[onChange.mock.calls.length - 1]?.[0] as OutputRecipe;
    expect(last.archive.enabled).toBe(false);
    expect(last.archive.fullCapturePackage).toBe(false);
  });

  it("populates the archive destination only from the returned dialog path", async () => {
    const user = userEvent.setup();
    dialogMocks.open.mockResolvedValue("/Users/test/Scans");
    const onChange = vi.fn();
    render(<OutputRecipeForm output={OUTPUT} onChange={onChange} />);
    await user.click(screen.getByTestId("Archive destination-pick-destination"));
    expect(dialogMocks.open).toHaveBeenCalledWith(
      expect.objectContaining({ directory: true, multiple: false }),
    );
    const last = onChange.mock.calls[onChange.mock.calls.length - 1]?.[0] as OutputRecipe;
    expect(last.archive.destination).toBe("/Users/test/Scans");
  });

  it("keeps the stored template string untouched while rendering the live preview", () => {
    const onChange = vi.fn();
    render(<OutputRecipeForm output={OUTPUT} onChange={onChange} />);
    expect(screen.getByTestId("archive-template-preview")).toHaveTextContent("IMG_0007.tiff");
    expect(screen.getByTestId("archive-filename-template")).toHaveValue("IMG_####.tiff");
  });
});
