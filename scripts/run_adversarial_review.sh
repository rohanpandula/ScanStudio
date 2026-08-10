#!/usr/bin/env bash
set -euo pipefail

required_review_model="openrouter/deepseek/deepseek-v4-flash-0731"

if [[ $# -lt 5 ]]; then
  echo "usage: $0 BASE REVIEWED PROVIDER/MODEL PROMPT TITLE [--shard-index N | --primary-path PATH ... | --semantic-plan FILE --semantic-shard-index N | --full] [--context-path PATH ...] [--variant high|low] [--failure-receipt FILE --failure-outcome OUTCOME]" >&2
  exit 2
fi

review_base="$1"
reviewed_commit="$2"
review_model="$3"
prompt_file="$4"
review_title="$5"
shift 5

selector_mode=""
review_selector=""
review_variant="high"
variant_seen=false
primary_paths=()
context_paths=()
semantic_plan=""
semantic_shard_index=""
semantic_index_seen=false
failure_receipt=""
failure_outcome=""

set_selector() {
  local requested="$1"
  if [[ -n "$selector_mode" && "$selector_mode" != "$requested" ]]; then
    echo "review selectors conflict: $selector_mode and $requested" >&2
    exit 2
  fi
  if [[ -n "$selector_mode" && "$requested" != "primary" ]]; then
    echo "review selector $requested may be supplied only once" >&2
    exit 2
  fi
  selector_mode="$requested"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shard-index)
      [[ $# -ge 2 ]] || { echo "--shard-index requires a value" >&2; exit 2; }
      set_selector shard
      review_selector="$2"
      shift 2
      ;;
    --primary-path)
      [[ $# -ge 2 ]] || { echo "--primary-path requires a value" >&2; exit 2; }
      set_selector primary
      primary_paths+=("$2")
      shift 2
      ;;
    --context-path)
      [[ $# -ge 2 ]] || { echo "--context-path requires a value" >&2; exit 2; }
      context_paths+=("$2")
      shift 2
      ;;
    --semantic-plan)
      [[ $# -ge 2 ]] || { echo "--semantic-plan requires a value" >&2; exit 2; }
      set_selector semantic
      semantic_plan="$2"
      shift 2
      ;;
    --semantic-shard-index)
      [[ $# -ge 2 ]] || { echo "--semantic-shard-index requires a value" >&2; exit 2; }
      if [[ "$semantic_index_seen" == true ]]; then
        echo "--semantic-shard-index may be supplied only once" >&2
        exit 2
      fi
      semantic_index_seen=true
      semantic_shard_index="$2"
      shift 2
      ;;
    --full)
      set_selector full
      shift
      ;;
    --variant)
      [[ $# -ge 2 ]] || { echo "--variant requires a value" >&2; exit 2; }
      if [[ "$variant_seen" == true ]]; then
        echo "--variant may be supplied only once" >&2
        exit 2
      fi
      variant_seen=true
      review_variant="$2"
      shift 2
      ;;
    --failure-receipt)
      [[ $# -ge 2 ]] || { echo "--failure-receipt requires a value" >&2; exit 2; }
      if [[ -n "$failure_receipt" ]]; then
        echo "--failure-receipt may be supplied only once" >&2
        exit 2
      fi
      failure_receipt="$2"
      shift 2
      ;;
    --failure-outcome)
      [[ $# -ge 2 ]] || { echo "--failure-outcome requires a value" >&2; exit 2; }
      if [[ -n "$failure_outcome" ]]; then
        echo "--failure-outcome may be supplied only once" >&2
        exit 2
      fi
      failure_outcome="$2"
      shift 2
      ;;
    *)
      echo "unknown review option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$review_base" =~ ^[0-9a-f]{40}$ ]] \
  || [[ ! "$reviewed_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "base and reviewed commit must be full lowercase commit IDs" >&2
  exit 2
fi
if [[ "$review_model" != "$required_review_model" ]]; then
  echo "model must be exactly $required_review_model" >&2
  exit 2
fi
if [[ "$review_variant" != "high" && "$review_variant" != "low" ]]; then
  echo "variant must be high or low" >&2
  exit 2
fi
if [[ -z "$selector_mode" ]]; then
  selector_mode="auto"
fi
if [[ "$review_variant" == "low" && "$selector_mode" != "full" ]]; then
  echo "low is allowed only for mandatory full-diff synthesis fallback" >&2
  exit 2
fi
if [[ "$selector_mode" == "semantic" ]]; then
  if [[ ! "$semantic_shard_index" =~ ^[1-9][0-9]*$ ]]; then
    echo "--semantic-plan requires a positive --semantic-shard-index" >&2
    exit 2
  fi
elif [[ "$semantic_index_seen" == true ]]; then
  echo "--semantic-shard-index requires --semantic-plan" >&2
  exit 2
fi
if [[ ${#context_paths[@]} -gt 0 \
  && "$selector_mode" != "auto" \
  && "$selector_mode" != "shard" \
  && "$selector_mode" != "primary" ]]; then
  echo "context paths are not allowed with this selector" >&2
  exit 2
fi
if [[ -n "$failure_receipt" || -n "$failure_outcome" ]]; then
  if [[ -z "$failure_receipt" || -z "$failure_outcome" ]]; then
    echo "--failure-receipt and --failure-outcome must be supplied together" >&2
    exit 2
  fi
  if [[ "$selector_mode" != "full" || "$review_variant" != "high" ]]; then
    echo "failure receipts are only available for high full-diff synthesis attempts" >&2
    exit 2
  fi
  case "$failure_outcome" in
    EMPTY_REPORT|NO_FINAL_VERDICT|OUTPUT_LIMIT) ;;
    *)
      echo "unsupported failure outcome: $failure_outcome" >&2
      exit 2
      ;;
  esac
  if [[ -e "$failure_receipt" || -L "$failure_receipt" ]]; then
    echo "failure receipt target must not already exist" >&2
    exit 2
  fi
fi

repository_root="$(git rev-parse --show-toplevel)"
if [[ -L "$repository_root/docs/adversarial-review-prompts/security-reliability.txt" \
  || -L "$repository_root/docs/adversarial-review-prompts/cross-layer-correctness.txt" ]]; then
  echo "canonical review prompts must not be symlinks" >&2
  exit 2
fi
security_prompt="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' \
  "$repository_root/docs/adversarial-review-prompts/security-reliability.txt")"
correctness_prompt="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' \
  "$repository_root/docs/adversarial-review-prompts/cross-layer-correctness.txt")"
if [[ ! -f "$prompt_file" || -L "$prompt_file" ]]; then
  echo "prompt must be a regular non-symlink file" >&2
  exit 2
fi
prompt_absolute="$(python3 - "$prompt_file" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).resolve(strict=True))
PY
)"
if [[ "$prompt_absolute" == "$security_prompt" ]]; then
  review_role="security-reliability"
elif [[ "$prompt_absolute" == "$correctness_prompt" ]]; then
  review_role="cross-layer-correctness"
else
  echo "prompt must be one of the two canonical repository review prompts" >&2
  exit 2
fi

if [[ -n "$(git -C "$repository_root" status --porcelain=v1 \
  --untracked-files=all --ignore-submodules=none)" ]]; then
  echo "review requires a clean worktree, including submodules" >&2
  exit 2
fi
if [[ "$review_base" == "$reviewed_commit" ]]; then
  echo "base and reviewed commits must differ" >&2
  exit 2
fi
git cat-file -e "${review_base}^{commit}"
git cat-file -e "${reviewed_commit}^{commit}"
git merge-base --is-ancestor "$review_base" "$reviewed_commit"

opencode_bin="$(command -v opencode)"
opencode_version="$("$opencode_bin" --version)"
if [[ ! "$opencode_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "OpenCode version is not a single semver-like value" >&2
  exit 2
fi

review_sandbox="$(mktemp -d)"
review_input_file="$(mktemp)"
input_metadata_file="$(mktemp)"
request_file="$(mktemp)"
title_file="$(mktemp)"
event_file="$(mktemp)"
export_file="$(mktemp)"
opencode_error_file="$(mktemp)"
export_error_file="$(mktemp)"
receipt_temp_file="$(mktemp)"
# shellcheck disable=SC2329  # Invoked indirectly by EXIT trap.
cleanup() {
  rm -f \
    "$review_input_file" "$input_metadata_file" "$request_file" "$title_file" \
    "$event_file" "$export_file" "$opencode_error_file" "$export_error_file" \
    "$receipt_temp_file"
  rmdir "$review_sandbox" 2>/dev/null || true
}
trap cleanup EXIT

input_command=(python3 "$repository_root/scripts/adversarial_review_input.py")
if [[ "$selector_mode" == "auto" ]]; then
  shard_count="$("${input_command[@]}" plan "$review_base" "$reviewed_commit" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["shards"]))')"
  if [[ "$shard_count" != "1" ]]; then
    echo "canonical diff has $shard_count shards; pass an explicit selector" >&2
    exit 2
  fi
  selector_mode="shard"
  review_selector="1"
fi

case "$selector_mode" in
  full)
    "${input_command[@]}" emit-full "$review_base" "$reviewed_commit" \
      >"$review_input_file"
    "${input_command[@]}" describe-full "$review_base" "$reviewed_commit" \
      >"$input_metadata_file"
    ;;
  semantic)
    selection_args=(
      --semantic-plan "$semantic_plan"
      --semantic-shard-index "$semantic_shard_index"
    )
    "${input_command[@]}" emit "$review_base" "$reviewed_commit" \
      "${selection_args[@]}" >"$review_input_file"
    "${input_command[@]}" describe "$review_base" "$reviewed_commit" \
      "${selection_args[@]}" >"$input_metadata_file"
    ;;
  primary)
    selection_args=()
    for path in "${primary_paths[@]}"; do
      selection_args+=(--primary-path "$path")
    done
    for path in "${context_paths[@]}"; do
      selection_args+=(--context-path "$path")
    done
    "${input_command[@]}" emit "$review_base" "$reviewed_commit" \
      "${selection_args[@]}" >"$review_input_file"
    "${input_command[@]}" describe "$review_base" "$reviewed_commit" \
      "${selection_args[@]}" >"$input_metadata_file"
    ;;
  shard)
    if [[ ! "$review_selector" =~ ^[1-9][0-9]*$ ]]; then
      echo "--shard-index must be a positive integer" >&2
      exit 2
    fi
    selection_args=(--shard-index "$review_selector")
    for path in "${context_paths[@]}"; do
      selection_args+=(--context-path "$path")
    done
    "${input_command[@]}" emit "$review_base" "$reviewed_commit" \
      "${selection_args[@]}" >"$review_input_file"
    "${input_command[@]}" describe "$review_base" "$reviewed_commit" \
      "${selection_args[@]}" >"$input_metadata_file"
    ;;
  *)
    echo "internal error: unsupported selector" >&2
    exit 2
    ;;
esac

if [[ ! -s "$review_input_file" ]]; then
  echo "deterministic review input is empty" >&2
  exit 2
fi
"${input_command[@]}" request --prompt "$prompt_absolute" --input "$review_input_file" \
  >"$request_file"
printf '%s' "$review_title" >"$title_file"
python3 "$repository_root/scripts/check_adversarial_review.py" \
  --scan-artifact "$request_file" >/dev/null
python3 "$repository_root/scripts/check_adversarial_review.py" \
  --scan-title "$title_file" >/dev/null

input_sha256="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["inputSha256"])' \
  <"$input_metadata_file")"
request_sha256="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' \
  <"$request_file")"
python3 - "$input_metadata_file" "$request_sha256" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value["requestSha256"] = sys.argv[2]
print("REVIEW_INPUT_METADATA " + json.dumps(value, sort_keys=True, separators=(",", ":")), file=sys.stderr)
PY

run_status=0
env \
  OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_DISABLE_CLAUDE_CODE=1 \
  OPENCODE_DISABLE_PROJECT_CONFIG=1 \
  OPENCODE_CONFIG_CONTENT='{"share":"disabled","instructions":[],"permission":{"*":"deny"},"agent":{"build":{"permission":{"*":"deny"}}}}' \
  "$opencode_bin" run \
    --pure \
    --agent build \
    --format json \
    --model "$review_model" \
    --variant "$review_variant" \
    --dir "$review_sandbox" \
    --title "$review_title" <"$request_file" >"$event_file" 2>"$opencode_error_file" \
  || run_status=$?

session_id="$(python3 "$repository_root/scripts/parse_opencode_review.py" \
  session-id --events "$event_file")" || {
  echo "OpenCode did not produce one identifiable session" >&2
  exit 1
}

export_status=0
(
  cd "$review_sandbox"
  env \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_CLAUDE_CODE=1 \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    OPENCODE_CONFIG_CONTENT='{"share":"disabled","instructions":[],"permission":{"*":"deny"},"agent":{"build":{"permission":{"*":"deny"}}}}' \
    "$opencode_bin" export --pure "$session_id"
) >"$export_file" 2>"$export_error_file" || export_status=$?
if [[ "$export_status" -ne 0 ]]; then
  echo "OpenCode session export failed" >&2
  exit 1
fi

report_status=0
python3 "$repository_root/scripts/parse_opencode_review.py" report \
  --events "$event_file" \
  --export "$export_file" \
  --request "$request_file" \
  --tool-version "$opencode_version" \
  --provider openrouter \
  --model deepseek/deepseek-v4-flash-0731 \
  --variant "$review_variant" || report_status=$?
if [[ "$run_status" -eq 0 && "$report_status" -eq 0 ]]; then
  exit 0
fi

if [[ -z "$failure_receipt" ]]; then
  echo "OpenCode review failed before a verifiable report was produced" >&2
  exit 1
fi
python3 "$repository_root/scripts/parse_opencode_review.py" failure-receipt \
  --events "$event_file" \
  --export "$export_file" \
  --request "$request_file" \
  --tool-version "$opencode_version" \
  --base "$review_base" \
  --reviewed "$reviewed_commit" \
  --role "$review_role" \
  --input-sha256 "$input_sha256" \
  --outcome "$failure_outcome" \
  --provider openrouter \
  --model deepseek/deepseek-v4-flash-0731 >"$receipt_temp_file"
if ! (set -o noclobber; cat "$receipt_temp_file" >"$failure_receipt"); then
  echo "failure receipt target already exists or is not writable" >&2
  exit 1
fi
echo "FAILURE_RECEIPT $failure_receipt" >&2
exit 1
