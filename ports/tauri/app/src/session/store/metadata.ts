// Metadata wire wrappers (07-01 Task 1): the plan's five wrapper functions
// over the engine request channel. Each takes the request function as its
// FIRST parameter (dependency injection), so this module has zero coupling to
// SessionStore internals and is unit-testable with a fake request. There is
// deliberately no React import and no UI here -- plain TypeScript.
//
// Safety note (threat T-07-01): none of these functions ever accepts an
// ExifTool argument list or command string. applyMetadata sends only
// frameIndex plus the reviewed preview fingerprint; the engine rebuilds and
// verifies the argument array entirely server-side
// (PROTOCOL.md: "applyMetadata always rebuilds its own argument array
// server-side ... never accepts or executes a client-supplied argument
// list").

import type {
  ApplyMetadataResult,
  ExifToolDetection,
  MetadataSet,
  PreviewMetadataCommandResult,
  ScanProject,
} from "../wire/types";

/** The injected request channel: method-name string + optional params. */
export type MetadataRequest = (method: string, params?: unknown) => Promise<unknown>;

/** exiftool.detect -> ExifToolDetection. Pure capability query. */
export async function detectExifTool(request: MetadataRequest): Promise<ExifToolDetection> {
  return (await request("exiftool.detect", {})) as ExifToolDetection;
}

/** project.previewMetadataCommand -> the exact argument array before anything runs. */
export async function previewMetadataCommand(
  request: MetadataRequest,
  frameIndex: number,
): Promise<PreviewMetadataCommandResult> {
  return (await request("project.previewMetadataCommand", {
    frameIndex,
  })) as PreviewMetadataCommandResult;
}

/**
 * project.applyMetadata -> ApplyMetadataResult, or null on rejection -- never
 * throws. Mirrors SessionModel.swift's one-shot "returns nil on failure"
 * pattern (lines 2243-2258), so the caller renders the resolved
 * exitCode/stdout/stderr truthfully without inventing success.
 */
export async function applyMetadata(
  request: MetadataRequest,
  frameIndex: number,
  previewFingerprint: string,
): Promise<ApplyMetadataResult | null> {
  try {
    return (await request("project.applyMetadata", {
      frameIndex,
      previewFingerprint,
    })) as ApplyMetadataResult;
  } catch {
    return null;
  }
}

/** project.setRollMetadata: whole-object metadata swap; returns the project. */
export async function setRollMetadata(
  request: MetadataRequest,
  metadata: MetadataSet,
): Promise<{ project: ScanProject }> {
  return (await request("project.setRollMetadata", { metadata })) as {
    project: ScanProject;
  };
}

/** project.setFrameMetadataOverride: whole-object swap; null clears. */
export async function setFrameMetadataOverride(
  request: MetadataRequest,
  frameIndex: number,
  metadata: MetadataSet | null,
): Promise<{ project: ScanProject }> {
  return (await request("project.setFrameMetadataOverride", {
    frameIndex,
    metadata,
  })) as { project: ScanProject };
}
