# ScanStudio

<img src="assets/scanstudio-app-icon.png" alt="ScanStudio app icon" width="128" height="128">

ScanStudio is a free, open-source film-scanning app for **Apple Silicon
(M-series, arm64) Macs running macOS 14 (Sonoma) or newer**. Its supported
Beta workflow is C-41 color-roll scanning with the Nikon SUPER COOLSCAN 5000 ED
(LS-5000): preview the film, choose frames, scan, and review saved images.

## Install and start

1. Open [GitHub Releases](https://github.com/rohanpandula/ScanStudio/releases)
   and choose a published Apple Silicon Beta:
   `ScanStudio-<version>-macOS-arm64.dmg`.
2. Open the DMG, copy **ScanStudio** to **Applications**, and launch it.
3. Connect your LS-5000 over USB and select the real scanner in the app.
   Being listed is discovery evidence; a successful connection and preview
   are separate steps.

The release workflow Developer ID-signs, notarizes, and staples both the app
and DMG. The app includes the hardware bridge, Python runtime, libusb, license
notices, and corresponding GPL source. The supported color-roll workflow and
software eject use direct USB: no Homebrew, SANE, or Nikon driver is required.
The separate legacy plain-scan path needs a compatible system SANE backend;
SANE may also be used for discovery when available.

Intel Macs, Windows, and Linux are **retired ScanStudio platforms**, with no
current builds, updates, or port support. NegPy offers an independent
nkscan-backed Coolscan workflow. Consult [NegPy downloads](https://github.com/marcinz606/NegPy/releases)
and [upstream setup and compatibility guidance](https://github.com/marcinz606/NegPy#readme)
for those systems. Check your scanner, holder, and OS against upstream guidance;
a download alone is not proof of compatibility. Older ScanStudio assets retain
only the support and evidence recorded at their release dates.

<img src="assets/scanstudio-ls5000-offline.jpeg" alt="ScanStudio on macOS with an LS-5000 offered as a Connect target; status OFFLINE, no scanner selected, no simulator or preview shown." width="1000">

## Scan and find your images

1. **Create or open a roll** and choose a writable save folder with enough free
   space for the selected frames and formats. Confirm the real device and holder.
2. **Preview** the film. Check frame count, order, and boundaries before capture.
   Detection can retry with wider limits and offer manual placement; recovered
   or manually placed frames require your approval. Panoramic frames beyond
   the 38.7 mm single-pass capture window are refused rather than cropped.
3. **Choose frames and outputs.** Set the film stock, recipe, orientation,
   naming, and resolution. Retain a Master TIFF, positive TIFF/JPEG, or both.
   Optional raw negative exports include Linear DNG and linear TIFF with infrared options.
4. **Scan** and stay nearby while film moves. Follow the app's progress and any
   readiness or review prompts.
5. **Review saved files.** In the inspector's **Saved roll** section, use
   **Show Roll Folder in Finder** or **Frame N Saved Files** to reveal a
   recorded output. Missing or moved files are reported explicitly. Completion
   counts follow saved receipts; inspect the images as well as the count.

Scanner preview establishes frame placement. Capture reads the selected film
at scan resolution. Positive TIFF/JPEG and generated Preview files are
processed exports; the optional Master TIFF retains the archival capture.
Settings apply to **future scans**: changing a recipe, color style, or crop
does not rewrite existing files or make the scanner preview a live color proof.
Keep a master if you will need it for later rendering work.

The optional **Full Capture Package** adds available settings, receipts,
checksums, and capture evidence alongside the master. Missing evidence is
identified; capture files are not rewritten. See the [app guide](app/ScanStudio/README.md)
and [color guide](app/ScanStudio/COLOR.md) for output and rendering details.

## Stop and recover

- Press **Stop after frame** once and wait for the current frame to finish
  safely and the batch to report stopped. Eject is unavailable during capture.
- Preserve the saved roll, completed images, receipts, and attempt journals.
  For a failure or lost connection, save the technical details or choose
  **Save Diagnostic Bundle…** before following the app's recovery instructions.
- Reopen the same roll when safe. A stopped batch needs a fresh preview;
  refeed first if the app reports shifted or interrupted film. Reconnection
  alone does not restore film position.
- Resolve the current readiness and approval prompts, then use **Resume Batch
  (N remaining)** when enabled. It reads pending frames from the saved project
  and omits completed and excluded frames. Resolve a disabled action's reason
  instead of restarting the whole roll or deleting receipts.

Launching the app does not move film. Preview, Scan, and Eject are explicit
physical operations. Follow [Mac acceptance and recovery](docs/MAC-ACCEPTANCE.md)
for attended operation, diagnostics, and the final full-roll acceptance record.
Simulator stop/reopen/interruption/resume checks do not prove real transport,
focus, framing, color, or dust-removal quality.

## Scanner support

| Scanner | Current scope |
| --- | --- |
| LS-5000 / SUPER COOLSCAN 5000 ED, USB | C-41 color-roll workflow in Beta; retained real preview/capture evidence from one Apple Silicon Mac and one scanner configuration. |
| LS-40 / Coolscan IV ED and LS-50 / Coolscan V ED, USB | Identity recognition only; unsupported for scanning. |
| LS-4000, LS-8000, LS-9000, FireWire | Discovery and a motion-free driver probe through ASFireWire; unsupported for scanning. See [FireWire guidance](coolscanpy/FIREWIRE.md). |

The [hardware evidence matrix](docs/HARDWARE-SUPPORT.md) separates package,
discovery, preview, and capture results. Final attended full-roll hardware
acceptance for beta.15 is **NOT RUN**. Real black-and-white fine scanning
remains blocked; infrared ICE is unsuitable for traditional silver B&W film.
The clearly labeled simulator is for software exploration, not hardware evidence.

## Develop and report problems

See [build, test, and packaging instructions](app/ScanStudio/README.md) and
[release notes and policy](docs/releases/README.md). CoolscanPy is also available for
scripting as `pip install coolscanpy`; see its [driver guide](coolscanpy/README.md).
The release pipeline checks the bundled driver against the authenticated PyPI
source, allowing only explicitly reviewed, hash-pinned differences.

Report problems in [GitHub Issues](https://github.com/rohanpandula/ScanStudio/issues)
with the app version, Mac/macOS, scanner/holder, failed step, and typed error.
Review diagnostic bundles before sharing; keep film images, private paths,
serial numbers, and raw capture journals out of public reports.

## Licenses and references

The app, engine, and documentation are MIT unless a file says otherwise.
The separate `scanstudio-bridge` process and CoolscanPy are **GPL-3.0-only**.
A bundle containing them is a mixed-license distribution: preserve its
licenses, corresponding source, and dependency notices.

NegPy is independent upstream software. ScanStudio's nkscan references are
**documentation-only cleanroom references** to identity and behavioral facts;
no nkscan implementation code or profiles are copied. ASFireWire is likewise
an interface reference, with no source vendored. See [third-party notices](THIRD_PARTY_NOTICES.md).

ScanStudio is not affiliated with Nikon. Nikon, Coolscan, SUPER COOLSCAN,
Nikon Scan, and Digital ICE belong to their respective trademark owners.
