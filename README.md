# ScanStudio

<img src="assets/scanstudio-app-icon.png" alt="ScanStudio app icon" width="128" height="128">

<img src="assets/scanstudio-ls5000-offline.jpeg" alt="ScanStudio running on macOS with an LS-5000 ED offered by the bridge as a Connect target. No scanner is selected, the status is OFFLINE, the simulator is absent, and no media or preview data is shown." width="1000">

ScanStudio is a free, open-source film-scanning app for Nikon Coolscan
scanners on Apple Silicon (M-series) Macs, built first around the SUPER COOLSCAN 5000 ED (LS-5000). It covers
the practical Nikon Scan workflow on macOS 14 (Sonoma) or newer: identify the loaded
holder, preview the film, choose frames, set the recipe and outputs, scan, and
stop safely when needed. When detection cannot find your frames, it works with
you -- an automatic wider retry, a plain-English explanation of what the film
measures, and full manual frame placement -- instead of just refusing.

The screenshot above is the installed app with an LS-5000 ED detected through
the bridge and offered as a Connect target: not connected, status OFFLINE,
simulator absent, no media or preview shown.

## Scanner compatibility

| Scanner | Connection | Status today |
| --- | --- | --- |
| SUPER COOLSCAN 5000 ED (LS-5000) | USB | Full workflow. Real-film validated on Apple Silicon macOS (Beta). |
| Coolscan IV ED (LS-40) / Coolscan V ED (LS-50) | USB | Detected and named, not yet driven. Triage in [#27](https://github.com/rohanpandula/ScanStudio/issues/27). |
| LS-4000 ED, LS-8000 ED, SUPER COOLSCAN 9000 ED | FireWire | Discovery, identity, and a motion-free probe on modern macOS through the [ASFireWire](https://github.com/mrmidi/ASFireWire) driver. Scanning is not wired up yet; probe output from real hardware is what unlocks it -- see [#28](https://github.com/rohanpandula/ScanStudio/issues/28) and the driver's [FIREWIRE.md](coolscanpy/FIREWIRE.md). |

Real scanning has been validated end-to-end on one Apple Silicon Mac and one
LS-5000. Treat everything else as narrow results rather than a promise for
every scanner, adapter, computer, or film holder. The hardware bridge can move
film, so stay nearby and supervise any real job. The canonical [hardware and
platform evidence matrix](docs/HARDWARE-SUPPORT.md) separates package,
enumeration, preview, and capture evidence. Reports from setups unlike the
tested one are the most useful thing you can send.

## Platform support

ScanStudio is **Apple Silicon only** (M-series, arm64), on **macOS 14
(Sonoma) or newer**. The LS-5000 color-roll workflow is Beta, with real-film
evidence from one Apple Silicon Mac and one scanner configuration.

Intel Macs, Windows, and Linux are retired ScanStudio platforms: no current
builds, downloads, updates, or ongoing port support. For those systems, see
[NegPy downloads](https://github.com/marcinz606/NegPy/releases) and the
[upstream setup and compatibility documentation](https://github.com/marcinz606/NegPy#readme).
NegPy's [0.55.0 release notes](https://github.com/marcinz606/NegPy/releases/tag/0.55.0)
introduced Nikon Coolscan scanning through nkscan. As checked on 2026-09-06,
[NegPy 0.57.0](https://github.com/marcinz606/NegPy/releases/tag/0.57.0) provides
Intel and Apple Silicon DMGs, a Windows installer, and a Linux AppImage.
Available downloads do not establish compatibility with your scanner, holder,
or OS; follow upstream guidance for your setup.

Older ScanStudio assets and [release notes](docs/releases/README.md) preserve
the platforms and evidence from their release dates. They are historical
records, not the current support promise.

## Download

Get the **Apple Silicon (M-series) Beta** from
[GitHub Releases](https://github.com/rohanpandula/ScanStudio/releases):
`ScanStudio-<version>-macOS-arm64.dmg`. Choose this arm64 DMG; older Intel,
Windows, and Linux assets are historical only.

Current release DMGs are Developer ID signed, notarized, and stapled. The
updater uses the arm64 feed entry and verifies the download and publisher
identity; release provenance must bind the assets to the same run and exact
tag. See [update verification](docs/AUTO-UPDATE.md). There is no release-schedule
promise.

A release DMG contains the app, the GPL hardware bridge and CoolscanPy source
required for redistribution, and the applicable dependency notices. The
supported LS-5000 color-roll workflow uses the signed libusb copy inside the
app, so installing ScanStudio does not require Homebrew, SANE, or a Nikon
driver. Software eject is likewise direct over USB (the traced unload
sequence, with typed failures and presence confirmation) and needs no SANE.
Only the legacy plain-scan path still requires a system SANE backend, which
also remains how SANE-based discovery lists scanners.

For scripting, or for running the FireWire probe without the app, the bundled
driver is also published on its own:
[`pip install coolscanpy`](https://pypi.org/project/coolscanpy/). Every
ScanStudio release ships in lockstep with the matching coolscanpy release --
the pipeline refuses to build until the exact bundled driver is on PyPI -- so
the app and the package always carry the same driver code.

## What it does

- Detects the reported carrier and media when the scanner can provide them, keeping simulator and real hardware visibly distinct.
- Previews the roll or strip, presents a contact sheet, and supports selected-frame or batch scanning with a Stop control.
- When frame detection fails, retries with wider limits, explains in plain English what the film actually measures (half-frame, narrow gaps, fogged or dense base, blocked film window), and offers manual frame placement -- dragged boundaries flow through the same physical checks as automatic detection, and anything recovered or hand-placed always requires your approval before scanning.
- Keeps scan settings, film stock, recipes, camera and lens metadata, naming, and save location together.
- Writes positive TIFF or JPEG outputs, an optional high-bit-depth master TIFF for archival work, and optional raw negative exports: a Linear DNG (one file, untouched 16-bit negative, infrared dust plane embedded as a marked sub-image) or a linear TIFF with the infrared plane as a fourth channel, a sidecar file, or omitted.
- Renders C-41 color through named styles: **Nikon Scan** (the default -- with matching builder inputs its output replays Nikon's own rendering byte-for-byte) plus experimental alternates (a gentler Noritsu-style look and a Flextight-style look). Styles only change the positive rendering; the archival scan is never touched.
- Uses Digital ICE only where a suitable infrared channel is available. For traditional silver black-and-white film, infrared ICE stays disabled and software dust cleanup is a separate option.
- Records receipts -- including authoritative per-frame timing -- so a finished scan can be reviewed after the job completes.

## Preview, capture, and processed exports

**Scanner preview** reads the film for a contact sheet and frame registration;
it is not the finished positive. **Capture** acquires the selected frames at
scan resolution. **Processed exports** render positive TIFF/JPEG files from
that capture using the job's recipe; an optional Master TIFF remains separate.
A generated Preview file is a rendered derivative, distinct from the scanner
preview used to place frames.

Settings apply to **future scans**. Changing a recipe, color style, or output
setting does not reprocess existing exports or turn the scanner preview into
a live proof of the finished image. Review the saved outputs after capture.

## What is a Coolscan?

A Coolscan is a dedicated film scanner. It reads a negative or slide directly
instead of photographing it with a camera. The LS-5000 is older hardware, but
its 4000 dpi film scans and infrared capability on many color films still make
it useful. ScanStudio supplies a current workflow around that hardware; the
compatibility table above is the honest statement of what is driven today.

## The 1:1 archive bundle

ScanStudio can create an optional archive bundle for a completed frame. It is
a record of the capture, not a substitute for the image. Depending on what the
job actually produced, it can include the separate RGB master, conditional
infrared and meter or prepass evidence, effective settings and alignment,
engine and bridge receipts, bridge attempt journals only when their exact
evidence root is reported, and a manifest with checksums.

The bundle names missing evidence instead of inventing it. It does not replace
or rewrite the capture files.

## Safety and limits

See [Mac acceptance and recovery](docs/MAC-ACCEPTANCE.md) for the packaged
software gate and attended hardware checks. Simulator acceptance is not
evidence of a successful real scan.

- Preview establishes the current registration. Preview again after a refeed or ejection.
- If Capture reports that the film shifted, physically refeed it and acquire a fresh preview; ScanStudio discards the old frame registration so it cannot be retried accidentally.
- Confirm that the app identifies a real scanner before treating it as hardware. The built-in simulator is for safe workflow exploration only.
- Keep physical film transport under supervision. Stop and inspect the scanner if the physical state is uncertain.
- Opening ScanStudio does not move film. Only explicit Preview, Scan, and Eject actions can move film; developer bridge sessions require the documented hardware authorization.
- Manual placement caps frames at the scanner's single-pass capture window (38.7 mm); panoramic frames refuse with an explanation instead of silently cropping.
- Do not post scans, private paths, device serial numbers, or raw capture journals in a public issue.

## Source and feedback

Source: <https://github.com/rohanpandula/ScanStudio>

Issues: <https://github.com/rohanpandula/ScanStudio/issues>

## License boundary

The ScanStudio app, engine, site, and documentation in this repository are
offered under MIT unless a file says otherwise. Real scanner access uses a
separate `scanstudio-bridge` program and its CoolscanPy dependency, both
GPL-3.0-only. The bridge is not part of the MIT-only app boundary.

Any distribution that includes the bridge must keep its GPL-3.0-only license,
corresponding source, and applicable dependency notices with that
distribution. Do not describe such a bundle as MIT-only.

Third-party behavioral references (the nkscan identity facts and the
ASFireWire interface facts) are documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); no source code from either
project is vendored.

ScanStudio is independent software. Nikon, Coolscan, SUPER COOLSCAN, Nikon
Scan, and Digital ICE are trademarks or registered trademarks of their
respective owners. No affiliation or endorsement is claimed.
