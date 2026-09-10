"""Frame-edge alignment for LS-50 capture.

Uses the whole-roll preview's row-density profile to find each frame's
exact vertical boundary (the dark inter-frame gap vs the dense frame), so a
capture window lands on the frame with no overlap and no big gap.
"""

from __future__ import annotations

import numpy as np

FRAME_PITCH_NATIVE = 5959

# Density thresholds are relative to the preview row profile's own range,
# so they work across stocks and exposures.
_GAP_FRACTION = 0.20      # rows below 20% of the peak-to-base range = gap
_MIN_GAP_ROWS = 3         # minimum consecutive gap rows to count as a seam


def row_density_profile(preview_rgb: np.ndarray) -> np.ndarray:
    """Return one density value per preview image row (mean of channels)."""
    a = np.asarray(preview_rgb)
    if a.ndim == 3:
        return a.mean(axis=(1, 2))
    return a.mean(axis=1)


def detect_frame_seams(
    density: np.ndarray,
    *,
    expected_frames: int,
    native_pitch: int = FRAME_PITCH_NATIVE,
    preview_dpi: int = 400,
) -> list[tuple[int, int]]:
    """Given a row-density profile, return each frame's (row_start, row_end)

    as preview rows. ``expected_frames`` is the known frame count (from the
    0x8f table / user). Uses per-pitch periodicity and gap detection: the
    ideal pitch in preview rows is ``native_pitch * preview_dpi // 4000``.
    """
    d = np.asarray(density, dtype=np.float64)
    if d.ndim != 1 or d.size == 0:
        raise ValueError("density profile must be a non-empty 1-D array")
    low = np.percentile(d, 5)
    high = np.percentile(d, 95)
    rng = max(high - low, 1.0)
    # gap mask: rows near the base (inter-frame spacing)
    gap = d < low + _GAP_FRACTION * rng

    # Find contiguous gap runs (seams).
    seams = []
    n = len(gap)
    i = 0
    while i < n:
        if gap[i]:
            j = i
            while j < n and gap[j]:
                j += 1
            if j - i >= _MIN_GAP_ROWS:
                seams.append((i, j - 1))
            i = j
        else:
            i += 1

    ideal_pitch = max(int(round(native_pitch * preview_dpi / 4000)), 1)
    # Use the first seam as the leading base; frames go between seams.
    frames: list[tuple[int, int]] = []
    if not seams:
        # no gaps detected (blank strip) -> divide evenly by pitch
        for k in range(expected_frames):
            s = k * ideal_pitch + 1
            e = min((k + 1) * ideal_pitch, max(n - 1, 1))
            frames.append((s, e))
        return frames

    # Frame k runs from end(seam k)+1 .. start(seam k+1) (or a full pitch
    # after the last known seam). If a leading seam exists before the first
    # frame, the first frame starts after it.
    prev_end = seams[0][1] + 1 if seams and seams[0][0] <= ideal_pitch // 2 else 0
    # take frames between seams
    region_ends = [s[0] - 1 for s in seams] + [n - 1]
    region_starts = [prev_end] + [s[1] + 1 for s in seams[1:]]
    # merge to expected count
    for k in range(min(expected_frames, len(region_starts))):
        s = region_starts[k]
        e = region_ends[k]
        frames.append((int(s), int(e)))
    # pad with pitch-based slots if fewer seams than frames
    while len(frames) < expected_frames:
        s = frames[-1][1] + 1
        e = min(s + ideal_pitch - 1, n - 1)
        frames.append((int(s), int(e)))
    return frames


__all__ = ["detect_frame_seams", "row_density_profile"]