/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ProcessingRecipe } from "../../../session/wire/types";
import ProcessingRecipeForm from "../ProcessingRecipeForm";

afterEach(cleanup);

const DEFAULT_PROCESSING: ProcessingRecipe = {
  filmProcess: "positive",
  autofocusEachFrame: false,
  autoExposureEachFrame: false,
  digitalIceEnabled: false,
  digitalIceMode: "hybrid",
  softwareDustRemovalBw: false,
};

describe("ProcessingRecipeForm", () => {
  it("renders filmProcess read-only plus the autofocus/autoexposure checkboxes", () => {
    render(
      <ProcessingRecipeForm
        processing={DEFAULT_PROCESSING}
        filmProcess="positive"
        onChange={() => {}}
      />,
    );
    const processValue = screen.getByTestId("processing-film-process-value");
    expect(processValue).toHaveTextContent("positive");
    expect(screen.getByLabelText("Autofocus each frame")).not.toBeChecked();
    expect(screen.getByLabelText("Auto-exposure each frame")).not.toBeChecked();
  });

  it("reports an autofocusEachFrame change through onChange", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(
      <ProcessingRecipeForm
        processing={DEFAULT_PROCESSING}
        filmProcess="positive"
        onChange={onChange}
      />,
    );
    await user.click(screen.getByLabelText("Autofocus each frame"));
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_PROCESSING, autofocusEachFrame: true });
  });

  it("shows the Digital ICE mode select only while Digital ICE is enabled", async () => {
    const seen: ProcessingRecipe[] = [];
    function Harness() {
      const [processing, setProcessing] = useState<ProcessingRecipe>(DEFAULT_PROCESSING);
      return (
        <ProcessingRecipeForm
          processing={processing}
          filmProcess="positive"
          onChange={(next) => {
            seen.push(next);
            setProcessing(next);
          }}
        />
      );
    }
    const user = userEvent.setup();
    render(<Harness />);
    expect(screen.queryByLabelText("Digital ICE mode")).toBeNull();
    await user.click(screen.getByLabelText("Digital ICE enabled"));
    expect(screen.getByLabelText("Digital ICE mode")).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText("Digital ICE mode"), "legacy");
    expect(seen[seen.length - 1]).toEqual({
      ...DEFAULT_PROCESSING,
      digitalIceEnabled: true,
      digitalIceMode: "legacy",
    });
  });

  it("reports an autoExposureEachFrame change through onChange", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(
      <ProcessingRecipeForm
        processing={DEFAULT_PROCESSING}
        filmProcess="positive"
        onChange={onChange}
      />,
    );
    await user.click(screen.getByLabelText("Auto-exposure each frame"));
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_PROCESSING, autoExposureEachFrame: true });
  });

  it("forces Digital ICE off with the honest no-B&W-ICE copy and shows softwareDustRemovalBw for bwNegative", () => {
    render(
      <ProcessingRecipeForm
        processing={{ ...DEFAULT_PROCESSING, filmProcess: "bwNegative", digitalIceEnabled: true }}
        filmProcess="bwNegative"
        onChange={() => {}}
      />,
    );
    const iceCheckbox = screen.getByLabelText("Digital ICE enabled");
    expect(iceCheckbox).not.toBeChecked();
    expect(iceCheckbox).toBeDisabled();
    expect(screen.queryByLabelText("Digital ICE mode")).toBeNull();
    expect(screen.getByTestId("processing-ice-bw-note")).toHaveTextContent(
      /cannot make an honest B&W ICE claim/i,
    );
    expect(screen.getByLabelText("Software dust removal (B&W)")).toBeInTheDocument();
  });

  it("hides softwareDustRemovalBw for every non-B&W film process", () => {
    render(
      <ProcessingRecipeForm
        processing={DEFAULT_PROCESSING}
        filmProcess="kodachrome"
        onChange={() => {}}
      />,
    );
    expect(screen.queryByLabelText("Software dust removal (B&W)")).toBeNull();
    expect(screen.queryByTestId("processing-ice-bw-note")).toBeNull();
    expect(screen.getByLabelText("Digital ICE enabled")).not.toBeDisabled();
  });

  it("keeps Digital ICE enabled reportable for a non-B&W process", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(
      <ProcessingRecipeForm
        processing={DEFAULT_PROCESSING}
        filmProcess="c41ColorNegative"
        onChange={onChange}
      />,
    );
    const iceCheckbox = screen.getByLabelText("Digital ICE enabled");
    expect(iceCheckbox).not.toBeDisabled();
    await user.click(iceCheckbox);
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_PROCESSING, digitalIceEnabled: true });
  });
});
