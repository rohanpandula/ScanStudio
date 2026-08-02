# nikonlook-v2 bundle provenance

## Source

Vendored on 2026-07-28 from `negfit/bundles/nikonlook-v2/` in the repository
owner's source materials (same source tree v1 was vendored from). The three
JSON files are the public, versioned numeric model record used by the Rust
engine.

## Files

| File | Description | sha256 |
|------|-------------|--------|
| `model.json` | Layer B: the DirectPF color model — a 3x3 matrix (`M`) plus 3 per-channel monotone curves (R, G, B grid_x/grid_y pairs). Semantically identical to `nikonlook-v1`'s `model.json` (same matrix, same curves, same training metadata; the two files differ only in JSON serialization formatting, so their hashes differ): Layer B was not retrained between v1 and v2, only Layer A changed. | `60d7f99b750ad6e012d354d695fc28714d0a6d629ef65874ae8639d64c649448` |
| `layer_a.json` | Layer A: the `hybrid-exposure-ridge-v2` per-frame exposure gain estimator — an optional hardware-exposure inverse (`metadata_estimator`, `inverse-hardware-exposure-v1`) that scales a per-channel reference gain by the ratio of a reference exposure to the frame's own hardware exposure, and a scored blind fallback (`blind_fallback`, `log-ridge-raw-features-v1`) that regresses gain from 48 log-scale raw distribution features when no exposure metadata is available. | `4ea99ff985cf3fff943a48bb61b9dd557f83441de71a60754f1df297b7236c0c` |
| `manifest.json` | Bundle version (`nikonlook-v2`), quality tier (`beta`), and provenance/gate metadata from the source repo's training run. | `18208e132512e21714b4d223561f8419f8d71ee9954b14e24ee36b3bdd08e2db` |

Hashes were computed with `shasum -a 256` against the vendored files in this
directory and match the source repo's own copies.

## Licensing

The repository owner licenses these numeric model files and the associated
`nikonlook_core.py` algorithm for use in this MIT-licensed repository. That
authorization covers vendoring the three JSON files as data under
`app/ScanStudio/engine/resources/nikonlook-v2/` and porting
`nikonlook_core.py`'s frozen `load_bundle` / `estimate_gains` / `apply` API
(v2 dispatch) to Rust.

No Nikon ICC profile bytes are redistributed in this repository, same as
v1: `nikon-adobe-rgb.icc` is deliberately excluded from this directory. The
numeric model targets Adobe RGB-family encoded values; the current alpha
renderer writes Adobe RGB (1998)-encoded values without embedding an ICC tag.

## Quality tier

`manifest.json`'s `quality_tier` is `"beta"`, same nominal tier as v1 — see
`manifest.json`'s own `quality_note` field for the full, honest gate
writeup (skin/global ΔE00 against Nikon Scan, holdout-frame provenance,
hardware-exposure anchor status). Read that field directly rather than
trusting this summary to stay in sync with it.

Measured on a 2026-07-28 live frame against the registered Nikon Scan
reference (median absolute per-channel difference, DN, and fraction of
interior red pixels pinned at the R curve's floor):

| Path | R | G | B | R pinned fraction |
|------|---|---|---|--------------------|
| v1 `percentile-stopgap-v1` | 19463 | 14040 | 17347 | 0.165 |
| v2 blind (`log-ridge-raw-features-v1`) | 3565 | 6682 | 3340 | 0.055 |
| v2 exposure (`inverse-hardware-exposure-v1`) | 9560 | 8064 | 3454 | 0.100 |

v2's blind path is a material improvement over v1 on this frame but is not
parity-quality (see `manifest.json`'s gates). The hardware-exposure path
measured worse on this frame and its anchor is `"experimental-one-frame"`
per `manifest.json`'s `hardware_exposure_evidence`/`layer_a_status`, so the
Rust port defaults to the blind path; the exposure path is ported and
tested but opt-in.

## Handling

These three JSON files must never be hand-edited. If the numeric bundle
changes, replace it as a complete, reviewed bundle rather than partially
patching it. The Rust port in `../../src/processing/nikonlook.rs` embeds the
JSON at compile time via `include_str!`, with no runtime file path or network
access.
