# Changelog

## Unreleased

C-41 fine scans now expose RGB the way Nikon Scan would. The meter loop's
own converged solve consistently landed 6–9 % brighter than Nikon's
rendering of the same physical frame, and matched-pair analysis against
Nikon's internal state traced the whole midtone gap to that exposure-policy
difference rather than to any colour mathematics. The final metering pass
therefore now derives a Nikon-like per-channel target from the settled
pass-3 raster and commands the guarded result — capped at the reviewed
64,880 q99.99 highlight threshold and clamped to the scanner's exposure
bounds, both journaled — as the fine-scan RGB contract by default. Infrared
stays with the existing controller unchanged. Every frame journal records
an `active_exposure_authority` block binding the active solve, the guarded
candidate, and the commanded wire contract together, and both the roll
publication consumer and the single-pass finalize validator verify that
chain instead of the old commanded-equals-active invariant. The uncapped
Nikon-like diagnostic value is journal-only and structurally unable to
reach a scanner command, which the fail-closed tests pin. A parity
calculation failure refuses the fine scan loudly rather than silently
falling back to the previous behaviour. Validated live on three frames with
matched Nikon Scan output using v3 fine-scan fractions R 0.950337,
G 0.987481, and B 0.983639. Nikon-referenced full-scale channel biases were
R +0.823…+2.086 %, G +0.146…+1.033 %, and B -0.391…+0.822 %; mean absolute
bias was 0.9129 %. Under the explicitly defined complement statistic
(100 % minus mean absolute full-scale channel bias), that is 99.0871 %
average full-scale RGB-channel agreement. Mean 8x8-smoothed ΔE00 improved
from 2.8469 to 2.1413 (-24.8 %). These figures describe this three-frame
validation set, not byte identity or a universal perceptual-accuracy
percentage.

The scanner's film-presence state is now readable without moving film.
`adapter_status` issues a bare TEST UNIT READY — no data phase, no
transport motion — and maps the two captured verdicts (`000000` ready with
medium, `023a00` medium not present) to a typed answer, refusing to guess
on any other sense. A companion USB selector translates local device
identifiers into exact bus/address locations and deliberately fails closed
on remote SANE identifiers, so a status probe can never wander to a
different scanner than the one that was opened. The probe answers presence
only; it cannot promise a subsequent movement will succeed, and its
docstring says so.

Frame-selection legality no longer inherits the SEND(0x8f) page capacity.
The physically addressable prefix and the fixed 37-record firmware page are
two different things, but `_addressable_frame_origins` silently truncated
the proven prefix to the page size, so frames 38+ of a long roll could never
be selected: every batch requesting them refused with `requested frame 38 is
outside the scanner-addressable table 1..37`. Observed live twice on
2026-07-25 with a 39-frame C-41 roll whose five persisted traversals (two
previews and all three batch index rereads) each prove 39 clean origins with
sub-row anchor residuals — the refusal was roll-independent, not a detection
shortfall. Frame addressing crosses the wire as an absolute native origin
bound into the dynamic SET_WINDOW, autofocus, and GET_WINDOW commands, never
as a page index, and Nikon Scan scans frame 38+ of the same roll while
sending the same fixed 300-byte page. The addressable prefix now returns
every proven origin; only `build_live_frame_table_payload` truncates to the
page's 37 records, and the page keeps its exact firmware-required shape. The
non-addressable flag gates (terminal-transport-tail, outside-index-raster,
spacing-outlier, residual bounds) are unchanged, so a genuinely
non-addressable trailing origin still stops selection at the proven prefix,
and the excess-frames-vs-reviewed-roll comparison now sees the true live
count instead of a page-capped one. A live fine scan of a frame past the
page boundary has not yet been performed; replaying the exact failed live
batch call (32 slots through frame 38) against the persisted reread
artifacts succeeds end-to-end through selection derivation and page
construction.

