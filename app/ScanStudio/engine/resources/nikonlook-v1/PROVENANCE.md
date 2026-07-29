# nikonlook-v1 bundle provenance

## Source

Vendored on 2026-07-23 from the repository owner's source materials. The
three JSON files are the public, versioned numeric model record used by the
Rust engine.

## Files

| File | Description |
|------|-------------|
| `model.json` | Layer B: the DirectPF color model — a 3x3 matrix (`M`) plus 3 per-channel monotone curves (R, G, B grid_x/grid_y pairs), fit once across the source repo's training corpus (`fit37/model_directpf.py`). |
| `layer_a.json` | Layer A: the `percentile-stopgap-v1` per-frame exposure gain estimator — one anchor frame's raw percentile span and DirectPF-gauge gain, used to blindly rescale gain for a newly scanned frame. |
| `manifest.json` | Bundle version (`nikonlook-v1`), quality tier (`beta`), and provenance/gate metadata from the source repo's training run. |

## Licensing

The three listed JSON files are owner-authored data. The repository owner
licenses those numeric model files and the associated `nikonlook_core.py`
algorithm for use in this MIT-licensed repository. That authorization covers
vendoring the three JSON files as data under
`app/ScanStudio/engine/resources/nikonlook-v1/` and to port
`nikonlook_core.py`'s frozen `load_bundle` / `estimate_gains` / `apply` API
to Rust.

No Nikon ICC profile bytes are redistributed in this repository. The numeric
model targets Adobe RGB-family encoded values; the current alpha renderer
writes Adobe RGB (1998)-encoded values without embedding an ICC tag.

## Handling

These three JSON files must never be hand-edited. If the numeric bundle
changes, replace it as a complete, reviewed bundle rather than partially
patching it. The Rust port in `../../src/processing/nikonlook.rs` embeds the
JSON at compile time via `include_str!`, with no runtime file path or network
access.
