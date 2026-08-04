import { describe, expect, it } from "vitest";
import { frameCountRangeFor, validateFrameCount } from "../projectRules";

describe("validateFrameCount", () => {
  it("accepts roll36 frames 1 through 40", () => {
    expect(validateFrameCount("roll36", 1)).toEqual({ valid: true });
    expect(validateFrameCount("roll36", 40)).toEqual({ valid: true });
  });

  it("rejects roll36 frame counts outside 1-40", () => {
    expect(validateFrameCount("roll36", 0)).toEqual({
      valid: false,
      message: expect.any(String),
    });
    expect(validateFrameCount("roll36", 41)).toEqual({
      valid: false,
      message: expect.any(String),
    });
  });

  it("accepts strip6 frames 1 through 6", () => {
    expect(validateFrameCount("strip6", 6)).toEqual({ valid: true });
  });

  it("rejects strip6 frame counts above 6", () => {
    expect(validateFrameCount("strip6", 7)).toEqual({
      valid: false,
      message: expect.any(String),
    });
  });

  it("accepts mounted exactly 1", () => {
    expect(validateFrameCount("mounted", 1)).toEqual({ valid: true });
  });

  it("rejects mounted frame counts other than 1", () => {
    expect(validateFrameCount("mounted", 2)).toEqual({
      valid: false,
      message: expect.any(String),
    });
  });
});

describe("frameCountRangeFor", () => {
  it("returns the roll36 range 1-40", () => {
    expect(frameCountRangeFor("roll36")).toEqual({ min: 1, max: 40 });
  });

  it("returns the strip6 range 1-6", () => {
    expect(frameCountRangeFor("strip6")).toEqual({ min: 1, max: 6 });
  });

  it("returns the mounted range 1-1", () => {
    expect(frameCountRangeFor("mounted")).toEqual({ min: 1, max: 1 });
  });
});
