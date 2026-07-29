#!/usr/bin/env python3
"""render_references.py -- renders fresh nikonlook color reference TIFFs for
Scan Studio's parity harness (nikon-coolscan4-software-archaeology, phase
13-parity-harness, plan 13-02) by invoking negfit's frozen nikonlook_core.py
API (load_bundle / estimate_gains / apply) directly against each corpus
slot's own raw RGB capture.

This script lives OUTSIDE the nikon-coolscan4-software-archaeology repo (GPL
reference code stays external -- see that repo's CLAUDE.md licensing
constraint) and is never copied into it. By default it writes
`acceptance_slotNN_reference_color_<bundle>.tif` next to the corpus, which
is what app/ScanStudio/engine/src/bin/parity.rs looks for as the color
module's reference. Pass --output-dir to write elsewhere instead (e.g. when
the corpus directory itself must stay read-only) -- see PARITY.md for the
current run's chosen path if --output-dir was used.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

import numpy as np
import tifffile

SLOT_COUNT = 6

# 65535.0 assumed as full_scale per nikonlook_core.py's own module docstring
# ("16-bit raw counts / full_scale"); no FULL_SCALE constant is defined in
# that file. VERIFY against negfit/models.py's own constant before trusting
# these renders for Phase 14 -- if it differs, fix this divisor and re-run.
FULL_SCALE = 65535.0


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
        "--bundle",
        default="~/Downloads/digital-ice-2026/negfit/bundles/nikonlook-v1",
        help="Path to the negfit bundle directory (default: nikonlook-v1)",
    )
    parser.add_argument(
        "--negfit-path",
        default="~/Downloads/digital-ice-2026/negfit",
        help="Path to negfit's directory, added to sys.path so nikonlook_core can be imported",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help=(
            "Directory to write acceptance_slotNN_reference_color_<bundle>.tif "
            "into (default: same directory as --corpus, which is what "
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
    return args


def main() -> int:
    args = parse_args()
    corpus = Path(args.corpus).expanduser().resolve()

    # Both defaults are documented as "expanduser'd" -- Python's import
    # machinery (unlike a shell) never expands a literal "~" placed on
    # sys.path, so this expansion must happen here, before use, or the
    # default --negfit-path silently fails to resolve to a real directory.
    negfit_path = Path(args.negfit_path).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else corpus
    output_dir.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(negfit_path))
    import nikonlook_core  # noqa: E402 -- import after sys.path mutation, by design

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

        # 2. DIY linear scanner RGB in [0, 1] -- see the FULL_SCALE comment above.
        raw_rgb_linear = raw.astype(np.float64) / FULL_SCALE

        # 3. Load the frozen nikonlook bundle (model.json / layer_a.json /
        # manifest.json / nikon-adobe-rgb.icc).
        bundle = nikonlook_core.load_bundle(args.bundle)

        # 4. Per-frame exposure gain estimate ("Layer A").
        k = nikonlook_core.estimate_gains(raw_rgb_linear, bundle)

        # 5. Shared matrix + curves color model ("Layer B") at that gain --
        # float64, [0, 1], clipped.
        nikon_rgb_device = nikonlook_core.apply(raw_rgb_linear, k, bundle)

        # 6. Re-quantize to 16-bit TIFF samples.
        out_u16 = np.clip(nikon_rgb_device * FULL_SCALE + 0.5, 0, 65535).astype(np.uint16)

        # 7. Write using the exact filename bin/parity.rs looks for.
        bundle_tag = Path(args.bundle).name  # e.g. "nikonlook-v1"
        out_path = output_dir / f"{base}_reference_color_{bundle_tag}.tif"
        tifffile.imwrite(str(out_path), out_u16, photometric="rgb")
        written += 1

        # 8. One line per slot.
        elapsed = time.monotonic() - slot_start
        print(
            f"slot {slot_number:02d}: bundle={bundle_tag} -> {out_path} "
            f"shape={out_u16.shape} dtype={out_u16.dtype} elapsed={elapsed:.2f}s"
        )

    total_elapsed = time.monotonic() - total_start
    print(f"wrote {written}/{SLOT_COUNT} reference TIFFs to {output_dir} in {total_elapsed:.2f}s total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
