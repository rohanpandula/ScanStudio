# ScanStudio Auto-Update: Two-Path Strategy

> **DO NOT attempt the Sparkle steps until a Developer ID exists.**

| Path | Status |
|------|--------|
| **Path A — custom updater** (shipped mechanism in this repo) | **CHECK-ONLY; INSTALL FAILS CLOSED UNTIL DEVELOPER ID GATE OPENS** |
| **Path B — Sparkle** | **GATED** on Developer ID; **NOT active** |

## Why two paths

Release builds are Developer-ID signed, notarized, and stapled as of the
signing lane (release.yml's DMG job signs the app and DMG, notarizes both,
and staples both; local/PR-CI builds stay ad-hoc — `codesign -dv` →
`Signature=adhoc`). The packaged Info.plist stamps
`ScanStudioUpdateTeamIdentifier`. A checksum supplied by the release server
is an integrity check, not an independent publisher identity. Path A can
check and download, and with the signing lane in place the running app and
update
are Developer ID signed, securely timestamped, notarized, and stapled.

## Path A — how it works and its publisher gate

The shipped pieces are the release pipeline (01-01), version identity (01-02),
install core (01-03), verified update service (01-04), Settings UI (01-05),
integration gate (01-06), and host-architecture-aware resolution (Phase 02).

- **Release pipeline (plan 01-01, shipped):** tag-triggered
  `.github/workflows/release.yml` (`on: push: tags: ['v*']`) runs `make dmg`
  the same way CI already does, then
  `app/ScanStudio/scripts/emit_release_assets.sh` writes `SHA256SUMS` +
  `latest.json` (the arch-keyed `{"version","architectures":{<arch>:{url,sha256}}}`
  pointer), re-verifies the checksum, and `gh release create`s the DMGs +
  `SHA256SUMS` + `latest.json`.
- **Version identity (plan 01-02, shipped):** the packaged app stamps its
  exact release into `Info.plist` (`ScanStudioRelease`, from
  `SCANSTUDIO_RELEASE_VERSION`), and
  `app/ScanStudio/Sources/ScanStudioKit/UpdateVersion.swift` provides the
  comparable `UpdateVersion` parser (orders `alpha < beta < rc < stable` and
  `alpha.9 < alpha.11`).
- **Install core (plan 01-03, shipped):**
  `app/ScanStudio/Sources/ScanStudioKit/UpdateInstaller.swift` does the pure
  app-bundle snapshot → stage (`ditto`) → swap → rollback, always without
  spawning the bridge or touching the scanner.
- **Service (plan 01-04, shipped):**
  `app/ScanStudio/Sources/ScanStudioKit/UpdateService.swift` provides
  `GitHubUpdateChecker` + `UpdateDownloader`, which resolve the pointer/channel,
  and verify the downloaded DMG's SHA-256 before mounting. A scoped read-only
  mount then requires exactly one `.app` anywhere in the image, and that app
  must be root-level `ScanStudio.app`; the image always detaches
  (normal detach followed by a bounded forced-detach fallback).
- **Independent publisher root (required for installation):** the signed
  `Info.plist` must contain `ScanStudioUpdateTeamIdentifier` with the real
  ten-character Apple Team ID. At runtime that stamp must match the running
  app's Developer ID certificate, exact Security.framework designated
  requirement, secure timestamp, and stapled notarization ticket. The mounted
  app, private staging copy, and installed copy must all satisfy the same root.
  Missing/empty stamps and ad-hoc signatures produce no policy and disable
  installation; there is no placeholder Team ID and no permissive fallback.
- **Bundle binding:** before and after staging, the updater requires bundle ID
  `dev.scanstudio.live`, `CFBundleExecutable=ScanStudioLauncher`, exact
  `ScanStudioRelease`, a single-architecture `Contents/MacOS/ScanStudio` Mach-O
  matching the selected host feed entry, and a valid `LSMinimumSystemVersion`
  from the supported macOS 14+ range that the current host can run. The install
  core also refuses a candidate that is not newer than the app already at the
  selected destination.
- **Architecture-aware resolution (Phase 02, shipped):** the updater resolves
  the newest release for the HOST architecture from the arch-keyed
  `latest.json` (a single `architectures` mapping with a distinct
  `url`+`sha256` per `arm64`/`x86_64`) and downloads + verifies only that
  architecture's DMG. Intel (x86_64) support shipped in Phase 02: each release
  publishes a `-macOS-arm64.dmg` for Apple Silicon and a `-macOS-x86_64.dmg`
  for Intel. A missing entry for a host architecture surfaces the typed
  unsupported-architecture error — never a wrong-arch install. Local
  verification proves selection + hash integrity offline; the real Intel
  bundle executes on the CI x86_64 runner.
