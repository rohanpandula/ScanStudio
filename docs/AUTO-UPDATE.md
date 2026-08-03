# ScanStudio Auto-Update: Two-Path Strategy

> **DO NOT attempt the Sparkle steps until a Developer ID exists.**

| Path | Status |
|------|--------|
| **Path A — custom updater** (shipped mechanism in this repo) | **ACTIVE** |
| **Path B — Sparkle** | **GATED** on Developer ID; **NOT active** |

## Why two paths

ScanStudio is ad-hoc signed today (`codesign -dv` → `Signature=adhoc`, no
TeamIdentifier). Sparkle's real value is silent, auto-verified updates via
Gatekeeper — and that only works once the app is Developer ID signed and
**notarized**, both of which are blocked on a Developer ID certificate. Path A
is a custom updater that delivers verified-update + rollback value at $0 and
works with the existing ad-hoc signing, so it ships now and Path B waits.

## Path A (active) — how it works

As of this writing the shipped pieces are the release pipeline (01-01), version
identity (01-02), the install core (01-03), and the verified update service
(01-04, extended in Phase 02 with host-architecture-aware resolution); the
Settings UI (01-05) is next in the plan queue but not yet shipped; the bullets
mark status rather than claim what exists.

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
  verify the downloaded DMG's SHA-256 before mounting, and code-signature
  verify (`codesign --verify --deep --strict`) the mounted app before install.
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
- **UI (plan 01-05, NOT yet shipped):** once landed, `UpdateSettingsView.swift`
  + `UpdateFlowModel.swift` will surface current version, "Check for Updates",
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
   `codesign -dv` on a signed product, e.g. `TEAMID`).
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
   **Why:** CI wiring is the last step and should reference already-decided
   names (`DEVELOPER_ID_CERT`, `DEVELOPER_ID_TEAM`, `NOTARY_API_KEY`,
   `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER_ID`, `SPARKLE_EDDSA_KEY`, …) so the
   appcast step is a one-shot edit to `release.yml`. **Where:** repository
   Settings → Secrets and variables → Actions; record the chosen names in the
   future Sparkle plan.

## Reuse map

What Path B reuses from Path A, and what Path B adds.

| Existing artifact (01-xx) | How Sparkle reuses it |
|---------------------------|-----------------------|
| `release.yml` + `SHA256SUMS` + `latest.json` (01-01) | Base data for the appcast feed entry; keeps the release pipeline single-source-of-truth for version + sha256 |
| `UpdateVersion` (01-02, `UpdateVersion.swift`) | Orders the appcast items / compares installed-version-vs-feed so the UI shows a truthful "up to date" |
| `UpdateInstaller` (01-03, `UpdateInstaller.swift`) | The atomic snapshot→swap→rollback engine Sparkle's installer triggers; no scanner motion boundary is preserved |
| `UpdateDownloader` (01-04, planned) | Already validates hash + code signature; can gate what Sparkle is offered as a candidate |
| `UpdateSettingsView` / `UpdateFlowModel` (01-05, planned) | Unchanged — they keep presenting version/install/rollback, just fed by Sparkle instead of Path A |

**What Sparkle ADDS (none exist today):** the `SUFeedURL` key in the packaged
`Info.plist`, EdDSA feed signatures, Developer ID signing, notarization +
staple, and an appcast publish step in CI.

**What would change when the gate opens:** `app/ScanStudio/packaging/Info.plist`
(SUFeedURL), `app/ScanStudio/scripts/package_app.sh` (sign `-` → Developer ID
identity), `release.yml` (emit + upload appcast, notarize).

**Explicitly untouched by Path B:** the update safety boundary (no bridge spawn,
no scanner motion), the snapshot/swap/rollback core (`UpdateInstaller`), version
ordering (`UpdateVersion`), and the GitHub Releases distribution surface.

## Explicit non-goals while gated

- No Sparkle SPM dependency is added.
- No `SUFeedURL` is added to the packaged `Info.plist`.
- No EdDSA keys are generated.
- No Developer ID signing is configured.
- No appcast step is added to `release.yml`.

When a future task needs Path B, start here: this document is the handoff and
the checklist above is the unlock gate. Do not skip the "decide + document
repo-secret names" step.
