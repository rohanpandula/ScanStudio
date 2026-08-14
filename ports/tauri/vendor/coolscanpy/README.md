# coolscanpy

coolscanpy is a direct-USB acquisition library for Nikon Coolscan film
scanners. It exposes a python-sane-style API: open a device, read and set
typed options, call `scan()` and get back an array. On top of that plain
surface it adds a roll-feeder extension for whole-roll workflows. A roll can
be previewed across all 40 addressable slots, each frame's transport spacing
adjusted individually, then batch-scanned in one continuous reservation.

Each scanned frame comes back as:
- scanner-linear RGB (4000 dpi, 16-bit)
- an aligned infrared plane
- the 285 dpi RGBI meter pass the scanner captured for auto-exposure (see
  `Frame.meter_rgbi`)
- an in-memory receipt with exposure, clipping, focus, and transport-smear
  telemetry

## Status

This code was extracted from a working NegPy integration branch. On real
hardware, an LS-5000 running firmware 1.03 with an SA-21 roll feeder
converted to SA-30 wiring, that integration produced full-roll previews and
4000 dpi 16-bit RGBI captures with receipts, and those captures fed the
downstream dust-repair pipeline.

The current source tree collects 911 hardware-free tests covering the
transport protocol, roll engine, capture finalization, receipt assembly, and
public facade against synthetic fixtures and replay data. CI runs that suite
and Ruff on Ubuntu and macOS with Python 3.13 and 3.14. Windows is not in the
CI matrix and has not run the direct-USB transport against real hardware.

Live validation ran on 2026-07-18 with the packaged wheel installed into a
clean environment against a powered LS-5000, with no SANE installed: USB
enumeration, `open()`, option introspection, and a full roll preview of a
6-slot strip. The transport index read cleanly, slots 1 through 4 came
back aligned with no manual spacing offset, slot 5 was flagged for manual
review near the strip end, and slot 6 was correctly reported as a 2-row
trailing sliver rather than a frame. That run exposed one real bug, fixed
in 0.1.1: roll fingerprinting rejected strips with a trailing sliver.

The 0.1.3 short-strip fixes allow preview and fine scanning of strips shorter
than a full roll. The current source also accepts the normal end-of-roll case
where a fresh transport table has fewer usable records than the reviewed
preview; it still refuses a count above the reviewed table, a mismatched visual
fingerprint, or a requested slot that is no longer addressable.

