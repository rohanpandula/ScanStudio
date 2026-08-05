# Parity Sign-Off Checklist (HW-03)

This document is the port's completion certificate: the milestone's final
checklist the owner completes before declaring the cross-platform ScanStudio
port shipped.

## How to Use This Document

Complete every checklist item below against the live Linux and/or Windows
validation you have already carried out per `runbooks/LINUX-LIVE-VALIDATION.md`
and `runbooks/WINDOWS-LIVE-VALIDATION.md`, then fill in the Final Sign-Off
block at the bottom. An unchecked or "fails" item means do not ship yet.

## Checklist

1. Honesty labels — the device bar/status display shows `real` vs `simulated`
   truthfully, and `motionArmed`/`filmPresent` render as their live tri-state
   values, never a cached or invented one. Quote (BRIDGE.md, DeviceStatus):
   "motionArmed: bool // live re-check result, never a cached value (see SAFE-02
   guardrails)" and "filmPresent: bool|null // live, no-motion film-presence
   read; null when no trustworthy verdict is available", where "true means the
   scanner reports medium gripped, false means its verified MEDIUM NOT PRESENT
   sense was observed, and null means no trustworthy verdict was available ...
   null is never interpreted as absence."
   - [ ] Note: ____

2. Approval flow end-to-end — a frame flagged `needsApproval: true` in preview
   was actually approved (or its spacing offset adjusted) before capture, and
   omitting approval was observed to surface as `MANUAL_REVIEW_REQUIRED`, not a
   silent capture. Quote (BRIDGE.md, roll.approve): "Records manual-review
   approval for one slot. Not motion-capable — no transport movement, no latch
   check. Required before scanning any slot whose last roll.thumbnail event had
   needsApproval: true; omitting it surfaces as MANUAL_REVIEW_REQUIRED when that
   slot's turn in scan.start comes up."
   - [ ] Note: ____

3. Stop-after-current semantics observed — a stop request during a multi-frame
   batch let the in-flight frame finish and reported it via
   `scan.frameCompleted`, then skipped the remainder, with no "immediate abort"
   behavior. Quote (BRIDGE.md, scan.stop): "Stops between transfers only
   (mirrors CoolscanPy's Roll.safe_stop()): the in-flight slot always finishes
   and is reported via scan.frameCompleted, the next slot is skipped, no other
   slots are attempted. There is no "immediate" mode — no safe immediate abort
   exists against real hardware."
   - [ ] Note: ____

4. Eject outcome surfaced verbatim — the app displayed the eject result exactly
   as returned (a bare confirmed-ejected result, or a named typed error such as
   `EJECT_FAILED`/`FEEDER_PARKED`), never paraphrased or silently treated as
   success. Quote (BRIDGE.md, device.eject): "{} means confirmed ejected, never
   anything less. A transport that reports the film did not come out, a
   capability-gated no-op, or any accepted-without-progress outcome surfaces as
   a typed error, never as {}."
   - [ ] Note: ____

5. Receipts complete — for the captured frame(s), the fingerprints
   (`reviewedFingerprintSha256`, `freshFingerprintSha256`), the exposure vector,
   at least one telemetry JSONL entry, and the `storageTransform` value were all
   present, and the `storageTransform` value was one this port recognizes.
   Quote (BRIDGE.md, ScanReceipt / storageTransform): "storageTransform is
   mandatory, never null or empty ... Today every live capture reports exactly
   one value, swapaxes01-scanner-native-to-nikon-render-parity-v2 ... A
   historical value, rot90k1-scanner-native-to-storage-v1, may appear in
   archives whose provenance predates this field, but it is never emitted by a
   live bridge. A consumer ... MUST branch on this value and MUST refuse rather
   than guess when it sees a value it does not recognize." An unrecognized value
   must have been refused, never guessed past.
   - [ ] Note: ____

6. Parity gap list reviewed and accepted — `app/PARITY-NOTES.md` has been read
   in full; every listed gap (if any) is one the owner explicitly accepts for
   this release; an empty gap list is itself a parity claim worth noting as
   such.
   - [ ] Note: ____

7. Full verification green on the tagged commit — `verify-all.sh` (repo root)
   was run against the exact commit about to be tagged and exited zero, with
   its per-section PASS/FAIL summary attached or referenced here.
   - [ ] Note: ____

## Final Sign-Off

This block is filled in by the owner only, after every checklist item above has
a verdict. Once filled, this document is the milestone's completion certificate.

- Date: ____
- Commit: ____ (full SHA)
- Verdict: choose one of `SHIP` / `SHIP WITH NOTED GAPS` / `DO NOT SHIP`
- Notes: ____ (free text)
