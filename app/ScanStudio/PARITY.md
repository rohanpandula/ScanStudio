# Scan Studio Parity Harness

The Rust parity harness (`scanstudio_engine::parity`, `make parity`) compares
Scan Studio's own module output against a "golden corpus" of real
Nikon SUPER COOLSCAN 5000 ED captures, so that as each pipeline module gets
ported (color in Phase 14, geometry in Phase 15, ICE in Phase 16), its
output can be checked against real reference data instead of intuition
alone. This document explains how to point the harness at the corpus, what
each reference is (and isn't), and how to read a report honestly.

## 1. Corpus setup

The parity corpus intentionally lives outside this repository. Obtain a
corpus you are authorized to use and set `SCANSTUDIO_PARITY_CORPUS` to its
root; no individual workstation location is part of this contract.

Set `SCANSTUDIO_PARITY_CORPUS` to the root of a "refeed" acceptance corpus
directory, then run:

```sh
SCANSTUDIO_PARITY_CORPUS=/path/to/corpus make parity        # human table
SCANSTUDIO_PARITY_CORPUS=/path/to/corpus JSON=1 make parity  # JSON report
```

`make parity` hard-fails with a clear message if `SCANSTUDIO_PARITY_CORPUS`
is unset — unlike `make test`, this target's whole purpose is comparing
against real data, so there is no meaningful "skip" behavior here (that
lives in `cargo test`'s corpus-gated tests instead, which print a skip
message and exit 0 when the env var is absent).

A corpus directory holds six numbered slots. For each `NN` in `01`..`06`:

| File | Contents |
|------|----------|
| `acceptance_slotNN_receipt.json` | Provenance: device, dpi, depth, capture session, color/repair pipeline metadata. This is the file the loader globs for — every other path is derived from its basename. |
| `acceptance_slotNN.tif` | Raw RGB archive capture, 16-bit, 3-sample. |
| `acceptance_slotNN_IR.tif` | Raw IR plane, 16-bit, 1-sample. |
| `acceptance_slotNN_positive.tif` | Corpus-bundled color+repair composite — **not** a nikonlook reference (see §3). |
| `acceptance_slotNN_repaired.tif` / `_repaired_IR.tif` | ICE-repaired RGB/IR. |
| `acceptance_slotNN_repaired_SYNTH.png` | ICE disclosure mask (hybrid-mode — see §3). |

The corpus directory also contains internal `.negpy-*` cache directories
with content-addressed filenames; `corpus::discover` ignores these
naturally (they're directories, not `*_receipt.json` files), no special
casing needed.

## 2. Provenance

Extracted from `acceptance_slot01_receipt.json` of the corpus this harness
was built and verified against:

- **Capture session directory:** `NEGPY-LS5000-SIX-STRIP-LIVE-20260722-D`, captured 2026-07-22, corpus subdirectory `outputs-refeed-7`.
- **Device:** `Nikon LS-5000 ED 1.03` (`.device_model`), a real SUPER COOLSCAN 5000 ED.
- **Resolution / depth:** 4000 dpi, 16-bit (`.dpi`, `.depth`).
- **Batch/session id:** `batch-slot01-slot06-31odjrup` (`.nikon_density_ownership.batch_session_id`) — identical across all 6 slots; they are one capture session of six frames (`.nikon_density_ownership.frame_total` = 6).
- **Reference-corpus positive color metadata:** `.outputs.positive.color_mode` = `nikon-exact`, built by `.outputs.positive.builder_receipt.algorithm` = `ls5000-md3-prescan-to-pref-v1` plus `.outputs.positive.cms_receipt.algorithm` = `cml4-captured-optimized-stage1-stage2-v1`, tagged `.outputs.positive.icc_profile.name` = `Nikon Adobe RGB 4.0.0.3000`. This records the external reference artifact only. ScanStudio does not redistribute those profile bytes; C41 derivatives instead embed a ScanStudio-authored ICC profile compatible with the Adobe RGB (1998) color space.
- **Repair pipeline:** `.outputs.repaired.engine` = `digital-fauxice`, `.outputs.repaired.engine_version` = `0.3.0`, `.outputs.repaired.mode_resolved` = `hybrid`.

## 3. Reference provenance mismatch — read this before trusting a score

**2026-07-29 update: every `nikonlook-v1` filename below is historical.**
`nikonlook.rs` removed the v1 bundle entirely that day (dead since v2
shipped hours earlier); `bin/parity.rs`'s `score_color` now derives its
expected reference filename from whichever bundle `nikonlook::load_bundle()`
actually returns, not a hardcoded literal — in this repo, always
`nikonlook-v2`. `render_references.py`'s own `--bundle` default was
updated to match. The `nikonlook-v1` filenames and the "original
validation" described in this section are kept as-written below because
they accurately describe what was verified AT THE TIME; do not run any
command in this section literally expecting a `-v1` file to be what
`make parity` looks for today — substitute `-v2` throughout, or (for
`render_references.py`) simply omit `--bundle` and let its now-current
default apply.

**Color.** The corpus's bundled `acceptance_slotNN_positive.tif` was
produced by a *native per-acquisition builder* (`ls5000-md3-prescan-to-pref-v1`)
plus a `cml4-captured-optimized-stage1-stage2-v1` color-management stage —
a completely different color pipeline than `nikonlook_core.py`'s
`load_bundle` / `estimate_gains` / `apply` model that Phase 14 ports to
Rust. **`_positive.tif` is therefore not usable as a nikonlook parity
reference.** The real reference is
`acceptance_slotNN_reference_color_{bundle_version}.tif`, freshly rendered by
`render_references.py` (this plan, Task 3) by literally invoking
`nikonlook_core.load_bundle` / `estimate_gains` / `apply` against each
slot's own raw `.tif` capture — not copied or derived from `_positive.tif`.

**`{bundle_version}` is not a fixed literal.** `bin/parity.rs`'s `score_color`
derives it from `processing::nikonlook::load_bundle().bundle_version` —
whichever bundle version is actually compiled into the engine build running
`make parity` — so a candidate rendered against bundle X is only ever
compared to bundle X's own reference. As of the nikonlook-v2 switch,
`load_bundle()` returns `nikonlook-v2` by default, so the filename `make
parity` looks for today is `acceptance_slotNN_reference_color_nikonlook-v2.tif`,
not `..._nikonlook-v1.tif`. Historical `nikonlook-v1`-named references may
still be used by external comparison tooling, but the v1 bundle and loader
are no longer compiled or distributed here. If the reference file
`score_color` expects doesn't exist,
`bin/parity.rs` reports `no_reference` with a message naming the exact
expected filename and the command to produce it, rather than silently
falling back to a differently-versioned reference.

`render_references.py` lives in this repository's own `bridge/tools/`
directory. Run it with:

```sh
python3 bridge/tools/render_references.py \
  --corpus "$SCANSTUDIO_PARITY_CORPUS" \
  --bundle /path/to/nikonlook-v2
```

`--bundle` defaults to this checkout's own vendored `nikonlook-v2`
resources (`app/ScanStudio/engine/resources/nikonlook-v2/` — the exact
model.json/layer_a.json/manifest.json bytes the Rust engine embeds via
`include_str!`; see the script's own `--help`), so an unqualified run
already matches whichever bundle version `load_bundle()` currently returns
without pointing at any private, maintainer-specific checkout. Pass
`--bundle` explicitly only to render against a *different* bundle version —
for example, an independently held historical bundle used by external
comparison tooling. `--negfit-path` has no default and must always be passed: negfit
is GPL-labeled reference code that stays external to this repository (see
the script's own module docstring). By default the script writes the
reference TIFFs next to the corpus, named
`acceptance_slotNN_reference_color_<bundle-directory-name>.tif` (exactly
where `bin/parity.rs` looks for them).

**Validation reference location.** The corpus used for the original
(nikonlook-v1) validation was read-only, so the six generated TIFFs were
written to an operator-chosen sibling directory rather than into the
corpus. All six files were verified (`acceptance_slot01..06_reference_color_nikonlook-v1.tif`,
each `(3946, 5959, 3)` uint16). **Because they are not colocated with that
corpus, `make parity` reports `color` as `no_reference`, not
`no_candidate`** — this is an honest, environment-driven gap, not a code
bug: `bin/parity.rs` looks for the reference at
`{SCANSTUDIO_PARITY_CORPUS}/acceptance_slotNN_reference_color_{bundle_version}.tif`
exactly, by design (see §6). To make `make parity` see external references,
either re-run `render_references.py` without `--output-dir` once the corpus
location is writable, copy the files into the corpus, or set `SCANSTUDIO_PARITY_REFS`
to the directory containing the reference TIFFs (see §7). A fresh
nikonlook-v2 validation run needs its own `render_references.py --bundle
.../nikonlook-v2` pass — the v1 references already on disk will not satisfy
a v2 `make parity` run.

**ICE.** The corpus's `acceptance_slotNN_repaired_SYNTH.png` disclosure
mask was produced in `hybrid` (ML-assisted) mode (`digital-fauxice`
v0.3.0, `.outputs.repaired.mode_resolved` = `hybrid`) — but Phase 16 ports
**Legacy (classical) ICE only**. This mask is usable as a rough reference,
not a strict gate: some divergence between a correct Legacy port and this
hybrid-mode mask is expected and does not by itself indicate a bug. Phase
16 should confirm applicability, or generate a legacy-only reference,
before treating a failing ICE score as a real regression.

**Hybrid/ML mode is confirmed absent from this Rust engine path (Phase
16, plan 16-03).** `processing::ice`
(`app/ScanStudio/engine/src/processing/ice.rs`) has zero ML dependencies:
it never imports or calls anything from the real `portable-digital-ice`
source's separate `hybrid`/`fauxce_hybrid` package, has no model-loading
code, and no mode-routing logic of any kind — confirmed by direct
inspection of the module's own `use` statements (still pure `std`, per
plans 16-01/16-02's own SUMMARYs) and its full public surface
(`IceInputFrame`, `IceParameters`, `DefectMap`, `IceResult`,
`detect_defects`, `heal`, `repair_frame` — nothing else). If a future
phase wants a Hybrid-mode extension point, it would live bridge-side
(outside this engine), per ROADMAP's own framing; this engine module is,
and is scoped to remain, Legacy-only.

**Phase 16's reference-mask investigation: RESOLVED, with real measured
evidence, against the real six-slot corpus configured as described in
§1.** `engine/tests/ice_candidates.rs`'s
`reference_mask_coverage_sanity_check` (Test C) was run for real
(`SCANSTUDIO_PARITY_CORPUS=/path/to/corpus \
cargo test --test ice_candidates reference_mask_coverage_sanity_check --
--nocapture`). Measured on slot 1: the corpus-bundled hybrid disclosure
mask covers **7.604681%** of the frame (1,788,181 of 23,514,214 pixels
>= 0.5), while the Rust Legacy port's own `DefectMap` covers **0.336715%**
(79,176 pixels) — a **~22.6x size mismatch in the OPPOSITE direction**
from this plan's original hypothesis (the hybrid mask was expected to be
much SMALLER, covering only "AI-escalated" pixels per the real package's
own README examples of 0.070727%/1.355904%; measured, it is much LARGER).
The measured Jaccard agreement between the two masks is **0.000176** —
for context, even in the best case where the smaller (Legacy) mask were a
perfect spatial subset of the larger (hybrid) one, Jaccard would be
~0.0443 (79,176 / 1,788,181); the ACTUAL measured value is ~250x below
even that floor, implying only ~329 of the Legacy port's 79,176 flagged
pixels land on a hybrid-flagged pixel at all. **Conclusion: the two masks
disagree about WHERE defects are, not just how many — the bundled hybrid
mask is structurally unrepresentative of Legacy-only output**, most
likely because the hybrid pipeline's AI inpainting stage patches a
broader spatial neighborhood than the pixel-level defect footprint a
classical detector flags. Per `<reference_decision>`'s own decision
framework, this real evidence (not a forced or assumed conclusion) means
the bundled mask is not usable as a reference for this port, and a
Legacy-only reference was generated instead.

`render_ice_references.py` lives in this repository's own `bridge/tools/`
directory, mirroring `render_references.py`/
`render_geometry_references.py`'s exact shape — argparse
`--corpus`/`--output-dir`, `sys.executable`-based dependency probe,
`.expanduser().resolve()` on path-like defaults. It invokes
the real, installed `portable_digital_ice` v0.3.1's own
`SharedLookupInputResponse`/`derive_auxiliary`/`continuous_score`
detection primitives directly — unmodified, exactly as shipped — using the
SAME single-acquisition `base_primary` substitute
(`IceParameters::for_main_scan`'s own recipe: `alpha=0.17`, this frame's
own rail-excluded R/IR statistics) the Rust port uses. Every fixed profile
constant it needs (`base_addend`/`scale`/`offset`/`floor`/`count_limit`/
`perpendicular_radius`/etc.) is read directly from the real, installed
`LS5000Selector8NormalProfile` object via a synthetic `PrepassFrameRecord`
carrying only the substitute `alpha`/`mean_r`/`mean_ir` — the script never
hand-transcribes a single fixed constant. The final defect-CONFIRMATION
step mirrors `processing::ice::is_confirmed`'s own adaptation (not the
real package's `evaluate_normal_decision`/`evaluate_normal_auxiliary_decision`),
for the same two empirically-verified reasons plan 16-01's own
`ICE-PROVENANCE.md` documents (the real decision functions' 4-disjoint-bar
structure cannot discriminate small genuine defects from noise at this
profile's `perpendicular_radius`, and their fixed `sample_threshold`
constant does not transfer to the single-acquisition substitute). This
script only reproduces the DETECTION half of Legacy ICE (not
reconstruction/healing) — `score_ice()` only ever compares masks, never
repaired-pixel values, so a mask-only reference is everything the gate
needs.

Run it via the scratchpad venv that has the real package installed:

```sh
/path/to/ice-venv/bin/python3 bridge/tools/render_ice_references.py \
  --corpus "$SCANSTUDIO_PARITY_CORPUS" \
  --output-dir /path/to/reference-output/ice-refs
```

It writes `acceptance_slotNN_reference_ice_legacy-v1.png` (the mask) plus
`acceptance_slotNN_reference_ice_legacy-v1.json` (a provenance sidecar:
package version, mode, the single-acquisition substitute's own
`alpha`/`mean_r`/`mean_ir`/`base_primary`, and the confirmation
adaptation's rationale) to a **sibling** directory next to the corpus,
never into the corpus itself — matching `render_references.py`/
`render_geometry_references.py`'s own established precedent exactly, and
verified: the corpus's raw capture files are mtime-unchanged after running
this script (checked directly, all six slots, before/after).

`score_ice()` in `bin/parity.rs` now prefers this Legacy-only reference
(`acceptance_slotNN_reference_ice_legacy-v1.png`, resolved via
`resolve_reference_path` — colocated with the corpus, falling back to
`$SCANSTUDIO_PARITY_REFS`, mirroring `score_color`/`score_autocrop`/
`score_deskew`'s existing pattern exactly), falling back to the
corpus-bundled hybrid mask (with its own accurate provenance warning)
only when no Legacy-only reference exists for a slot.

**Real gate result** (`SCANSTUDIO_PARITY_CORPUS`, `SCANSTUDIO_PARITY_REFS`
pointed at `outputs-refeed-7-ice-refs/`, `SCANSTUDIO_PARITY_CANDIDATES`
all set; `make render-ice-candidates` then `JSON=1 make parity`, real
corpus, real six slots): **all six `ice` rows report `pass`, Jaccard
`1.000000` exactly on every slot** (`ICE_MASK_AGREEMENT_THRESHOLD = 0.85`
— see §5). Independently re-verified outside the Rust binary too (direct
Python decode of both candidate and reference PNGs, all six slots):
`disagreeing_pixels = 0` at the threshold=0.5 binarization on every slot
(intersection == union == candidate_on == reference_on exactly), and at
the continuous-value level the max absolute difference between candidate
and reference is `0.000015` (in `[0,1]`-normalized units — u16
quantization noise between two independent PNG encoders, not an
algorithmic discrepancy). This is a genuine result, not the scorer's
documented "both masks empty" degenerate shortcut (`score_ice_mask_agreement`
returns `1.0` when `union_count == 0`) — both masks have substantial,
non-trivial coverage (0.34%-1.02% of the frame across the six slots), and
the perfect agreement was independently confirmed pixel-by-pixel.

**Geometry (Autocrop + Deskew).** No reference of any kind existed for
either module before Phase 15 — both real references are freshly rendered
by `render_geometry_references.py` (plan 15-02), by literally invoking the
real `negpy.features.geometry.logic.get_autocrop_coords` (both Film and
Image modes) and `apply_fine_rotation` against each slot's own raw `.tif`
capture, exactly mirroring how `render_references.py` produced the color
reference. `render_geometry_references.py` lives in this repository's own
`bridge/tools/` directory. Run it with:

```sh
python3 bridge/tools/render_geometry_references.py --corpus "$SCANSTUDIO_PARITY_CORPUS"
```

Unlike color, deskew has no automatic-detection ground truth to reproduce:
NegPy's `apply_fine_rotation` only ever APPLIES a caller-supplied angle, it
never detects one (confirmed by exhaustively grepping `negpy-src` for
`deskew`/`skew` and every `fine_rotation` call site before this plan was
written). `render_geometry_references.py` therefore applies one fixed,
documented test angle (`1.75` degrees, matching plan 15-01's own ground
truth and `parity::candidates::GEOMETRY_TEST_ANGLE_DEGREES`) identically to
every slot — the same "one fixed, documented parameter applied to the
whole corpus" pattern `render_references.py` already established for its
`nikonlook-v1` bundle. Autocrop needs no such caveat: `get_autocrop_coords`
is a real, automatic, content-driven detection algorithm on both sides.

**Validation reference location.** Like the color references (see above),
the corpus used to build and verify this plan was read-only, so the geometry
references were written with `--output-dir` to an operator-chosen sibling
directory. All six slots' `acceptance_slotNN_reference_autocrop_negpy-v1.json`,
`acceptance_slotNN_reference_deskew_negpy-v1.tif`, and
`acceptance_slotNN_reference_deskew_negpy-v1.json` were verified there. Set
`SCANSTUDIO_PARITY_REFS` to that directory (see §7) to make `make parity`
see them.

## 4. Per-module status (as of Phase 16)

| Module | Reference status | Notes |
|--------|------------------|-------|
| Color | Real reference rendered (`render_references.py`, bundle-derived filename — see §3; production default is now `nikonlook-v2`); real Rust candidate available via `make render-color-candidates` (Phase 14, `processing::nikonlook`) | Reference not colocated with this corpus snapshot in this environment — see §3's read-only caveat; set `SCANSTUDIO_PARITY_REFS`. With `SCANSTUDIO_PARITY_REFS` and `SCANSTUDIO_PARITY_CANDIDATES` (see §7) both set and candidates rendered for the SAME bundle version, `make parity` reports `pass` for all six slots. |
| Autocrop | Real reference rendered (`render_geometry_references.py`, Phase 15); real Rust candidate available via `make render-geometry-candidates` (`processing::geometry::autocrop_roi`) | `make parity`'s `autocrop` row reports **Image mode (AUTO_FRAME_EDGE)** only — NegPy's own default; `ModuleKind::Autocrop` (Phase 13's report schema) is not split into separate Film/Image variants for this. **Film mode (AUTO_FILM_BORDER) is fully ported and independently proven against the real corpus** via a corpus-gated `cargo test` (`film_mode_iou_matches_reference` in `engine/tests/geometry_candidates.rs`), not this table — both modes are implemented and both are proven, just through two different mechanisms. With `SCANSTUDIO_PARITY_REFS`/`SCANSTUDIO_PARITY_CANDIDATES` set and candidates rendered, all six slots report `pass` (`AUTOCROP_IOU_THRESHOLD = 0.93` — see §5). |
| Deskew | Real reference rendered (`render_geometry_references.py`, Phase 15); real Rust candidate available via `make render-geometry-candidates` (`processing::geometry::apply_fine_rotation`) | `make parity`'s `deskew` row is a **rotation-matrix angle-provenance check**, not a full geometric-correctness proof: both sides decompose `rotation_matrix_2x3`'s own closed-form output (`atan2(m[0][1], m[0][0])`) at the same fixed, documented test angle (`1.75` degrees — see §3), so it verifies matrix-construction correctness (sign convention, degrees-to-radians conversion, center-point formula) but cannot by itself detect a resampling bug. **The real pixel-level regression protection for the bilinear-resample step lives in a separate corpus-gated `cargo test`** (`deskew_pixel_fidelity_within_tolerance` in `engine/tests/geometry_candidates.rs`), which compares actual candidate/reference rotated TIFFs pixel-by-pixel. With `SCANSTUDIO_PARITY_REFS`/`SCANSTUDIO_PARITY_CANDIDATES` set and candidates rendered, all six slots report `pass` (`DESKEW_ANGLE_EPSILON_DEGREES = 0.05`, unchanged — measured agreement is ~2.22e-16 on all six slots). |
| ICE | Legacy-only reference freshly rendered (`render_ice_references.py`, real `portable_digital_ice` v0.3.1); real Rust candidate available via `make render-ice-candidates` (Phase 16, `processing::ice::repair_frame`) | Reference-mask investigation **resolved with real measured evidence** — see §3: the corpus-bundled hybrid mask is structurally unrepresentative (Jaccard ~0.000176 against the Legacy port on slot 1); `score_ice()` now prefers the Legacy-only reference, falling back to the hybrid mask only when no Legacy-only reference exists. With `SCANSTUDIO_PARITY_REFS`/`SCANSTUDIO_PARITY_CANDIDATES` set and candidates rendered, **all six slots report `pass`, Jaccard `1.000000` exactly** (`ICE_MASK_AGREEMENT_THRESHOLD = 0.85` — see §5), independently re-verified pixel-by-pixel outside the Rust binary. |

## 5. Threshold rationale

From `engine/src/parity/scoring.rs`'s doc comments (restated here so a
reader doesn't need to open the Rust source):

- **`COLOR_PER_CHANNEL_TOLERANCE_U16 = 8`** — about 0.012% of the 65535
  full-scale range. Generous enough to absorb f32-vs-f64 or
  accumulation-order differences between the Python reference and a future
  Rust port of the *same* nikonlook algorithm, tight enough to catch a real
  logic bug. Measures Rust-port fidelity to the Python reference render,
  not real-world accuracy against true Nikon Scan color.
- **`COLOR_DELTA_E76_TOLERANCE = 0.5`** — same port-fidelity framing; 0.5
  is well under the ~1.0 "just noticeable difference" convention,
  appropriate when comparing two implementations of the same algorithm on
  the same input rather than measuring perceptual accuracy against ground
  truth — which only holds when candidate and reference actually are the
  same bundle version. `bin/parity.rs`'s `score_color` derives the
  reference filename from the loaded bundle's own `bundle_version` (never a
  fixed literal) specifically so this threshold can never end up silently
  scoring one bundle version's candidate against another's reference; see
  §3. Separately and importantly: the nikonlook bundles' own
  `manifest.json` (Layer B — shared, unchanged across bundle versions)
  documents that it does **not** numerically pass its own skin ΔE00 quality
  gate — best oracle-gain holdout result is 3.55 ΔE00 against a ≤1.0
  target, identical in both the `nikonlook-v1` and `nikonlook-v2`
  manifests. That is a known, owner-documented property of the
  nikonlook algorithm itself (real-world color accuracy), completely
  orthogonal to `COLOR_DELTA_E76_TOLERANCE`, which only measures whether a
  Rust port reproduces the *same* (imperfect) Python algorithm faithfully.
- **`AUTOCROP_IOU_THRESHOLD = 0.93`** (Phase 15 validated; lowered from the
  Phase 13 placeholder of `0.98`). Measured against the real six-slot
  corpus (Image mode): **5 of 6 slots score a perfect `1.0`** IoU against
  the real reference at the ORIGINAL `0.98` value — strong evidence the
  port itself is highly faithful. Slot 3 alone measured `0.9432`,
  root-caused (not just threshold-loosened blind) to genuine numerical
  differences between `imageproc` and `cv2`'s contour-detection paths on
  real photographic content the tiny synthetic images plan 15-01's own
  ground-truth tests used never exercised. Two real, verified bugs were
  found and fixed during this investigation (a channel-order swap in the
  `cv2.cvtColor(..., COLOR_BGR2GRAY)`-equivalent conversion — cv2 applies
  its weights POSITIONALLY, not by channel meaning, so feeding it
  genuinely-RGB-ordered data swaps the R/B weights relative to a
  perceptually "correct" formula; and a binary-vs-grayscale morphology
  mismatch in the blackhat mask, where `imageproc::morphology::dilate`/
  `erode` treat any nonzero pixel as full foreground, collapsing real
  photographic content to a near-uniform image before a close operation
  that was supposed to preserve grayscale structure), together closing
  most of slot 3's gap (`0.879` -> `0.9432` — see
  `engine/src/processing/geometry.rs`'s `bgr_to_gray_u8`/`blackhat_u8` doc
  comments for the full writeup). The remaining residual traces to
  `imageproc::edges::canny` producing a measurably different edge map than
  `cv2.Canny` on this specific slot's content — expected cross-library
  algorithm variance for a multi-stage edge detector, not a further
  fixable defect. `0.93` sits comfortably below the measured `0.9432` (a
  few points of headroom for `imageproc`'s Otsu-level/contour-tracing
  noise) while remaining far above what a genuinely broken detection
  (wrong region, wrong mode, mis-scaled ROI) would produce in practice
  (well under `0.5`), so it still catches real regressions on all six
  slots, including the five that hit `1.0` exactly.
- **`DESKEW_ANGLE_EPSILON_DEGREES = 0.05`** (Phase 15 validated; left
  UNCHANGED). This row is a rotation-matrix angle-provenance check — both
  sides decompose `rotation_matrix_2x3`'s own closed-form output via the
  same `atan2` formula, with no image resampling involved — so it carries
  none of `AUTOCROP_IOU_THRESHOLD`'s contour-detection numerical noise.
  Measured `deskew_angle_degrees` on all six real slots: `~2.22e-16`
  (IEEE-754 double epsilon) — effectively exact agreement, roughly
  2.3x10^14 times tighter than this threshold, with zero headroom needed.
  The real pixel-level regression protection for the bilinear-resample
  step (which this angle-only row cannot provide) lives in a separate
  corpus-gated `cargo test` — see §4's Deskew row.
- **`ICE_MASK_AGREEMENT_THRESHOLD = 0.85`** — set lower than the
  geometry/color thresholds deliberately by Phase 13, anticipating exactly
  the reference-mismatch this plan's own investigation later confirmed
  with real evidence (see §3): the corpus-bundled hybrid-mode disclosure
  mask is structurally unrepresentative of Legacy-only output (measured
  Jaccard against it: `0.000176`, essentially zero). **Left UNCHANGED by
  plan 16-03, now VALIDATED against real measured data**: once `score_ice()`
  was pointed at a real Legacy-only reference
  (`render_ice_references.py`) instead of the hybrid mask, measured
  Jaccard on all six real corpus slots is `1.000000` exactly — 0.15
  comfortably above this threshold with zero headroom needed (unlike
  `AUTOCROP_IOU_THRESHOLD`, this port shows no cross-implementation
  numerical noise at all: max continuous-value disagreement between the
  Rust candidate and the independently-generated Python reference is
  `0.000015` in `[0,1]`-normalized units, u16 quantization noise between
  two different PNG encoders, not an algorithmic gap). No evidence from
  this investigation suggested moving this number in either direction, so
  it stays at Phase 13's original placeholder — which turned out to be a
  well-chosen value, not just an untested guess.

## 6. Candidate-dir contract for Phases 14-16

`bin/parity.rs` accepts an optional `--candidate-dir <path>` flag. When
given, it looks for each module's candidate output at:

- **Color:** `{candidate_dir}/color/acceptance_slotNN.tif` — an RGB16 TIFF, same shape as the reference, written by `render_color_candidates` (`make render-color-candidates`), which drives the Rust `processing::nikonlook` port end-to-end (Phase 14, implemented).
- **Autocrop:** `{candidate_dir}/autocrop/acceptance_slotNN.json` — `{"film":{"y1":..,"y2":..,"x1":..,"x2":..},"image":{...}}`, written by `render_geometry_candidates` (`make render-geometry-candidates`), which drives the Rust `processing::geometry::autocrop_roi` port end-to-end (Phase 15, implemented). `bin/parity.rs`'s `autocrop` row reads only the `"image"` field (see §4); the `"film"` field exists in the same file for the corpus-gated `cargo test` that proves Film mode (`film_mode_iou_matches_reference`).
- **Deskew:** `{candidate_dir}/deskew/acceptance_slotNN.tif` — an RGB16 TIFF rotated by the fixed test angle, written by `render_geometry_candidates`, which drives the Rust `processing::geometry::apply_fine_rotation` port end-to-end (Phase 15, implemented). No candidate-side JSON sidecar is written — `bin/parity.rs`'s `deskew` row calls `processing::geometry::rotation_matrix_2x3` directly on the candidate TIFF's own dimensions rather than round-tripping a matrix through a file, since that computation is pure/stateless and input-independent.
- **ICE:** `{candidate_dir}/ice/acceptance_slotNN.png` — a mask (any bit depth; normalized on read the same way as the reference), written by the Rust Legacy ICE port (Phase 16, `make render-ice-candidates`, `processing::ice::repair_frame`). `{candidate_dir}/ice/acceptance_slotNN_repaired.tif` is also written alongside it (the repaired RGB16 output) — informational only, not read by `bin/parity.rs`'s `score_ice()`, useful for Phase 17 and manual inspection.

If a slot's reference exists but no matching candidate file is found (or
`--candidate-dir` wasn't given at all), that module/slot reports
`no_candidate` with `reference_provenance` explaining what reference does
exist and why there's nothing to compare it against yet — never a
fabricated pass or fail.

## 7. Reference and candidate directory fallbacks (`SCANSTUDIO_PARITY_REFS` / `SCANSTUDIO_PARITY_CANDIDATES`)

Color reference TIFFs rendered by `render_references.py` can live in a
separate directory from the corpus. When `bin/parity.rs` doesn't find
`acceptance_slotNN_reference_color_{bundle_version}.tif` (`{bundle_version}`
per §3 — `nikonlook-v2` by default) colocated with the corpus, it falls back
to `$SCANSTUDIO_PARITY_REFS/acceptance_slotNN_reference_color_{bundle_version}.tif`.
Set the env var when references are stored elsewhere — for the
read-only-corpus scenario described in §3:

```sh
SCANSTUDIO_PARITY_REFS=/path/to/nikonlook-refs make parity
```

The colocated path is always checked first; the fallback only applies
when no colocated file exists. The binary still hard-fails if neither
location has the file (exit 1, `no_reference` status), preserving the
existing behavior for every other case.

Candidate TIFFs written by `render_color_candidates` (Phase 14, `make
render-color-candidates`) work the same way. `bin/parity.rs` accepts an
optional `--candidate-dir <path>` flag (see §6); when that flag isn't
passed, it falls back to `$SCANSTUDIO_PARITY_CANDIDATES`. This is the only
way `make parity` (whose Makefile target does not forward a
`--candidate-dir` flag) can ever see real candidate files without
hardcoding a path into the Makefile. `--candidate-dir` is always checked
first; the fallback only applies when that flag isn't given. Combine all
three env vars to render candidates and then score them in one pass:

```sh
export SCANSTUDIO_PARITY_CORPUS=/path/to/corpus
export SCANSTUDIO_PARITY_REFS=/path/to/nikonlook-refs
export SCANSTUDIO_PARITY_CANDIDATES=/path/to/candidates
make render-color-candidates && make parity
```

A slot with no matching candidate file reports `no_candidate` (not a
fabricated pass or fail) — never a hard failure, matching the existing
behavior for a missing reference.

Geometry references (`acceptance_slotNN_reference_autocrop_negpy-v1.json`,
`acceptance_slotNN_reference_deskew_negpy-v1.{tif,json}`, Phase 15,
`render_geometry_references.py`) and candidates
(`render_geometry_candidates`, `make render-geometry-candidates`, see §6)
resolve through the exact same `SCANSTUDIO_PARITY_REFS` /
`SCANSTUDIO_PARITY_CANDIDATES` fallback mechanism — no separate env vars
needed.

ICE's reference (as of plan 16-03, resolved via
`resolve_reference_path` exactly like color/geometry: the Legacy-only
`acceptance_slotNN_reference_ice_legacy-v1.png`, `render_ice_references.py`
— see §3 — checked colocated with the corpus first, then
`$SCANSTUDIO_PARITY_REFS`) uses the exact same
`SCANSTUDIO_PARITY_REFS` fallback mechanism color/geometry already use.
Only if NO Legacy-only reference is found anywhere does `score_ice()` fall
back to the corpus-bundled `_repaired_SYNTH.png` disclosure mask (resolved
directly from the corpus manifest's own `repaired_synth_mask_path` field,
which never depends on `SCANSTUDIO_PARITY_REFS`, since it always lives
alongside the corpus itself). ICE's candidate (`render_ice_candidates`,
`make render-ice-candidates`, see §6) respects `SCANSTUDIO_PARITY_CANDIDATES`,
the same as every other module.

A full run against a read-only corpus, all four modules at once:

```sh
export SCANSTUDIO_PARITY_CORPUS=/path/to/corpus
export SCANSTUDIO_PARITY_REFS=/path/to/refs      # nikonlook + geometry refs, colocated or not
export SCANSTUDIO_PARITY_CANDIDATES=/path/to/candidates
make render-color-candidates && make render-geometry-candidates && make render-ice-candidates && make parity
```
