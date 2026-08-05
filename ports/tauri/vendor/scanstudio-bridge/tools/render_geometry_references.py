#!/usr/bin/env python3
"""render_geometry_references.py -- renders fresh autocrop + fine-deskew
geometry reference files for Scan Studio's parity harness (phase
15-geometry-port, plan 15-02) by invoking the real
`negpy.features.geometry.logic` module directly against each corpus slot's
own raw RGB capture.

This script is vendored in this repository, at `bridge/tools/`. The GPL
reference code it CALLS -- negpy-src -- is the thing that must stay
external so this repository's MIT licence is not entangled; this script
itself is MIT-licensed like the rest of this repository and has always been
intended to ship with it. Point --negpy-src-path at a checkout of that
external negpy-src (no default -- see that flag's own --help). By default
it writes reference files next to the corpus, which is what
app/ScanStudio/engine/src/bin/parity.rs looks for as the geometry modules'
references. Pass --output-dir to write elsewhere instead (e.g. when the
corpus directory itself must stay read-only) -- see PARITY.md for the
current run's chosen path if --output-dir was used.

For each of the six corpus slots this writes:
  - acceptance_slotNN_reference_autocrop_negpy-v1.json
      {"film": {"y1":.., "y2":.., "x1":.., "x2":..},
       "image": {"y1":.., "y2":.., "x1":.., "x2":..}}
    from the real get_autocrop_coords(img, mode=AutocropMode.FILM) and
    get_autocrop_coords(img, mode=AutocropMode.IMAGE).
  - acceptance_slotNN_reference_deskew_negpy-v1.tif
      the raw capture rotated by GEOMETRY_TEST_ANGLE_DEGREES via the real
      apply_fine_rotation, requantized to 16-bit.
  - acceptance_slotNN_reference_deskew_negpy-v1.json
      {"applied_angle_degrees": 1.75, "width": w, "height": h,
       "rotation_matrix": [[..], [..]]}
    from the real cv2.getRotationMatrix2D((w/2.0, h/2.0), 1.75, 1.0) --
    captured independently of apply_fine_rotation's own internals, so this
    is a genuine second source, not a value trusted from inside the
    function under test.

See app/ScanStudio/engine/src/parity/candidates.rs's
`<deskew_metric_design_rationale>` (plan 15-02) for why a fixed, documented
test angle is the correct design here -- NegPy has no automatic deskew-angle
detection anywhere in its source to compare against.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

SLOT_COUNT = 6

# 65535.0 assumed as full_scale, matching render_references.py's own
# FULL_SCALE convention and processing::geometry's own to_geometry_image
# conversion (parity::candidates.rs, plan 15-02).
FULL_SCALE = 65535.0

# Fixed, documented fine-deskew test angle applied uniformly across the
# whole corpus -- keep this literal in sync with
# app/ScanStudio/engine/src/parity/candidates.rs's own
# GEOMETRY_TEST_ANGLE_DEGREES constant (plan 15-01's own
# <rotation_algorithm> ground-truth angle). If either side changes, update
# both.
GEOMETRY_TEST_ANGLE_DEGREES = 1.75

# Dependencies this script itself needs, checked with a probe BEFORE
# importing negpy (see check_dependencies() below) so a missing package
# produces one actionable message instead of a raw traceback partway
# through a slot's processing.
REQUIRED_MODULES = ("cv2", "numpy", "numba", "tifffile")


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
        "--negpy-src-path",
        default=None,
        help=(
            "Path to negpy-src's directory, added to sys.path so "
            "negpy.features.geometry.logic can be imported. Required -- "
            "negpy-src is GPL-labeled reference code that stays external to "
            "this repository (see this file's own module docstring), so "
            "there is no in-checkout path to default to."
        ),
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help=(
            "Directory to write the reference files into (default: same "
            "directory as --corpus, which is what "
            "app/ScanStudio/engine/src/bin/parity.rs looks for). Use a "
            "separate directory when the corpus itself must stay read-only "
            "-- record the chosen path in PARITY.md so the harness can "
            "eventually be pointed at it."
        ),
    )
    args = parser.parse_args()
    if not args.corpus:
        parser.error(
            "--corpus not given and SCANSTUDIO_PARITY_CORPUS is not set in the environment"
        )
    if not args.negpy_src_path:
        parser.error(
            "--negpy-src-path is required (no default -- see --help): point it at a checkout "
            "of negpy-src's GPL-licensed source"
        )
    return args


def check_dependencies() -> None:
    """Verifies cv2/numpy/numba/tifffile import cleanly under the SAME
    interpreter that will run the rest of this script (sys.executable, not
    a bare `python3` shell-out -- `python3`/`pip3` can resolve to two
    different Python environments, in which case `pip3 show <pkg>` can
    report a package "installed" while the interpreter that actually runs
    this script still raises ModuleNotFoundError). Importing
    negpy.features.geometry.logic transitively requires numba (via
    negpy.kernel.image.logic's get_luminance) -- a dependency the color
    port's render_references.py never needed. Exits with an actionable
    message rather than letting a raw ModuleNotFoundError traceback surface
    from deep inside a negpy import.
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
        print("Fix with:", file=sys.stderr)
        print(
            f"    {sys.executable} -m pip install numpy opencv-python-headless numba tifffile",
            file=sys.stderr,
        )
        sys.exit(1)


def main() -> int:
    check_dependencies()

    # Import only after the dependency probe passes -- these are now
    # guaranteed importable under this exact interpreter.
    import cv2
    import numpy as np
    import tifffile

    args = parse_args()
    corpus = Path(args.corpus).expanduser().resolve()

    # Python's import machinery (unlike a shell) never expands a literal
    # "~" placed on sys.path, so this expansion must happen here, before
    # use, or the default --negpy-src-path silently fails to resolve to a
    # real directory (same fix render_references.py already applies to its
    # own --negfit-path).
    negpy_src_path = Path(args.negpy_src_path).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else corpus
    output_dir.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(negpy_src_path))
    import negpy.features.geometry.logic as geometry_logic  # noqa: E402 -- import after sys.path mutation, by design

    total_start = time.monotonic()
    written = 0
    for slot_number in range(1, SLOT_COUNT + 1):
        base = f"acceptance_slot{slot_number:02d}"
        raw_path = corpus / f"{base}.tif"
        if not raw_path.exists():
            print(f"ERROR: raw capture not found for slot {slot_number}: {raw_path}", file=sys.stderr)
            return 1

        slot_start = time.monotonic()

        # 1. This slot's raw RGB archive capture: (H, W, 3) uint16.
        raw = tifffile.imread(str(raw_path))

        # 2. Linear scanner RGB in [0, 1], float32 -- matches negpy's own
        # ImageBuffer = npt.NDArray[np.float32] convention exactly (unlike
        # nikonlook_core.py, which is float64) and
        # parity::candidates::to_geometry_image's own conversion.
        img = raw.astype(np.float32) / np.float32(FULL_SCALE)

        # 3. Autocrop: the real, automatic, content-driven detection
        # algorithm -- both modes, each a genuine end-to-end regression
        # check (no fixed-parameter caveat needed, unlike deskew below).
        film_roi = geometry_logic.get_autocrop_coords(img, mode=geometry_logic.AutocropMode.FILM)
        image_roi = geometry_logic.get_autocrop_coords(img, mode=geometry_logic.AutocropMode.IMAGE)

        # ROI is (y1, y2, x1, x2) -- map field names explicitly by
        # position, never assume dict-ordering.
        film_y1, film_y2, film_x1, film_x2 = film_roi
        image_y1, image_y2, image_x1, image_x2 = image_roi

        autocrop_json = {
            "film": {"y1": film_y1, "y2": film_y2, "x1": film_x1, "x2": film_x2},
            "image": {"y1": image_y1, "y2": image_y2, "x1": image_x1, "x2": image_x2},
        }
        autocrop_path = output_dir / f"{base}_reference_autocrop_negpy-v1.json"
        autocrop_path.write_text(_to_json(autocrop_json))

        # 4. Deskew: NegPy has no automatic deskew-ANGLE detection anywhere
        # in its source -- apply_fine_rotation only ever APPLIES a given
        # angle, never detects one. Apply the same fixed, documented test
        # angle the Rust candidate uses (GEOMETRY_TEST_ANGLE_DEGREES; see
        # this file's module docstring and
        # parity::candidates::GEOMETRY_TEST_ANGLE_DEGREES).
        rotated = geometry_logic.apply_fine_rotation(img, GEOMETRY_TEST_ANGLE_DEGREES)
        rotated_u16 = np.clip(rotated * FULL_SCALE + 0.5, 0, 65535).astype(np.uint16)
        deskew_tif_path = output_dir / f"{base}_reference_deskew_negpy-v1.tif"
        tifffile.imwrite(str(deskew_tif_path), rotated_u16, photometric="rgb")

        # 5. Separately capture the real rotation matrix cv2 itself
        # produces for this angle -- an independent second source, not a
        # value read out of apply_fine_rotation's own internals.
        h, w = img.shape[:2]
        rotation_matrix = cv2.getRotationMatrix2D((w / 2.0, h / 2.0), GEOMETRY_TEST_ANGLE_DEGREES, 1.0)
        deskew_json = {
            "applied_angle_degrees": GEOMETRY_TEST_ANGLE_DEGREES,
            "width": int(w),
            "height": int(h),
            "rotation_matrix": rotation_matrix.tolist(),
        }
        deskew_json_path = output_dir / f"{base}_reference_deskew_negpy-v1.json"
        deskew_json_path.write_text(_to_json(deskew_json))

        written += 1

        elapsed = time.monotonic() - slot_start
        print(
            f"slot {slot_number:02d}: film={film_roi} image={image_roi} "
            f"deskew_shape={rotated_u16.shape} elapsed={elapsed:.2f}s"
        )

    total_elapsed = time.monotonic() - total_start
    print(f"wrote {written}/{SLOT_COUNT} slots' geometry references to {output_dir} in {total_elapsed:.2f}s total")
    return 0


def _to_json(obj: dict) -> str:
    import json

    return json.dumps(obj, indent=2) + "\n"


if __name__ == "__main__":
    raise SystemExit(main())