The 285 dpi meter pass is now surfaced on every frame. The scanner already
captures three of these per frame during auto-exposure; the third (settled
exposure) is decoded and attached to the `Frame`. Downstream tools that
need a dual-capture (prepass + main) can use it directly. See the
[downstream pipeline](#downstream-pipeline) section.

C-41 fine scans expose RGB to Nikon Scan's rendering intent by default.
The auto-exposure loop still converges exactly as before, but the commanded
fine-scan RGB exposures are now a guarded Nikon-like target derived from
the settled meter pass. Live v3 validation used fine-scan fractions
R 0.950337, G 0.987481, and B 0.983639. Across three matched physical
frames, the Nikon-referenced full-scale channel biases were R +0.823…+2.086
%, G +0.146…+1.033 %, and B -0.391…+0.822 %, with a 0.9129 % mean absolute
bias. Under the explicitly defined complement statistic (100 % minus mean
absolute full-scale channel bias), that is 99.0871 % average full-scale
RGB-channel agreement. Mean 8x8-smoothed ΔE00 improved from 2.8469 to
2.1413 (-24.8 %). These figures describe this three-frame validation set;
they are neither a byte-identity claim nor a universal perceptual-accuracy
percentage. Highlights are capped at a reviewed q99.99 threshold and the
device exposure bounds, both journaled; infrared metering is unchanged; and
each frame's journal carries an `active_exposure_authority` record binding
the active solve, the guarded candidate, and the exact commanded contract,
so the receipt trail proves which numbers reached the scanner and why.

For the proven LS-5000 full-record geometry, fine-scan decoding now starts
while the raw capture is still arriving. This is an advisory fast path: the
raw capture remains the oracle, and an absent, slow, malformed, or failed
streaming sidecar falls back to the normal offline decode without interrupting
or blocking the scanner read. Set `COOLSCANPY_CAPTURE_STREAMING=0` to disable
this optimization. The streaming path is covered by hardware-free tests; no
additional live-hardware claim is made for it here.

Coverage is uneven by material. `Material.COLOR_NEGATIVE` scans through a
direct-USB single-pass path and is implemented end to end, preview through
receipt. `Material.BLACK_AND_WHITE_NEGATIVE` previews and approves
correctly, but its fine-scan path routes through SANE and that route is not
yet wired into the roll batch engine; calling `scan()` or `scan_many()` on
a black-and-white roll raises `NotImplementedError` with a message
explaining the gap.

## Downstream pipeline

coolscanpy gets the raw data off the scanner. Three other projects turn it
into a finished image:

**[digital-fauxice](https://github.com/rohanpandula/digital-fauxice)** —
infrared dust and scratch repair. A byte-exact, from-scratch
reimplementation of Digital ICE (the Nikon/Applied Science Fiction process
that uses the IR channel to find defects and reconstruct the RGB underneath).
Validated against Nikon's own output: 68 million 16-bit values per frame,
zero mismatches. It takes the 4000 dpi RGBI main scan plus the 285 dpi
meter pass as its prepass, and produces the same repaired output Nikon
would have. An optional hybrid mode routes the worst damage (where the
exact repair leaves visible scars) to a LaMa inpainting model, disclosed
and bounded. The meter pass coolscanpy now surfaces on `Frame` is exactly
what fauxice's input contract expects — same physical frame, same focus,
same transport position, captured milliseconds before the fine scan.

**[cool-colors](https://github.com/rohanpandula/cool-colors)** — C-41
color inversion. Turns the scanner-linear negative into a positive,
reproducing Nikon Scan 4's CMS-off color pipeline bit-for-bit (the
per-frame inversion LUT, fixed tone curve, and gamma 2.2). With a
captured per-frame builder LUT, output matches Nikon Scan byte-for-byte.
Without it, a principled density inversion (film-base estimation, log
inversion, normalization) gets you a natural positive from any C-41 scan.

**[NegPy](https://github.com/marcinz606/NegPy)** — the desktop
application that ties capture, repair, and inversion together behind a
GUI. It consumes coolscanpy as an optional scanner backend, digital-fauxice
as an optional IR repair engine, and runs its own inversion pipeline for
the final print rendering.

The pipeline in order: coolscanpy captures → fauxice repairs dust →
cool-colors (or NegPy) inverts to a positive. Each step is optional and
independently installable.

## Install

```
pip install coolscanpy
```

coolscanpy requires Python 3.13 or later. To use the current checkout rather
than an index release, install it in editable mode:

```
python -m pip install -e .
```

The base install covers `get_devices()`, `open()`, `Device.eject()`, and the
roll preview, registration, and color-capture operations under
`Device.roll()`. None of those needs SANE. `get_devices()`/`open()` fall back
to direct USB enumeration when python-sane is not installed, the roll-feeder
capture extension talks to the scanner over raw USB in a separate process
regardless, and `Device.eject()` (and `Roll.eject()`, which delegates to it)
replays the scanner's own traced unload sequence over that same raw-USB
transport.

Standalone/source installs still need a host libusb shared library for PyUSB.
On macOS, install it with `brew install libusb`. ScanStudio's release DMG is a
separate distribution shape that includes and pins its own signed libusb, so
ScanStudio users do not need that Homebrew installation for color-roll work.

SANE is needed only for the plain `Device.scan()` path:

```
pip install "coolscanpy[scanner]"
```

On macOS, that build needs sane-backends' headers, and Homebrew does not put
them on the default include path:

```
brew install sane-backends
CPPFLAGS="-I$(brew --prefix)/include" LDFLAGS="-L$(brew --prefix)/lib" pip install "coolscanpy[scanner]"
```

On Linux, `sudo apt install libsane-dev` before the plain `pip install`
above is usually enough.

## Quickstart

Plain scan, the python-sane-shaped path:

```python
import coolscanpy

dev = coolscanpy.open("ls5000")
print(dev.option_names)
print(dev["resolution"].constraint)

dev.resolution = 4000
dev.depth = 16
rgb = dev.scan()  # uint16, shape (H, W, 3)
dev.close()
```

Roll workflow:

```python
import coolscanpy

with coolscanpy.open("ls5000") as dev:
    with dev.roll(material=coolscanpy.Material.COLOR_NEGATIVE) as roll:
        thumbnails = roll.preview()

        for thumb in thumbnails:
            if thumb.needs_approval:
                roll.approve(thumb.slot)

        selected = [thumb.slot for thumb in thumbnails[:36]]
        for frame in roll.scan_many(selected, eject_after=True):
            print(frame.slot, frame.rgb.shape, frame.receipt.transport_smear.verdict)
            # The 285 dpi RGBI meter pass, if present:
            if frame.meter_rgbi is not None:
                print("  prepass for fauxice:", frame.meter_rgbi.shape)
```

`roll.scan_many()` opens one continuous transport reservation for the whole
list of slots and yields a `Frame` as each completes. `roll.scan(slot)` is
sugar for scanning one slot. Calling `roll.safe_stop()` from another thread
lets the frame in flight finish normally; the next one raises
`SafeStopRequested` instead of starting. The `preview()` call above leaves
its reservation open, which is why this `scan_many()` resumes it directly
instead of needing a refeed -- and, left to run without `eject_after`, a
*further* `scan_many()`/`scan()` call would resume it again, any number of
times, on the same feed; see Safety model below for the exact scope of that
hold.

`eject_after=True` ends the batch, once the last requested slot's frame is
finalized, by replaying the scanner's own traced end-of-session eject
sequence -- still inside this batch's original reservation -- before
releasing, instead of the plain release every batch without it already
performs when it was never holding anything. Leave it off (the default) and
a batch that resumed a held reservation keeps that same reservation held
afterward too -- the strip stays parked inside for a later
`preview()`/`scan_many()`/`scan()` on the same feed, or an explicit
`roll.eject()` -- rather than releasing. The other way to eject is
`roll.eject()`, for the "I'm not scanning anything else on this roll" case:
valid whenever a reservation is currently held, whether that is `preview()`'s
own (before the first `scan_many()`/`scan()` consumes it) or a later batch's
(before the next one, or an explicit `release()`). Either path raises
`FeederParked` instead of completing if the traced sequence does not finish
as expected -- most often a suspected transport wedge, for which a power
cycle is the only demonstrated recovery.

Both `scan_many()` and `scan()` also accept an `exposure_override_10ns=(red,
green, blue)` keyword: raw 10 ns hardware exposure ticks that replace the AE
meter's own proposal for every frame in the batch, without changing what the
meter itself measures.

For live diagnostics or acceptance runs, pass an absolute caller-owned
directory as `dev.roll(attempts_root=...)`. Preview rasters, transport tables,
journals, and capture scratch written there survive `Roll.close()` for offline
verification. Omitting it retains the self-cleaning temporary default.

## Hardware support

Tested: Nikon Super Coolscan 5000 ED (LS-5000), firmware 1.03, with an SA-21
roll feeder wired for SA-30 compatibility.

Untested: every other Coolscan model, and any roll feeder other than the
SA-21/SA-30 configuration above. Platforms: the suite runs on Linux and
macOS in CI. Windows is untested; the transport layer has never run there
and the concurrency tests assume POSIX file-lock semantics. The code does not assume LS-5000-only
behavior where the protocol is generic, but nothing beyond the one
combination above has run against real film. Reports and pull requests
against other bodies are welcome, and an LS-50 test is particularly wanted:
its transport and optics differ from the LS-5000, and none of those
differences are covered here yet.

On the tested LS-5000/SA-21, startup `READ(0x8f)` can return a complete
self-declared shorter frame-table envelope with the observed `022b4b`
data-underrun status. coolscanpy accepts that status only when the envelope is
valid and shorter than the requested 40-slot maximum. The observed exact
37-record canonical prefix is also bound to a matching shorter preview window
and read allocation; the canonical 40-record path is unchanged. Every other
short count, changed record prefix, malformed envelope, full-length underrun,
or differently failed response still refuses before motion. The later live
`0x8e` index and preview independently validate roll identity and frame
addressability before any fine scan. If the live transport table has already
entered its terminal `0x81xx`/`0x83xx` suffix, affected trailing slots remain
visible for review but are deliberately not scanner-addressable on that
insertion.

Strips shorter than a full roll work for preview and, as of 0.1.3, for fine
scanning too. A preview traversal parks a short strip at the transport
end-stop. `preview()` keeps its reservation open, and every
`scan_many()`/`scan()` call afterward -- not just the first -- resumes it
directly instead of re-reading the index, so the ordinary preview-then-scan
sequence no longer needs a refeed for that reason, on a short strip or a
full roll. `RefeedRequired` still applies if a held reservation cannot be
resumed (the scanner may have auto-ejected, or the held child died), if
`release()` was called first, or to a batch on a feed that was never held
in the first place: pull the strip out, reinsert it until the feeder grips,
and run the batch again. Treat that refeed as a new registration.

The converted SA-21 can park or eject a strip after an uncharacterized idle
interval. Start the intended capture promptly after feeding. A transport-index
stall or refusal is a stop condition: preserve the evidence, establish the
physical media state, and do not retry the same insertion.

## Relationship to NegPy

coolscanpy is a dependency, the way NegPy already consumes python-sane or
gphoto2. It does not import NegPy, and NegPy does not depend on it by
default. A caller wires it in behind whatever extension seam their own
application already uses for other scanner backends: open a device, run one
roll to completion, close it.

## How this compares to SANE

SANE's `coolscan3` backend is the mature, general route to these scanners:
one API across many models, a daemon ecosystem, and a working eject. NegPy
consumes it happily. coolscanpy exists for the narrower job SANE's frame
API cannot express: archival capture with evidence. The honest split:

| Capability | coolscanpy | SANE `coolscan3` |
|---|---|---|
| Single-pass 4000 dpi 16-bit RGBI contract | yes, fixed protocol | partial — RGB + separate IR handling, backend-dependent |
| 285 dpi meter-pass surfaced per frame (`Frame.meter_rgbi`) | yes | no |
| Density-calibration payloads exposed with hashes | yes | no |
| Per-frame receipt telemetry (exposure vectors, clipping, focus, transport smear) | yes | no |
| Per-frame + session journals on disk | yes | no |
| Hash-pinned capture bundle provenance | yes | no |
| Roll batch under one reservation with fingerprint identity checks | yes | no — per-frame `--frame n` |
| Whole-roll preview with per-slot review states | yes | no |
| Eject | delegated to SANE (`coolscanpy[scanner]` extra) | yes |
| Scanner model breadth | one tested body (LS-5000/SA-30 wiring) | many Coolscan models |
| Years in production | extracted 2026 | decades |

They compose rather than compete: the direct-USB path owns capture and its
evidence chain, and the optional SANE extra covers motion conveniences the
capture path does not need. A live LS-5000 color-roll preview, capture, and
eject requires no SANE; plain scan still does.

## Safety model

A roll batch takes one reservation over the physical transport for its whole
scan_many() call, not one per frame, and releases it exactly once on close.
Requesting a safe stop never interrupts the frame currently being read; only
the next one is affected.

`preview()` keeps its own reservation open rather than releasing
immediately, so every `scan_many()`/`scan()` call that follows resumes it
directly instead of reacquiring the transport, with no refeed needed, even
on hardware that parks between reads. This is not limited to the first
batch after a preview: a batch that completes without `eject_after=True`
keeps the same reservation held for the next one too -- same child process,
same reservation, same retained frame table, matching the vendor's own
traced session shape (one `RESERVE_UNIT` from feed to eject, any number of
fine scans in between, no repeated frame-table read, no intermediate
`RELEASE_UNIT`) -- so a whole roll can be scanned across as many
`scan_many()`/`scan()` calls as the caller wants without a refeed between
them. `release()` gives up a still-held reservation explicitly at any point
between batches, reverting to a fresh reservation on the next scan; calling
`preview()` again always supersedes whatever reservation the one before it
was holding, whether that was `preview()`'s own or a batch's. A cold batch
-- no preceding `preview()`, or one whose hold was already
released/ejected/never established -- opens its own fresh reservation
exactly as every batch always has, and can still raise `RefeedRequired` if
the transport has parked by then; a batch resuming a held reservation whose
child died in the meantime (auto-eject, crash) raises the same
`RefeedRequired` rather than assuming the reservation is still good.

Ejecting -- `scan_many(..., eject_after=True)` or `roll.eject()` on a
still-held reservation -- replays the scanner's own traced end-of-session
sequence inside the reservation already held, the same session shape a
normal scan already uses, rather than releasing first and re-reserving to
eject afterward. Every reply is checked against that trace; any deviation
stops before another motion command is sent and raises `FeederParked`
instead of reporting success, since a mid-motion failure with film still
inside is exactly the case a power cycle, not a retry, is the documented
recovery for. `EjectNotAvailable` is raised instead if nothing is currently
held to eject -- no `preview()` has run yet, or the hold was already
consumed by a `scan_many()`/`scan()` call that ended it with
`eject_after=True`, or was released/ejected explicitly.

Before the first fine scan of a batch, the roll's fingerprint (bound at the
last preview) is checked against a fresh read of the transport. If the
comparison doesn't match, `FingerprintRefused` is raised instead of scanning
under the wrong geometry. Separately, a slot whose transport origin was not
confidently automatic must be approved against its current thumbnail before
it can be fine-scanned; scanning an unapproved flagged slot raises
`ManualReviewRequired`.

Every returned frame carries transport-smear and clipping telemetry.
Clipping is informational and never gates a capture. An abnormal repeated
tail from a stopped transport does gate: that frame is refused rather than
returned with smeared rows.

The concurrent decoder used for proven full-record captures is deliberately
non-authoritative. It submits work without blocking the USB loop, has a
bounded completion wait, and records its terminal state in the frame journal.
Finalization consumes its derived artifact only after revalidating its schema,
raw-stream binding, hash, NPY layout, and file identities; otherwise it decodes
the retained raw stream offline.

## What this package is not

There is no GUI. The RGB comes back scanner-linear and unmodified; color
inversion and print rendering belong to the application above this library
(see [cool-colors](https://github.com/rohanpandula/cool-colors) for a
standalone C-41 inverter, or
[NegPy](https://github.com/marcinz606/NegPy) for the full desktop app).
The infrared plane comes back raw as well, and both arrays are stored in
Nikon Scan's own orientation rather than the scanner's native portrait
readout, so `frame.rgb`/`frame.ir` line up with what Nikon Scan renders for
the same frame with no extra rotation downstream. Turning the infrared
plane into a defect mask and healing the dust it reveals is the job of
[digital-fauxice](https://github.com/rohanpandula/digital-fauxice), which
consumes this package's RGBI output directly — the `Frame.meter_rgbi`
field is the 285 dpi prepass its input contract requires.

## License

GPL-3.0-only. The code began life on a fork branch of
[NegPy](https://github.com/marcinz606/NegPy), marcinz606's film-negative
processing application, and is republished here as a standalone package
under the same license.
