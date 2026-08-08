# Raw DNG and linear TIFF implementation report

## Outcome

ScanStudio now has an opt-in **Raw negative** output throughout the macOS app, engine, bridge, and CoolscanPy writer. It can produce:

- a 16-bit, three-channel LinearRaw DNG with the untouched infrared plane embedded as a grayscale SubIFD;
- a 16-bit linear TIFF with interleaved R, G, B, IR samples and one unspecified `ExtraSamples` channel; or
- a 16-bit linear RGB TIFF with infrared omitted.

The real-hardware export is written from the original contiguous `numpy.uint16` RGB and IR arrays before the bridge reports the frame complete. It does not invert, color-convert, crop, rotate, flip, rescale, dust-clean, or requantize those arrays. The existing Positive output remains the honest route for an inverted or IR-cleaned rendered image.

The feature is additive. Raw export defaults off in new and legacy recipes, and existing Master/Positive/Preview writers are not entered through a new code path when it is disabled. Legacy project manifests are migrated to a disabled, project-local Raw Negative destination.

## Container contract and converter expectations

The DNG is classic little-endian TIFF with uncompressed strips. Its first IFD is full-resolution, chunky RGB with `BitsPerSample=16`, `SamplesPerPixel=3`, `PhotometricInterpretation=34892` (`LinearRaw`), DNG version 1.4, backward version 1.1, full-image crop/active-area tags, zero black level, 65535 white level, and scanner identity. `SampleFormat` is unsigned integer through TIFF's default value of 1. An identity `ColorMatrix1`, unknown calibration illuminant, and neutral balance are deliberately transparent interoperability metadata, not a claim of measured scanner calibration.

A normal DNG/LibRaw-family importer is expected to open the first IFD as the uninverted RGB negative. It should not need to understand the infrared extension. When IR was captured, TIFF tag 330 points to a same-size, 16-bit BlackIsZero SubIFD. That SubIFD carries private ASCII tag 65001 with `scanstudio.infrared.linear.uint16.v1`; a TIFF-aware NegPy or other scanner converter can follow tag 330 and verify tag 65001 before consuming the IR samples. Generic raw processors are expected to ignore the SubIFD and are not expected to perform IR dust removal from it.

The four-channel TIFF uses RGB photometric interpretation, `SamplesPerPixel=4`, and `ExtraSamples=0`; its sample order is R, G, B, IR. Software with incomplete multi-sample TIFF support may reject or ignore the IR channel, which is why the explicit RGB-only TIFF choice exists.

Unit tests parse the produced IFDs back, follow the DNG SubIFD, assert tag values, and compare nontrivial 16-bit fixtures sample-for-sample, including zero and 65535. Simulator output implements the same observable container layout without adding a dependency.

## Fail-closed behavior

Every possible real output path, including raw output and per-frame overrides, is normalized, collision-checked, and exclusively reserved before scanner motion. Encoding uses that reservation's open, identity-checked descriptor. A raw path enters a receipt only after the full encode, DNG LinearRaw patch, flush, and sync succeed. A failed write removes only the bridge-owned incomplete reservation and cannot emit a successful frame completion.

The engine independently validates the bridge's returned raw path against the materialized recipe before it persists success or retires private capture evidence. Simulator publication uses a same-directory temporary file and create-only final publication.

## Files changed and current line counts

The user prohibited git commands, so these are current whole-file line counts, not added/deleted diff statistics.

### Design and protocol documentation

- `DNG-PLAN.md` — 173 lines before this report's final reconciliation check.
- `app/ScanStudio/protocol/PROTOCOL.md` — 335 lines.
- `app/ScanStudio/protocol/BRIDGE.md` — 429 lines.
- `DNG-REPORT.md` — see the final line-count note at the end of this file.

### CoolscanPy writer and tests

- `coolscanpy/src/coolscanpy/io/encoders.py` — 420 lines.
- `coolscanpy/tests/io/test_encoders.py` — 384 lines.

### Python bridge and tests

- `bridge/src/scanstudio_bridge/domain.py` — 416 lines.
- `bridge/src/scanstudio_bridge/transport/output_reservation.py` — 402 lines.
- `bridge/src/scanstudio_bridge/transport/coolscanpy_transport.py` — 1,088 lines.
- `bridge/src/scanstudio_bridge/transport/mock.py` — 577 lines.
- `bridge/tests/test_domain.py` — 452 lines.
- `bridge/tests/test_transport_coolscanpy.py` — 2,535 lines.
- `bridge/tests/test_transport_mock.py` — 868 lines.

### Rust engine and tests

