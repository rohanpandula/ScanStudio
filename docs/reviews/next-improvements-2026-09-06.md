# What we learned and what to improve next

Status: implementation plan, not a completed hardware acceptance report.
Prepared on 2026-09-06 for the continuation of short-strip QA and beta.15.

## What we learned from nkscan

The [documentation review](nkscan-behavior-requirements-2026-09-06.md) gave us
useful questions to test, rather than an implementation to transplant:

- **Speed has several controls.** Its documentation describes resolution,
  sampling, reuse of the first frame's exposure, and model-specific CCD modes.
  These are candidates for experiments, not proof that ScanStudio can safely
  enable them or that they will improve our image quality or throughput.
- **Support depends on the whole setup.** A scanner model, holder, adapter,
  transport and software version need their own evidence. Finding a device
  over USB or FireWire does not establish that scanning works.
- **Performance claims need measurements.** The reviewed release notes mention
  two-line LS-5000 scanning. We did not benchmark it, establish a speedup, or
  implement that mode in ScanStudio.
- **Assets need separate provenance.** The reviewed metadata treats some
  Nikon-derived profiles separately. This review transferred no profiles,
  implementation code, or algorithms.

The bounded review found no demonstrated feature gap requiring an immediate
driver replacement. It did not establish that nkscan has stronger Stop or
recovery guarantees. Read the linked resource audit for the exact research
boundary; do not generalize that review's attestation to all historical work.

## What we actually implemented

ScanStudio still uses its own Rust engine, Python bridge and CoolscanPy driver.
We did not switch the backend to nkscan. The comparison reinforced capability
checks and honest support claims; most recent changes came from independent
code review, issue reports and testing of our own app:

- Fixed connection through CoolscanPy's real public discovery/open API.
- Preserved early Stop requests and ownership of a held scanner session.
- Made resume use the saved project's current unfinished-frame list, while
  preserving completed images and requiring fresh registration when needed.
- Distinguished saved files from settings for the next scan and made recorded
  outputs accessible through Finder.
- Restricted current app builds/releases to Apple Silicon macOS and retained
  full packaging, signature, notarization and release checks.
- Added executable simulator acceptance for interruption, resume, output
  decoding and receipt integrity. These tests do not establish image quality.

PR #112 merged as `4d4e05cb13b72d74df845f6920c5070f8072e768` after its full gate
passed. Canonical CoolscanPy 0.7.6 was published and its source parity verified.
Further startup-error and button-contrast fixes are in progress, not yet
included in that merge or in the running local candidate.

## What the 2026-09-06 hardware run established

The user supplied a C-41 strip estimated at 5–7 shots. Local candidate #1
(Developer ID-signed beta.15 build from `6622f260`, not notarized) connected
to an LS-5000 ED reporting firmware 1.03 and an SA-30 holder. Its explicit
preview found six frames (bridge telemetry: preview 16:58:41.594 to
16:59:01.070 UTC, about 19.5 s for this one run). The first and last
boundaries were reviewed and accepted at zero offset.

The six-frame capture then failed before any frame completed. The operator
started the batch by accident at 17:15:32 UTC; the held preview worker's
first USB write returned `No such device` (its handle, open since 16:58,
had become invalid while idle), the app reported FEEDER_PARKED, a fresh
worker re-opened the scanner and failed 83 s later with a libusb bulk-read
I/O error during `command 607 READ`, and the engine then quarantined its
still-running bridge after a 10 s status timeout. "Connect" afterwards
reported "bridge process exited unexpectedly" although the process was
alive, while the banner said no power-cycle was needed. The operator
power-cycled the scanner, quit the app and re-fed the film. Evidence:
`/Users/rohan/ScanStudio-QA/short-strip-20260906/failure-20260906T1717Z/`.

Fixes taken from that run, together with the earlier review items:

- A configured bridge that fails to start is a visible, recoverable
  `BRIDGE_STARTUP_FAILED` discovery error; "Look Again" performs the real
  `scanner.rescan` instead of re-reading the cached list.
