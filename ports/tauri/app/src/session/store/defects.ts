// Defect-analysis wire wrapper (07-02 Task 2): project.analyzeFrameDefects.
// Same dependency-injection pattern as 07-01's metadata.ts -- the request
// function is the first parameter, so this module has zero coupling to
// SessionStore internals and is unit-testable with a fake request. Plain
// TypeScript, no React, no UI.

import type {
  AnalyzeFrameDefectsResult,
  CaptureRecipe,
  ProcessingRecipe,
} from "../wire/types";

/** The injected request channel: method-name string + optional params. */
export type DefectRequest = (method: string, params?: unknown) => Promise<unknown>;

/**
 * project.analyzeFrameDefects -> AnalyzeFrameDefectsResult, returned
 * unchanged. The engine resolves the frame's effective capture/processing
 * (including its own overrides) and chooses the data source (real RGB+IR
 * receipt analysis vs. the seeded synthetic generator) and reports
 * `simulated` honestly -- the UI must not re-derive or mask that flag.
 */
export async function analyzeFrameDefects(
  request: DefectRequest,
  frameIndex: number,
  capture: CaptureRecipe,
  processing: ProcessingRecipe,
): Promise<AnalyzeFrameDefectsResult> {
  return (await request("project.analyzeFrameDefects", {
    frameIndex,
    capture,
    processing,
  })) as AnalyzeFrameDefectsResult;
}
