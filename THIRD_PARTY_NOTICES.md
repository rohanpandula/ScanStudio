# Third-party notices

This file describes the licensing boundary for the public source repository and for any future binary release. It is a notice guide, not legal advice.

## Project-owned material

The repository's original ScanStudio source, documentation, and structured inventory are offered under the [MIT License](LICENSE), except where a more specific file says otherwise. That license does not grant rights to Nikon software, firmware, manuals, trademarks, private evidence, or third-party components.

The repository intentionally does not distribute Nikon executables, drivers, firmware, profiles, or manuals.

## Hardware bridge and corresponding source

Real LS-5000 access is provided through the `scanstudio-bridge` executable and
CoolscanPy. Their complete source trees live in this repository under
`bridge/` and `coolscanpy/`, and both are GPL-3.0-only. `make package` bundles
the helper for a local working app, so a packaged `ScanStudio.app` is a
mixed-license distribution and is not covered by this repository's MIT license
alone.

Do not label a bundle that includes the bridge as MIT-only. The package script places the bridge and CoolscanPy GPL texts under `Contents/Resources/Licenses`, and complete source snapshots under `Contents/Resources/CorrespondingSource`. CPython 3.13's license and the visible metadata/license material for every included Python wheel live in the same `Licenses` directory. Preserve those locations in any copied or redistributed app.

The bundle dynamically loads libusb 1.0.30 from
`Contents/Frameworks/coolscanpy/_native`. It is licensed
LGPL-2.1-or-later; the exact license and build notice are under
`Contents/Resources/Licenses`, and the complete hash-pinned upstream source
archive, exact build script, and rebuild instructions are under
`Contents/Resources/CorrespondingSource/libusb`. The library
is built for the app's declared macOS deployment target before signing, and
the package check proves a relocated bundled Python process resolves that
exact app-owned file rather than a Homebrew copy.

The bundle also includes `python-sane` for CoolscanPy's optional plain-scan
and software-eject paths. It deliberately does **not** include an operating-
system SANE backend; the bundled `_sane` extension expects a compatible host
`libsane.1.dylib` when one of those optional paths is used. The supported
LS-5000 color-roll workflow does not require SANE: discovery and connection
fall back to direct USB when SANE is absent, while status, preview, and color
capture use direct USB. A missing optional backend must remain a clear
operation failure, never a simulated successful connection.

## Nikon Coolscan USB identity table (reference)

CoolscanPy's USB discovery recognizes Nikon Coolscan units by vendor/product id.
The PID-to-model mapping (LS-40 `04b0:4000`, LS-50 `04b0:4001`, LS-5000
`04b0:4002`) is referenced from the `nkscan` project by activexray, licensed
Apache-2.0, at commit `87a1724886f8262e7791731ca055aa00ad6632fb`
(`src/scanners/ls40.rs`, `src/scanners/ls50/mod.rs`, `src/scanners/ls5000/mod.rs`;
`src/devices.rs` round-trip tests). This is a reference to the USB identity
facts only; no `nkscan` source code is vendored.

## Rust engine dependencies

The macOS app package includes the Rust engine, and its compiled binary includes Rust dependency code. The current locked dependency set uses the licenses shown below. `Cargo.lock` is the source of the version set; these SPDX expressions come from the resolved package metadata.

| Package | Version | SPDX license expression |
|---|---:|---|
| image | 0.25.10 | MIT OR Apache-2.0 |
| imageproc | 0.27.0 | MIT |
| moxcms | 0.8.1 | BSD-3-Clause OR Apache-2.0 |
| serde | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.151 | MIT OR Apache-2.0 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 |
| tiff | 0.11.3 | MIT |

The same lockfile also resolves the following transitive packages. This is a conservative whole-lockfile inventory, so a specific production binary may link fewer packages. Preserve the applicable license choices and copyright notices for every package actually included in the binary you distribute:

