"""Run one calibration pass on the LS-50 (Coolscan V).

Usage (matches the operator guide's per-pass flow):

    python -m coolscanpy.protocol.ls50.pass_runner \
        --stock portra400 --pass A1 --out <project> --frames 36 \
        [--slot-map slotmap.json] [--dpi 4000] [--depth 14] [--rgbi] \
        [--exp-r-us ..] [--exp-g-us ..] [--exp-b-us ..] [--preview]

Flow per the guide:
  1. (--preview) capture a whole-roll preview and write
     <out>/<stock>/coolscan/preview/<stock>_preview.tif
  2. For each frame NN in 1..frames (or the slot map), capture the raw
     RGBI frame and write
     <out>/<stock>/coolscan/<stock>_<NN>_<pass>.tif,
     <stock>_<NN>_<pass>-ir.tif, and <stock>_<NN>_<pass>.receipt.json

The slot map, when supplied, maps physical slot -> frame; otherwise
slot == frame (identity), which is the default for a fresh strip where
the first slot is frame 1.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

from . import Ls50ScanOptions, Ls50Session
from .workflow import Ls50Roll


def _load_slot_map(path: str | None) -> dict[int, int]:
    if not path:
        return {}
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    if not isinstance(raw, dict):
        raise ValueError("slot map must be a JSON object {slot: frame}")
    return {int(k): int(v) for k, v in raw.items()}


def _synthetic_frame(frame: int):
    from .workflow import Ls50Frame
    return Ls50Frame(index=frame, native_origin=(frame - 1) * 5959)


def _write_proof(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(text)
        fh.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a calibration pass on the Nikon LS-50 (Coolscan V)"
    )
    parser.add_argument("--stock", required=True, help="stock name, e.g. portra400")
    parser.add_argument("--pass", dest="pass_token", required=True,
                        help="pass token: A1, A2, Arep01..Arep10, B")
    parser.add_argument("--out", required=True, help="project/collection root")
    parser.add_argument("--frames", type=int, default=36)
    parser.add_argument("--page-frames", type=int, default=0,
                        help="for Arep: how many repeats of the page frame (10 normally)")
    parser.add_argument("--page-frame", type=int, default=20,
                        help="for Arep: which frame to repeat (20 normally)")
    parser.add_argument("--slot-map", default=None)
    parser.add_argument("--dpi", type=int, default=4000)
    parser.add_argument("--depth", type=int, default=14, choices=(8, 14))
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--exp-r-us", type=int, default=10000)
    parser.add_argument("--exp-g-us", type=int, default=10000)
    parser.add_argument("--exp-b-us", type=int, default=10000)
    args = parser.parse_args()

    slot_map = _load_slot_map(args.slot_map)
    cool_dir = Path(args.out) / args.stock / "coolscan"
    cool_dir.mkdir(parents=True, exist_ok=True)

    with Ls50Session() as session:
        roll = Ls50Roll(session=session)

        if args.preview:
            t0 = time.monotonic()
            res = roll.preview(dpi=400, depth=8)
            prev_dir = cool_dir / "preview"
            prev_dir.mkdir(parents=True, exist_ok=True)
            import tifffile
            tifffile.imwrite(prev_dir / f"{args.stock}_preview.tif",
                             res.rgb, photometric="rgb")
            print(f"preview {time.monotonic()-t0:.0f}s -> {prev_dir / f'{args.stock}_preview.tif'}",
                  f"({res.rgb.shape}) frames={res.slot_count}")
            _write_proof(cool_dir / "pass-summary.txt",
                         f"preview {args.stock}: {res.rgb.shape} frames={res.slot_count}")

        # Determine the list of (slot, frame) to capture this pass.
        if args.pass_token.startswith("Arep") and args.pass_token != "A":
            count = args.page_frames or int(args.pass_token.removeprefix("Arep"))
            frames_list = [("20", "20")] * count
        else:
            frames_list = [(str(slot_map.get(slot, slot)),
                            str(slot_map.get(slot, slot)))
                           for slot in range(1, args.frames + 1)]

        start = time.monotonic()
        for i, (slot_s, frame_s) in enumerate(frames_list, 1):
            frame = int(frame_s)
            stem = f"{args.stock}_{int(slot_s):02d}_{args.pass_token}"
            t0 = time.monotonic()
            paths = roll.capture_frame(
                roll.preview.frames[frame - 1] if roll.preview is not None
                else _synthetic_frame(frame),
                stem=stem,
                directory=cool_dir,
                pass_token=args.pass_token,
                exposure_r=args.exp_r_us * 100,
                exposure_g=args.exp_g_us * 100,
                exposure_b=args.exp_b_us * 100,
            )
            dt = time.monotonic() - t0
            print(f"[{i}/{len(frames_list)}] {stem}: {dt:.0f}s "
                  f"({os.path.getsize(paths.rgb)>>20}MB tif)")
            _write_proof(cool_dir / "pass-summary.txt",
                         f"{stem}: {dt:.0f}s {os.path.getsize(paths.rgb)} {os.path.getsize(paths.ir)}")
        total = time.monotonic() - start
        print(f"\npass {args.pass_token}: {len(frames_list)} frames in {total:.0f}s "
              f"({total/len(frames_list):.0f}s/frame)" if frames_list else "")
        roll.close()


if __name__ == "__main__":
    main()