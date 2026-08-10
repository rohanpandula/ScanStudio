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

The required reviewer is OpenCode using the exact provider/model pin
`openrouter/deepseek/deepseek-v4-flash-0731`. Generate the deterministic
file-boundary shard plan for one frozen base/head diff, then run two fresh,
independent `high`-variant contexts over every shard: one security/reliability
pass and one cross-layer correctness pass. Neither first-pass reviewer may see
the other first-pass report. Do not silently substitute an alias, newer model,
different provider, or lower variant for any required shard review.

A full-diff integration synthesis is mandatory and never substitutes for
shard coverage. It uses `high` by default. `low` is allowed only when the
manifest contains a canonical, hashed failure receipt for a same-role `high`
attempt over the identical base, reviewed head, input, and request. Follow the
fallback schema and limits in the review protocol; do not use prose summaries
as a substitute for canonical source bytes.

Resolve every validated blocker, rerun deterministic tests, freeze the updated
diff, and repeat both reviews. Do not treat review output as proof by itself:
reproduce findings against the code and tests before changing behavior.

Keep model/API calls local, tool-denied, and isolated from the repository
directory. Use OpenCode JSON output and retain only the parsed assistant
report plus sanitized session metadata. Never send credentials, environment
files, untracked files, scanner logs, capture evidence, personal absolute
paths, or live-media artifacts. Never copy raw reasoning into repository
evidence. OpenCode necessarily retains the local session for export and
auditable context IDs; subsequent local retention follows operator/tool
policy. CI verifies evidence consistency, deterministic shard coverage,
request hashes, and the trusted PR base/head; CI must not call model APIs.
Those checks do not authenticate model provenance, so protected-branch review
remains mandatory.

If OpenCode or the exact model is unavailable, stop at the review gate and
report that limitation. Do not waive the gate or claim the step complete.
