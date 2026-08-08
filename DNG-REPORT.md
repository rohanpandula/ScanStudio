# Raw DNG and linear TIFF implementation report

## Outcome

Raw export now has a third infrared policy, `sidecar`, for both main formats. With captured IR it writes a fail-closed pair: the untouched RGB main export and a same-size 16-bit grayscale TIFF named `{main-stem}-ir.tif`. The DNG main has no embedded IR SubIFD in this mode; the TIFF main uses the existing RGB-only layout. The sidecar carries the established private ASCII tag 65001 marker `scanstudio.infrared.linear.uint16.v1`, Orientation 1, and capture-matching X/Y resolution in inches.

All established branches remain on their existing encoders and layouts: DNG with embedded IR SubIFD, four-channel RGBI TIFF with `ExtraSamples=0`, and RGB-only TIFF with no IR. Raw export still performs no inversion, color conversion, crop, rotation, flip, Digital ICE, Nikonlook, ICC assignment, rescaling, or requantization.

## Exact option surface

The serialized recipe remains `OutputRecipe.rawExport` with `fileFormat: linearDng|linearTiff` and the compatibility-preserving field `tiffInfrared: fourthChannel|omitted|sidecar`.

| App choice | Recipe | Captured-IR artifacts | No-IR behavior |
| --- | --- | --- | --- |
| Linear DNG / Inside the DNG | `linearDng` + legacy `fourthChannel` or `omitted` | RGB LinearRaw DNG with grayscale IR SubIFD | RGB LinearRaw DNG without SubIFD |
| Linear DNG / Separate grayscale TIFF | `linearDng` + `sidecar` | RGB LinearRaw DNG without SubIFD + `{stem}-ir.tif` | Same RGB-only DNG; no sidecar |
| Linear TIFF / Fourth channel | `linearTiff` + `fourthChannel` | One interleaved RGBI TIFF | Rejected before motion |
| Linear TIFF / Separate grayscale TIFF | `linearTiff` + `sidecar` | Existing RGB-only TIFF + `{stem}-ir.tif` | Same RGB-only TIFF; no sidecar |
| Linear TIFF / Omit (RGB only) | `linearTiff` + `omitted` | Existing RGB-only TIFF | Same RGB-only TIFF |

The Batch inspector and per-frame output editor use plain-English “Infrared” pickers. DNG shows “Inside the DNG” and “Separate grayscale TIFF”; TIFF additionally shows “Omit (RGB only).” A legacy DNG recipe containing `omitted` is displayed as “Inside the DNG” without rewriting the persisted recipe.

## Publication and receipts

The bridge derives the sidecar name only after normalizing and resolving the main target. Both names join the capture-wide, case-folded collision check and are exclusively reserved before motion. The main is encoded, flushed, and synced first; the sidecar is then encoded, flushed, and synced. Neither reservation is marked written until both operations finish. Any main or sidecar exception identity-checks and removes both raw reservations, including a completely written main, and the frame callback never emits a receipt for the pair.

Simulator pairs use synced same-directory temporary files and create-only hard-link publication. If sidecar publication fails after the main final name exists, both pair names are removed. Existing single-file simulator branches retain their prior create-only path.

The bridge receipt adds optional `rawExportIrPath` next to `rawExportPath`. The Rust engine validates both reported paths against its preflight plan before persistence or private-capture cleanup, then records them as `WrittenOutputs.rawNegativePath` and `rawNegativeIrPath`. Swift decodes both paths and defaults the new field to absent for older receipts.

## Test coverage added

- Python domain round trips cover the `sidecar` enum and both bridge receipt paths.
- Bridge reservation tests cover deterministic `-ir.tif` naming, pre-motion sidecar collision cleanup, and no sidecar reservation for RGB capture.
- Mock and real bridge tests byte-parse DNG and TIFF sidecar pairs, checking three-sample main layout, absent DNG SubIFD, one-sample BlackIsZero sidecar, 16-bit values, marker, orientation, matching DPI, and sample-for-sample round trip.
- Failure injection makes the DNG main succeed and the sidecar TIFF write fail; the test proves there is no receipt, main orphan, or sidecar orphan.
- Rust byte parsers cover both sidecar main formats, grayscale sidecar tags/DPI/marker/samples, and the no-IR fallback. A publication hook fails after the main final name exists and proves both final names are removed.
- Rust bridge-plan and integration coverage proves both real-backend receipt paths are validated, persisted, and point to existing files.
- Swift recipe, receipt, session-model, and size-estimator tests cover the new policy and paired path.

