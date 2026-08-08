# Raw DNG and linear TIFF export plan

## Goal and interpretation

ScanStudio has one optional **Raw negative** output alongside the existing Master TIFF, Positive, and Preview outputs. The raw output is disabled by default, so old projects and scans keep their current files and byte layout. When enabled, the operator chooses one of:

- **Linear DNG (IR inside file)**: untouched 16-bit RGB scanner samples in the DNG raw image, plus the untouched 16-bit infrared plane in an embedded SubIFD.
- **Linear DNG + separate IR**: the same three-sample DNG main IFD with no IR SubIFD, plus a paired 16-bit grayscale TIFF.
- **Linear TIFF (RGB + IR)**: untouched 16-bit samples interleaved as R, G, B, IR.
- **Linear TIFF + separate IR**: the same RGB-only TIFF plus a paired 16-bit grayscale TIFF.
- **Linear TIFF (RGB only)**: untouched 16-bit RGB samples with infrared omitted.

The issue's “baked in” wording is interpreted as the processed Positive path ScanStudio already has: Digital ICE may use IR there and the negative may be inverted/rendered. It will not be presented as a raw option because calling an IR-cleaned or inverted image “raw” would be misleading. The raw infrared policies are “inside the main file,” “separate grayscale TIFF,” and, for linear TIFF, “omitted”; the UI points people who want an IR-cleaned result to Positive.

All five choices preserve the stored capture orientation recorded by `storageTransform`. They do not crop, rotate, flip, invert, run Digital ICE, apply Nikonlook, assign an ICC profile, rescale, or requantize the real scanner data.

## Existing flow and export hook

The real capture flow today is:

1. CoolscanPy's single-pass workflow decodes scanner records into contiguous `numpy.uint16` RGB and IR arrays. The returned `Frame` also carries the capture receipt and its versioned `storage_transform`.
2. `scanstudio_bridge.transport.coolscanpy_transport` receives those arrays and writes an RGB Master TIFF plus separate IR and optional meter TIFFs through `OutputReservations`. Every possible path is exclusively reserved before scanner motion.
3. The bridge emits the written paths in `ScanReceipt`.
4. The Rust real backend validates those paths, reads the RGB/IR capture pair for Positive and Preview rendering, persists an engine receipt, optionally packages capture evidence, and only then retires a private capture workspace when Master retention was off.

Raw export hooks into step 2, while the original `uint16` arrays are still available. This is the narrowest place that can guarantee the promised untouched samples without decoding an intermediate image. The bridge reserves every raw target in the same pre-motion output group as RGB, IR, and meter, writes it before reporting the frame complete, and includes the final path or pair in the bridge receipt. A failed raw write therefore cannot produce a successful frame event. Fully written capture evidence remains recoverable, while incomplete raw reservations are identity-checked and removed.

The Rust engine owns the user recipe, naming, collision preflight, per-frame overrides, receipt persistence, and private-capture lifecycle. It translates the effective raw recipe into the bridge output plan and records the returned path or pair under `WrittenOutputs.rawNegativePath` and `rawNegativeIrPath`. The deterministic Rust simulator writes the same container contracts from its synthetic source raster so simulator-only app and engine tests exercise the option; simulated IR is test data and is always identified by the receipt's existing `simulated` flag.

## Recipe, settings, and UI surface

The engine and Swift wire model have an additive `RawExportRecipe` at `OutputRecipe.rawExport`:

- `enabled`, default `false` for old manifests and clients.
- `fileFormat`: `linearDng` or `linearTiff`, default `linearDng`.
- `tiffInfrared`: `fourthChannel`, `omitted`, or additive `sidecar`, default `fourthChannel`. The historical field name remains unchanged for recipe compatibility. For DNG, `sidecar` selects the new pair while both legacy values retain embedded-IR behavior.
- independent `filenameTemplate` and `destination`, following Archive/Positive/Preview.

Raw export counts as a retained output. The engine and Swift retention guards allow Master, Positive, and Preview all to be off when Raw negative is on, but still reject a recipe with every output off. Filename materialization, auto-sequence reservation, case-insensitive alias detection, per-frame output overrides, project defaults/migration, and receipt normalization include the new output by following the existing recipe patterns.

The Batch Settings inspector and per-frame output editor have a **Raw negative** disclosure with a format picker and a context-sensitive infrared picker. Together they expose:

- “Linear DNG — IR embedded”
- “Linear DNG — separate grayscale TIFF”
- “Linear TIFF — RGB + IR”
- “Linear TIFF — separate grayscale TIFF”
- “Linear TIFF — RGB only”

