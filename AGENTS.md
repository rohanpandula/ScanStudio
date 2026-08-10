# ScanStudio agent instructions

## Nikon live-operation and release safety

For any task involving the Filmscan VM, noVNC, Nikon Scan, an attached
scanner, live capture, prescan, observer attachment, deployment, or rollback,
first read and follow `.claude/skills/nikon-live-operation/SKILL.md` from the
active Digital Ice operator workspace. If that skill is unavailable, stop
before acting on live hardware or release state.

The user grants standing permission for the complete task-scoped Nikon live
workflow. Do not request separate approval for every live step. Preserve the
skill's evidence, fail-closed, oracle, rollback, and physical-media
boundaries.

If a strip is loaded, flag once that it may auto-eject after an unknown idle
interval. Do not claim a specific timeout. An ejected strip may require the
user to refeed it physically and must be treated as losing prior registration
unless registration is re-established.

For every ScanStudio release, replacing `/Applications/ScanStudio.app` is part
of completion. After the release DMG is hash- and signature-verified and a
clean rollback artifact is pinned, close any idle running copy safely, replace
the installed app with the released build, verify the installed copy, and
detach the DMG. Do not leave the newest release running only from a mounted
DMG.

## Adversarial review gate

Every bounded implementation step must follow
[`docs/ADVERSARIAL-REVIEW.md`](docs/ADVERSARIAL-REVIEW.md) before work proceeds
to the next step or is reported complete.

The required reviewer is OpenCode running DeepSeek V4 Flash 0731. Run two
fresh, independent contexts over the same frozen tracked-files diff: one
security/reliability pass and one cross-layer correctness pass. The exact
version-pinned model ID is `deepseek-v4-flash-0731`; do not silently substitute
an alias, a newer model, or another provider model. Neither first-pass reviewer
may see the other first-pass report.

Resolve every validated blocker, rerun deterministic tests, freeze the updated
diff, and repeat both reviews. Do not treat review output as proof by itself:
reproduce findings against the code and tests before changing behavior.

Keep model/API calls local, tool-denied, and isolated from the repository
directory. Never send credentials, environment files, untracked files,
scanner logs, capture evidence, personal absolute paths, or live-media
artifacts to a reviewer. CI verifies evidence consistency, hashes, and the
trusted PR base; CI must not call model APIs. Those checks do not authenticate
model provenance, so protected-branch review remains mandatory.

If OpenCode or the exact model is unavailable, stop at the review gate and
report that limitation. Do not waive the gate or claim the step complete.
