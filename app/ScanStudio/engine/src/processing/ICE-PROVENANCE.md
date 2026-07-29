# Legacy ICE (`processing::ice`) — porting provenance

## Source

Ported from the owner's MIT-licensed `portable-digital-ice` package, from a
private owner-maintained source checkout kept outside this repository:

```
portable-digital-ice
```

specifically `src/portable_digital_ice/{x3a,profile}.py` (version 0.3.1 at
the time of this port, confirmed via the package's own `pyproject.toml`).

## Licensing

`portable-digital-ice` ships its own MIT license, copyright 2026 Rohan
Pandula, who is also this repository's owner. The port retains that
provenance. Components with different source licenses carry their own
licensing and provenance records.

## What was ported (this plan: detection only)

From `src/portable_digital_ice/x3a.py`:

| Real function/class | This port |
|---|---|
| `_finite` (line 37) | Not carried over as a standalone helper — this port's own f32/f64 arithmetic never introduces non-finite intermediates from finite inputs (see threat T-16-03's mitigation notes below and in `ice.rs`) |
| `generate_nikon_response_lut` (line 111) | `generate_response_lut` |
| `SharedLookupInputResponse` + `.convert` (lines 136-166) | `convert_response` |
| `AuxiliaryParameters` / `_validate_working_rgbi` / `derive_auxiliary` (lines 167-223) | `derive_auxiliary_plane` (private; fixed to this profile's constants — channel 0/R, offset 1.0, alpha 0.17) |
| `ScoreParameters` / `continuous_score` (lines 225-288) | `single_pixel_severity` + `continuous_score_plane` (private) |
| `X3AAnalysis` / `analyze_main` (lines 290-337) | Adapted into `detect_defects`'s own whole-frame orchestration (not a 1:1 struct port — this port has no row-streaming caller to serve) |
| `evaluate_normal_decision` / `evaluate_normal_auxiliary_decision` (lines 452-589) | Adapted into `is_confirmed` — a whole-frame neighborhood scan, NOT a byte-exact port. See `is_confirmed`'s own doc comment in `ice.rs` for the full rationale, including a concrete numeric finding (the real `sample_threshold` constant does not transfer to this port's frame-relative `base_primary` substitute) that drove the adaptation. |

From `src/portable_digital_ice/profile.py`'s `LS5000Selector8NormalProfile`:
every FIXED constant from `score_parameters()`, `decision_parameters()`, and
`reconstruction_parameters()` (transcribed via `f32::from_bits`, never
hand-converted from hex to decimal — see plan 16-01's
`<ice_parameters_table>`, cross-checked once more against a live
`struct.unpack("<f", ...)` decode during this plan's execution), plus the
single-acquisition substitute for `base_primary`/`coarse_reference` (see
`IceParameters::for_main_scan`'s doc comment and the Handling section
below).

Reconstruction/healing (`reconstruction.py`, `dither.py`, `output.py`,
`repair_frame`) is plan 16-02's job, appended to this same `ice.rs` in a
later wave — not ported here. See `ice.rs`'s own `<scope_map>`-derived
module doc comment for the full list of what was deliberately excluded
(row-streaming/hidden-startup-row replay machinery, GPU backends, the
alternate unused `LinearInputResponse`, Nikon-hardware-register byte
parsing) and why.

## Handling: the single-acquisition adaptation

This port does NOT reproduce the real package's byte-exact Nikon-firmware
calibration replay. `portable_digital_ice.contracts.DualRGBIAcquisition`
hard-requires a same-frame 285 dpi prepass + 4000 dpi main RGBI pair; this
project's six-slot refeed-7 parity corpus (`engine/src/parity/corpus.rs`'s
`CorpusSlot`) has no prepass file at all. Traced through `profile.py` during
planning, the ENTIRE prepass dependency of the whole parameter set reduces
to one scalar, `base_primary = (mean_ir_response - alpha * mean_r_response)
/ (1 - alpha)`. This port computes that scalar directly from the MAIN
scan's own rail-excluded (1st-99th percentile) mean response-converted R
and IR samples, using `alpha = 0.17` — the real algorithm's OWN documented
"no usable prepass regression signal" fallback constant
(`portable_digital_ice.prepass.PrepassParameters
.captured_ls5000_selector8().zero_denominator_alpha`), not a fabricated
number. The same substitute alpha is also reused by `derive_auxiliary_plane`
(its `alpha` field mirrors the identical `record.observed_main_alpha` value
`_base_primary` reads in the real source), so both call sites stay
internally consistent.

This is a deliberate, documented fidelity reduction gated by this project's
own parity harness (mask-agreement Jaccard, deliberately generous — see
`app/ScanStudio/PARITY.md`'s `ICE_MASK_AGREEMENT_THRESHOLD = 0.85`), not a
byte-exact reproduction of Nikon's firmware prepass-register replay. See
plan 16-01's `<single_acquisition_adaptation>` for the complete rationale,
and `ice.rs`'s own module doc comment / `IceParameters::for_main_scan`'s doc
comment for where this is re-documented at the code level.

## Handling: the neighborhood-confirmation adaptation

`is_confirmed` (in `ice.rs`) is likewise NOT a byte-exact port of the real
`evaluate_normal_decision`/`evaluate_normal_auxiliary_decision`. Verified
empirically during this plan's execution: the real functions' 4-disjoint-
bar structure (each offset a fixed `perpendicular_radius` pixels away from
the candidate) cannot distinguish a small genuine defect from an isolated
single-pixel noise spike at this profile's own `perpendicular_radius = 4`,
and the real `sample_threshold` constant (calibrated for the real
prepass-reduced pipeline's absolute auxiliary scale) does not transfer to
this port's frame-relative `base_primary` substitute. `is_confirmed`
instead uses a single, unified square neighborhood scan and a
frame-relative floor/ceiling severity cutoff — see its own doc comment in
`ice.rs` for the full numeric evidence and reasoning.

## Do not hand-edit constants

Every `f32::from_bits(0x...)` literal in `IceParameters::for_main_scan`
must be re-verified against `profile.py`'s `LS5000Selector8NormalProfile`
directly (not retyped from memory) if this port is ever revisited — a
single wrong hex digit changes real behavior silently. Cross-checked once,
numerically, via a live invocation of `struct.unpack("<f", ...)` against
every value in plan 16-01's `<ice_parameters_table>` during this plan's
execution (isolated venv, package version 0.3.1).