The explanatory copy will say that these are uninverted, unprocessed scanner samples and that Positive is the place for an IR-cleaned rendered image. Raw output gets its own default folder name and participates in the shared save location and filename template. It remains off on fresh installs and on projects whose saved recipe predates the field.

RGB-only captures cannot supply IR. The deliberate sidecar fallback is to behave exactly like the corresponding no-IR sibling: DNG contains the untouched RGB main image with no IR SubIFD; TIFF contains the untouched RGB-only main image; neither reserves, writes, nor receipts a `-ir.tif` path. Linear TIFF “RGB + IR” still fails closed if the requested capture receipt has no IR rather than silently emitting three channels under a four-channel choice.

## Linear DNG layout

The file is classic little-endian TIFF/DNG with uncompressed strips. Real files are written by the in-repository CoolscanPy/tifffile encoder; the simulator uses an in-repository Rust encoder with the same observable tag and sample contract. No dependency is added.

### Main IFD: converter-facing raw negative

- `NewSubfileType` (254): `0`. The deprecated `SubfileType` (255) is not emitted. LibRaw-family readers reject otherwise-valid generated DNGs when the main raw IFD does not explicitly identify itself as the full-resolution image.
- `ImageWidth`, `ImageLength`: stored capture raster dimensions.
- `BitsPerSample`: `16,16,16`.
- `Compression`: `1` (none).
- `PhotometricInterpretation`: `34892` (`LinearRaw`).
- `SamplesPerPixel`: `3`, interleaved R, G, B.
- `PlanarConfiguration`: `1` (chunky).
- `SampleFormat`: unsigned integer through TIFF 6.0's default value of `1`; the redundant tag is not emitted.
- `Orientation`: `1`; orientation ownership remains in the receipt's `storageTransform`, and no export-time transform is applied.
- `XResolution`, `YResolution`, `ResolutionUnit`: capture DPI in pixels per inch.
- `Make`: `Nikon`.
- `Model`: the receipt's scanner model.
- `Software`: `ScanStudio`.
- `DNGVersion` (50706): `1,4,0,0`.
- `DNGBackwardVersion` (50707): `1,1,0,0`. LinearRaw entered the baseline in DNG 1.1; the private IR SubIFD is ignorable by a 1.1 reader.
- `UniqueCameraModel` (50708): a stable Nikon scanner model string derived from the receipt model.
- `BlackLevel` (50714): zero for all three channels.
- `WhiteLevel` (50717): 65535 for all three channels.
- `DefaultScale` (50718): 1:1 in both axes.
- `DefaultCropOrigin` (50719): `0,0`.
- `DefaultCropSize` (50720): full width and height.
- `ActiveArea` (50829): `0,0,height,width`.
- `AsShotNeutral` (50728): `1,1,1`; no capture-time white balance is applied.
- `CalibrationIlluminant1` (50778): `0` (unknown).
- `ColorMatrix1` (50721): a 3x3 identity SRATIONAL matrix. ScanStudio has no measured LS-5000 scanner-to-XYZ calibration to publish. Omitting the matrix causes stricter DNG consumers to refuse an otherwise usable color DNG; publishing an sRGB or camera matrix would make a false calibration claim and steer negative pixels through an invented transform. Identity is therefore an explicit interoperability placeholder, paired with an unknown illuminant and neutral balance. It changes no stored samples, and converter-specific scanner profiling remains the right place for real color characterization.
- `SubIFDs` (330): one offset when IR exists and the policy is embedded; absent for RGB-only capture and `sidecar`.

The main IFD deliberately has no `ExtraSamples`. This preserves three plain color samples, matching the existing pidng-derived convention in this repository. LibRaw/dcraw-family readers, and applications built on them such as RawTherapee and darktable, are much more likely to accept a three-sample LinearRaw main image than a four-sample LinearRaw image whose photometric sample count is ambiguous. Those applications are expected to open and process the RGB negative while ignoring the private IR SubIFD. NegPy or another TIFF-aware converter can additionally locate and consume the embedded IR plane.

This plan does not claim that generic raw processors will perform dust removal from the embedded IR plane. DNG 1.4 has no standardized scanner-infrared role. The interoperability goal is that the RGB raw opens normally and the IR remains inside the same durable container for software that understands ScanStudio's marker.

### Infrared SubIFD

