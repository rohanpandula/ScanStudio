# Optional macOS web runtime distribution

## Status and boundary

The macOS browser runtime is an **optional, separately downloaded** release
component. It is disabled by default in release automation. Neither
`ScanStudio.app` nor either main ScanStudio DMG may contain `WebRuntime` or
`WebFrontend`; both app packaging and mounted-DMG verification enforce that
absence.

When enabled, each release can publish these three assets per native Mac
architecture:

```text
ScanStudio-WebRuntime-<version>-macOS-<arch>.dmg
ScanStudio-WebRuntime-<version>-macOS-<arch>.json
ScanStudio-WebRuntime-<version>-macOS-<arch>.json.sig
```

The read-only DMG contains exactly one `ScanStudioWebRuntime.bundle`. The
bundle contains the simulator-only gateway, the hash-pinned
python-build-standalone CPython 3.13.14 runtime, the shared web frontend,
notices, source, and a CycloneDX inventory.
It does **not** contain another engine, the Python scanner bridge, CoolScanPy,
libusb, python-sane, USB/device access, or a motion authorization latch. Its
native launcher requires an absolute `SCANSTUDIO_ENGINE_PATH` supplied by the
matching installed app, and removes `SCANSTUDIO_BRIDGE_CMD` and
`SCANSTUDIO_HW_MOTION` before starting the gateway. The gateway repeats that
scrub before it starts the host app's engine.

The runtime is exact-version and exact-protocol material. A runtime manifest
for one ScanStudio version or architecture cannot satisfy another request.
The current engine protocol value is `1`.

## Trust contract

This optional executable payload is intentionally held to a stronger release
bar than today's main app:

1. Every Mach-O file, the bundle, and the DMG are timestamped with a real
   `Developer ID Application` identity. Ad-hoc identity `-` is rejected.
2. The DMG is submitted to Apple's notary service, must return `Accepted`, is
   stapled, and is assessed again before its manifest is emitted.
3. The manifest includes the final stapled DMG byte size and SHA-256, the
   exact Developer Team ID/bundle identifier, and a deterministic hash of the
   extracted payload tree.
4. The canonical manifest bytes are signed with Ed25519. The `.json.sig` file
   is the raw 64-byte signature, not base64, PEM, SSHSIG, CMS, or JSON.
5. ScanStudio authenticates the manifest before interpreting any URL or path,
   verifies the DMG size/hash before mounting, validates the read-only DMG and
   exact one-bundle layout, and re-hashes/re-assesses the cached payload before
   every launch.

The external manifest is compact, sorted-key UTF-8 JSON with one trailing LF.
Unknown or missing fields fail. Its exact schema is:

```json
{
  "architecture": "arm64",
  "asset": {
    "name": "ScanStudio-WebRuntime-1.2.3-macOS-arm64.dmg",
    "sha256": "<lowercase SHA-256>",
    "size": 123,
    "url": "https://github.com/rohanpandula/ScanStudio/releases/download/v1.2.3/ScanStudio-WebRuntime-1.2.3-macOS-arm64.dmg"
  },
  "hostVersion": "1.2.3",
  "payload": {
    "bundleIdentifier": "dev.scanstudio.live.web-runtime",
    "bundleName": "ScanStudioWebRuntime.bundle",
    "developerIDSigned": true,
    "executableRelativePath": "Contents/MacOS/scanstudio-web-runtime",
    "fileCount": 123,
    "installedSize": 123456,
    "notarized": true,
    "staticDirectoryRelativePath": "Contents/Resources/WebFrontend",
    "teamIdentifier": "<configured 10-character Team ID>",
    "treeSHA256": "<lowercase payload-tree SHA-256>"
  },
  "platform": "macos",
  "protocolVersion": 1,
  "repository": "rohanpandula/ScanStudio",
  "runtimeVersion": "1.2.3",
  "schemaVersion": 1,
  "tag": "v1.2.3"
}
```

Field order in this readable example is already canonical because keys are
sorted; real output has no indentation or incidental whitespace.
The app and publisher also share the same hard ceilings: a 64 KiB manifest,
a 1 GiB DMG, 100,000 regular payload files, and 8 GiB installed file bytes.

