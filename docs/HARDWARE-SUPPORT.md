# Hardware and platform evidence

This is the canonical ScanStudio hardware-support matrix. The [model table](#model-compatibility) below separates recognition from capture support. It records what the
project has actually observed at four separate boundaries; a built package or
an enumerated USB device is not evidence that preview or capture works.

Current support is **Apple Silicon only** (M-series, arm64), macOS 14 (Sonoma)
or newer, with the LS-5000 color-roll workflow in Beta. No new hardware tests
are implied by this policy change. Intel Macs, Windows, and Linux are retired;
use [NegPy downloads](https://github.com/marcinz606/NegPy/releases) and
[upstream compatibility guidance](https://github.com/marcinz606/NegPy#readme),
without assuming a download guarantees scanner support.

Latest release notes: [v0.7.0-beta.17](releases/v0.7.0-beta.17.md) (release candidate; not published).

| Host and scanner | Package built | Device enumerated | Preview exercised | One-frame capture validated | Support / next evidence |
| --- | --- | --- | --- | --- | --- |
| Apple Silicon macOS + LS-5000 USB | Yes | Yes | Yes | Yes, on one Mac/scanner configuration; five of six frames of a C-41 short strip on the 2026-09-06 beta.15 candidate (firmware 1.03, SA-30), the sixth refused by the exposure-meter controller | **Beta.** CLI-driven attended roll evidence from 2026-09-07 covers frames 1–9 and 11–36; frame 10 was refused by the IR meter gate, and 37–40 were excluded. More firmware, adapter, macOS, and media diversity is human-owned in [#23](https://github.com/rohanpandula/ScanStudio/issues/23). |
| LS-40 / Coolscan IV and LS-50 / Coolscan V USB | Packages contain identity recognition only | No retained packaged-app field result | No | No | **Recognized; unverified.** CoolscanPy 0.7.8 permits explicit opt-in while binding the selected USB identity. No capture has been validated. Identification evidence is requested in [#27](https://github.com/rohanpandula/ScanStudio/issues/27). |
| LS-4000, LS-8000, and LS-9000 FireWire | No scanning package | Yes, discovery and a motion-free probe on modern macOS | No | No | **Unsupported for scanning.** Driver-probe evidence and the remaining hardware work are tracked in [#28](https://github.com/rohanpandula/ScanStudio/issues/28). |

## Model compatibility

The runtime authority is `_NIKON_COOLSCAN_USB_MODELS` and
`_SANE_COOLSCAN_MODEL_MARKERS` in `coolscanpy/src/coolscanpy/_device.py`.
`scripts/verify_hardware_support_docs.py` checks this table against those names.
The [evidence matrix above](#hardware-and-platform-evidence) records observed
results; recognition alone does not establish a usable transport or capability.

| Model | Adapter | Verified on | Evidence | Status |
| --- | --- | --- | --- | --- |
| LS-5000 ED | SA-30 observed; other adapter identities reported at runtime | Apple Silicon macOS, firmware 1.03 | 2026-09-06/07 attended runs; [beta.16 notes](releases/v0.7.0-beta.16.md) | Verified — supported C-41 workflow in Beta; evidence applies to the observed configuration |
| LS-50 ED | Unknown; report actual identity | None | No capture evidence | Recognized; unverified — explicit opt-in requires CoolscanPy 0.7.8; frozen LS-5000 protocol may fail at any stage |
| LS-40 ED | Unknown; report actual identity | None | No capture evidence | Recognized; unverified — explicit opt-in requires CoolscanPy 0.7.8; frozen LS-5000 protocol may fail at any stage |
| LS-4000 ED | Unknown | None | Discovery/probe only | Recognized by name only — no direct-USB capture path |
| LS-8000 ED | Unknown | None | Discovery/probe only | Recognized by name only — no direct-USB capture path |
| LS-2000 | Unknown | None | None | Recognized by name only — no direct-USB capture path |
| COOLSCANIII | Unknown | None | None | Recognized by name only — no direct-USB capture path |

LS-9000 appears in historical FireWire probe guidance but is absent from these
runtime identity tables. It is not an unverified capture candidate. Native
resolution, bit depth, infrared, multisampling, and adapter capabilities for
unverified models have not been established by ScanStudio evidence.

One-frame 1x capture validated — **No.** The 2026-09-06 attempt failed with
`LIBUSB_ERROR_OVERFLOW` at the first fine READ and needed a power-cycle.
Evidence: `~/ScanStudio-QA/single-sample-20260906/single-sample-failure-1949Z/`.
The single-sample gate remains closed pending an attended junk-strip run; see
[beta.17 notes](releases/v0.7.0-beta.17.md).

## Testing an unverified scanner

The candidate adds **Allow unverified scanners** in Settings and
`scanstudio-cli connect --allow-unverified-hardware`. The CLI requires its own
explicit flag; a saved GUI preference does not opt a CLI command in. CoolscanPy
0.7.8 supports this opt-in; an older driver without the API returns a typed
upgrade refusal. There is no fallback retry.

The opt-in allows a recognized USB identity through the existing LS-5000
command path. It does not adapt that
trace to a different scanner. Discovery or connection may succeed while focus,
metering, preview, or fine reads fail. Status, receipts, derivative TIFF metadata,
and diagnostics carry the model and `hardwareVerification: unverified`;
this is provenance, not successful hardware validation.

An identity or unsupported-parameter refusal is expected evidence. Stop on a
transport error, recovery requirement, or unexpected motion; do not blindly
retry. Use the error banner's **Save Diagnostic Bundle** action or
`scanstudio-cli diagnostics export` and report the exact command and typed error.
Include the firmware, adapter, native resolution, and bit depth actually reported
by the device, plus which boundaries succeeded. No non-LS-5000 capture has been
validated by this project.

Review diagnostic bundles locally before sharing. Never post film images,
private paths, serial numbers, or raw capture journals publicly. See
[Reporting a new result](#reporting-a-new-result) and the
[CLI guide](CLI.md) for command and evidence handling.

## Retired platform evidence (historical only)

These observations remain valid records of earlier work. They do not authorize
current builds, downloads, updates, acceptance testing, or continuing port work.
Linked issues preserve the original results and limitations.

| Host and scanner | Package built | Device enumerated | Preview exercised | One-frame capture validated | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| Intel macOS + LS-5000 USB | Yes | Yes | Yes | No; capture refused at binding/meter gates | Retired. Original objective completed in [closed evidence #24](https://github.com/rohanpandula/ScanStudio/issues/24); no successful frame was claimed. Meter refusals were tracked in [#101](https://github.com/rohanpandula/ScanStudio/issues/101). |
| Windows x64 + WSL2 + LS-5000 USB | Yes | Yes | No retained post-fix preview result | No | Retired. Enumeration/setup evidence in [closed evidence #26](https://github.com/rohanpandula/ScanStudio/issues/26); no retained packaged preview or capture result. |
| Linux x64 + LS-5000 USB | Yes | No packaged-app field result | No | No | Retired. Package/runtime checks and uncompleted physical validation recorded in [#25](https://github.com/rohanpandula/ScanStudio/issues/25). |

“Yes” applies only to the retained setup evidence, not every machine, firmware,
adapter, holder, or film stock. A failed boundary is still useful evidence when
the exact installed version and typed error report are retained.

Release provenance is a separate question from runtime support. The
same-run/exact-tag verification discrepancy is tracked in
[#104](https://github.com/rohanpandula/ScanStudio/issues/104); it does not by
itself establish a defect in any downloaded runtime package.

Current macOS release artifacts are Developer ID signed, notarized, and
stapled. Historical release notes retain the signing and support facts that
applied to older Intel, Windows, and Linux artifacts; those assets are not
current supported downloads.

## Reporting a new result

Follow [Mac acceptance and recovery](MAC-ACCEPTANCE.md) for the packaged
software gate and attended hardware checks; a simulator pass is not a real
preview or capture result.

Record the exact ScanStudio version, host/OS, scanner model and firmware,
adapter or holder, and media type. Report each boundary separately: installed
package launched, device enumerated, connection opened, preview completed, and
one-frame capture produced a receipt. If a boundary fails, include the typed
in-app report. Keep diagnostic bundles local until their contents have been
reviewed; never post film images, private paths, serial numbers, or raw capture
journals publicly.
