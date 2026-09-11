"""Command-line LS-50 capture -> calibration artifacts.

Usage:
    python -m coolscanpy.protocol.ls50 --out <dir> --stem test_01_A1 \
        [--dpi 4000] [--depth 14] [--rgbi] [--frame 1] [--pass A1]

Writes <stem>.tif, <stem>-ir.tif, <stem>.receipt.json in <dir>.
"""

from __future__ import annotations

import argparse
import os

from . import Ls50ScanOptions, Ls50Session
from .artifacts import write_capture_artifacts


def main() -> None:
    parser = argparse.ArgumentParser(description="LS-50 RGBI capture to calibration artifacts")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--stem", required=True, help="file stem (e.g. portra400_01_A1)")
    parser.add_argument("--dpi", type=int, default=4000)
    parser.add_argument("--depth", type=int, default=14, choices=(8, 14))
    parser.add_argument("--rgbi", action="store_true", default=True)
    parser.add_argument("--frame", type=int, default=1)
    parser.add_argument("--pass", dest="pass_token", default="A1")
    parser.add_argument("--exp-r", type=int, default=1_000_000)
    parser.add_argument("--exp-g", type=int, default=1_000_000)
    parser.add_argument("--exp-b", type=int, default=1_000_000)
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    opt = Ls50ScanOptions(dpi=args.dpi, depth=args.depth, rgbi=args.rgbi)
    print(f"scanning LS-50 at {args.dpi} dpi, {args.depth}-bit, RGBI={args.rgbi}...")
    with Ls50Session() as session:
        data = session.capture(opt, boundary_best_effort=True)
    print(f"captured {len(data)} bytes")
    paths = write_capture_artifacts(
        data=data, opt=opt, directory=args.out, stem=args.stem,
        frame=args.frame, pass_token=args.pass_token,
        exposure_r=args.exp_r, exposure_g=args.exp_g, exposure_b=args.exp_b,
    )
    print("wrote:", paths.rgb)
    print("wrote:", paths.ir)
    print("wrote:", paths.receipt)


if __name__ == "__main__":
    main()