## App trust bootstrap without runtime bundling

When optional publishing is enabled, the main app packager stamps exactly two
values into its existing `Info.plist`:

- `ScanStudioWebRuntimeEd25519PublicKey`: base64 of the raw 32-byte Ed25519
  public key;
- `ScanStudioWebRuntimeTeamIdentifier`: the configured Developer ID Team ID.

The packager validates that the committed PEM is an Ed25519 SubjectPublicKeyInfo
value before deriving the raw bytes. It requires both values together and
refuses pre-existing fields. With optional publishing disabled it stamps
neither. It never copies the PEM, private key, runtime bundle, or frontend into
the app.

## GitHub configuration and fail-closed behavior

Set repository variable `SCANSTUDIO_PUBLISH_WEB_RUNTIME=true` only after every
item below exists:

- variable `SCANSTUDIO_WEB_MANIFEST_KEY_ID`, naming a reviewed committed
  `ports/web/packaging/macos/manifest-keys/<key-id>.pem`;
- secret `SCANSTUDIO_WEB_MANIFEST_PRIVATE_KEY_BASE64`, containing the base64
  encoding of the matching Ed25519 private PEM;
- secrets `SCANSTUDIO_DEVELOPER_ID_P12_BASE64`,
  `SCANSTUDIO_DEVELOPER_ID_P12_PASSWORD`,
  `SCANSTUDIO_DEVELOPER_ID_APPLICATION`, and
  `SCANSTUDIO_DEVELOPER_ID_TEAM`;
- secrets `SCANSTUDIO_NOTARY_KEY_P8_BASE64`,
  `SCANSTUDIO_NOTARY_KEY_ID`, and `SCANSTUDIO_NOTARY_ISSUER_ID`.

The workflow imports signing credentials into an ephemeral keychain, verifies
that the private manifest key matches the committed public key, builds each
architecture natively, and deletes temporary credentials. If the opt-in is
true and any credential, identity, key match, notary result, staple,
signature, payload check, or architecture check fails, the combined GitHub
release is not published. If the opt-in is false, the exact existing release
set remains unchanged and no runtime asset is advertised. A stable runtime is
never silently downgraded to ad-hoc signing or an unsigned checksum.

The runtime job also downloads one exact architecture-specific
python-build-standalone `20260728` `pgo+lto` full archive. Asset size/SHA-256,
`PYTHON.json` SHA-256, target triple, exact 3.13.14 interpreter version, and
every distribution-supplied license file size/SHA-256 are committed in
`python-build-standalone-lock.json`. Packaging uses that extracted interpreter
and refuses a different uv-managed Python. OpenSSL is similarly selected by an
absolute OpenSSL 3 path and must complete a real raw Ed25519 sign/verify probe
before credentials or release manifests are processed.

The publisher accepts exactly six ordinary platform packages when disabled,
or those six plus the two three-file runtime sets when enabled. `SHA256SUMS`
contains every enabled package/manifest/signature asset; `latest.json` remains
the main Mac app updater pointer and does not advertise the optional runtime.

## Key creation and rotation

Generate a manifest key offline and protect the private PEM:

```sh
export OPENSSL_BIN="$(brew --prefix openssl@3)/bin/openssl"
ports/web/packaging/macos/require-openssl3.sh "$OPENSSL_BIN"
"$OPENSSL_BIN" genpkey -algorithm Ed25519 -out scanstudio-web-runtime-private.pem
"$OPENSSL_BIN" pkey -in scanstudio-web-runtime-private.pem -pubout \
  -out ports/web/packaging/macos/manifest-keys/2026-01.pem
```

Commit only the public PEM through normal review. Store the private PEM as the
base64 secret above. Do not publish it, put it in a release artifact, or write
it into an app/DMG.

The manifest intentionally has no attacker-selected key ID. Key selection is
bound out of band to the exact host app release. To rotate:

1. add a new, differently named public PEM; never replace an old PEM in place;
2. update the app trust bootstrap for the next exact host version and review
   that change before publishing its runtime;
3. change the repository key-ID variable and private-key secret together;
4. make one candidate release and verify both raw signature and app-side
   resolution before promoting it;
