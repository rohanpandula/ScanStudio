/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ResolvedCaptureRecipe } from "../../../session/store/session";
import CaptureRecipeForm from "../CaptureRecipeForm";

afterEach(cleanup);

const DEFAULT_CAPTURE: ResolvedCaptureRecipe = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
};

const SIMULATOR_OPTIONS = [1, 2, 4, 8, 16];
const REAL_DEVICE_OPTIONS = [4];

describe("CaptureRecipeForm", () => {
  it("renders every field with the PROTOCOL.md defaults", () => {
    render(
      <CaptureRecipeForm
        capture={DEFAULT_CAPTURE}
        filmProcess="positive"
        multisampleOptions={SIMULATOR_OPTIONS}
        onChange={() => {}}
      />,
    );
    expect(screen.getByLabelText("Resolution (Dpi)")).toHaveValue(4000);
    expect(screen.getByLabelText("16 bits")).toBeChecked();
    expect(screen.getByLabelText("8 bits")).not.toBeChecked();
    expect(screen.getByLabelText("Multisample passes")).toHaveValue("1");
    expect(screen.getByLabelText("Rgb + infrared (rgbi)")).toBeChecked();
    expect(screen.getByLabelText("Rgb")).not.toBeChecked();
    expect(screen.queryByTestId("capture-bw-channels-note")).toBeNull();
  });

  it("reports a resolutionDpi change through onChange", async () => {
    const seen: ResolvedCaptureRecipe[] = [];
    function Harness() {
      const [capture, setCapture] = useState<ResolvedCaptureRecipe>(DEFAULT_CAPTURE);
      return (
        <CaptureRecipeForm
          capture={capture}
          filmProcess="positive"
          multisampleOptions={SIMULATOR_OPTIONS}
          onChange={(next) => {
            seen.push(next);
            setCapture(next);
          }}
        />
      );
    }
    const user = userEvent.setup();
    render(<Harness />);
    await user.clear(screen.getByLabelText("Resolution (Dpi)"));
    await user.type(screen.getByLabelText("Resolution (Dpi)"), "2000");
    expect(seen[seen.length - 1]).toEqual({ ...DEFAULT_CAPTURE, resolutionDpi: 2000 });
  });

  it("reports a bitDepth change through onChange", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(
      <CaptureRecipeForm
        capture={DEFAULT_CAPTURE}
        filmProcess="positive"
        multisampleOptions={SIMULATOR_OPTIONS}
        onChange={onChange}
      />,
    );
    await user.click(screen.getByLabelText("8 bits"));
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_CAPTURE, bitDepth: 8 });
  });

  it("reports a multisamplePasses change through onChange", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(
      <CaptureRecipeForm
        capture={DEFAULT_CAPTURE}
        filmProcess="positive"
        multisampleOptions={SIMULATOR_OPTIONS}
        onChange={onChange}
      />,
    );
    await user.selectOptions(screen.getByLabelText("Multisample passes"), "16");
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_CAPTURE, multisamplePasses: 16 });
  });

  it("reports a channels change through onChange", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(
      <CaptureRecipeForm
        capture={DEFAULT_CAPTURE}
        filmProcess="positive"
        multisampleOptions={SIMULATOR_OPTIONS}
        onChange={onChange}
      />,
    );
    await user.click(screen.getByLabelText("Rgb"));
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_CAPTURE, channels: "rgb" });
  });

  it("forces channels to rgb and disables the control with explanatory text for bwNegative", () => {
    render(
      <CaptureRecipeForm
        capture={{ ...DEFAULT_CAPTURE, channels: "rgbi" }}
        filmProcess="bwNegative"
        multisampleOptions={SIMULATOR_OPTIONS}
        onChange={() => {}}
      />,
    );
    const rgb = screen.getByLabelText("Rgb");
    expect(rgb).toBeChecked();
    expect(rgb).toBeDisabled();
    expect(screen.getByLabelText("Rgb + infrared (rgbi)")).toBeDisabled();
    expect(screen.getByTestId("capture-bw-channels-note")).toHaveTextContent(/forced to rgb/i);
  });

  it("keeps the channels control enabled (never forced) for a non-B&W process", () => {
    render(
      <CaptureRecipeForm
        capture={DEFAULT_CAPTURE}
        filmProcess="c41ColorNegative"
        multisampleOptions={SIMULATOR_OPTIONS}
        onChange={() => {}}
      />,
    );
    expect(screen.getByLabelText("Rgb")).not.toBeDisabled();
    expect(screen.getByLabelText("Rgb + infrared (rgbi)")).not.toBeDisabled();
    expect(screen.queryByTestId("capture-bw-channels-note")).toBeNull();
  });

  describe("device-aware multisampleOptions (Issue: real LS-5000 offered 2x/8x/16x)", () => {
    it("offers the full simulator range when no device is connected yet", () => {
      render(
        <CaptureRecipeForm
          capture={DEFAULT_CAPTURE}
          filmProcess="positive"
          multisampleOptions={SIMULATOR_OPTIONS}
          onChange={() => {}}
        />,
      );
      const options = screen
        .getAllByRole<HTMLOptionElement>("option")
        .map((option) => option.value);
      expect(options).toEqual(["1", "2", "4", "8", "16"]);
    });

    it("offers only the connected real device's own set, never the simulator's 2x/8x/16x", () => {
      render(
        <CaptureRecipeForm
          capture={{ ...DEFAULT_CAPTURE, multisamplePasses: 4 }}
          filmProcess="positive"
          multisampleOptions={REAL_DEVICE_OPTIONS}
          onChange={() => {}}
        />,
      );
      const options = screen
        .getAllByRole<HTMLOptionElement>("option")
        .map((option) => option.value);
      expect(options).toEqual(["4"]);
    });
  });
});
