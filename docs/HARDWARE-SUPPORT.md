# Hardware and platform evidence

This is the canonical ScanStudio hardware-support matrix. It records what the
project has actually observed at four separate boundaries; a built package or
an enumerated USB device is not evidence that preview or capture works.

Current published release: [v0.7.0-beta.12](releases/v0.7.0-beta.12.md).

| Host and scanner | Package built | Device enumerated | Preview exercised | One-frame capture validated | Support / next evidence |
| --- | --- | --- | --- | --- | --- |
| Apple Silicon macOS + LS-5000 USB | Yes | Yes | Yes | Yes, on one Mac/scanner configuration | **Beta.** More firmware, adapter, macOS, and media diversity is human-owned in [#23](https://github.com/rohanpandula/ScanStudio/issues/23). |
| Intel macOS + LS-5000 USB | Yes | Yes | Yes | No; capture refused at binding/meter gates | The original validation objective is **complete** ([closed evidence #24](https://github.com/rohanpandula/ScanStudio/issues/24)); this does not claim a successful frame. Typed meter refusal work continues in [#101](https://github.com/rohanpandula/ScanStudio/issues/101). |
| Windows x64 + WSL2 + LS-5000 USB | Yes | Yes | No retained post-fix preview result | No | **Preview.** The initial enumeration/setup objective is **complete** ([closed evidence #26](https://github.com/rohanpandula/ScanStudio/issues/26)); a packaged preview and capture still need new field evidence. |
| Linux x64 + LS-5000 USB | Yes | No packaged-app field result | No | No | **Preview.** Package/runtime checks exist; physical validation remains human-owned in [#25](https://github.com/rohanpandula/ScanStudio/issues/25). |
| LS-40 / Coolscan IV and LS-50 / Coolscan V USB | Packages contain identity recognition only | No retained packaged-app field result | No | No | **Unsupported for scanning.** Identification evidence is requested in [#27](https://github.com/rohanpandula/ScanStudio/issues/27). |
| LS-4000, LS-8000, and LS-9000 FireWire | No scanning package | Yes, discovery and a motion-free probe on modern macOS | No | No | **Unsupported for scanning.** Driver-probe evidence and the remaining hardware work are tracked in [#28](https://github.com/rohanpandula/ScanStudio/issues/28). |

“Yes” applies only to the retained setup evidence, not every machine, firmware,
adapter, holder, or film stock. A failed boundary is still useful evidence when
the exact installed version and typed error report are retained.

Release provenance is a separate question from runtime support. The
same-run/exact-tag verification discrepancy is tracked in
[#104](https://github.com/rohanpandula/ScanStudio/issues/104); it does not by
itself establish a defect in any downloaded runtime package.

Current macOS release artifacts are Developer ID signed, notarized, and
stapled. Windows and Linux artifacts remain unsigned. Historical release notes
retain the signing and support facts that applied to those older artifacts.

## Reporting a new result

Record the exact ScanStudio version, host/OS, scanner model and firmware,
adapter or holder, and media type. Report each boundary separately: installed
package launched, device enumerated, connection opened, preview completed, and
one-frame capture produced a receipt. If a boundary fails, include the typed
in-app report. Keep diagnostic bundles local until their contents have been
reviewed; never post film images, private paths, serial numbers, or raw capture
journals publicly.

