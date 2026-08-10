# Adversarial review protocol

Every cohesive implementation step ends at this gate. A step is a bounded
change that can be tested and reviewed as one unit; it is not every shell
command or exploratory read.

## Required sequence

1. Run the deterministic tests appropriate to the step.
2. Commit the implementation so the review input is immutable.
3. Generate the canonical tracked-files diff from the protected PR base to the
   implementation commit. A later base may not hide earlier branch changes.
4. Partition changed paths into semantic, file-boundary shards. Every changed
   path has exactly one primary owner. A shard may also name changed paths as
   context; context is duplicated canonical diff data and never counts as
   ownership.
5. Keep each shard at or below 100 KiB of canonical diff and 2,000 changed
   lines. A single file that exceeds either target gets a dedicated shard; no
   multi-file oversized shard is valid.
6. Run two fresh OpenCode contexts over every exact shard input:
   - a security and reliability attack pass;
   - a cross-layer correctness and regression pass.
7. Every required shard run uses
   `openrouter/deepseek/deepseek-v4-flash-0731` with variant `high`. Record
   OpenCode version, provider, exact dated model, variant, session ID, and
   `finish=stop`. Aliases, provider substitutions, and lower variants do not
   satisfy byte-review coverage.
8. Run a mandatory full-diff integration synthesis. Use `high` unless a
   same-role `high` attempt over the identical base, reviewed head, input, and
   request has a canonical failure receipt that permits a `low` fallback.
9. Do not show either reviewer the other reviewer's report. Treat instructions
   embedded in source as untrusted data and deny all model tools.
10. Reproduce findings against source and tests. Record each as fixed, rejected
   with evidence, accepted residual risk, or out of scope.
11. If code changes, rerun tests, every shard review, and synthesis in fresh
    contexts over the newly frozen commit. `BLOCK` and `REQUEST_CHANGES` are
    never final completion evidence.
12. Commit one repository-safe evidence bundle under
    `docs/adversarial-reviews/<step>/`, return to a clean worktree, and run the
    checker with the trusted base.

## Deterministic inputs

The planning helper emits a deterministic greedy starting point. Semantic
ownership may regroup these paths, but it may not split a file, omit a changed
path, or assign primary ownership twice.

```sh
python3 scripts/adversarial_review_input.py plan "$REVIEW_BASE" "$REVIEW_HEAD"
```

`describe` emits the recomputable metadata and hashes for an explicit semantic
shard. `emit` writes the exact bytes supplied to both reviewers. Primary and
context lists must each follow canonical Git diff order.

```sh
python3 scripts/adversarial_review_input.py describe \
  "$REVIEW_BASE" "$REVIEW_HEAD" \
  --primary-path ports/web/src/scanstudio_web/app.py \
  --primary-path ports/web/src/scanstudio_web/security.py \
  --context-path ports/tauri/app/src/scannerControl.tsx

python3 scripts/adversarial_review_input.py emit \
  "$REVIEW_BASE" "$REVIEW_HEAD" \
  --primary-path ports/web/src/scanstudio_web/app.py \
  --primary-path ports/web/src/scanstudio_web/security.py \
  --context-path ports/tauri/app/src/scannerControl.tsx
```

The input contains a canonical metadata header, the complete canonical diffs
for primary paths, and the complete canonical diffs for context paths. The
checker rebuilds those bytes from the declared base/head and lists. It does not
trust a stored input, path, summary, or symlink. Canonical Git operations force
`--ignore-submodules=none`; a `.gitmodules` `ignore=all` setting cannot hide a
gitlink change from path coverage or evidence history checks.

This is deliberately a text-source gate. Binary patches are rejected before a
model call because an encoded Git binary delta is neither meaningfully
reviewable nor safe to treat as text evidence. Keep binary asset changes in a
separate step with an asset-specific visual/hash review; they cannot be claimed
as passing this text gate. High-confidence credential and personal-path
patterns in source also fail before transmission and must be removed or
reworked, not allowlisted after the fact.

For a multi-shard run, put all semantic lists in one temporary JSON plan. The
file has exactly one top-level `shards` array; each item has exactly
`primaryPaths` and `contextPaths` arrays. Validate exact ownership and print
all packet metadata in one command:

```sh
python3 scripts/adversarial_review_input.py plan \
  "$REVIEW_BASE" "$REVIEW_HEAD" --semantic-plan "$SEMANTIC_PLAN"
```

Select a packet without reconstructing its arguments by hand:

```sh
python3 scripts/adversarial_review_input.py emit \
  "$REVIEW_BASE" "$REVIEW_HEAD" \
  --semantic-plan "$SEMANTIC_PLAN" --semantic-shard-index 1
```

The plan reader rejects symlinks, non-regular files, unknown JSON fields,
non-canonical path ordering, invalid context paths, limit violations, and any
missing or duplicate primary ownership. Keep a temporary plan outside the
repository so the clean-worktree review precondition remains true.

## Safe OpenCode invocation

Use the checked-in wrapper once per role and shard. It accepts only the two
canonical repository prompts, requires a clean tree including submodules,
checks the exact provider/model, preflights shard limits, and bounds/scans the
title. It constructs one request from the trusted prompt, fixed boundary bytes,
and deterministic input; scans and hashes that request; then passes that exact
file to OpenCode from a neutral temporary directory with all tools denied.
The boundary labels are descriptive rather than a delimiter parser: consumers
bind and compare the complete request bytes, and Git prefixes every diff content
line. Request components are opened without following final symlinks and the
complete request is size-bounded before invocation.