- `app/ScanStudio/engine/src/domain.rs` — 2,013 lines.
- `app/ScanStudio/engine/src/bridge_protocol.rs` — 996 lines.
- `app/ScanStudio/engine/src/render.rs` — 5,783 lines.
- `app/ScanStudio/engine/src/real_backend.rs` — 6,218 lines.
- `app/ScanStudio/engine/src/manifest.rs` — 1,654 lines.
- `app/ScanStudio/engine/src/sim.rs` — 2,209 lines.
- `app/ScanStudio/engine/src/exiftool.rs` — 582 lines.
- `app/ScanStudio/engine/src/server.rs` — 3,839 lines.
- `app/ScanStudio/engine/src/bin/mock_bridge.rs` — 1,252 lines.
- `app/ScanStudio/engine/tests/real_backend_mapping.rs` — 2,574 lines.

### Swift app and tests

- `app/ScanStudio/Sources/ScanStudioKit/WireProtocol.swift` — 1,557 lines.
- `app/ScanStudio/Sources/ScanStudioKit/SessionModel.swift` — 4,596 lines.
- `app/ScanStudio/Sources/ScanStudioKit/CaptureWorkflowSupport.swift` — 392 lines.
- `app/ScanStudio/Sources/ScanStudio/BatchInspectorView.swift` — 1,865 lines.
- `app/ScanStudio/Sources/ScanStudio/FrameDetailWorkspaceView.swift` — 2,043 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/FixtureDecodingTests.swift` — 184 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/ProjectWireProtocolTests.swift` — 541 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/CaptureWorkflowSupportTests.swift` — 150 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/SessionEventPolicyTests.swift` — 3,268 lines.

## Verification results

Final writer and bridge runs:

```text
1545 passed, 3 skipped, 1 xfailed in 270.70s (0:04:30)
298 passed in 1.74s
All checks passed!
All checks passed!
```

Those lines are from `uv run pytest` in `coolscanpy`, `uv run pytest` in `bridge`, and Ruff checks of the touched CoolscanPy paths and the complete bridge `src tests` trees.

The Rust engine's complete suite passed. The principal library summary and raw-path real-backend integration summary were:

```text
test result: ok. 369 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 14.41s
test result: ok. 36 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 3.60s
```

Other Rust test binaries also passed; two existing corpus/hardware-dependent tests remained explicitly ignored.

The sandbox-compatible Swift run excluding the two disk-image update tests passed:

```text
Test run with 421 tests in 43 suites passed after 0.258 seconds.
```

The raw/settings-focused Swift filter also passed:

```text
Test run with 6 tests in 3 suites passed after 0.068 seconds.
```

The requested top-level `make test` was run. Its Rust phase passed, but its unmodified `/usr/bin/swift test` invocation could not compile the package manifest because the nested SwiftPM sandbox cannot start inside this workspace sandbox:

```text
sandbox-exec: sandbox_apply: Operation not permitted
error: ExitCode(rawValue: 1)
make: *** [app-test] Error 2
```

Running SwiftPM with `--disable-sandbox` allows the tests to execute. The unfiltered run then had only two failures, both pre-existing update tests whose fixture setup invokes a blocked macOS disk-image operation:

```text
Executed 59 tests, with 2 failures (2 unexpected) in 2.584 (2.589) seconds
Error Domain=UpdateServiceTests Code=1 "hdiutil create failed (status 1)"
Test run with 421 tests in 43 suites passed after 0.248 seconds.
```

Excluding `UpdateServiceTests` produces the fully green 421-test Swift result above. All feature source and tests compile in both sandbox-compatible invocations.

## Deliberately not done

- No new Python, Rust, or Swift dependency was added.
- No existing Master, Positive, or Preview output was rewritten or redirected.
- No “baked-in raw” mode was added. Dust-cleaning or inversion changes pixels, so the existing Positive output owns that behavior.
- ExifTool is not run on raw negative files. Post-write metadata mutation would weaken the untouched, fail-closed raw contract; the DNG/TIFF writers supply their structural scanner metadata directly.
- No compression was introduced. Uncompressed strips keep the writer small and the byte contract easy to validate, at the cost of larger files.
- No measured scanner-to-XYZ color calibration was invented.
- No physical scanner capture was attempted in the test environment.
- NegPy, dcraw, RawTherapee, darktable, and LibRaw executables were not available in the worktree, and network access was forbidden. No external-application smoke-test claim is made.
- The cross-platform Tauri port was not changed; the requested surface was the macOS SwiftUI app plus its shared Rust engine and Python capture stack.

## Open questions for the owner

1. Should tag 65001 remain a ScanStudio-private IR marker, or should a future release publish a small external interoperability note and reserve a different tag through an appropriate registry?
2. Is there a measured LS-5000 scanner-to-XYZ calibration the project wants to ship later? If so, it can replace the identity matrix without changing raw samples or the IR layout.
3. Which converter/version matrix should be release-gated on real exported frames? A practical manual matrix would include NegPy plus current LibRaw, RawTherapee, and darktable builds.
4. Is uncompressed output the preferred first release tradeoff, or should lossless compression be a later opt-in after converter testing?

Final report line count: 153 lines.
