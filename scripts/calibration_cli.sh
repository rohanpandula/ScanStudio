#!/usr/bin/env bash
# Thin, explicit command runner for the attended calibration procedure.
# It never selects a scanner/project/film/placement or retries a command.
# Without --execute it only prints the commands it would run.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: calibration_cli.sh --phase PHASE --cli PATH --socket PATH --device ID \
  --project DIR [phase options] [--film-loaded --confirm-motion] [--execute]

PHASE is one of: A1 A2 reload repeat B verify collect.
Required for all phases: --cli, --socket, --device, --project.
Additional options:
  --placement FILE       reviewed placement JSON (A1)
  --settings-a FILE      reviewed settings JSON (A1)
  --outputs-a FILE       reviewed outputs JSON (A1)
  --settings-b FILE      reviewed settings JSON (B)
  --outputs-b FILE       reviewed outputs JSON (B)
  --pass TOKEN            exact token for repeat/verify/collect
  --stock NAME            explicit film stock for collect
  --slot-map FILE         reviewed slot -> physical-frame JSON for collect
  --to DIR                fresh, non-existent collection destination
  --operator NAME         operator recorded in collection metadata
  --film-loaded           explicit physical film-loaded confirmation
  --confirm-motion        explicit authorization for motion
  --execute               execute commands; otherwise print only

The script deliberately has no eject/reload/retry path. Physical reloads and
preview/placement checkpoints remain attended operations.
USAGE
}

cli= socket= device= project= phase= placement= settings_a= outputs_a=
settings_b= outputs_b= pass_token= stock= slot_map= destination= operator=
film_loaded=0 confirm_motion=0 execute=0

need_value() { [[ $# -ge 2 && -n "$2" ]] || { echo "$1 requires a value" >&2; exit 64; }; }
while (($#)); do
    case "$1" in
        --cli) need_value "$1" "${2-}"; cli=$2; shift 2 ;;
        --socket) need_value "$1" "${2-}"; socket=$2; shift 2 ;;
        --device) need_value "$1" "${2-}"; device=$2; shift 2 ;;
        --project) need_value "$1" "${2-}"; project=$2; shift 2 ;;
        --phase) need_value "$1" "${2-}"; phase=$2; shift 2 ;;
        --placement) need_value "$1" "${2-}"; placement=$2; shift 2 ;;
        --settings-a) need_value "$1" "${2-}"; settings_a=$2; shift 2 ;;
        --outputs-a) need_value "$1" "${2-}"; outputs_a=$2; shift 2 ;;
        --settings-b) need_value "$1" "${2-}"; settings_b=$2; shift 2 ;;
        --outputs-b) need_value "$1" "${2-}"; outputs_b=$2; shift 2 ;;
        --pass) need_value "$1" "${2-}"; pass_token=$2; shift 2 ;;
        --stock) need_value "$1" "${2-}"; stock=$2; shift 2 ;;
        --slot-map) need_value "$1" "${2-}"; slot_map=$2; shift 2 ;;
        --to) need_value "$1" "${2-}"; destination=$2; shift 2 ;;
        --operator) need_value "$1" "${2-}"; operator=$2; shift 2 ;;
        --film-loaded) film_loaded=1; shift ;;
        --confirm-motion) confirm_motion=1; shift ;;
        --execute) execute=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[[ -n "$cli" && -x "$cli" ]] || { echo "--cli must name an executable" >&2; exit 64; }
[[ -n "$socket" ]] || { echo "--socket is required" >&2; exit 64; }
[[ -n "$device" ]] || { echo "--device is required; scanner selection is never implicit" >&2; exit 64; }
[[ -n "$project" && -d "$project" ]] || { echo "--project must name an existing prepared project" >&2; exit 64; }
case "$phase" in A1|A2|reload|repeat|B|verify|collect) ;; *) echo "--phase must be A1, A2, reload, repeat, B, verify, or collect" >&2; exit 64 ;; esac

file_arg() { [[ -f "$2" ]] || { echo "$1 does not exist: $2" >&2; exit 64; }; }
require_motion() {
    (( film_loaded )) || { echo "$phase requires --film-loaded" >&2; exit 77; }
    (( confirm_motion )) || { echo "$phase requires --confirm-motion" >&2; exit 77; }
}
run() {
    printf '+ '
    printf '%q ' "$cli" "$@" --socket "$socket" --attach
    printf '\n'
    if (( execute )); then
        "$cli" "$@" --socket "$socket" --attach
    fi
}
require_common() {
    run connect --device "$device"
    run status --refresh
    run roll open "$project"
}

case "$phase" in
    A1)
        require_motion
        file_arg --settings-a "$settings_a"; file_arg --outputs-a "$outputs_a"; file_arg --placement "$placement"
        require_common
        run settings set --from-json "$settings_a"
        run outputs set --from-json "$outputs_a"
        run preview --film-loaded
        run frames place --from "$placement"
        run frames select --all
        run roll solve-exposure --frame 2 --confirm-motion
        run scan --frames 1-36 --pass A1 --confirm-motion --wait
        ;;
    A2)
        require_motion
        require_common
        run settings get
        run outputs get
        run preview --film-loaded
        run frames place --replay
        run frames select --all
        run scan --frames 1-36 --pass A2 --confirm-motion --wait
        ;;
    reload)
        require_motion
        require_common
        run preview --film-loaded
        run frames place --replay
        run frames select --all
        ;;
    repeat)
        require_motion
        [[ "$pass_token" =~ ^Arep(0[1-9]|10)$ ]] || { echo "--pass must be one explicit Arep01...Arep10 token" >&2; exit 64; }
        require_common
        run scan --frames 20 --pass "$pass_token" --confirm-motion --wait
        ;;
    B)
        require_motion
        file_arg --settings-b "$settings_b"; file_arg --outputs-b "$outputs_b"
        require_common
        run settings set --from-json "$settings_b"
        run outputs set --from-json "$outputs_b"
        run preview --film-loaded
        run frames place --replay
        run frames select --all
        run scan --frames 1-36 --pass B --confirm-motion --wait
        ;;
    verify)
        [[ "$pass_token" =~ ^(A1|A2|Arep(0[1-9]|10)|B)$ ]] || { echo "--pass must be an exact A1, A2, Arep01...Arep10, or B token" >&2; exit 64; }
        run roll open "$project"
        if [[ "$pass_token" == B ]]; then
            run roll verify --pass "$pass_token" --no-clipping
        else
            run roll verify --pass "$pass_token" --exposure-identical --no-clipping
        fi
        ;;
    collect)
        [[ "$pass_token" =~ ^(A1|A2|Arep(0[1-9]|10)|B)$ ]] || { echo "--pass must be an exact A1, A2, Arep01...Arep10, or B token" >&2; exit 64; }
        [[ -n "$stock" ]] || { echo "--stock is required; film identity is never implicit" >&2; exit 64; }
        [[ -n "$operator" ]] || { echo "--operator is required" >&2; exit 64; }
        file_arg --slot-map "$slot_map"
        [[ -n "$destination" && ! -e "$destination" ]] || { echo "--to must name a fresh, non-existent destination" >&2; exit 64; }
        run roll open "$project"
        run roll collect --to "$destination" --stock "$stock" --pass "$pass_token" --slot-map "$slot_map" --operator "$operator"
        ;;
esac

if (( execute )); then
    printf 'CALIBRATION COMMAND COMPLETE: phase=%s (physical calibration remains unvalidated)\n' "$phase"
else
    printf 'DRY RUN ONLY: phase=%s; pass --execute after the attended checkpoint.\n' "$phase"
fi
