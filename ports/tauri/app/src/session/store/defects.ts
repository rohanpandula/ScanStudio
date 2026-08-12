// Defect-analysis wire wrapper (07-02 Task 2): project.analyzeFrameDefects.
// Same dependency-injection pattern as 07-01's metadata.ts -- the request
// function is the first parameter, so this module has zero coupling to
// SessionStore internals and is unit-testable with a fake request. Plain
// TypeScript, no React, no UI.

import type { AnalyzeFrameDefectsResult } from "../wire/types";

/** The injected request channel: method-name string + optional params. */
export type DefectRequest = (method: string, params?: unknown) => Promise<unknown>;

/**
 * project.analyzeFrameDefects -> AnalyzeFrameDefectsResult, returned
 * unchanged. Only the frame identity crosses the renderer boundary: the
 * engine resolves effective capture/processing authoritatively from project
 * state, frame overrides, and the latest receipt, then chooses real RGB+IR
 * receipt analysis vs. the seeded synthetic generator) and reports
 * `simulated` honestly -- the UI must not re-derive or mask that flag.
 */
export async function analyzeFrameDefects(
  request: DefectRequest,
  frameIndex: number,
): Promise<AnalyzeFrameDefectsResult> {
  return (await request("project.analyzeFrameDefects", {
    frameIndex,
  })) as AnalyzeFrameDefectsResult;
}