- Explicit reconnect names a quarantined-but-running bridge honestly and
  tells the operator to quit and reopen; the NOT_CONNECTED guidance no
  longer promises that no power-cycle is needed.
- Amber prominent buttons keep a black label only while the fill is amber;
  disabled buttons and inactive windows fall back to the system label color.

Still open after that run (recorded, not fixed here):

- Why the held device handle became invalid after about 16 minutes idle, and
  the later bulk-read failure. Both are below the app (scanner, hub or USB
  power management); reproduce with the hub removed before changing code.
- `scanner.rescan` drops an unhealthy backend on the assumption that its
  child exited; after a timeout quarantine the child may still be running.
  Align it with connect's proven-exit rule, or re-validate a live child with
  `bridge.hello` before reusing it. Either needs a mock-bridge test first.

The re-run with candidate #2 (this fix set) is recorded below as it happens.

### Candidate #2 run

Candidate #2 was a Developer ID-signed local package of commit `7b8dbe0`
(this fix set minus the later presentation-only batch-summary change).

- **Cold launch reproduced the startup timeout** (17:36:07–17:36:22 UTC):
  the first bridge handshake exceeded the engine's 10 s deadline and the app
  showed "Scanner discovery failed … bridge call timed out". "Look Again"
  spawned a second bridge that listed the scanner 5 s later. Candidate #1's
  first launch had failed the same way, silently. The cause of the slow first
  handshake (first-run validation of a freshly signed bundle, cold Python
  imports, or the scanner right after power-on) is not yet measured.
- **Connect, preview:** connected at 17:37:58; explicit preview 17:38:37–
  17:38:56 (19.4 s), six frames; boundaries for frames 1 and 6 reviewed and
  accepted at zero offset.
- **Capture:** batch started 17:42:33 with all six slots on the held
  reservation. Frames 1–5 completed in 148.8, 186.9, 187.0, 186.1 and 187.5 s
  (4 passes, 4000 ppi, 16-bit, RGB + infrared, ICE Legacy). Each archive TIFF
  is 5959×3946 16-bit RGB (141,085,556 bytes) with a 16-bit infrared TIFF
  (47,028,684 bytes) and a 281×425 four-channel meter TIFF; positive TIFFs are
  5959×3946 16-bit and preview JPEGs 8-bit. All fifteen receipt bindings
  matched SHA-256, byte length, inode and volume.
- **Frame 6 refused** at 17:58:24 by the driver's bounded exposure-meter
  controller: `meter pass 3 final controller refused: nonconverged`. The
  metering window's central signal sat at the 65535 ceiling through three
  passes (R 90000 → 76500 → 65025 raw 10 ns, the bounded 0.85 ratio each
  time); the final update of 0.150 exceeded the 0.050 limit. The worker
  released the scanner cleanly (`unit_released: true`, transport idle) and
  no retry was attempted. The driver wrapped the refusal as `RollMismatch`,
  the engine surfaced INTERNAL/ROLL_MISMATCH, and the app showed "Failed: 06"
  with no reason while offering Resume and Retry; fixed in this PR at the
  presentation layer (batch summary and footer show the reason for any
  failed frame; the "controller refused" phrase keeps the exposure
  guidance).
- **Images (subjective, no reference):** frames 1–5 are complete scenes
  matching their previews, sharp on the subject at 100%, with a strong
  magenta/blue cast from the default blind render, clipped sky highlights in
  frame 2, and visible dust specks at 100% with ICE Legacy on frame 1.
  Orientation is as scanned (rotated, mirrored text); no per-frame rotation
  or mirror was applied.

Evidence: `/Users/rohan/ScanStudio-QA/short-strip-20260906/candidate-2/`
(signature, hashes, log snapshots at preview start, capture start, frame-6
failure and completion, inspection crops) and the roll under
`~/ScanStudio Projects/qa-short-strip-20260906-c41-run2-proj-18d2cc3a47016f10`.

