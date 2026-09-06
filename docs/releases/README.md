# ScanStudio releases

[v0.7.0-beta.16 release notes](v0.7.0-beta.16.md) describe held exposure,
the multi-sampling contract, measured bridge deadlines, the CoolscanPy 0.7.7
sync, and the hardware evidence behind them.

Use the [GitHub Releases listing](https://github.com/rohanpandula/ScanStudio/releases)
to find published downloads. A versioned notes file or locally built DMG does
not establish publication. Releases remain prereleases with `latest=false`;
a stable `/latest` link is not the download entry point.

## Current release scope

ScanStudio targets **Apple Silicon (M-series, arm64) only, macOS 14 (Sonoma)
or newer**. The downloadable image is
`ScanStudio-<version>-macOS-arm64.dmg`; copy the app to Applications.
The release workflow Developer ID-signs, notarizes, and staples **both the
app and DMG**. It publishes one arm64 DMG, `SHA256SUMS`, and `latest.json`.

The supported LS-5000 C-41 color-roll workflow remains Beta, with limited
retained hardware evidence. LS-40/LS-50 identity recognition and FireWire
probing are not scanning support. Refer to the [hardware matrix](../HARDWARE-SUPPORT.md)
and [Mac acceptance and recovery](../MAC-ACCEPTANCE.md) when describing results.
Final attended full-roll hardware acceptance for beta.16 is **NOT RUN**.
Software checks cannot establish real focus, framing, color, dust repair, or
physical stop/resume behavior.

Intel Macs, Windows, and Linux are retired ScanStudio platforms. Direct those
users to [NegPy downloads](https://github.com/marcinz606/NegPy/releases) and
[upstream setup and compatibility guidance](https://github.com/marcinz606/NegPy#readme),
without promising scanner or holder support. nkscan remains a documentation-only
cleanroom reference; no implementation code or profiles are copied.

Historical versioned notes and published assets retain the support, test, and
signing facts that applied to them. Preserve those records without extending
their platform promises to current releases. Keep live guidance concise;
release-by-release history belongs in the versioned notes.

## Prepare the release notes

Before creating `v<version>`, include `docs/releases/v<version>.md` in the exact
commit to be tagged. The release workflow requires that commit to be contained
in reviewed `main` history. Write the complete changelog in that file; GitHub's
release body must come from it, not generated commit subjects or later edits.

The file must begin with `# ScanStudio v<version>` and contain each of these
non-empty sections exactly once, in this order:

1. `## Everything that changed`
2. `## Validation`
3. `## Platform support and installation`
4. `## Known limitations`

Use verified test results and precise hardware boundaries. Keep unperformed
hardware acceptance explicitly **NOT RUN**. Resolve draft language and
placeholders before tagging; a structurally valid file is not proof that its
claims are true. The verifier requires a regular non-symlink UTF-8 file,
LF line endings with a final newline, and a size of 1–128 KiB. It rejects
placeholder tokens, wrong titles/paths, and mismatched tags or versions.

From the **repository root**, for beta.16:

```sh
python3 -I -S -B scripts/verify_release_notes.py \
  docs/releases/v0.7.0-beta.16.md v0.7.0-beta.16 0.7.0-beta.16
python3 -I -S -B scripts/verify_hardware_support_docs.py
python3 -I -S -B scripts/verify_scanner_contract_docs.py
python3 -I -S -B scripts/verify_release_workflow.py
python3 -I -S -B scripts/check_github_action_pins.py
python3 -I -S -B -m unittest discover -s scripts/tests -p 'test_*.py'
```

These documentation and policy checks supplement the full application,
bridge, driver, packaging, and updater gates. See the [developer build guide](../../app/ScanStudio/README.md)
for current commands and their directory scopes.

## Existing release pipeline

[`.github/workflows/release.yml`](../../.github/workflows/release.yml) owns
publication. Its reusable [verification workflow](../../.github/workflows/ci.yml)
runs for the **exact tagged commit in the same release run**. Prior green PR
runs, local checks, or artifacts from another run cannot substitute for it.

1. **Authorize the tag.** Fetch and pin the remote tag object, verify its commit
   and containment in `main`, and validate the committed release notes.
2. **Require all verification families.** Run Swift/Rust, bridge, CoolscanPy,
   supply-chain policy, arm64 package, macOS 14 runtime, and updater integration
   checks. Failed, canceled, skipped, timed-out, or missing required results
   block publication; the verified SHA must equal the tagged commit.
3. **Check driver publication and build.** The PyPI synchronization gate compares
   the bundled CoolscanPy tree with authenticated published source, permitting
   only explicitly reviewed differences pinned by hashes on both sides. Publish
   the required driver and reconcile those pins before tagging; matching version
   strings alone are insufficient. Use the pinned toolchains and locked
   dependencies. The app-directory `make package` builds and checks the app.
4. **Sign and notarize in order.** Sign the app with Developer ID, verify it,
   then notarize and staple it. Build the DMG from that already-stapled app using
   `app/ScanStudio/scripts/package_dmg.sh`; sign, notarize, and staple the DMG.
   Each artifact needs its own ticket. Emit checksums and updater metadata only
   after DMG stapling, which changes its bytes.
5. **Bind and verify the artifacts.** Provenance ties hashes to repository,
   workflow run and attempt, commit, and tag. The final gate requires every
   same-run job to succeed. Publication verifies provenance, asset names,
   checksums, and the arm64 updater entry, and rechecks the pinned remote tag.
6. **Publish the verified prerelease.** Create and verify a draft, then publish
   it as a prerelease with `latest=false`. Both draft and published API bodies
   must equal the committed notes exactly; downloaded assets and published
   metadata are checked by the workflow.

The central package check runs relocated bridge smoke and simulator acceptance
before final signature verification. The macOS 14 job executes the exact app
from the CI package job; signed release packages and mounted DMG contents also
run the package gate. This covers software stop/reopen/interruption/resume and
saved-output integrity, while the separate final hardware record remains
**NOT RUN** until an attended run supplies evidence.

[Signing dry runs](../../.github/workflows/signing-dry-run.yml) exercise signing
without replacing release authorization or publishing a release. Local
`make package`/`make dmg` are likewise build checks, not publication commands.
See [update verification](../AUTO-UPDATE.md) for publisher trust and updater
behavior. Preserve all bridge/CoolscanPy GPL source and dependency notices in
both app and DMG distributions; see [third-party notices](../../THIRD_PARTY_NOTICES.md).
