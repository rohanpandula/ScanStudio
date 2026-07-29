#!/usr/bin/env python3
"""render_ice_references.py -- renders a fresh Legacy-only (classical, no
Hybrid/ML) ICE defect-mask reference for Scan Studio's parity harness
(nikon-coolscan4-software-archaeology, phase 16-legacy-ice, plan 16-03) by
invoking the real, installed `portable_digital_ice` v0.3.1 package's own
detection primitives directly against each corpus slot's own raw RGB+IR
capture.

WHY THIS SCRIPT EXISTS (read this before trusting a score). Phase 13's
`bin/parity.rs` originally had `score_ice()` compare the Rust Legacy-ICE
candidate against the corpus's own bundled `acceptance_slotNN_repaired_SYNTH.png`
disclosure mask -- but that mask was produced in `hybrid` (ML-assisted) mode
(`digital-fauxice` v0.3.0), not Legacy mode. Plan 16-03's own real,
self-measured investigation (`engine/tests/ice_candidates.rs`'s
`reference_mask_coverage_sanity_check`, run against this exact corpus) found
the two masks essentially DISJOINT: on slot 1, the bundled mask covers
7.604681% of the frame (1,788,181 / 23,514,214 px >= 0.5) while the Rust
Legacy port's own DefectMap covers 0.336715% (79,176 px) -- a ~22.6x size
mismatch in the OPPOSITE direction from this plan's original hypothesis
(hybrid was expected to be much SMALLER, being "AI-escalated pixels only";
measured, it is much LARGER) -- and the measured Jaccard agreement (0.000176)
is roughly 250x below even the best-case floor if the smaller mask were a
perfect spatial subset of the larger one (~0.0443), meaning the two masks
disagree about WHERE defects are, not just how many. Whatever the reason
(the hybrid pipeline's AI inpainting stage likely patches a broader
neighborhood than the pixel-level defect footprint), the bundled disclosure
mask is not a meaningful reference for scoring a Legacy-only port. This
script generates the missing Legacy-only reference instead.

WHY THIS SCRIPT LIVES OUTSIDE nikon-coolscan4-software-archaeology. Unlike
`render_references.py`/`render_geometry_references.py` (which MUST live
externally -- their upstream sources are GPL-labeled/unlicensed, and the
target repo is MIT), `portable-digital-ice` is ALREADY MIT, same owner
(Rohan Pandula) as nikon-coolscan4-software-archaeology. Keeping this
script here too is a CONSISTENCY choice (every other reference-rendering
script in this project already lives in this directory; keeping a one-off
Python dependency out of the primary Swift/Rust app repo), NOT a licensing
requirement -- do not mistake this for a GPL boundary. See
app/ScanStudio/PARITY.md in nikon-coolscan4-software-archaeology for the
full writeup.

WHAT THIS SCRIPT DOES NOT DO. It only reproduces the DETECTION half of
Legacy ICE (response-LUT conversion -> auxiliary derivation -> continuous
score -> defect confirmation -> renormalized [0,1] mask) -- it does NOT
reproduce the RECONSTRUCTION/healing half (multiscale candidates, band
combination, dither, output-LUT emission). `bin/parity.rs`'s `score_ice()`
only ever compares MASKS (Jaccard agreement), never repaired-pixel values
(that comparison, if ever needed, would require a much larger, separate
effort mirroring `processing::ice::heal`'s own ~2,000 lines of ported
reconstruction math) -- so a mask-only reference is everything the parity
gate needs.

WHAT THIS SCRIPT CALLS, AND WHY IT IS NOT A BYTE-EXACT PORT OF THE REAL
PACKAGE'S OWN TOP-LEVEL DECISION FUNCTION. This script calls the REAL,
installed package's own response-LUT (`SharedLookupInputResponse`),
auxiliary-derivation (`derive_auxiliary`), and continuous-score
(`continuous_score`) functions directly -- unmodified, exactly as shipped.
For the final defect-CONFIRMATION step, this script mirrors
`processing::ice::is_confirmed` (the Rust port's own adaptation, plan
16-01) instead of calling the real package's own
`evaluate_normal_decision`/`evaluate_normal_auxiliary_decision`. This is
deliberate, not an oversight: plan 16-01's own `ICE-PROVENANCE.md`
documents two independently-verified, empirical reasons the real decision
functions do not work in this project's single-acquisition (no real
prepass) context -- (1) their 4-disjoint-bar structure, offset a fixed
`perpendicular_radius` away from the candidate pixel, cannot discriminate a
small genuine defect from isolated single-pixel noise, since both are
smaller than the mandatory offset; (2) their fixed `sample_threshold`
constant is calibrated for the real prepass-reduced pipeline's absolute
auxiliary scale and does not transfer to this project's frame-relative
`base_primary` substitute. Calling the real decision functions as-is here
would just reproduce that already-documented broken behavior, not produce
a meaningful reference. Every fixed profile constant this script's
confirmation step needs (`count_limit`, `perpendicular_radius`) is still
read directly from the REAL, installed `LS5000Selector8NormalProfile`
object below (via `decision_parameters()`) -- nothing is hand-transcribed
from the Rust source.

THE SINGLE-ACQUISITION SUBSTITUTE. `portable_digital_ice`'s real
`ProcessingJob`/`DualRGBIAcquisition` API hard-requires a same-frame 285 dpi
prepass + 4000 dpi main RGBI pair; this project's six-slot parity corpus has
no prepass file. Mirroring `IceParameters::for_main_scan`'s own Rust
recipe exactly (plan 16-01's `<single_acquisition_adaptation>`): this
script computes `base_primary` directly from THIS frame's own rail-excluded
(1st-99th percentile) mean response-converted R and IR samples, using
`alpha = 0.17` -- the real algorithm's OWN documented
`zero_denominator_alpha` "no usable prepass regression signal" fallback,
not a fabricated number. Rather than hand-transcribing every other fixed
profile constant a second time, this script constructs a SYNTHETIC
`PrepassFrameRecord` payload carrying only `alpha=0.17` and this frame's own
`mean_r`/`mean_ir`, then calls the REAL, installed profile object's own
`auxiliary_parameters()`/`score_parameters()`/`decision_parameters()`
methods to derive every other constant -- so this script never
hand-transcribes a single fixed hex constant; every one traces to a live
call into the real, installed package.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np

SLOT_COUNT = 6

# Dependencies this script itself needs, checked with a probe BEFORE
# importing portable_digital_ice (see check_dependencies() below), mirroring
# render_geometry_references.py's exact pattern -- sys.executable, not a
# bare `python3` shell-out, since `python3`/`pip3` can resolve to a
# different interpreter than the one actually running this script. This
# script is specifically meant to be run under the scratchpad venv that has
# the REAL portable_digital_ice v0.3.1 installed -- the system-wide install
# (if any) may be stale; never trust it (see plan 16-01/16-02's own
# SUMMARYs for why a fresh scratchpad venv was used instead).
REQUIRED_MODULES = ("numpy", "tifffile", "PIL", "portable_digital_ice")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--corpus",
        default=os.environ.get("SCANSTUDIO_PARITY_CORPUS"),
        help="Path to the parity corpus directory (default: $SCANSTUDIO_PARITY_CORPUS)",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help=(
            "Directory to write acceptance_slotNN_reference_ice_legacy-v1.png "
            "(+ .json provenance sidecar) into (default: same directory as "
            "--corpus). Use a separate SIBLING directory when the corpus "
            "itself must stay read-only -- matches the exact precedent "
            "render_references.py/render_geometry_references.py already "
            "established for this project; record the chosen path in "
            "PARITY.md so the harness can eventually be pointed at it via "
            "SCANSTUDIO_PARITY_REFS."
        ),
    )
    args = parser.parse_args()
    if not args.corpus:
        parser.error(
            "--corpus not given and SCANSTUDIO_PARITY_CORPUS is not set in the environment"
        )
    return args


def check_dependencies() -> None:
    """Verifies numpy/tifffile/PIL/portable_digital_ice import cleanly under
    the SAME interpreter that will run the rest of this script
    (sys.executable). Exits with an actionable message rather than letting a
    raw ModuleNotFoundError traceback surface partway through a slot's
    processing -- mirrors render_geometry_references.py's own
    check_dependencies() exactly.
    """
    probe = subprocess.run(
        [sys.executable, "-c", f"import {', '.join(REQUIRED_MODULES)}"],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        print(
            "ERROR: one or more required Python packages are not importable "
            f"under {sys.executable} (the interpreter running this script):",
            file=sys.stderr,
        )
        print(probe.stderr.strip(), file=sys.stderr)
        print("", file=sys.stderr)
        print(
            "This script must be run under the scratchpad venv that has the "
            "REAL portable_digital_ice v0.3.1 installed (see plan 16-01/16-02's "
            "own SUMMARYs) -- e.g.:",
            file=sys.stderr,
        )
        print(
            "    /path/to/ice-venv/bin/python3 render_ice_references.py --corpus ...",
            file=sys.stderr,
        )
        print(
            f"If numpy/tifffile/Pillow specifically are missing under that venv: "
            f"{sys.executable} -m pip install numpy tifffile pillow imagecodecs",
            file=sys.stderr,
        )
        sys.exit(1)


def _windowed_sum_excluding_center(mask: "np.ndarray", radius: int) -> "np.ndarray":
    """For every pixel, the sum of `mask` (an int array of 0/1) over a
    Chebyshev-radius (2*radius+1) x (2*radius+1) square window, EXCLUDING the
    center pixel, with out-of-frame neighbors contributing 0 -- an O(H*W)
    vectorized equivalent of `processing::ice::is_confirmed`'s own
    zero-padded boundary handling (Rust, plan 16-01: neighbors outside
    [0,height)x[0,width) are simply skipped, never counted), computed via a
    zero-padded integral image rather than a per-pixel Python loop (which
    would be far too slow at this project's real ~23.5M-pixel frame size).
    """

    import numpy as np

    height, width = mask.shape
    padded = np.pad(mask, radius, mode="constant", constant_values=0).astype(np.int64)
    integral = np.zeros((padded.shape[0] + 1, padded.shape[1] + 1), dtype=np.int64)
    integral[1:, 1:] = np.cumsum(np.cumsum(padded, axis=0), axis=1)

    window = 2 * radius + 1
    top_left = integral[0:height, 0:width]
    top_right = integral[0:height, window : window + width]
    bottom_left = integral[window : window + height, 0:width]
    bottom_right = integral[window : window + height, window : window + width]
    window_sum_including_self = bottom_right - bottom_left - top_right + top_left
    return window_sum_including_self - mask.astype(np.int64)


def _rail_excluded_mean(values: "np.ndarray") -> float:
    """Mean of `values`, excluding samples outside the 1st-99th percentile
    range (rail exclusion), falling back to the full population's mean if
    the trimmed subset is empty -- mirrors `processing::ice::rail_excluded_mean`
    (Rust, plan 16-01) exactly: same percentile definition (NumPy's own
    default "linear" interpolation -- used directly here via `np.percentile`,
    not hand-reimplemented), same trim-then-mean approach, same empty-trim
    fallback to the untrimmed population.
    """

    import numpy as np

    flat = values.astype(np.float64).ravel()
    if flat.size == 0:
        return 0.0
    lo, hi = np.percentile(flat, [1.0, 99.0])
    trimmed = flat[(flat >= lo) & (flat <= hi)]
    source = trimmed if trimmed.size > 0 else flat
    return float(source.mean())


def render_one_slot(
    slot_number: int,
    corpus: Path,
    profile,
    contracts_module,
    x3a_module,
) -> tuple["np.ndarray", dict]:
    """Renders one slot's Legacy-only defect mask (float32 [0,1], 0=clean,
    1=severe -- the exact same public convention `processing::ice::DefectMap`
    uses) plus the provenance dict this run's findings get recorded into.
    Returns (mask, provenance) -- writes nothing; the caller decides paths.
    """

    import numpy as np
    import tifffile

    base = f"acceptance_slot{slot_number:02d}"
    rgb_path = corpus / f"{base}.tif"
    ir_path = corpus / f"{base}_IR.tif"
    if not rgb_path.exists():
        raise FileNotFoundError(f"raw RGB capture not found for slot {slot_number}: {rgb_path}")
    if not ir_path.exists():
        raise FileNotFoundError(f"raw IR capture not found for slot {slot_number}: {ir_path}")

    evidence_id = base

    # 1. Read raw RGB (H, W, 3) uint16 + raw IR (H, W) uint16, assemble into
    # the real package's own RGBI16Frame contract (H, W, 4) uint16, channel
    # order R,G,B,IR -- matches processing::ice::IceInputFrame's own
    # rgb[R,G,B] + ir convention (parity::candidates::render_ice_candidate,
    # plan 16-03), just interleaved into one array the way the real
    # contract requires.
    rgb = tifffile.imread(str(rgb_path))
    ir = tifffile.imread(str(ir_path))
    if ir.ndim == 3:
        ir = ir[:, :, 0]
    height, width = rgb.shape[0], rgb.shape[1]
    rgbi = np.empty((height, width, 4), dtype=np.uint16)
    rgbi[:, :, 0:3] = rgb
    rgbi[:, :, 3] = ir

    frame = contracts_module.RGBI16Frame(
        rgbi, contracts_module.AcquisitionEpoch.MAIN, profile.main_dpi, evidence_id
    )

    # 2. Real response-LUT conversion (x3a.SharedLookupInputResponse,
    # generate_nikon_response_lut internally) -- unmodified real function.
    response = x3a_module.SharedLookupInputResponse.nikon_logarithmic()
    working = response.convert(frame.pixels)  # (H, W, 4) float32

    # 3. Single-acquisition base_primary substitute: THIS frame's own
    # rail-excluded mean response-converted R (channel 0) and IR (channel 3)
    # samples, alpha=0.17 -- see module docstring.
    mean_r = _rail_excluded_mean(working[:, :, 0])
    mean_ir = _rail_excluded_mean(working[:, :, 3])

    # 4. Synthetic PrepassFrameRecord carrying ONLY the substitute
    # alpha/mean_r/mean_ir at the real dataclass's own documented byte
    # offsets (contracts.PrepassFrameRecord: alpha @ 0x04, mean_r @ 0x28,
    # mean_ir @ 0x2C) -- every OTHER profile constant this script needs
    # (base_addend/scale/offset/floor/count_limit/perpendicular_radius/etc.)
    # is read directly from the real profile object below, never
    # hand-transcribed here.
    payload = bytearray(0x40)
    struct.pack_into("<f", payload, 0x04, 0.17)
    struct.pack_into("<f", payload, 0x28, mean_r)
    struct.pack_into("<f", payload, 0x2C, mean_ir)
    record = contracts_module.PrepassFrameRecord(bytes(payload), slot_number, evidence_id)

    aux_params = profile.auxiliary_parameters(record)
    score_params = profile.score_parameters(record)
    decision_params = profile.decision_parameters()

    # 5. Real auxiliary derivation + real continuous score (WITH the real
    # function's own horizontal 3-tap minimum smoothing -- always active
    # under this profile's fixed constants, 550 < 4000).
    auxiliary = x3a_module.derive_auxiliary(working, aux_params)  # (H, W) float32
    raw_score = x3a_module.continuous_score(auxiliary, score_params)  # (H, W) float32

    # 6. Confirmation step -- mirrors processing::ice::is_confirmed exactly
    # (see module docstring for why this is not the real
    # evaluate_normal_decision/evaluate_normal_auxiliary_decision). Per-pixel
    # UNSMOOTHED severity (the real continuous_score's own core affine+clamp
    # formula, applied directly to the raw auxiliary plane, bypassing its
    # horizontal-smoothing pre-step -- matches Rust's single_pixel_severity,
    # itself extracted from this exact real formula).
    primary = float(np.float32(score_params.base_primary))
    addend = float(np.float32(score_params.base_addend))
    scale = float(np.float32(score_params.scale))
    offset = float(np.float32(score_params.offset))
    floor = float(np.float32(score_params.floor))
    aux64 = auxiliary.astype(np.float64)
    unsmoothed_severity = np.clip(((primary + addend) - aux64) * scale + offset, floor, 1.0)
    midpoint = (floor + 1.0) / 2.0
    is_low = (unsmoothed_severity < midpoint).astype(np.int64)

    radius = int(decision_params.perpendicular_radius)
    low_count = _windowed_sum_excluding_center(is_low, radius)
    confirmed = (low_count >= 1) & (low_count <= decision_params.count_limit)

    # 7. Renormalize exactly like processing::ice::detect_defects: 0.0=clean
    # ceiling / 1.0=severe, via (1.0 - raw_score) / (1.0 - floor), clamped,
    # ONLY on confirmed pixels; everything else reads bit-exact 0.0.
    denom = max(1.0 - floor, 1e-9)
    mask = np.where(
        confirmed,
        np.clip((1.0 - raw_score.astype(np.float64)) / denom, 0.0, 1.0),
        0.0,
    ).astype(np.float32)

    provenance = {
        "package": "portable_digital_ice",
        "package_version": _package_version(),
        "mode": "legacy",
        "slot": slot_number,
        "scope": "detection_only_mask -- no repaired-RGB reference generated; bin/parity.rs's score_ice() only ever compares masks",
        "single_acquisition_substitute": {
            "alpha": 0.17,
            "mean_r_response": mean_r,
            "mean_ir_response": mean_ir,
            "base_primary": float(score_params.base_primary),
            "note": (
                "base_primary computed from THIS frame's own rail-excluded "
                "(1st-99th percentile) mean response-converted R/IR samples, "
                "using alpha=0.17 (the real algorithm's own documented "
                "zero_denominator_alpha 'no usable prepass regression signal' "
                "fallback) -- NOT a byte-exact reproduction of Nikon's "
                "firmware prepass-register replay. See "
                "processing/ICE-PROVENANCE.md's 'Handling: the "
                "single-acquisition adaptation' section in "
                "nikon-coolscan4-software-archaeology."
            ),
        },
        "confirmation_adaptation": {
            "mirrors": "processing::ice::is_confirmed (Rust, plan 16-01)",
            "not": "portable_digital_ice.x3a.evaluate_normal_decision / evaluate_normal_auxiliary_decision",
            "reason": (
                "The real decision functions' 4-disjoint-bar structure "
                "cannot discriminate a small genuine defect from isolated "
                "noise at this profile's own perpendicular_radius, and their "
                "fixed sample_threshold constant does not transfer to this "
                "single-acquisition base_primary substitute -- both "
                "empirically verified during plan 16-01's execution. See "
                "processing/ICE-PROVENANCE.md's 'Handling: the "
                "neighborhood-confirmation adaptation' section."
            ),
            "perpendicular_radius": int(decision_params.perpendicular_radius),
            "count_limit": int(decision_params.count_limit),
        },
        "mask_convention": "float32 [0.0, 1.0], 0.0=clean (bit-exact on every unconfirmed pixel), 1.0=most severe",
        "frame_shape": {"height": height, "width": width},
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    return mask, provenance


def _package_version() -> str:
    import importlib.metadata

    try:
        return importlib.metadata.version("portable_digital_ice")
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def main() -> int:
    check_dependencies()

    # Import only after the dependency probe passes.
    import numpy as np
    from PIL import Image

    import portable_digital_ice.contracts as contracts_module
    import portable_digital_ice.x3a as x3a_module
    from portable_digital_ice.profile import DEFAULT_PROFILE

    args = parse_args()
    corpus = Path(args.corpus).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else corpus
    output_dir.mkdir(parents=True, exist_ok=True)

    total_start = time.monotonic()
    written = 0
    for slot_number in range(1, SLOT_COUNT + 1):
        slot_start = time.monotonic()
        mask, provenance = render_one_slot(
            slot_number, corpus, DEFAULT_PROFILE, contracts_module, x3a_module
        )

        # Round-half-up quantization to full-scale u16, matching
        # parity::candidates.rs's own quantize_u16 formula exactly.
        mask_u16 = np.clip(mask.astype(np.float64) * 65535.0 + 0.5, 0.0, 65535.0).astype(np.uint16)

        base = f"acceptance_slot{slot_number:02d}"
        mask_path = output_dir / f"{base}_reference_ice_legacy-v1.png"
        Image.fromarray(mask_u16).save(mask_path)

        coverage_fraction = float(np.count_nonzero(mask_u16 >= 32768) / mask_u16.size)
        provenance["coverage_fraction_at_0.5"] = coverage_fraction

        sidecar_path = output_dir / f"{base}_reference_ice_legacy-v1.json"
        sidecar_path.write_text(json.dumps(provenance, indent=2) + "\n")

        written += 1
        elapsed = time.monotonic() - slot_start
        print(
            f"slot {slot_number:02d}: coverage={coverage_fraction * 100:.6f}% "
            f"base_primary={provenance['single_acquisition_substitute']['base_primary']:.4f} "
            f"-> {mask_path.name} elapsed={elapsed:.2f}s"
        )

    total_elapsed = time.monotonic() - total_start
    print(
        f"wrote {written}/{SLOT_COUNT} Legacy ICE reference masks to {output_dir} "
        f"in {total_elapsed:.2f}s total"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
