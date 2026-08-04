import { describe, expect, it } from "vitest";
import {
  assertFrameTransition,
  assertJobTransition,
  IllegalTransitionError,
  isTerminalJobState,
} from "../store/machines";
import type { FrameState, JobState } from "../wire/types";

const JOB_STATES: JobState[] = [
  "queued",
  "scanning",
  "completed",
  "failed",
  "stoppingAfterCurrentFrame",
  "stoppingImmediately",
  "stopped",
];

const FRAME_STATES: FrameState[] = ["waiting", "active", "completed", "failed", "skipped"];

const LEGAL_JOB_TRANSITIONS: Array<[JobState | null, JobState]> = [
  [null, "queued"],
  ["queued", "scanning"],
  ["queued", "stopped"],
  ["scanning", "completed"],
  ["scanning", "failed"],
  ["scanning", "stoppingAfterCurrentFrame"],
  ["scanning", "stoppingImmediately"],
  ["stoppingAfterCurrentFrame", "stopped"],
  ["stoppingAfterCurrentFrame", "completed"],
  ["stoppingImmediately", "stopped"],
];

const LEGAL_FRAME_TRANSITIONS: Array<[FrameState | null, FrameState]> = [
  [null, "waiting"],
  ["waiting", "active"],
  ["active", "completed"],
  ["active", "failed"],
  ["active", "skipped"],
  ["failed", "active"],
];

describe("job state machine (PROTOCOL.md State machines)", () => {
  it("accepts every legal JobState transition", () => {
    for (const [from, to] of LEGAL_JOB_TRANSITIONS) {
      expect(() => assertJobTransition(from, to)).not.toThrow();
    }
  });

  it("rejects every JobState pair not listed as legal", () => {
    const legal = new Set(LEGAL_JOB_TRANSITIONS.map(([from, to]) => `${from}->${to}`));
    let illegalCount = 0;
    for (const from of JOB_STATES) {
      for (const to of JOB_STATES) {
        if (legal.has(`${from}->${to}`)) continue;
        illegalCount += 1;
        expect(() => assertJobTransition(from, to)).toThrow(IllegalTransitionError);
      }
    }
    expect(illegalCount).toBeGreaterThan(0);
  });

  it("rejects creation into any state other than queued", () => {
    for (const to of JOB_STATES) {
      if (to === "queued") continue;
      expect(() => assertJobTransition(null, to)).toThrow(IllegalTransitionError);
    }
  });

  it("rejects the specific illegal cases named in the plan", () => {
    expect(() => assertJobTransition("queued", "completed")).toThrow(IllegalTransitionError);
    expect(() => assertJobTransition("queued", "failed")).toThrow(IllegalTransitionError);
    expect(() => assertJobTransition("stoppingImmediately", "completed")).toThrow(
      IllegalTransitionError,
    );
    expect(() => assertJobTransition("stoppingAfterCurrentFrame", "failed")).toThrow(
      IllegalTransitionError,
    );
  });

  it("gives terminal JobStates zero legal outbound transitions", () => {
    for (const terminal of ["completed", "stopped", "failed"] as JobState[]) {
      for (const to of JOB_STATES) {
        expect(() => assertJobTransition(terminal, to)).toThrow(IllegalTransitionError);
      }
    }
  });

  it("names both states in the error message", () => {
    expect(() => assertJobTransition("queued", "completed")).toThrow(
      /queued.*completed|completed.*queued/,
    );
  });
});

describe("frame state machine (PROTOCOL.md State machines)", () => {
  it("accepts every legal FrameState transition including failed -> active retry", () => {
    for (const [from, to] of LEGAL_FRAME_TRANSITIONS) {
      expect(() => assertFrameTransition(from, to)).not.toThrow();
    }
  });

  it("rejects every FrameState pair not listed as legal", () => {
    const legal = new Set(LEGAL_FRAME_TRANSITIONS.map(([from, to]) => `${from}->${to}`));
    let illegalCount = 0;
    for (const from of FRAME_STATES) {
      for (const to of FRAME_STATES) {
        if (legal.has(`${from}->${to}`)) continue;
        illegalCount += 1;
        expect(() => assertFrameTransition(from, to)).toThrow(IllegalTransitionError);
      }
    }
    expect(illegalCount).toBeGreaterThan(0);
  });

  it("rejects creation into any state other than waiting", () => {
    for (const to of FRAME_STATES) {
      if (to === "waiting") continue;
      expect(() => assertFrameTransition(null, to)).toThrow(IllegalTransitionError);
    }
  });

  it("gives terminal FrameStates (completed, skipped) zero legal outbound transitions", () => {
    for (const terminal of ["completed", "skipped"] as FrameState[]) {
      for (const to of FRAME_STATES) {
        expect(() => assertFrameTransition(terminal, to)).toThrow(IllegalTransitionError);
      }
    }
  });

  it("names both states in the error message", () => {
    expect(() => assertFrameTransition("completed", "active")).toThrow(
      /completed.*active|active.*completed/,
    );
  });
});

describe("isTerminalJobState", () => {
  it("returns true only for completed, stopped, and failed", () => {
    expect(isTerminalJobState("completed")).toBe(true);
    expect(isTerminalJobState("stopped")).toBe(true);
    expect(isTerminalJobState("failed")).toBe(true);
    expect(isTerminalJobState("queued")).toBe(false);
    expect(isTerminalJobState("scanning")).toBe(false);
    expect(isTerminalJobState("stoppingAfterCurrentFrame")).toBe(false);
    expect(isTerminalJobState("stoppingImmediately")).toBe(false);
  });
});