Follow-ups recorded from this run, in addition to the two above:

- The meter controller's three bounded passes at a 0.85 ratio can only cut
  exposure by about 39% from the seed; a frame whose window is saturated
  beyond that is always refused. Evaluate more passes or a wider first step
  when linearity is confirmed, and carrying the previous frame's result as
  the seed for an explicitly locked roll (step 5 below) — in CoolscanPy,
  with a fixture from this frame's meter evidence.
- CoolscanPy reports the meter refusal as `RollMismatch`; it should carry
  `MeterControllerRefused` so no phrase matching is needed downstream.
- Measured later the same day: cold handshakes exceeded 10 s on three of
  five first launches of freshly signed bundles (warm respawns about 5 s),
  and `device.open` took about 8 s on three connects and over 10 s on two
  connects right after film was re-fed (standalone: discovery 6.5 s + open
  5.6 s). The engine now bounds `bridge.hello` at 45 s and `device.open` at
  60 s instead of the generic 10 s control-plane timeout; the slow
  discovery itself (about 6.5 s of libusb enumeration and inquiry) is still
  worth profiling in CoolscanPy.

### Single-sample and held-exposure attempt (candidates #4 and #5)

A friend's calibration guide asked for a "Pass A" of 1 sample per line with
auto exposure off and one exposure held for the roll. Both were built the
same day: CoolscanPy `feat/samples-per-scan` (`Roll.scan_many(samples_per_scan=1|4)`
patching the fine SET_WINDOW multi-read byte and its GET_WINDOW echo), and a
bridge that accepts `multisamplePasses` from the driver's declared set and
`autoExposure: false` as "meter the lowest slot, hold it for the rest"
through the driver's existing `exposure_override_10ns`.

Live result (candidate #5, commit 5b82b03 with the vendored driver change,
evidence in `/Users/rohan/ScanStudio-QA/single-sample-20260906/`):

- The scanner accepted the one-sample window (GET_WINDOW echoed samples=1
  on all four colours) and metered normally with the same exposures as the
  morning's 4× frame 1. The first fine READ (command 607) then failed with
  libusb OVERFLOW during its status phase and the transport had to be
  power-cycled. Twenty minutes later, after another power-cycle, an ordinary
  4× preview failed the same way on command 122 (a plain bulk read), so the
  USB link itself was unreliable in this session (the scanner sits behind an
  Anker USB-C hub) and the single-sample result is inconclusive rather than
  a proven protocol mismatch. A verified single-sample capture on a reliable
  link is required either way. Decision: single-sample stays behind
  `SCANSTUDIO_BRIDGE_SINGLE_SAMPLE=1` (lab-only); production advertises
  `[4]`. Next session: connect the scanner directly to the Mac with a
  different cable before any further transport work.
