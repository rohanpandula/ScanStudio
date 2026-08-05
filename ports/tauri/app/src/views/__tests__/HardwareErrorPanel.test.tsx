/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadRealBackendFixture, type FixtureWireMessage } from "../../session/testing/realBackendFixtureStream";
import HardwareErrorPanel from "../HardwareErrorPanel";

afterEach(cleanup);

const ERRORS_FIXTURE = resolve(
  __dirname,
  "../../session/__tests__/fixtures/real-backend/02-typed-hardware-errors.ndjson",
);
const STALL_FIXTURE = resolve(
  __dirname,
  "../../session/__tests__/fixtures/real-backend/04-stream-stalled-preview-failure.ndjson",
);

describe("HardwareErrorPanel", () => {
  const errorMessages = loadRealBackendFixture(ERRORS_FIXTURE)
    .map((line: FixtureWireMessage) => {
      const error = line.error;
      if (error === undefined) return null;
      return { code: error.code, message: error.message, recoverable: error.recoverable };
    })
    .filter((e) => e !== null);

  it("renders FEEDER_PARKED's bridge message verbatim plus power-cycle guidance", () => {
    const feederParked = errorMessages.find((e) => e?.code === "FEEDER_PARKED");
    expect(feederParked).toBeDefined();
    render(<HardwareErrorPanel error={feederParked ?? null} />);
    expect(screen.getByTestId("feeder-parked-message")).toHaveTextContent(
      "transport parked at end-stop after slot 14; power cycle required before further motion",
    );
    expect(screen.getByTestId("feeder-parked-guidance")).toHaveTextContent("power cycle");
    expect(screen.getByTestId("hardware-error-panel")).toHaveAttribute(
      "data-code",
      "FEEDER_PARKED",
    );
  });

  it("renders HW_MOTION_NOT_ARMED as operator-owned with no in-app arm action", () => {
    const motionNotArmed = errorMessages.find((e) => e?.code === "HW_MOTION_NOT_ARMED");
    expect(motionNotArmed).toBeDefined();
    render(<HardwareErrorPanel error={motionNotArmed ?? null} />);
    expect(screen.getByTestId("motion-not-armed-message")).toHaveTextContent(
      "motion refused: SCANSTUDIO_HW_MOTION unset or hw-motion-armed latch missing/empty",
    );
    expect(screen.getByTestId("motion-independent-guidance")).toHaveTextContent(
      "operator-owned",
    );
  });

  it("offers no retry/eject/arm control in either special-cased render", () => {
    const feederParked = errorMessages.find((e) => e?.code === "FEEDER_PARKED");
    const motionNotArmed = errorMessages.find((e) => e?.code === "HW_MOTION_NOT_ARMED");
    // The safety guarantee is that NO interactive control (retry, eject, arm,
    // refeed) is offered anywhere near either panic -- assert by absence of
    // buttons and links, plus the CES guide text renders only as guidance.
    const { unmount } = render(<HardwareErrorPanel error={feederParked ?? null} />);
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.queryByRole("link")).toBeNull();
    expect(screen.queryByRole("button", { name: /retry|eject|re-feed|arm/i })).toBeNull();
    unmount();
    render(<HardwareErrorPanel error={motionNotArmed ?? null} />);
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.queryByRole("link")).toBeNull();
    expect(screen.queryByRole("button", { name: /retry|eject|re-feed|arm/i })).toBeNull();
    // The guidance copy itself never instructs an in-app action.
    expect(screen.getByTestId("motion-independent-guidance").textContent).toContain(
      "operator-owned",
    );
  });

  it("renders a generic fallback (verbatim message) for an unknown code", () => {
    render(
      <HardwareErrorPanel
        error={{ code: "SCANNER_BUSY", message: "device busy", recoverable: true }}
      />,
    );
    expect(screen.getByTestId("generic-error-code")).toHaveTextContent("SCANNER_BUSY");
    expect(screen.getByTestId("generic-error-message")).toHaveTextContent("device busy");
  });

  it("explains FILM_FEED_INTERRUPTED without offering a blind retry", () => {
    render(
      <HardwareErrorPanel
        error={{
          code: "FILM_FEED_INTERRUPTED",
          message: "verified medium not present while positioning frame 6",
          recoverable: false,
        }}
      />,
    );
    expect(screen.getByTestId("hardware-error-panel")).toHaveAttribute(
      "data-code",
      "FILM_FEED_INTERRUPTED",
    );
    expect(screen.getByTestId("film-feed-interrupted-guidance")).toHaveTextContent(
      "finished frames are safe",
    );
    expect(screen.getByTestId("film-feed-interrupted-guidance")).toHaveTextContent(
      "fresh preview",
    );
    expect(screen.queryByRole("button")).toBeNull();
  });

  it("renders BRIDGE_STREAM_STALLED as a failed preview, never an empty success", () => {
    const stalled = loadRealBackendFixture(STALL_FIXTURE)
      .map((line: FixtureWireMessage) => line.payload as unknown as { code?: string; message?: string })
      .find((p) => p && p.code === "BRIDGE_STREAM_STALLED");
    expect(stalled).toBeDefined();
    render(
      <HardwareErrorPanel error={null} thumbnailsFailed={{ code: "BRIDGE_STREAM_STALLED", message: stalled?.message ?? "" }} />,
    );
    expect(screen.getByTestId("preview-failed-state")).toHaveTextContent("Preview failed");
    expect(screen.getByTestId("preview-failed-code")).toHaveTextContent("BRIDGE_STREAM_STALLED");
    expect(screen.getByTestId("preview-failed-message")).toHaveTextContent(
      stalled?.message ?? "",
    );
    expect(screen.queryByTestId(/success|done|empty/i)).toBeNull();
  });
});
