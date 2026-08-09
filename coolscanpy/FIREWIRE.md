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
transport. No compiled extension, no extra install.

## What works today

Device discovery, identity, and a motion-free probe:

```
python -m coolscanpy.transport.macos_scsi
python -m coolscanpy.transport.macos_scsi --probe <registry-id>
```

The probe takes exclusive access, runs TEST UNIT READY, INQUIRY, and
(on a check condition) REQUEST SENSE, prints the scanner's identity
block, and releases the device. It never moves film.

## What deliberately does not work yet

Scanning. coolscanpy's single-pass protocol layer is validated against
the LS-5000's USB dialect, byte-for-byte, on real captures. Whether the
FireWire models answer the same command vocabulary is an open question
that only real hardware can settle -- guessing would produce silently
wrong scans, which is worse than refusing. The probe output above is
exactly the evidence that question needs: if you have a FireWire
Coolscan running through ASFireWire, please run it and paste the output
into [ScanStudio issue #28](https://github.com/rohanpandula/ScanStudio/issues/28),
the coordination thread for these models.

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
- On Linux, none of this is needed: the kernel's own `firewire-sbp2`
  exposes the same scanners as SCSI devices, and the long-term plan for
  FireWire units remains Linux-first (issue #16 discussion).
