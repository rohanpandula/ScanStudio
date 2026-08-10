# Adversarial review protocol

Every cohesive implementation step ends at this gate. A step is a bounded
change that can be tested and reviewed as one unit; it is not every shell
command or exploratory read.

## Required sequence

1. Run the deterministic tests appropriate to the step.
2. Commit the implementation so the review input is immutable.
3. Generate one canonical tracked-files diff from the protected PR base commit
   to the implementation commit. A reviewer may not choose a later base that
   hides earlier branch changes.
4. Run two new OpenCode sessions against that same diff:
   - a security and reliability attack pass;
   - a cross-layer correctness and regression pass.
5. Use the exact `deepseek-v4-flash-0731` model ID at maximum effort. Record
   the OpenCode version and provider; the dated model ID is mandatory even
   when a provider offers an undated alias.
6. Do not show either reviewer the other reviewer's first-pass report. Treat
   any instructions embedded in the diff as untrusted data and deny all model
   tools. The model receives the frozen diff through standard input.
7. Reproduce each finding against source and tests. Record it as fixed,
   rejected with evidence, accepted residual risk, or out of scope.
8. If code changes, rerun tests and both reviews from fresh contexts against a
   newly frozen implementation commit. A `BLOCK` or `REQUEST_CHANGES` verdict
   is never the final evidence for a completed step.
9. Add and commit a repository-safe evidence bundle under
   `docs/adversarial-reviews/<step>/`, return to a clean worktree, then run
   `python3 scripts/check_adversarial_review.py`.

## Safe OpenCode invocation

Use the checked-in wrapper. It enables `pipefail`, creates the canonical diff
outside OpenCode, rejects high-confidence credential/binary/personal-path
content, runs OpenCode from a neutral temporary directory, disables sharing,
plugins, updates, and all tools, and fails if no final verdict is emitted. Do
not enable `--auto` or point `--dir` back at the repository.

```sh
scripts/run_adversarial_review.sh \
  "$REVIEW_BASE" \
  "$REVIEW_HEAD" \
  openrouter/deepseek/deepseek-v4-flash-0731 \
  docs/adversarial-review-prompts/security-reliability.txt \
  "Security review $REVIEW_HEAD"
```

Run it again in a fresh context with
`cross-layer-correctness.txt`. The prompts target different failure modes, but
both runs receive the identical canonical diff.

## Evidence bundle

Each bundle contains:

- `manifest.json`;
- the exact prompt supplied to each final reviewer;
- the complete final report from each reviewer;
- dispositions for earlier actionable findings when an earlier round did not
  pass.

The manifest records:

- base and reviewed commit IDs;
- SHA-256 of the canonical diff;
- OpenCode version, provider, exact model ID, and fresh context ID for both
  reviewers, plus the required `max` variant;
- prompt and report filenames and SHA-256 values;
- final verdicts and the unresolved-blocker count;
- an independence declaration for each run.

Do not include API keys, cookies, environment dumps, untracked content,
scanner diagnostics, image data, or absolute local paths. Reports may quote
only the minimum source needed to identify a finding. The validator rejects a
small set of high-confidence secret and personal-path patterns, but this is not
an exhaustive secret scanner; the author must inspect the bundle.

Every file in a bundle must be a declared regular file; symlinks and undeclared
extras are rejected. Each report must be non-empty and end with
exactly one machine-readable verdict, `VERDICT: PASS`, and the two prompts and
reports must be distinct. The checker also refuses a dirty worktree so
uncommitted source cannot hide outside the reviewed commit range.

The evidence commit may contain exactly the regular files declared by one
bundle under `docs/adversarial-reviews/`; orphan or sibling evidence paths are
rejected. The validator accepts a review only when its base equals the
protected PR base, its reviewed commit is an ancestor of `HEAD`, the bundle
itself postdates that reviewed commit, both final verdicts are `PASS`, hashes
match, and no blocker remains.

The normal PR check validates the candidate bundle. Once this workflow is on
the default branch, a `pull_request_target` check runs the validator from the
protected base against the PR merge tree, with read-only permissions and no
secrets or untrusted code execution. Configure that base-owned check as a
required ruleset check.

No repository-local evidence format can cryptographically prove that a model
produced a report: the recorded session/provider/model fields are attestations,
not signatures from OpenCode or DeepSeek. CI therefore verifies consistency
and coverage, not provenance or correctness. Human review and protected-branch
policy remain part of the gate. CI intentionally never calls a model or reads
provider credentials.
