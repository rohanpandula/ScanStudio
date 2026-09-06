# Apple Silicon reliability review — 2026-09-06

Scope: current Apple Silicon app, its release workflow, interruption recovery,
saved-output clarity, and preparation for a supervised full-roll scan. The
original ScanStudio checkout was preserved; changes were prepared in the
separate `codex/mac-only-reliability` checkout.

## Findings fixed

- Resume could use cached pending frames after an authoritative read failed.
  Resume now owns the read/start sequence and rejects failed or stale reads.
- A delayed recovery reply could cross project reopen, connection replacement,
  or newly observed receipt state. Request identity and connection/project
  checks retire stale replies; durable completions cannot become retry targets.
- Scan, preview, project-change and approval actions could compete during
  recovery. Shared model guards exclude overlapping actions, and the UI shows
  resume preparation instead of leaving duplicate actions enabled.
- Interrupted transport registration and durable saved progress were mixed.
  Stopped batches require fresh previews; receipt-backed completion and project
  edits survive loss of the live scanner state.
- The inspector conflated requested output with saved files and did not provide
  a direct path to recorded outputs. It now labels future settings, provides
  receipt-backed Finder actions, and reports missing files. Crop guidance no
  longer promises re-rendering without a retained master.
- Live simulator verification found a false unsaved warning after Save & Scan:
  the engine persisted the recipe while the client retained the create-time
  snapshot. A bounded background refresh follows job adoption; held storage
  reads cannot delay Stop or apply across a retired session/project/job.
- Live dark-mode verification found a black Scan label on a dark native button.
  Native prominent-button foreground styling now determines readable contrast.
- Independent review found the reduced publish job was missing its arm64
  artifact download. The download is restored before provenance verification;
  policy tests reject a missing, duplicate, wrong-root, or cross-run download.

## Verification boundaries

The canonical engine suite, Swift suites, root policy tests, packaging guards,
and documentation checks were run. Developer ID-signed package verification
includes the new simulator acceptance gate: preview, partial stop, reopen,
SIGKILL, unusable destination, pending-only resume, nine decoded image outputs,
and receipt hashes/file identities. Final signature checks follow execution.
The release workflow separately verifies the exact tagged commit, supported OS
floor, updater, notarization, stapling and same-run artifact provenance.

Live UI testing used only a simulator and a disposable six-frame project. One
frame was saved through Save & Scan, appeared as one frame with receipts, and
its processed positive was correctly selected by the Finder action. A second
fresh Save & Scan on the final build showed one saved frame without the false
unsaved warning and readable native Scan button styling. No real
scanner movement was performed. Tests requiring external real-image evidence
remain explicitly separate.

The [nkscan documentation review](nkscan-behavior-requirements-2026-09-06.md)
found no justified feature gap. No implementation source, algorithms or profiles
were copied. Its behavior cases are acceptance requirements, not hardware proof.

## Remaining final step

Use [Mac acceptance and recovery](../MAC-ACCEPTANCE.md) after the user connects
the scanner. Existing telemetry, diagnostic snapshots, attempt journals and
manifest receipts support continuous observation during that attended run.
Physical focus, frame boundaries, color, IR treatment and full-roll completion
still need retained evidence. No simulator test closes those hardware questions.
Windows/Linux and Intel app support is retired; historical assets remain intact.
