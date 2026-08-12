/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { PartialDate } from "../../session/wire/types";
import PartialDateEditor from "../PartialDateEditor";

afterEach(cleanup);

type OnChange = (next: PartialDate | null) => void;

function renderEditor(value: PartialDate | null, onChange: OnChange): void {
  render(<PartialDateEditor value={value} onChange={onChange} />);
}

describe("PartialDateEditor", () => {
  it("selecting Exact precision before a full date is entered does NOT call onChange (no fabricated day/month)", async () => {
    const onChange = vi.fn();
    renderEditor(null, onChange);
    const user = userEvent.setup();
    await user.click(screen.getByTestId("date-precision-exact"));
    // No fabricated date is produced by the precision selection alone.
    expect(onChange).not.toHaveBeenCalled();
    // Only a genuine user-picked date commits.
    fireEvent.change(screen.getByTestId("date-exact-input"), { target: { value: "2024-05-06" } });
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0][0]).toEqual({ kind: "exact", date: "2024-05-06" });
  });

  it("a value of null and a value of {kind:'unknown'} both render identically as Unknown with no sub-fields", () => {
    const { unmount } = render(<PartialDateEditor value={null} onChange={vi.fn()} />);
    expect(screen.getByTestId("date-precision-unknown")).toBeChecked();
    expect(screen.queryByTestId("date-exact-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-year-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-month-select")).not.toBeInTheDocument();
    unmount();

    renderEditor({ kind: "unknown" }, vi.fn());
    expect(screen.getByTestId("date-precision-unknown")).toBeChecked();
    expect(screen.queryByTestId("date-exact-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-year-input")).not.toBeInTheDocument();
    expect(screen.queryByTestId("date-month-select")).not.toBeInTheDocument();
  });

  it("Month precision with no known year defers the commit until a full year is typed", async () => {
    const onChange = vi.fn();
    renderEditor(null, onChange);
    const user = userEvent.setup();
    await user.click(screen.getByTestId("date-precision-month"));
    fireEvent.change(screen.getByTestId("date-month-select"), { target: { value: "6" } });
    expect(onChange).not.toHaveBeenCalled();
    await user.type(screen.getByTestId("date-year-input"), "2024");
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0][0]).toEqual({ kind: "monthOnly", year: 2024, month: 6 });
  });

  it("a partial typed year ('2', '20') never commits a year value", async () => {
    const onChange = vi.fn();
    renderEditor(null, onChange);
    const user = userEvent.setup();
    await user.click(screen.getByTestId("date-precision-year"));
    await user.type(screen.getByTestId("date-year-input"), "20");
    expect(onChange).not.toHaveBeenCalled();
  });

  it("does not fabricate January when switching a year-only value to Month", async () => {
    const onChange = vi.fn();
    renderEditor({ kind: "yearOnly", year: 1985 }, onChange);
    const user = userEvent.setup();
    await user.click(screen.getByTestId("date-precision-month"));
    expect(onChange).not.toHaveBeenCalled();
    expect(screen.getByTestId("date-year-input")).toHaveValue("1985");

    await user.selectOptions(screen.getByTestId("date-month-select"), "6");
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0][0]).toEqual({ kind: "monthOnly", year: 1985, month: 6 });
  });
});
