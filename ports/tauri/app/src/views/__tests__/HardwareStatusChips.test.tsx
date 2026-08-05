/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadRealBackendFixture } from "../../session/testing/realBackendFixtureStream";
import type { FixtureWireMessage } from "../../session/testing/realBackendFixtureStream";
import HardwareStatusChips from "../HardwareStatusChips";

afterEach(cleanup);

const FIXTURE = resolve(
  __dirname,
  "../../session/__tests__/fixtures/real-backend/01-hardware-status-tristate.ndjson",
);

interface StatusEvent {
  status: { motionArmed?: boolean | null; filmPresent?: boolean | null };
}

describe("HardwareStatusChips", () => {
  const statuses = loadRealBackendFixture(FIXTURE)
    .map((line: FixtureWireMessage) => line.payload as unknown as StatusEvent)
    .filter((p) => p.status !== undefined);

  it("is driven from the fixture file, not hand-duplicated literals", () => {
    expect(statuses.length).toBe(3);
  });

  it("renders the armed state distinctly from not-armed and unknown", () => {
    const [bothArmed] = statuses;
    render(
      <HardwareStatusChips
        motionArmed={bothArmed.status.motionArmed ?? null}
        filmPresent={bothArmed.status.filmPresent ?? null}
      />,
    );
    expect(screen.getByTestId("motion-chip")).toHaveTextContent("Motion: Armed");
    expect(screen.getByTestId("film-chip")).toHaveTextContent("Film: Present");
    expect(screen.getByTestId("motion-chip")).toHaveAttribute("data-state", "armed");
  });

  it("renders the not-armed/not-present state distinctly", () => {
    const [, bothNotArmed] = statuses;
    render(
      <HardwareStatusChips
        motionArmed={bothNotArmed.status.motionArmed ?? null}
        filmPresent={bothNotArmed.status.filmPresent ?? null}
      />,
    );
    expect(screen.getByTestId("motion-chip")).toHaveTextContent("Motion: Not Armed");
    expect(screen.getByTestId("film-chip")).toHaveTextContent("Film: Not Present");
    expect(screen.getByTestId("motion-chip")).toHaveAttribute("data-state", "not-armed");
  });

  it("renders an explicit Unknown for null, never blank and never the same as true/false", () => {
    const [, , filmUnknown] = statuses;
    render(
      <HardwareStatusChips
        motionArmed={filmUnknown.status.motionArmed ?? null}
        filmPresent={filmUnknown.status.filmPresent ?? null}
      />,
    );
    // motionArmed is true, filmPresent is null in fixture line 3.
    expect(screen.getByTestId("film-chip")).toHaveTextContent("Film: Unknown");
    expect(screen.getByTestId("film-chip")).toHaveAttribute("data-state", "unknown");
    expect(screen.getByTestId("film-chip").textContent).not.toBe("");
    // The unknown state renders different copy than both true/false.
    expect(screen.getByTestId("film-chip").textContent).not.toContain("Present");
    expect(screen.getByTestId("film-chip").textContent).not.toContain("Not Present");
  });

  it("never treats null as absence — the chip is always present with text", () => {
    render(<HardwareStatusChips motionArmed={null} filmPresent={null} />);
    expect(screen.getByTestId("motion-chip")).toHaveTextContent("Motion: Unknown");
    expect(screen.getByTestId("film-chip")).toHaveTextContent("Film: Unknown");
  });
});