- Held exposure was validated at 4× on the same strip once the scanner was
  moved to another hub (candidate #6, 20:07–20:12 UTC): frame 1 metered
  890.92/1781.93/1633.44 µs, frame 2 was captured at exactly those values
  (driver journal `exposure_override.applied: true`; its own meter would have
  chosen 1466.67/3650.71/3320.72 µs), both receipts verified, IR metered.
- Two other findings were fixed on the way: `device.open` and the cold
  `bridge.hello` now have measured deadlines (60 s and 45 s) after both
  exceeded the generic 10 s timeout on this scanner; the multi-sampling
  picker labels one sample as "1× (off)" and the app default is the traced
  4 so a wider advertised set never lands on a lower value silently.
- Film handling limited the session: after repeated ejects and reinserts of
  the short strip, one preview refused with REFEED_REQUIRED (anchor residual
  up to 7.6 rows) and one batch refused before motion because the fresh
  frame-table read did not fit the preview within 2 rows. That refusal is
  reported as "live mapping has fewer than 2 scanner-addressable frame
  records" (ROLL_MISMATCH) and does not persist which anchor failed; both
  the wording and the missing evidence are follow-ups.

## Implementation order and acceptance

1. **Finish the current capture and remove release blockers.** Inspect outputs,
   retain the master, save a new QA project and capture the six selected frames
   using normal controls. Verify completed receipts and decode the actual files.
   Inspect boundaries, grain/detail, color and IR treatment; record uncertainty
   where no reference exists. Preserve diagnostics for any refusal. Integrate
   the in-progress startup-error, real retry and contrast fixes, verify them,
   merge through CI, then publish and verify the signed/notarized artifact.
   Do not rebuild or replace the currently running app during its held session.

2. **Measure where time and resources go.** Reuse phase telemetry and receipts
   to separate preview, positioning, focus, metering, acquisition, rendering and
   file publication. Record settings, dimensions, elapsed time, peak memory and
   disk use alongside image evidence. Add only missing phase measurements needed
   to distinguish a bottleneck. Establish a baseline before choosing an
   optimization; report scanner time separately from computer processing time.

3. **Remove measured computer-side waste.** Inspect the slowest measured phase
   for repeated decoding, unnecessary full-image copies or redundant file I/O.
   Reuse existing buffers and dependencies where appropriate. Change one cause
   at a time and repeat the same fixture. Keep changes only when measurements
   improve and bit depth, color behavior, receipt integrity, memory bounds and
   Stop responsiveness remain correct. Do not remove integrity checks to save
   time. Do not parallelize commands to the physical scanner.

4. **Make everyday use clearer.** Complete the actionable startup error and
   retry behavior; inspect prominent buttons in dark and light appearance.
   Explain automatic adjustments such as the current supported 4× sampling
   mode. Use measured phases to improve progress/ETA only if current estimates
   prove misleading. Verify with the native app, including failure paths.

5. **Evaluate faster acquisition as separate experiments.** Investigate
   first-frame exposure reuse only for an explicitly locked, consistent roll;
   compare it against per-frame metering on varied densities and scenes.
   Independently investigate alternate sampling or CCD modes only when our
   driver has a justified supported implementation and an attended test plan.
   Keep experimental modes out of production capability advertisements until
   geometry, color, focus, IR behavior, Stop and recovery are validated. No
   promised speed multiplier and no copied command streams or profiles.

6. **Prioritize features that avoid repeating physical scans.** Evaluate an
   explicit offline re-render action using a retained master, reusing the
   existing renderer. First verify that the retained data and settings are
   sufficient. Write new derivative files, preserve the master and previous
   outputs, and record which recipe produced each derivative. This is a future
   feature proposal; changing current settings does not re-render saved files.

7. **Expand evidence before expanding scope.** Finish the attended full-roll
   test, including Stop/reopen/resume when the physical setup permits it.
   Compare original completed-file hashes after resume. Add known reference
   scans for image-quality comparisons. Retain Apple Silicon-only app scope;
   other scanners, holders and film processes require their own test evidence.

Steps 1–2 come first. Steps 3–4 can proceed in parallel on separate files once
their evidence is available. Step 5 requires controlled hardware experiments;
step 6 is independent of scanner transport. Each accepted change gets the
smallest regression check that exercises its actual failure mode, followed by
the required release gates. Avoid a new monitoring service or driver rewrite
unless measurements demonstrate a need.

## Required final explanation

After QA and release work, give the user a plain-English report covering:

1. What the other driver's published behavior taught us, with source links.
2. Which ideas were implemented, which were already present, and which remain
   proposals. Credit fixes found in our own code separately.
3. What real hardware and software tests proved, including actual failures,
   untested cases, performance measurements and the tested build identity.
4. The next improvements in priority order, expected benefit, dependencies and
   how each benefit will be measured. Do not state speculative savings as fact.

Update this plan and the hardware record with actual results before calling the
work complete. A six-frame preview is not a six-frame capture or a full-roll pass.
