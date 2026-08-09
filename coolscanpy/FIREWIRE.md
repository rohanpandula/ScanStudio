# FireWire Coolscans on modern macOS (ASFireWire)

The FireWire Coolscan models -- LS-4000 ED, LS-8000 ED, and SUPER
COOLSCAN 9000 ED -- speak Nikon's SCSI command family over IEEE 1394
instead of USB. Apple removed the FireWire stack in macOS Tahoe, and
Apple Silicon Macs never had one; the open-source
[ASFireWire](https://github.com/mrmidi/ASFireWire) DriverKit stack
rebuilds it. ASFireWire logs into the scanner's SBP-2 unit and publishes
it as a **standard macOS SCSI device** -- the same surface VueScan uses
to scan an LS-9000 through it today.

coolscanpy's client for that surface is
`coolscanpy.transport.macos_scsi`: a pure-Python (ctypes) SCSITaskLib
transport. No compiled extension, no extra install. On Linux the same
role is played by `coolscanpy.transport.linux_sg`, a pure-Python client
for the kernel's v3 `SG_IO` interface over the nodes `firewire-sbp2`
publishes.

## What works today

Device discovery, identity, and a motion-free probe, on either OS:

```
python -m coolscanpy.transport.macos_scsi
python -m coolscanpy.transport.macos_scsi --probe <registry-id>
```

```
python -m coolscanpy.transport.linux_sg
python -m coolscanpy.transport.linux_sg --probe /dev/sgN
```

The probe takes exclusive access, runs TEST UNIT READY, INQUIRY, and
(on a check condition) REQUEST SENSE, prints the scanner's identity
block, and releases the device. It never moves film.

## What deliberately does not work yet

Scanning. coolscanpy's single-pass protocol layer is validated against
the LS-5000's USB dialect, byte-for-byte, on real captures. The command
vocabulary itself is settled -- Nikon's own interface specifications
describe one protocol for the LS-5000 and LS-9000, and the nkscan
project has driven a real LS-9000 with it (next section) -- but
everything between a vocabulary and a correct scan through ASFireWire
is not: SBP-2 status and sense behavior, transfer chunking under the
1 MB task ceiling, frame geometry on the medium-format holders.
Guessing at those would produce silently wrong scans, which is worse
than refusing. The probe output above is exactly the evidence this
needs: if you have a FireWire Coolscan running through ASFireWire,
please run it and paste the output into
[ScanStudio issue #28](https://github.com/rohanpandula/ScanStudio/issues/28),
the coordination thread for these models.

## What the nkscan v0.3.0 rewrite establishes

[nkscan](https://github.com/activexray/nkscan) is the independent
open-source Coolscan driver this project coordinates with rather than
duplicates (the engineering thread in issue #28). Its v0.3.0 release
(2026-08-09, tag `v0.3.0`) is a ground-up rewrite against Nikon's own
interface specifications, and it changes what is known about the
FireWire models:

- Nikon's official wire-protocol documents for the LS-5000 (USB) and
  LS-9000 (IEEE 1394/SBP-2) are published in nkscan's `docs/`
  directory. Compared side by side they describe one command protocol,
  with fields in the same bit and byte positions on both units;
  per-model differences are advertised by the scanner through
  capability pages, not baked into per-model dialects. v0.3.0 is built
  on that finding and carries no per-model scanner modules at all.
- Its command set is a superset of the vocabulary coolscanpy validated
  byte-for-byte on the LS-5000. Common to both implementations:
  TEST UNIT READY, INQUIRY, MODE SELECT, RESERVE UNIT, SCAN,
  SET WINDOW, GET WINDOW, READ, SEND, and Nikon's SET PARAMETER /
  GET PARAMETER / EXECUTE (E0h/E1h/C1h). nkscan additionally issues
  RELEASE UNIT, MODE SENSE, SEND DIAGNOSTIC, and ABORT (C0h).
- What is genuinely different on the FireWire units, per its transport
  and scan layers: SBP-2 can answer BUSY and RESERVATION CONFLICT,
  statuses the USB wrapper never carries; sense data arrives in
  per-transport shapes; the LS-8000/9000's three-line CCD needs a
  row-response correction the single-line units do not; and some
  holders publish frame rectangles without lengths, so framing works
  from a whole-strip thumbnail.
- Hardware validation is complementary: nkscan has run against a real
  LS-9000 (with the 869S holder); every LS-5000 row in its support
  matrix is marked theoretical. coolscanpy is the exact reverse.
- Its transports are Linux `sg`, Windows `scsiscan.sys`, and
  cross-platform USB. There is no macOS FireWire transport, and its
  README defers Mac FireWire support -- ASFireWire remains the only
  macOS path to these scanners, so this file's plan stands.
- The rewrite removed nkscan's Python bindings, marked temporary in
  its changelog; the `nkscan` package on PyPI is still the pre-rewrite
  0.2.0. The surface a future binding would wrap is its `Transport`
  trait -- execute one CDB with a data phase and a timeout, get
  status, sense, and bytes transferred back -- the open/claim plus
  read/write shape a protocol layer sits on the same way the USB lane
  here sits on libusb.

The USB identity facts credited in `THIRD_PARTY_NOTICES.md` were
re-verified at v0.3.0: the table moved from `src/devices.rs` to
`src/protocol/model.rs` and the vendor/product ids are unchanged.

## Requirements and honest limits

- ASFireWire installed and running. It is a beta DriverKit extension:
  today it requires disabling SIP, and it matches one FireWire
  controller chip (the Agere FW643 in Apple's own
  Thunderbolt-to-FireWire adapter chain). Its README is the authority
  on setup.
- One scanner at a time (ASFireWire exposes a single SBP-2 target).
- Reads above 1 MB must be split across SCSI tasks (ASFireWire's
  per-task ceiling); `chunk_transfer_lengths()` in the transport module
  encodes that policy.
- If another client (VueScan, a stale probe) holds the device,
  exclusive access fails with a named error -- close the other client
  first.
- On Linux, none of the ASFireWire requirements apply: the kernel's own
  `firewire-sbp2` exposes the same scanners as SCSI devices, nkscan
  drives a real LS-9000 that way today, and the long-term plan for
  FireWire units remains Linux-first (issue #16 discussion).
  coolscanpy's probe runs there through `linux_sg` with no extra
  install; the same paste-the-output ask in issue #28 applies.