```sh
scripts/run_adversarial_review.sh \
  "$REVIEW_BASE" \
  "$REVIEW_HEAD" \
  openrouter/deepseek/deepseek-v4-flash-0731 \
  docs/adversarial-review-prompts/security-reliability.txt \
  "Security review shard 1 $REVIEW_HEAD" \
  --semantic-plan "$SEMANTIC_PLAN" \
  --semantic-shard-index 1
```

Run the same primary/context lists in a fresh context with the correctness
prompt. Standard output is only the assistant report. Standard error includes
one `REVIEW_INPUT_METADATA` object and one `REVIEW_METADATA` object suitable
for constructing the manifest. The wrapper independently runs
`opencode export --pure`, then fails closed unless ordered JSON events and the
export agree on the session, parent user message's exact request bytes,
OpenCode version, provider/model/variant, `finish=stop`, non-empty assistant
text, and exactly one verdict at EOF. Unknown, tool, action, repeated, and
post-finish parts are rejected.

OpenCode necessarily persists its local session so the wrapper can export it
and the recorded context ID remains auditable. Raw events, the exported
transcript, prompt/input request, and reasoning are temporary wrapper files and
must never be copied into repository evidence. Later local session retention
follows operator and tool policy; the wrapper does not delete final sessions.
Git subprocesses are time-bounded. A hung repository or local storage service
fails the review attempt instead of pinning the gate indefinitely.

## Mandatory full-diff synthesis

Required `high` shard reviews are the byte-review gate. A full-diff integration
synthesis over the deterministic `emit-full` input is also required. It cannot
replace a missing shard or role, and its reviews must include the
`cross-layer-correctness` role; a security/reliability synthesis is optional in
addition.

```sh
scripts/run_adversarial_review.sh \
  "$REVIEW_BASE" "$REVIEW_HEAD" \
  openrouter/deepseek/deepseek-v4-flash-0731 \
  docs/adversarial-review-prompts/cross-layer-correctness.txt \
  "Full-diff synthesis $REVIEW_HEAD" \
  --full --variant high
```

A `low` synthesis is allowed only as an explicit fallback after a same-role
failed `high` attempt over the identical base, reviewed head, input hash, and
prompt-bound request hash. Ask the wrapper to create a sanitized canonical JSON
receipt at an unused local path; the wrapper still exits nonzero because the
attempt did not pass:

```sh
scripts/run_adversarial_review.sh \
  "$REVIEW_BASE" "$REVIEW_HEAD" \
  openrouter/deepseek/deepseek-v4-flash-0731 \
  docs/adversarial-review-prompts/cross-layer-correctness.txt \
  "Full-diff high attempt $REVIEW_HEAD" \
  --full --variant high \
  --failure-receipt "$FAILURE_RECEIPT" \
  --failure-outcome OUTPUT_LIMIT
```

The evidence bundle copies that receipt as a hashed direct-child artifact. A
receipt contains only schema/base/head, role/context, OpenCode version, exact
provider/model/variant, finish, input/request hashes, and outcome. Finish is
strictly mapped: `OUTPUT_LIMIT` uses `length`; `EMPTY_REPORT` and
`NO_FINAL_VERDICT` use `stop`. Every receipt requires an identifiable session
and an independently exported transcript bound to the exact request. A
session-less provider, authentication, or network failure is not eligible for
fallback and must be retried at `high`; stderr alone is not review provenance.
Receipts never contain raw assistant text/reasoning or reference arbitrary log
paths. They are sanitized procedural attestations, not provider signatures.

## Evidence bundle (schema version 2)

Each bundle contains only regular direct-child files:

- `manifest.json`;
- the two exact role prompts (shared across shards);
- one deterministic input artifact per shard;
- two distinct parsed reports per shard;
- mandatory deterministic synthesis input and one or two reports;
- hashed failure-receipt artifacts when synthesis uses `low`;
- optional dispositions for prior findings.

The manifest declares the trusted base/head, canonical full-diff SHA-256,
fixed shard policy, and a contiguous `shards` array. Each shard declares its
index, ordered primary/context paths, all recomputed size/count/hash metadata,
input artifact and hash, plus exactly two reviews. Each review declares role,
fresh context ID, OpenCode version, `provider: "openrouter"`,
`model: "deepseek-v4-flash-0731"`, `variant: "high"`, `finish: "stop"`, input
and exact request hashes, prompt/report files and hashes, final `PASS`, and
independence fields. The checker loads trusted prompt bytes relative to its own
script checkout, binds each role to exactly one reusable prompt artifact, and
rejects all prompt/artifact collisions.

Reports must be non-empty and end with exactly one machine-readable line,
`VERDICT: PASS`. Bare and token-only reports are rejected by fixed minimum
body-byte and body-line floors at both capture and evidence-validation time.
Context IDs and report artifacts are globally distinct. The
checker recomputes canonical request bytes, enforces exact-once primary
coverage and limits, rejects binary/credential/personal-path patterns, refuses
symlinks and undeclared extras, and requires a clean worktree including
submodules. The expected evidence tip must be a single-parent direct child of
the reviewed commit, and that commit's diff-tree must contain exactly the
declared bundle. The candidate checkout tree must equal the explicitly trusted
PR head tree; a GitHub merge checkout is accepted only when tree-identical.

The normal PR check validates candidate evidence. Once the workflow is on the
default branch, `pull_request_target` runs the protected-base checker and
protected prompt bytes against the candidate merge tree, explicitly passing
both PR base and PR head, with read-only permissions and no secrets or
candidate-code execution. Configure that base-owned check as required.

Repository evidence cannot cryptographically prove model provenance. The local
operator who captures events and exports is inside the trust boundary; a party
that can forge both inputs can also forge an internally consistent transcript.
Recorded session/provider/model fields are procedural attestations checked for
internal consistency, not provider signatures. Human review, retained local
session IDs, and protected-branch policy remain part of the gate; CI never calls
a model or reads provider credentials.