## Files changed and current line counts

These are whole-file line counts because Git commands were prohibited; they are not diff statistics.

### Design and protocol

- `DNG-PLAN.md` — 189 lines.
- `DNG-REPORT.md` — see final note.
- `app/ScanStudio/protocol/PROTOCOL.md` — 336 lines.
- `app/ScanStudio/protocol/BRIDGE.md` — 453 lines.

### Python bridge and tests

- `bridge/src/scanstudio_bridge/domain.py` — 464 lines.
- `bridge/src/scanstudio_bridge/transport/output_reservation.py` — 455 lines.
- `bridge/src/scanstudio_bridge/transport/coolscanpy_transport.py` — 1,611 lines.
- `bridge/src/scanstudio_bridge/transport/mock.py` — 732 lines.
- `bridge/tests/test_domain.py` — 459 lines.
- `bridge/tests/test_transport_coolscanpy.py` — 3,301 lines.
- `bridge/tests/test_transport_mock.py` — 1,126 lines.

### Rust engine and tests

- `app/ScanStudio/engine/src/domain.rs` — 2,016 lines.
- `app/ScanStudio/engine/src/bridge_protocol.rs` — 1,186 lines.
- `app/ScanStudio/engine/src/render.rs` — 6,151 lines.
- `app/ScanStudio/engine/src/real_backend.rs` — 6,473 lines.
- `app/ScanStudio/engine/src/sim.rs` — 2,847 lines.
- `app/ScanStudio/engine/src/exiftool.rs` — 583 lines.
- `app/ScanStudio/engine/src/bin/mock_bridge.rs` — 1,351 lines.
- `app/ScanStudio/engine/tests/real_backend_mapping.rs` — 2,590 lines.

### Swift app and tests

- `app/ScanStudio/Sources/ScanStudioKit/WireProtocol.swift` — 1,624 lines.
- `app/ScanStudio/Sources/ScanStudioKit/SessionModel.swift` — 4,777 lines.
- `app/ScanStudio/Sources/ScanStudio/BatchInspectorView.swift` — 1,891 lines.
- `app/ScanStudio/Sources/ScanStudio/FrameDetailWorkspaceView.swift` — 2,058 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/FixtureDecodingTests.swift` — 184 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/ProjectWireProtocolTests.swift` — 543 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/CaptureWorkflowSupportTests.swift` — 157 lines.
- `app/ScanStudio/Tests/ScanStudioKitTests/SessionEventPolicyTests.swift` — 3,268 lines.

No CoolscanPy source file changed. The sidecar writer is bridge-owned and reuses tifffile already present there; DNG main encoding continues to call the existing CoolscanPy writer.

## Verification results

CoolscanPy full suite:

```text
1648 passed, 4 skipped, 1 xfailed in 286.06s (0:04:46)
```

Bridge full suite and Ruff over its touched Python source/tests:

```text
335 passed in 3.13s
All checks passed!
```

Rust full suite, including the principal library, real-backend end-to-end, and real mapping summaries:

```text
test result: ok. 403 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 14.14s
test result: ok. 44 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.70s
test result: ok. 36 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 3.59s
```

Every other Rust test binary passed. The two established real-archive tests remained explicitly ignored because their environment variables and corpus captures were not supplied.

Swift used writable `/tmp` caches, `--disable-sandbox`, and an exact skip regex for only the two disk-image tests whose `hdiutil create` operation is blocked in this sandbox. The other 20 `UpdateServiceTests` ran and passed:

```text
Executed 57 tests, with 0 failures (0 unexpected) in 0.297 (0.301) seconds
Test run with 459 tests in 46 suites passed after 0.252 seconds.
```

## Deliberately not done

- No Git command was run, no GitHub content was posted, and no network access was used.
- No dependency was added and no existing output compression or color metadata policy changed.
- No converter or physical-scanner smoke test was attempted. NegPy, LibRaw, RawTherapee, darktable, and dcraw are not vendored here, so compatibility remains a container-shape expectation rather than an external test claim.
- No standardized DNG meaning for scanner IR was claimed; the existing private, versioned tag remains the opt-in interoperability marker.
- The serialized field was not renamed from `tiffInfrared`, preserving legacy recipes even though `sidecar` now applies to DNG too.
- No empty, synthetic, or placeholder sidecar is emitted when IR was not captured.
- The two `UpdateServiceTests` that require creating disk images were not run; every other Swift test ran green with the sandbox workaround.

Final report line count: 128 lines.