- **UI (plan 01-05, shipped):** `UpdateSettingsView.swift` +
  `UpdateFlowModel.swift` surface current version, "Check for Updates",
  channel toggle, install/rollback, a 24 h background cadence, and the guard
  that refuses an install while a scan/preview job is active.

## Path B (gated) — unlock checklist

Nothing in this section happens until the gate opens. Each item has a one-line
**why** and a **where** (how/where it is satisfied). If the Developer ID is
borrowed from a friend, the checklist applies identically after the cert is
imported into your keychain.

1. **Developer ID Application certificate in the keychain** — the identity
   Gatekeeper trusts; nothing signed works without it.
   **Why:** without it `codesign` cannot attest authorship, so macOS keeps
   flagging the bundle. **Where:** Apple's certs portal → download → double-click
   to install into `login` keychain; record the **Team ID** (visible via
   `codesign -dv` on a signed product). Stamp that exact value as
   `ScanStudioUpdateTeamIdentifier`; never use a sample or guessed value.
2. **Notarization capability** — a channel to submit builds to Apple's
   notary and staple the ticket.
   **Why:** notarization is what turns "first-launch warning" into Gatekeeper
   approval. **Where:** App Store Connect API key (preferred for CI) or Apple ID
   + app-specific password, usable via `xcrun notarytool submit ... --wait`.
3. **EdDSA signing keypair for the Sparkle feed** — Sparkle's feed-signature
   mechanism.
   **Why:** Sparkle requires every appcast item to carry an EdDSA signature so
   updates cannot be tampered with in transit. **Where:** generate with
   Sparkle's `generate_keys`/`sign_update` tooling; store the **private** key
   only as a GitHub Actions **secret** — never in the repo.
4. **A hosted appcast feed (XML)** — the thing Sparkle polls for new versions.
   **Why:** Sparkle has no feed without an appcast, and the feed signature needs
   a stable URL. **Where:** GitHub Pages on this repo is the zero-cost candidate
   (set up on `gh-pages`); the existing `SHA256SUMS` + `latest.json` values are
   the feed's base data (see reuse map below).
5. **Decide and document repo-secret names before wiring CI** — settle the
   secret surface only after the cert + notary + key all exist.
   **Why:** CI wiring should reference already-decided names. DECIDED and
   live in the signing lane: `MACOS_SIGNING_CERT_P12_BASE64`,
   `MACOS_SIGNING_CERT_PASSWORD`, `APPSTORE_CONNECT_API_KEY_P8` (raw PEM,
   not base64), `APPSTORE_CONNECT_API_KEY_ID`,
   `APPSTORE_CONNECT_API_ISSUER_ID`. A Sparkle path would add only
   `SPARKLE_EDDSA_KEY`. **Where:** repository Settings → Secrets and
   variables → Actions.

## Reuse map

What Path B reuses from Path A, and what Path B adds.

| Existing artifact (01-xx) | How Sparkle reuses it |
|---------------------------|-----------------------|
| `release.yml` + `SHA256SUMS` + `latest.json` (01-01) | Base data for the appcast feed entry; keeps the release pipeline single-source-of-truth for version + sha256 |
| `UpdateVersion` (01-02, `UpdateVersion.swift`) | Orders the appcast items / compares installed-version-vs-feed so the UI shows a truthful "up to date" |
| `UpdateInstaller` (01-03, `UpdateInstaller.swift`) | The atomic snapshot→swap→rollback engine Sparkle's installer triggers; no scanner motion boundary is preserved |
| `UpdateDownloader` (01-04, planned) | Already validates hash + code signature; can gate what Sparkle is offered as a candidate |
| `UpdateSettingsView` / `UpdateFlowModel` (01-05, planned) | Unchanged — they keep presenting version/install/rollback, just fed by Sparkle instead of Path A |

**What Sparkle ADDS (beyond the signing lane, which already provides
Developer ID signing, notarization, and stapling on releases):** the
`SUFeedURL` key in the packaged `Info.plist`, EdDSA feed signatures, and an
appcast publish step in CI.

**What would change when the gate opens:** `app/ScanStudio/packaging/Info.plist`
(SUFeedURL), `app/ScanStudio/scripts/package_app.sh` (sign `-` → Developer ID
identity), `release.yml` (emit + upload appcast, notarize).

**Explicitly untouched by Path B:** the update safety boundary (no bridge spawn,
no scanner motion), the snapshot/swap/rollback core (`UpdateInstaller`), version
ordering (`UpdateVersion`), the custom updater's Developer ID publisher gate,
and the GitHub Releases distribution surface.

## Explicit non-goals while gated

- No Sparkle SPM dependency is added.
- No `SUFeedURL` is added to the packaged `Info.plist`.
- No EdDSA keys are generated.
- No Developer ID signing is configured.
- No appcast step is added to `release.yml`.

When a future task needs Path B, start here: this document is the handoff and
the checklist above is the unlock gate. Do not skip the "decide + document
repo-secret names" step.