| License expression | Resolved packages |
|---|---|
| Apache-2.0 | approx 0.5.1; nalgebra 0.35.0; simba 0.10.0 |
| BSD-2-Clause OR Apache-2.0 OR MIT | zerocopy 0.8.55; zerocopy-derive 0.8.55 |
| BSD-3-Clause OR Apache-2.0 | pxfm 0.1.30 |
| MIT | crunchy 0.2.4; fax 0.2.7; generic-array 0.14.7; imageproc 0.27.0; libm 0.2.16; simd-adler32 0.3.10; zmij 1.0.23 |
| MIT OR Apache-2.0 | autocfg 1.5.1; bitflags 2.13.1; block-buffer 0.10.4; bumpalo 3.20.3; cfg-if 1.0.4; chacha20 0.10.1; cpufeatures 0.2.17 and 0.3.0; crc32fast 1.5.0; crypto-common 0.1.7; digest 0.10.7; either 1.16.0; fdeflate 0.3.7; flate2 1.1.9; getrandom 0.4.3; glam 0.30.10, 0.31.1, 0.32.1, and 0.33.2; half 2.7.1; image 0.25.10; itertools 0.14.0; itoa 1.0.18; js-sys 0.3.103; libc 0.2.189; num 0.4.3; num-bigint 0.4.8; num-complex 0.4.6; num-integer 0.1.46; num-iter 0.1.46; num-rational 0.4.2; num-traits 0.2.19; once_cell 1.21.4; png 0.18.1; proc-macro2 1.0.107; quote 1.0.47; rand 0.10.2; rand_core 0.10.1; rand_distr 0.6.0; rustversion 1.0.23; serde 1.0.229; serde_core 1.0.229; serde_derive 1.0.229; serde_json 1.0.151; sha2 0.10.9; syn 2.0.119 and 3.0.3; typenum 1.20.1; wasm-bindgen 0.2.126; wasm-bindgen-macro 0.2.126; wasm-bindgen-macro-support 0.2.126; wasm-bindgen-shared 0.2.126; weezl 0.1.12 |
| MIT OR Apache-2.0 OR LGPL-2.1-or-later | r-efi 6.0.0 |
| MIT OR Apache-2.0 OR Zlib | miniz_oxide 0.8.9; zune-core 0.5.1; zune-jpeg 0.5.15 |
| MIT OR Zlib OR Apache-2.0 | bytemuck 1.25.2; safe_arch 1.1.0; wide 1.5.0 |
| MIT/Apache-2.0 | matrixmultiply 0.3.11; quick-error 2.0.1; rawpointer 0.2.1; version_check 0.9.5 |
| Unlicense OR MIT | byteorder-lite 0.1.0; memchr 2.8.3 |
| Unicode-3.0 AND (MIT OR Apache-2.0) | unicode-ident 1.0.24 |
| 0BSD OR MIT OR Apache-2.0 | adler2 2.0.1 |

## Binary distribution checklist

Before distributing `ScanStudio.app`, a DMG, or any other binary artifact:

1. Regenerate the resolved dependency inventory from the exact `Cargo.lock` used to build the release.
2. Include the full text of every selected Rust dependency license and the required copyright notices in the shipped archive or app bundle.
3. Include the MIT license for this project.
4. A `make package` bundle includes `scanstudio-bridge`: verify its GPL-3.0-only license, CoolscanPy source, CPython license, Python wheel metadata/licenses, and libusb license, notice, binary, complete pinned source archive, exact build script, and rebuild instructions are present in `Contents/Resources/Licenses`, `Contents/Resources/CorrespondingSource`, and `Contents/Frameworks`.
5. Keep Nikon software and private evidence out of the release.
6. Recheck this document after every dependency or packaging change.

The package script generates the bridge/Python license and source layout for its local bundle. A release maintainer must still regenerate the Rust dependency notices from the exact release lockfile, retain all package checks, and satisfy the GPL's corresponding-source obligations for every separately distributed binary artifact.