5. retain old public keys so historical release evidence remains verifiable.

If a key is compromised, disable `SCANSTUDIO_PUBLISH_WEB_RUNTIME` immediately,
do not replace assets on an existing tag, rotate to a new key and new release
version, and document which versions must no longer fetch or launch a runtime.

Developer ID/notary credential rotation follows the same no-overwrite rule:
update the secrets, confirm the resulting Team ID still matches the app trust
bootstrap, and publish only a new version/tag.

## Independent verification

After downloading the three architecture-matched assets and obtaining the
trusted public PEM from the matching reviewed source tag:

```sh
export OPENSSL_BIN="$(brew --prefix openssl@3)/bin/openssl"
ports/web/packaging/macos/require-openssl3.sh "$OPENSSL_BIN"
"$OPENSSL_BIN" pkeyutl -verify -rawin -pubin \
  -inkey ports/web/packaging/macos/manifest-keys/<key-id>.pem \
  -in ScanStudio-WebRuntime-<version>-macOS-<arch>.json \
  -sigfile ScanStudio-WebRuntime-<version>-macOS-<arch>.json.sig

ports/web/packaging/macos/verify-runtime-release.sh \
  ScanStudio-WebRuntime-<version>-macOS-<arch>.dmg \
  ScanStudio-WebRuntime-<version>-macOS-<arch>.json \
  ScanStudio-WebRuntime-<version>-macOS-<arch>.json.sig \
  ports/web/packaging/macos/manifest-keys/<key-id>.pem \
  <version> <arch> <team-id>
```

The second command is macOS-only because it also stapler-validates and
Gatekeeper-assesses the DMG, mounts it read-only, checks every Mach-O
signature/architecture, rejects
engine/bridge/hardware paths, and recomputes the app-compatible payload tree
hash. The raw-signature/schema/hash portion has a cross-platform verifier in
`verify-integrity.sh`.

## Licensing and source evidence

The current optional runtime is simulator-only and includes no GPL component.
That is a verified payload constraint, not a license relabeling shortcut. The
DMG includes:

- the repository MIT license and third-party notices;
- the exact python-build-standalone source-metadata identity (with a canonical
  copy whose temporary builder paths are redacted) plus every license file
  supplied by the pinned distribution, checked against reviewed hashes and
  represented component-for-component in the SBOM;
- the hash-pinned CPython 3.13.14 `Doc/license.rst` supplement for incorporated
  mimalloc, asyncio code derived from uvloop, and FreeBSD Global Unbounded
  Sequences/QSBR code that the distribution's shorter license file omits;
- an exact locked Python application closure using plain Uvicorn, wsproto, and
  Pydantic 1, without uvloop, httptools, watchfiles, websockets, or
  pydantic-core; wheel metadata and every license/notice file present in those
  exact distributions are preserved;
- the production npm lock/inventory and full available license text for that
  closure;
- a dependency-notice hash manifest;
- a CycloneDX inventory of the pinned CPython distribution components plus the
  installed Python and production npm closures;
- source snapshots for the ScanStudio gateway and shared frontend.

The pinned upstream metadata mentions `LICENSE.zlib-ng.txt` as an alternative
for the `zlib` extension but does not supply that file. This is not waived
silently: the evidence verifier requires the exact metadata hash and proves
that the extension has only a system `-lz` link, that the applicable supplied
`LICENSE.zlib.txt` matches its reviewed hash, and that the SBOM names required
`zlib` rather than `zlib-ng`. Any static zlib-ng link or metadata change fails.
The unused Tcl/Tk 9 stack and `_tkinter` extension are removed by exact pinned
paths; the final verifier rejects any remainder. Every remaining Mach-O must
contain the target slice, universal inputs are thinned before signing, and the
mounted DMG must contain only exact-target Mach-O files.

If a future runtime adds the GPL bridge or CoolScanPy, this packager will fail.
That future hardware-capable distribution needs a separate reviewed packaging
change that adds the complete corresponding source, GPL texts, hardware safety
gates, and owner-attended validation described in
[`WEB-HEADLESS.md`](WEB-HEADLESS.md).