The scan-time manual-review gate could still refuse an otherwise clean frame
1 that the operator already reviewed. The five-row leading-anchor cap on the
physically addressable table only decides which records the scanner can be
told to address; it does not by itself exempt a slot from the separate,
same-traversal manual-review gate a fresh scan-time reread runs before frame
binding. A live 36-slot reservation whose reviewed preview measured a
-1.525-row leading residual (automatic, inside the two-row interior bound)
produced a fresh scan-time reread of -2.497 rows on the same slot -- still
inside the five-row leading bound, but now flagged
`leading-anchor-divergence` -- and refused before the fine scan ever began,
despite matching global and selected visual fingerprints on both traversals.
The scan-time gate now narrowly auto-accepts exactly that condition: a fresh
frame-1 origin whose only flagged issue is `leading-anchor-divergence`,
inside the five-row bound, when the reviewed session's own preflight already
classified that slot automatic, both the whole-roll and selected-slot visual
fingerprints already matched, and every interior mapping gate already
passed. An accepted slot's journal now carries a
`leading-anchor-divergence-accepted` marker with its fresh residual. The
two-row interior bound is unchanged, the fingerprint checks keep running
first in the same order, and every other manual-review cause -- including
any slot the reviewed session itself flagged manual -- still refuses exactly
as before.

Full-roll transport mapping now permits the directly observed Nikon leading
record to differ by up to five 97-dpi preview rows from the independently
fitted interior traversal. A live 36-frame reservation produced a 3.924-row
leader residual while its 33 interior anchors remained tightly consistent
(0.275-row MAE, 1.161-row maximum); the former three-row leader cap therefore
refused before frame binding despite clean same-traversal evidence. The wider
cap applies only to the excluded leading record. Interior scale, MAE, maximum
residual, monotonicity, exact live-table provenance, and manual-review gates
remain unchanged, and a leader beyond five rows still fails closed.

Whole-roll preview now binds its motion window and USB read allocation to a
validated complete 37-record startup table. The Nikon 40-record trace uses a
native height of `42 * 5959`; the observed full-roll response omits the last
three records, so the bound preview uses `39 * 5959`, decodes 5,668 complete
rows, reads exactly 5,804,032 bytes, and marks that shorter final read as the
scan drain boundary. The original 40-record plan remains byte-for-byte
unchanged. Both Nikon's archived prefix and live position-bearing tables are
accepted, but live records must reproduce Nikon's transport-coordinate
identity, remain strictly increasing and in range, and follow the proven
selector cadence. Any other short count, status, record shape, odd row
geometry, or non-contiguous read allocation still refuses before the first
preview `SET_WINDOW`. Nikon-density evidence, offline replay, and the durable
preview/frame mapping receipt carry the exact whitelisted preview geometry, so
a 37-record traversal remains independently size- and identity-verifiable.

`Device.roll()` now accepts an optional caller-owned `attempts_root`. Evidence
written below that directory survives `Roll.close()`, including failed-preview
rasters, live `0x8e` transport tables, and journals needed for offline
diagnosis. Omitting the argument preserves the temporary self-cleaning
behavior. This closes an evidence-loss path in which a synchronized refusal
was recorded and then removed during otherwise successful cleanup.

Short-strip transport mapping now recognizes Nikon's contiguous terminal
`0x81xx`/`0x83xx` table suffix after the film leaves the drive. Those records
are excluded from the affine anchor fit and are unconditionally
scanner-nonaddressable: manual approval and boundary offsets cannot put one
back into `SEND(0x8f)`. The physical `40..45` scale and anchor-residual gates
remain unchanged. This prevents a terminal slot from pulling an otherwise
valid six-strip fit from about `42.33` to the observed false `61.34` scale.

Continuation frames now record the same complete 285-dpi analyzer layout as
the first frame, allowing their durable meter sidecars to pass Nikon-exact
publication validation in multi-frame batches.

0.1.3's live-table-vs-fingerprint frame count check broke full-roll scanning.
A batch run over slots 3 and 20 of a reviewed 36-exposure roll failed with
a `RollMismatch` reporting a live table of 37 scanner-addressable records
against the reviewed fingerprint's 40, even though the same roll had
scanned successfully six times earlier the same night on 0.1.1 and 0.1.2,
neither of which had this check. A separate hardware investigation found
why: the transport's native-origin ramp is clean while the feeder grips
the film, then jumps by several frames' worth of distance the instant the
trailing edge clears the drive, and every record built from that jump is
garbage that gets excluded downstream. A live count several frames below
the reviewed count is the ordinary shape of a roll ending, not a sign of a
wrong roll, so 0.1.3's plus-or-minus-one tolerance was refusing a normal
case in the direction it should never have restricted.

The comparison is now a one-directional bound instead of a symmetric
tolerance: it refuses a live count more than one above the reviewed count
(the direction with no benign explanation), and no longer bounds how far
the live count can fall below it. Roll identity was never this check's
job in the first place -- the reviewed-fingerprint visual comparison
refuses a genuinely different or reordered roll on its own, and the
per-slot addressing checks that already run downstream refuse any
requested slot the live table cannot address regardless of this count.

