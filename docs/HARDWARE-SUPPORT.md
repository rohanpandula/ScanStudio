# Hardware and platform evidence

This is the canonical ScanStudio hardware-support matrix. It records what the
project has actually observed at four separate boundaries; a built package or
an enumerated USB device is not evidence that preview or capture works.

Current support is **Apple Silicon only** (M-series, arm64), macOS 14 (Sonoma)
or newer, with the LS-5000 color-roll workflow in Beta. No new hardware tests
are implied by this policy change. Intel Macs, Windows, and Linux are retired;
use [NegPy downloads](https://github.com/marcinz606/NegPy/releases) and
[upstream compatibility guidance](https://github.com/marcinz606/NegPy#readme),
without assuming a download guarantees scanner support.

Latest release notes: [v0.7.0-beta.16](releases/v0.7.0-beta.16.md).

| Host and scanner | Package built | Device enumerated | Preview exercised | One-frame capture validated | Support / next evidence |
| --- | --- | --- | --- | --- | --- |
| Apple Silicon macOS + LS-5000 USB | Yes | Yes | Yes | Yes, on one Mac/scanner configuration; five of six frames of a C-41 short strip on the 2026-09-06 beta.15 candidate (firmware 1.03, SA-30), the sixth refused by the exposure-meter controller | **Beta.** Full-roll attended run still pending. More firmware, adapter, macOS, and media diversity is human-owned in [#23](https://github.com/rohanpandula/ScanStudio/issues/23). |
| LS-40 / Coolscan IV and LS-50 / Coolscan V USB | Packages contain identity recognition only | No retained packaged-app field result | No | No | **Unsupported for scanning.** Identification evidence is requested in [#27](https://github.com/rohanpandula/ScanStudio/issues/27). |
| LS-4000, LS-8000, and LS-9000 FireWire | No scanning package | Yes, discovery and a motion-free probe on modern macOS | No | No | **Unsupported for scanning.** Driver-probe evidence and the remaining hardware work are tracked in [#28](https://github.com/rohanpandula/ScanStudio/issues/28). |

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