- Referenced only through the main IFD's `SubIFDs` tag; it is not in the top-level TIFF page chain.
- Same `ImageWidth` and `ImageLength` as the main RGB image.
- `NewSubfileType`: `0`. It is full resolution and is not mislabeled as a transparency mask or reduced preview.
- `BitsPerSample`: `16`.
- `Compression`: `1`.
- `PhotometricInterpretation`: `1` (`BlackIsZero`).
- `SamplesPerPixel`: `1`.
- `SampleFormat`: unsigned integer through TIFF 6.0's default value of `1`; the redundant tag is not emitted.
- `Orientation`: `1`.
- `XResolution`, `YResolution`, `ResolutionUnit`: the same capture DPI.
- `ImageDescription`: plain text identifying an untouched scanner infrared plane.
- private tag `65001`: ASCII marker `scanstudio.infrared.linear.uint16.v1` so a TIFF-aware importer can distinguish it from an arbitrary auxiliary image without guessing.

A SubIFD is chosen instead of a fourth main-image `ExtraSample`. TIFF's `ExtraSamples=0` can honestly label a non-alpha auxiliary sample, but DNG defines `LinearRaw` around color planes and does not standardize IR. Keeping IR out of the converter-facing three-channel IFD prevents raw engines from treating R/G/B/IR as an unknown four-color camera or one color channel plus three auxiliaries.

### Separate infrared TIFF

For either main format, `tiffInfrared=sidecar` writes captured IR to `{main-stem}-ir.tif` in the same destination. The sidecar is classic little-endian TIFF, full-resolution, uncompressed, unsigned 16-bit, one-sample `BlackIsZero`, chunky, Orientation 1, and has the same X/Y resolution and inch unit as the main export. It carries `ImageDescription` identifying the untouched scanner plane and private ASCII tag 65001 with `scanstudio.infrared.linear.uint16.v1`. The main DNG has no `SubIFDs` tag; the main TIFF has the existing RGB-only layout.

## Linear TIFF layout

Both TIFF modes use classic little-endian TIFF, unsigned 16-bit samples, no compression, chunky organization, capture DPI tags, Orientation 1, and no ICC profile. Pixels retain capture orientation and values.

- **RGB only**: `PhotometricInterpretation=RGB`, `SamplesPerPixel=3`, `BitsPerSample=16,16,16`, and no `ExtraSamples`.
- **RGB + IR**: samples are interleaved R,G,B,IR; `PhotometricInterpretation=RGB`, `SamplesPerPixel=4`, `BitsPerSample=16,16,16,16`, and `ExtraSamples=0` for the one IR channel. “Unspecified” is intentional: IR is neither associated nor unassociated alpha.
- **RGB + separate IR**: the main file is the existing RGB-only layout and the infrared plane uses the separate TIFF contract above.

The four-channel TIFF also carries private tag 65001 with the same infrared marker. Software that only understands RGB may ignore or reject the fourth sample; that is why RGB-only is an explicit alternative rather than a silent fallback.

## Fail-closed publication and compatibility

- Every real-hardware raw target is resolved and exclusively reserved with the capture group before progress or motion. Cross-slot, cross-output, case-only, symlink, and existing-file collisions fail before scanning.
- Data is encoded through already-open reservations. For a pair, the main and sidecar are each fully encoded, flushed, and synced before either reservation is marked written. Any exception removes both identity-owned raw reservations, even when the main write already completed, and does not emit `scan.frameCompleted`.
- Simulator raw output is encoded into unique same-directory siblings, flushed and synced, and published create-only. Pair publication removes both final names if the sidecar step fails after the main name was published.
- Both raw receipt paths are validated against the effective engine recipe before the engine opens sources, persists success, or cleans a private capture. Bridge receipts use `rawExportPath`/`rawExportIrPath`; persisted engine/app receipts use `rawNegativePath`/`rawNegativeIrPath`.
- Existing Master/Positive/Preview naming and bytes are unchanged when `rawExport.enabled` is false. Default serialization/deserialization is additive.

## Tests

### CoolscanPy writer

- Parse the main DNG IFD and assert all required TIFF/DNG tags and exact types/values.
- Assert main `SamplesPerPixel=3`, no `ExtraSamples`, `PhotometricInterpretation=LinearRaw`.
- Follow `SubIFDs`, assert its grayscale/marker layout, and prove it is not a top-level page.
- Round-trip a small nontrivial `uint16` RGB+IR fixture and compare every sample, including zero, midrange, and 65535.
- Assert RGB-only DNG omits `SubIFDs`.
- Inject encoder/patch failures and assert no final DNG is published.

### Bridge

