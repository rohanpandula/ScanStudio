#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 BASE_COMMIT REVIEWED_COMMIT PROVIDER/MODEL PROMPT_FILE TITLE" >&2
  exit 2
fi

review_base="$1"
reviewed_commit="$2"
review_model="$3"
prompt_file="$4"
review_title="$5"

if [[ ! "$review_base" =~ ^[0-9a-f]{40}$ ]] \
  || [[ ! "$reviewed_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "base and reviewed commit must be full lowercase commit IDs" >&2
  exit 2
fi
if [[ ! "$review_model" =~ /deepseek-v4-flash-0731$ ]]; then
  echo "model must use the version-pinned deepseek-v4-flash-0731 ID" >&2
  exit 2
fi
if [[ ! -f "$prompt_file" ]]; then
  echo "prompt file does not exist: $prompt_file" >&2
  exit 2
fi

repository_root="$(git rev-parse --show-toplevel)"
if [[ -n "$(git -C "$repository_root" status --porcelain --untracked-files=all)" ]]; then
  echo "review requires a clean worktree so the committed diff is authoritative" >&2
  exit 2
fi
if [[ "$review_base" == "$reviewed_commit" ]]; then
  echo "base and reviewed commits must differ" >&2
  exit 2
fi
review_sandbox="$(mktemp -d)"
diff_file="$(mktemp)"
report_file="$(mktemp)"
cleanup() {
  rm -f "$diff_file" "$report_file"
  rmdir "$review_sandbox"
}
trap cleanup EXIT

git cat-file -e "${review_base}^{commit}"
git cat-file -e "${reviewed_commit}^{commit}"
GIT_OPTIONAL_LOCKS=0 git -c core.quotePath=true --no-pager diff \
  --binary \
  --full-index \
  --no-renames \
  --no-ext-diff \
  --no-textconv \
  --no-color \
  --diff-algorithm=histogram \
  --indent-heuristic \
  --inter-hunk-context=0 \
  --src-prefix=a/ \
  --dst-prefix=b/ \
  --output-indicator-new=+ \
  --output-indicator-old=- \
  --output-indicator-context=' ' \
  --unified=3 \
  "$review_base" "$reviewed_commit" >"$diff_file"
if [[ ! -s "$diff_file" ]]; then
  echo "canonical review diff is empty" >&2
  exit 2
fi

python3 "$repository_root/scripts/check_adversarial_review.py" \
  --scan-artifact "$prompt_file" >/dev/null
python3 "$repository_root/scripts/check_adversarial_review.py" \
  --scan-artifact "$diff_file" >/dev/null

{
  cat "$prompt_file"
  printf '\n--- BEGIN FROZEN TRACKED-FILES DIFF ---\n'
  cat "$diff_file"
  printf '\n--- END FROZEN TRACKED-FILES DIFF ---\n'
} | env \
  OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_DISABLE_CLAUDE_CODE=1 \
  OPENCODE_DISABLE_PROJECT_CONFIG=1 \
  OPENCODE_CONFIG_CONTENT='{"share":"disabled","instructions":[],"permission":{"*":"deny"},"agent":{"build":{"permission":{"*":"deny"}}}}' \
  opencode run \
    --pure \
    --agent build \
    --model "$review_model" \
    --variant high \
    --dir "$review_sandbox" \
    --title "$review_title" | tee "$report_file"

if ! grep -Eiq '^[[:space:]#>*-]*VERDICT:[[:space:]]*(PASS|REQUEST_CHANGES|BLOCK)[[:space:]]*$' "$report_file"; then
  echo "review did not emit a final machine-checkable VERDICT line" >&2
  exit 1
fi
