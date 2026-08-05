export type Carrier = "roll36" | "strip6" | "mounted";

export interface FrameCountRange {
  min: number;
  max: number;
}

export interface FrameCountValidation {
  valid: boolean;
  message?: string;
}

const RANGES: Record<Carrier, FrameCountRange> = {
  roll36: { min: 1, max: 40 },
  strip6: { min: 1, max: 6 },
  mounted: { min: 1, max: 1 },
};

export function frameCountRangeFor(carrier: Carrier): FrameCountRange {
  return RANGES[carrier];
}

export function validateFrameCount(
  carrier: Carrier,
  frameCount: number,
): FrameCountValidation {
  const range = frameCountRangeFor(carrier);
  if (Number.isInteger(frameCount) && frameCount >= range.min && frameCount <= range.max) {
    return { valid: true };
  }
  if (range.min === range.max) {
    return {
      valid: false,
      message: `${carrier} requires exactly ${range.min} frame`,
    };
  }
  return {
    valid: false,
    message: `${carrier} requires between ${range.min} and ${range.max} frames`,
  };
}