Adds a streaming decoder and a fail-open capture sidecar so a fine scan can be
decoded as it arrives, and lets offline finalization consume that streamed
artifact instead of re-decoding the raw oracle.

`packed.py` gains `StreamingFrameDecoder`, an incremental decoder for the same
207,872-byte full records. It accepts arbitrarily fragmented chunks (down to
one byte at a time), stages at most one record, and routes every record through
the exact kernel `decode_full_records` now shares (`_decode_record_block`) and
the same fail-closed padding check, so its output is byte-identical to an
offline decode. It enforces an exact stream length and reveals its private
buffer only after a complete, padding-valid finish. `decode_full_records` was
refactored onto the shared kernel with no behavior change.

`streaming_sidecar.py` adds two layers. `FailOpenStreamConsumer` is a generic,
decoder-agnostic producer/consumer: submission is nonblocking and bounded by a
small queue, the consumer thread starts lazily, and a queue-full, a consumer
exception, or a failed finish permanently disables the stream and is reported,
never raised. `FineStreamSession` is the LS-5000 adapter: it streams the decode
directly into a private `.npy` memmap (no second full-frame allocation or copy)
and, only after an exact padding-valid finish, durably publishes the data
artifact plus a strict receipt -- fsynced, never overwritten (a collision is a
refusal, not a claimed success), receipt last, with scratch cleaned up on every
safe failure path. If the deadline expires while a decoder is still writing,
cleanup is deferred to a daemon janitor until that thread terminates; a
permanently wedged thread may retain its clearly private temp for the worker
process lifetime rather than risk closing a live memory map. The whole
seal-and-collect wait is one short bounded deadline
(default 5 s, materially below the old 60 s) so a wedged consumer cannot hold a
retained batch reservation; submission stays `put_nowait`.

The capture worker feeds both the first-frame and the continuation-frame
fine-read loops through one shared hook (`_open_fine_stream_session` /
`_submit_fine_stream_record` / `_finish_fine_stream`). The hook engages only for
the proven full-record geometry, is gated by `COOLSCANPY_CAPTURE_STREAMING=0`,
and fails open: a synchronous decoder exception, queue backpressure, or a wedged
consumer never aborts, drains, or blocks the live scan -- raw capture continues
unchanged. Capture errors explicitly abort any uncommitted sidecar, while a
submission exception aborts it before the worker drops its reference. The
durable frame journal records the terminal streaming outcome, and finalization
will not trust leftover receipt/data files unless that exact successful outcome
is bound into the journal. Because the worker now imports this code, `packed.py` and
`streaming_sidecar.py` join the pinned capture-bundle identity alongside the
re-pinned `worker.py`.

`LS5000SinglePassWorkflow` finalization: with no injected decoder, it first
tries to consume a bound streamed artifact and otherwise falls back to offline
decode. The receipt is treated as an untrusted hint -- finalization re-validates
the schema, the raw SHA/byte binding against the already-computed stream
identity, a fresh hash of the derived file, `allow_pickle=False` loading, and
exact no-follow receipt/data identities plus NPY header, shape, dtype, and
layout before consuming. The derived file is hashed, loaded, and re-hashed
through one stable descriptor. Any absent, abandoned, incomplete,
colliding, malformed, or mismatched sidecar falls back; the second raw hash
after decode still catches a mid-decode stream mutation; and a caller-injected
decoder keeps its exact semantics and never sees the fast path. The finalization
module stays out of the capture-bundle identity (it is the offline verifier, not
scanner-facing code); its correctness rests on this runtime re-validation.
After committed outputs and manifest reverify, a consumed sidecar is removed
marker-first and data-second before the raw oracle; cleanup failure retains the
raw stream so resume can finish safely.

Public API: `StreamingFrameDecoder`, `FailOpenStreamConsumer`, and
`FineStreamSession` are exported from
`coolscanpy.protocol.ls5000_single_pass`.

## 0.1.3
- Boundary-offset application rebases a frame-1 leading origin onto the fresh traversal's detected origin (recorded in the frame journal) instead of raising, when the divergence is within the five-row leading-anchor bound and both roll fingerprints match; all other out-of-affine origins still raise.


A live hardware session scanning a 6-frame strip found two bugs in the
fine-scan path, both specific to strips shorter than a full roll.