- Domain/wire decoding defaults absent raw output to disabled/no export.
- Output reservation tests cover `.dng`/`.tif` normalization, raw-vs-capture and cross-slot collisions, per-slot overrides, and cleanup after a partial raw write.
- Mock and real-transport tests assert raw writes happen before frame completion and receipts contain the validated raw path.
- Parse bridge-produced DNG/TIFF files and assert tag layout, exact 16-bit RGB round-trip, and exact IR placement.
- Parse both DNG and TIFF `-ir.tif` sidecars and assert grayscale tag layout, marker, matching DPI, deterministic naming, and exact 16-bit IR round-trip.
- Assert four-channel TIFF uses one unspecified `ExtraSamples` value; RGB-only has three samples and no extra sample.
- Inject a sidecar write failure after the main succeeds and assert no receipt, main file, sidecar file, or untouched raw reservation remains.

### Rust engine

- Serde round trips and legacy JSON defaults for `RawExportRecipe`.
- Retention validation accepts raw-only and rejects all-off.
- Naming, auto-sequence, alias, per-frame override, real bridge-plan, path-validation, manifest migration, and receipt tests include raw output.
- Parse simulator-produced DNG/TIFF bytes with a small test-only TIFF parser and assert tag values, SubIFD linkage, sample round-trip, and IR placement.
- Parse simulator sidecar bytes and assert one-sample 16-bit layout, marker, DPI, and sample round-trip; inject failure after main publication and assert both final names are absent.
- Real-backend integration tests assert bridge raw paths are persisted and a failed/mismatched raw path cannot count as completion or trigger private-source cleanup.

### Swift app

- Codable legacy-default and round-trip tests for the new recipe enums and struct.
- Receipt Codable tests cover both paired paths and legacy absence.
- Session-model tests assert UI state becomes the expected wire recipe, project load restores it, project creation preserves a pre-save choice, shared naming/location includes it, and raw-only satisfies retention.
- Size-estimator and policy tests cover DNG/RGBI TIFF versus RGB TIFF.

### Verification commands

- `cd coolscanpy && uv run pytest`
- `cd bridge && uv run pytest`
- `cd app/ScanStudio/engine && cargo test`
- `cd app/ScanStudio && CLANG_MODULE_CACHE_PATH=/tmp/scanstudio-dng-swift/clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/scanstudio-dng-swift/swiftpm XDG_CACHE_HOME=/tmp/scanstudio-dng-swift swift test --disable-sandbox --scratch-path /tmp/scanstudio-dng-swift/scratch --skip 'UpdateServiceTests/(testMountLocateApp|testMountLocateAppNoAppThrows)'`
- Ruff over touched Python paths in CoolscanPy and the bridge.

Converter binaries are not vendored in this worktree and network access is forbidden, so automated tests cannot launch NegPy, dcraw, RawTherapee, or darktable here. Compatibility is based on the repository's existing pidng/LibRaw constraints and will be reported as an expectation, not as a claim of an external smoke test.

## Risks and open design consequences

- There is no standard DNG role for scanner IR. The private marker is intentionally simple and versioned; consumers must opt in.
- Identity `ColorMatrix1` maximizes structural acceptance but is not scanner calibration. A measured LS-5000 profile can replace it in a later version without changing pixels or IR layout.
- Uncompressed RGB+IR is large. Embedded, fourth-channel, and sidecar variants are all roughly four 16-bit samples per pixel plus small metadata overhead; sidecar mode trades one-file convenience for broader converter access to the grayscale plane.
- A real frame may have a bridge-written Master pair and a raw export. Filesystem publication is atomic per file, not across every filename in the frame. The frame is reported complete only after all requested files finish; receipts and recovery evidence distinguish a recoverable capture from a successful requested output set.

## Deviations during implementation

- The historical `tiffInfrared` wire/property name is retained even though `sidecar` also applies to DNG. Renaming it would churn existing serialized recipes; the UI uses plain “Infrared” copy instead.
- The UI uses a two-choice format picker plus a context-sensitive infrared picker: DNG shows “Inside the DNG” and “Separate grayscale TIFF”; TIFF additionally shows “Omit (RGB only).” A legacy DNG recipe carrying `omitted` continues to encode embedded IR and is displayed as “Inside the DNG.”
- The writers rely on TIFF 6.0's default `SampleFormat=1` rather than emitting the redundant tag. Parsed samples are still unsigned 16-bit values, and byte-level tests round-trip them exactly.
- The standalone CoolscanPy helper publishes by same-directory atomic replacement. In the bridge, the writer instead uses the already-open, identity-checked exclusive reservation so it cannot replace a path after pre-motion collision checks. It is marked successful only after encoding, the LinearRaw patch, flush, and sync complete.
- Verification could not execute third-party converter binaries because none are vendored and network access is forbidden. Compatibility claims remain expectations based on the documented IFD shape. The two `UpdateServiceTests` that create disk images also cannot run inside this sandbox; every other Swift test passed.
