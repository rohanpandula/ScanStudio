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

Pending.

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
