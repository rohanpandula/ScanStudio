# Release notes policy

Every ScanStudio release must publish a full changelog. The release body is a
source-controlled artifact, not text generated from commit subjects or edited
into GitHub after publication.

Before creating a tag named `v<version>`:

1. Add `docs/releases/v<version>.md` in the exact commit that will be tagged.
2. Start it with `# ScanStudio v<version>`.
3. Include, in order, one non-empty section with each exact heading:
   `## Everything that changed`, `## Validation`,
   `## Platform support and installation`, and `## Known limitations`.
4. Replace draft language and placeholders with the final verified test counts,
   support claims, installation instructions, and residual boundaries.
5. Run `python3 -I -S -B scripts/verify_release_notes.py
   docs/releases/v<version>.md v<version> <version>` and the complete
   `scripts/tests` unittest suite before tagging.

The tag-triggered release workflow derives the filename from the validated tag,
refuses symlinks, invalid UTF-8, abnormal sizes, placeholders, a tag/version
mismatch, and missing or reordered sections. It passes that committed file to
GitHub and requires the draft and published API bodies to equal it exactly.
Publication remains a prerelease with `latest=false` until the release workflow
is deliberately changed for a field-proven stable release.