The frame table sent to SEND(0x8f) required at least 37 scanner-addressable
records, a full-roll assumption left over from when every roll filled all
37 slots. The live mapping's record count now only has to cover every
requested slot in the batch, with a floor of 2. When a reviewed roll
fingerprint is available at the same point, the live table's addressable
count is also checked against the fingerprint's frame count, tolerating a
difference of one for a trailing sliver that crosses the 16-row
visual-signing threshold between traversals.

The tested LS-5000/SA-21 can return a complete shorter startup `0x8f`
frame-table envelope with status `022b4b` after a preview traversal. That
status is the observed completion for the shorter transfer, not proof that
the transport requires a refeed. It is now accepted only when the
self-declared envelope is valid and shorter than the 40-slot request; the
fresh live `0x8e` index and preview still independently bind roll identity
and frame addressability before fine scanning. Malformed, full-length, and
differently failed replies remain fail-closed.

`RefeedRequired` remains exported for compatibility, but generic command-64
status text is no longer translated into it without a separately confirmed
physical refeed condition.

## 0.1.2

The exclusive output lock in the full-negative capture workflow no longer
hard-imports `fcntl`, which does not exist on Windows and broke test
collection there. Windows now uses `msvcrt` byte-range locking, and the
lock is only released when it was actually acquired.

CI runs on Linux and macOS. Windows stays out of scope for now: the
transport layer has never run there and the concurrency tests assume
POSIX lock semantics. The README says the same.

## 0.1.1

Fixes a bug found during the first live-hardware validation of 0.1.0: a
roll whose strip end leaves a trailing sliver shorter than 16 preview rows
crashed `build_reviewed_roll_fingerprint` on both the reviewed and the
fresh traversal. Sliver intervals are now skipped deterministically on
every traversal, frame native origins are filtered in lockstep with the
visual hashes, and an all-sliver roll raises a clear `ValueError`.

Live validation results from 2026-07-18, using the packaged wheel in a
clean environment against an LS-5000: SANE-free USB enumeration, `open()`,
option introspection, and a full roll preview of a 6-slot strip. Slots 1
through 4 aligned automatically at offset 0, slot 5 was flagged for manual
review near the strip end, and slot 6 was correctly reported as a 2-row
trailing sliver rather than a frame.

## 0.1.0

Initial standalone release, extracted from a NegPy integration branch.

Public API:

- `coolscanpy.get_devices()` / `coolscanpy.open()`: python-sane-shaped device
  enumeration and open, scoped to Nikon Coolscan LS-5000 units.
- `Device`: typed option attributes (`resolution`, `depth`, `samples`,
  `autofocus`, `auto_exposure`) with constraint validation, option
  introspection through `Device.option_names` and `Device[name]`,
  `scan()`, `cancel()`, `eject()`.
- `Device.roll()`: the 40-slot roll-feeder extension. `Roll.preview()`,
  `Roll.spacing_offset()` / `set_spacing_offset()`, `Roll.approve()` /
  `needs_approval()`, `Roll.fingerprint`, `Roll.scan()` /
  `scan_many()`, `Roll.safe_stop()`, `Roll.eject()`.
- `Frame` and `Receipt`: in-memory RGB, aligned infrared plane, and
  per-frame provenance (exposure, clipping, focus detail, transport-smear
  assessment, fingerprint hashes, artifact hashes).
- A typed exception hierarchy rooted at `PyCoolscanError`, including
  `DeviceBusy`, `FingerprintRefused`, `ManualReviewRequired`,
  `SafeStopRequested`, `FeederParked`, `TransportSmearDetected`, and
  `BatchIntegrityError`.

Streaming: `Roll.scan_many()` yields each frame as it completes instead of
buffering the whole batch, keeping memory bounded to roughly two frames in
flight regardless of how many slots are requested.

Implemented end to end for `Material.COLOR_NEGATIVE` (the direct-USB
single-pass RGBI4 route). `Material.BLACK_AND_WHITE_NEGATIVE` previews and
approves correctly; its fine-scan path is not yet wired to the roll batch
engine and raises `NotImplementedError`.

Packaging: `py.typed` marker, publish-grade `pyproject.toml` metadata,
optional `[scanner]` extra for the SANE-backed plain-scan path, console
scripts `coolscanpy-practical-parity` and `coolscanpy-roll-scan`.

Testing: 807 hardware-free tests across the transport protocol, roll
engine, receipt assembly, and public facade, run against synthetic
fixtures and replay data. No test in this suite touches real hardware.

CI: GitHub Actions matrix across Ubuntu, macOS, and Windows on Python 3.13
and 3.14, running pytest and ruff.
