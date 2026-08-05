// JobState/FrameState transition tables, transcribed verbatim from the
// "State machines" section of PROTOCOL.md (read-only source of truth).
// The engine enforces these tables server-side; the store mirrors the same
// discipline client-side so an illegal transition arriving over the wire is
// surfaced, never silently applied.

import type { FrameState, JobState } from "../wire/types";

export class IllegalTransitionError extends Error {
  readonly from: string;
  readonly to: string;

  constructor(machine: "job" | "frame", from: string | null, to: string) {
    super(`Illegal ${machine} state transition: "${from ?? "(none)"}" -> "${to}"`);
    this.name = "IllegalTransitionError";
    this.from = from ?? "(none)";
    this.to = to;
  }
}

// Legal next-states per current state. PROTOCOL.md:
// JobState queued -> scanning -> {completed | failed | stoppingAfterCurrentFrame |
// stoppingImmediately}; stoppingAfterCurrentFrame -> {stopped | completed};
// stoppingImmediately -> stopped; queued -> stopped (stop before first frame).
// Terminal: completed, stopped, failed -- zero outbound transitions.
const JOB_TRANSITIONS: Record<JobState, readonly JobState[]> = {
  queued: ["scanning", "stopped"],
  scanning: ["completed", "failed", "stoppingAfterCurrentFrame", "stoppingImmediately"],
  stoppingAfterCurrentFrame: ["stopped", "completed"],
  stoppingImmediately: ["stopped"],
  completed: [],
  stopped: [],
  failed: [],
};

// The only state a job may be created in (from === null).
const JOB_INITIAL_STATE: JobState = "queued";

// FrameState waiting -> active -> {completed | failed | skipped};
// failed -> active (retry, attempt+1). Project-level "excluded" frames never
// enter a job at all -- exclusion is not a job state.
const FRAME_TRANSITIONS: Record<FrameState, readonly FrameState[]> = {
  waiting: ["active"],
  active: ["completed", "failed", "skipped"],
  failed: ["active"],
  completed: [],
  skipped: [],
};

const FRAME_INITIAL_STATE: FrameState = "waiting";

export function assertJobTransition(from: JobState | null, to: JobState): void {
  if (from === null) {
    if (to !== JOB_INITIAL_STATE) {
      throw new IllegalTransitionError("job", from, to);
    }
    return;
  }
  if (!JOB_TRANSITIONS[from].includes(to)) {
    throw new IllegalTransitionError("job", from, to);
  }
}

export function assertFrameTransition(from: FrameState | null, to: FrameState): void {
  if (from === null) {
    if (to !== FRAME_INITIAL_STATE) {
      throw new IllegalTransitionError("frame", from, to);
    }
    return;
  }
  if (!FRAME_TRANSITIONS[from].includes(to)) {
    throw new IllegalTransitionError("frame", from, to);
  }
}

export function isTerminalJobState(state: JobState): boolean {
  return JOB_TRANSITIONS[state].length === 0;
}
