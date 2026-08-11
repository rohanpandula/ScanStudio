#!/usr/bin/env bash
set -euo pipefail

# Offline safety tests for the Windows owner-session launcher. The WSL helper
# is exercised against an isolated state directory on macOS/Linux; PowerShell,
# NSIS, and packaging wiring are checked structurally here and parsed again by
# build-and-verify.ps1 on the Windows packaging runner.

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
windows_dir="$(cd "$tests_dir/.." && pwd)"
port_root="$(cd "$windows_dir/../.." && pwd)"
repo_root="$(cd "$port_root/../.." && pwd)"

helper="$windows_dir/scanstudio-hardware-session-latch.sh"
launcher="$windows_dir/Start-ScanStudio-Hardware-Session.ps1"
entrypoint="$windows_dir/Start-ScanStudio-Hardware-Session.cmd"
hooks="$windows_dir/installer-hooks.nsh"
assembler="$windows_dir/assemble-staging.sh"
manifest="$port_root/packaging/license-manifest.json"
tauri_config="$port_root/app/src-tauri/tauri.windows.conf.json"
windows_builder="$windows_dir/build-and-verify.ps1"
windows_black_box="$tests_dir/test-hardware-session-launcher.ps1"
checker="$port_root/app/src-tauri/src/wsl/checker.rs"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

require_text() {
    local file="$1" text="$2" label="$3"
    if [[ -f "$file" ]] && grep -Fq -- "$text" "$file"; then
        pass "$label"
    else
        fail "$label (missing: $text)"
    fi
}

reject_regex() {
    local file="$1" pattern="$2" label="$3"
    if [[ -f "$file" ]] && ! grep -Eiq -- "$pattern" "$file"; then
        pass "$label"
    else
        fail "$label"
    fi
}

for file in "$helper" "$launcher" "$entrypoint" "$hooks"; do
    [[ -f "$file" ]] || fail "required launcher source exists: $file"
done

if sh -n "$helper"; then
    pass 'WSL latch helper parses as POSIX shell'
else
    fail 'WSL latch helper parses as POSIX shell'
fi

require_text "$launcher" "\$DistroName = 'Ubuntu-24.04'" \
    'launcher pins the WSL distribution'
require_text "$launcher" "Get-Process -Name 'scanstudio-app'" \
    'launcher refuses an already-running app'
require_text "$launcher" '[System.Diagnostics.ProcessStartInfo]::new()' \
    'launcher starts an actual child process without a shell'
require_text "$launcher" "EnvironmentVariables['SCANSTUDIO_HW_MOTION'] = '1'" \
    'launcher authorizes only the child environment'
# shellcheck disable=SC2016 # literal PowerShell source assertion
require_text "$launcher" '$process.WaitForExit()' \
    'launcher waits for the actual child process'
require_text "$launcher" '-Operation release' \
    'launcher always has an ownership-checked release path'
require_text "$launcher" "Join-Path \$env:SystemRoot 'System32\\wsl.exe'" \
    'launcher uses the absolute Windows WSL executable'
require_text "$launcher" '-e /bin/sh' \
    'launcher passes helper arguments directly without a command string'
require_text "$launcher" "'SCANSTUDIO_BRIDGE_BASE_DIR'" \
    'launcher strips bridge-base override state'
require_text "$launcher" "'SCANSTUDIO_STATE_DIR'" \
    'launcher strips state-directory override state'
require_text "$launcher" "'HOME'" \
    'launcher strips HOME forwarding from WSLENV'
require_text "$launcher" 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE' \
    'launcher creates a kill-on-close Windows process job'
require_text "$launcher" 'AssignProcessToJobObject(job, GetCurrentProcess())' \
    'launcher joins the job before creating later descendants'
require_text "$launcher" 'Start-CleanupGuardian' \
    'launcher starts a detached ownership cleanup guardian'
# shellcheck disable=SC2016 # literal PowerShell source assertion
require_text "$launcher" '$guardianReadyEvent.WaitOne(10000)' \
    'launcher waits for the detached guardian to report ready'
require_text "$launcher" '-Operation check-orphans' \
    'launcher checks WSL bridge orphans around latch acquisition'
# The guardian must not unblock the main launcher until it has opened and
# verified the exact owner process it promises to supervise.
# shellcheck disable=SC2016 # literal PowerShell source assertion
guardian_owner_line="$(grep -n -F '$ownerProcess = [System.Diagnostics.Process]::GetProcessById($OwnerProcessId)' "$launcher" | head -n 1 | cut -d: -f1)"
# shellcheck disable=SC2016 # literal PowerShell source assertion
guardian_ready_line="$(grep -n -F '$readyEvent = [Threading.EventWaitHandle]::OpenExisting($GuardianReadyEventName)' "$launcher" | head -n 1 | cut -d: -f1)"
if [[ -n "$guardian_owner_line" && -n "$guardian_ready_line" \
    && "$guardian_owner_line" -lt "$guardian_ready_line" ]]; then
    pass 'guardian verifies the exact owner before reporting ready'
else
    fail 'guardian must verify the exact owner before reporting ready'
fi
reject_regex "$launcher" '(^|[^[:alnum:]_])setx([^[:alnum:]_]|$)' \
    'launcher never persists authorization'
# shellcheck disable=SC2016 # literal PowerShell source assertion
reject_regex "$launcher" '^[[:space:]]*\$env:SCANSTUDIO_HW_MOTION[[:space:]]*=' \
    'launcher never authorizes its whole PowerShell process'
reject_regex "$launcher" 'Start-Process' \
    'launcher does not lose the child handle through detached launching'

require_text "$entrypoint" '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' \
    'double-click entrypoint avoids PATH lookup'
require_text "$entrypoint" 'pause >nul' \
    'double-click entrypoint keeps cleanup evidence visible'
# shellcheck disable=SC2016 # literal NSIS source assertion
require_text "$hooks" '${PRODUCTNAME} Hardware Session.lnk' \
    'installer adds a clearly separate hardware-session shortcut'
require_text "$hooks" 'Start-ScanStudio-Hardware-Session.cmd' \
    'hardware-session shortcut targets only the dedicated entrypoint'
require_text "$hooks" 'NSIS_HOOK_POSTUNINSTALL' \
    'installer removes the hardware shortcut only after uninstall succeeds'
require_text "$hooks" 'IsShortcutTarget' \
    'uninstaller deletes only its own matching hardware shortcut'
reject_regex "$hooks" 'SCANSTUDIO_HW_MOTION' \
    'installer hook does not authorize the normal app shortcut'
require_text "$tauri_config" '"installerHooks": "../../packaging/windows/installer-hooks.nsh"' \
    'Tauri NSIS build loads the hardware-session shortcut hook'

for packaged_file in \
    Start-ScanStudio-Hardware-Session.ps1 \
    Start-ScanStudio-Hardware-Session.cmd \
    scanstudio-hardware-session-latch.sh; do
    require_text "$assembler" "$packaged_file" \
        "staging assembler includes $packaged_file"
    require_text "$manifest" "\"$packaged_file\"" \
        "bundle manifest requires $packaged_file"
done

syntax_assertions="$(grep -Fc 'Assert-HardwareSessionLauncherSyntax' "$windows_builder" || true)"
if [[ "$syntax_assertions" -ge 4 ]]; then
    pass 'Windows build parses launcher in staging, installed, and portable trees'
else
    fail 'Windows build must parse launcher in staging, installed, and portable trees'
fi

black_box_assertions="$(grep -Fc 'Invoke-HardwareSessionLauncherBlackBox' "$windows_builder" || true)"
if [[ -f "$windows_black_box" && "$black_box_assertions" -ge 4 ]]; then
    pass 'Windows build runs the behavioral launcher suite for source, installed, and portable layouts'
else
    fail 'Windows build must run the behavioral launcher suite for source, installed, and portable layouts'
fi
# shellcheck disable=SC2016 # literal PowerShell source assertion
require_text "$windows_black_box" '$forcedLauncher.Kill()' \
    'Windows behavioral suite force-kills the launcher owner'
require_text "$windows_black_box" 'guardian leaves a foreign replacement latch untouched' \
    'Windows behavioral suite checks guardian ownership after forced death'
require_text "$windows_black_box" 'guardian removes the matching owned latch after forced launcher death' \
    'Windows behavioral suite checks guardian cleanup after forced death'
# shellcheck disable=SC2016 # literal PowerShell source assertions
require_text "$launcher" '-TestWslExe $TestWslExe' \
    'production main passes only the optional test override to the guardian'
# shellcheck disable=SC2016 # literal PowerShell regression assertion
if grep -Fq -- '-TestWslExe $wslExe' "$launcher"; then
    fail 'production main must not misclassify resolved System32 WSL as a test override'
else
    pass 'production guardian omits the fake-WSL argument'
fi
require_text "$windows_builder" 'Assert-HardwareSessionShortcut' \
    'Windows build resolves the installed hardware-session shortcut'
require_text "$windows_builder" 'Assert-HardwareSessionLauncherLayout' \
    'Windows build checks launcher and main-executable co-location'
require_text "$windows_builder" 'Assert-NoExistingScanStudioInstall' \
    'Windows package verifier refuses to overwrite a real current-user install'
require_text "$windows_builder" "GetFolderPath('Desktop')" \
    'Windows package verifier protects an existing desktop shortcut'
require_text "$windows_builder" 'Uninstall\ScanStudio' \
    'Windows package verifier checks the fixed Tauri uninstall key directly'
# shellcheck disable=SC2016 # literal PowerShell source assertion
require_text "$windows_builder" '$productKeyPath = Join-Path $manufacturerKey.PSPath' \
    'Windows package verifier checks the Tauri manufacturer/product install key'
require_text "$windows_builder" 'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall' \
    'Windows package verifier protects an existing machine-wide ScanStudio install'
require_text "$windows_builder" "Get-Process -Name 'scanstudio-app'" \
    'Windows package verifier refuses a running portable app'
require_text "$windows_builder" "Test-RegistryValueExists -Path \$runKey -Name 'ScanStudio'" \
    'Windows package verifier protects the current-user ScanStudio Run value'
require_text "$windows_builder" 'Remove-OwnedTemporaryProductRegistryKey' \
    'Windows package verifier ownership-checks temporary product-key cleanup'
require_text "$windows_builder" 'Assert-TemporaryInstallUserStateRemoved' \
    'Windows package verifier checks that temporary user state is gone'
require_text "$windows_builder" 'Assert-TemporaryUninstallOwnership' \
    'Windows package verifier ownership-checks state immediately before uninstall'
require_text "$windows_builder" 'ExpectedProductRegistryPath' \
    'Windows package verifier pins the exact temporary product registry path'
require_text "$windows_builder" '[IO.FileMode]::CreateNew' \
    'Windows package verifier publishes release outputs without overwriting'
require_text "$windows_builder" 'Publish-VerifiedOutputs' \
    'Windows package verifier publishes the setup and portable outputs as one rollback pair'
# shellcheck disable=SC2016 # literal PowerShell source assertion
require_text "$windows_builder" '-not $installerMayHaveModifiedUserState -or $temporaryUserStateRemoved' \
    'Windows package verifier deletes its temporary tree only after cleanup is proven'
require_text "$windows_builder" 'Preserving the temporary install tree because user-state cleanup could not be proven' \
    'Windows package verifier retains the uninstaller when cleanup is unproven'
# shellcheck disable=SC2016 # literal PowerShell source assertion
require_text "$windows_builder" 'if ($temporaryInstallRemoved -and -not $temporaryUserStateRemoved)' \
    'Windows package verifier does not re-run cleanup after proof and publication'

package_preflight_line="$(grep -nF 'Assert-NoExistingScanStudioInstall' "$windows_builder" | tail -1 | cut -d: -f1 || true)"
# shellcheck disable=SC2016 # literal PowerShell source assertion
installer_start_line="$(grep -nF '$installerProcess = Start-Process' "$windows_builder" | head -1 | cut -d: -f1 || true)"
if [[ -n "$package_preflight_line" && -n "$installer_start_line" \
    && "$package_preflight_line" -lt "$installer_start_line" ]]; then
    pass 'Windows package verifier preflights user state before starting NSIS'
else
    fail 'Windows package verifier must preflight user state before starting NSIS'
fi

uninstall_preflight_line="$(grep -nF 'Assert-TemporaryUninstallOwnership' "$windows_builder" | tail -1 | cut -d: -f1 || true)"
# shellcheck disable=SC2016 # literal PowerShell source assertion
uninstaller_start_line="$(grep -nF '$uninstallerProcess = Start-Process' "$windows_builder" | head -1 | cut -d: -f1 || true)"
if [[ -n "$uninstall_preflight_line" && -n "$uninstaller_start_line" \
    && "$uninstall_preflight_line" -lt "$uninstaller_start_line" ]]; then
    pass 'Windows package verifier ownership-checks state immediately before starting the uninstaller'
else
    fail 'Windows package verifier must ownership-check state immediately before starting the uninstaller'
fi

# shellcheck disable=SC2016 # literal PowerShell source assertion
verified_cleanup_line="$(grep -nF 'Assert-TemporaryInstallUserStateRemoved -InstallRoot $installRoot' "$windows_builder" | head -1 | cut -d: -f1 || true)"
publish_outputs_line="$(grep -nF 'Publish-VerifiedOutputs `' "$windows_builder" | tail -1 | cut -d: -f1 || true)"
if [[ -n "$verified_cleanup_line" && -n "$publish_outputs_line" \
    && "$verified_cleanup_line" -lt "$publish_outputs_line" ]]; then
    pass 'Windows package verifier publishes release-named outputs only after uninstall cleanup passes'
else
    fail 'Windows package verifier must delay release-named outputs until uninstall cleanup passes'
fi

new_usbipd_command='usbipd attach --wsl Ubuntu-24.04 --busid=<busid>'
usbipd_command_count="$(
    # shellcheck disable=SC2126 # total matches across three files is intentional
    {
        grep -Fh -- "$new_usbipd_command" \
            "$port_root/runbooks/WINDOWS-LIVE-VALIDATION.md" \
            "$port_root/runbooks/WINDOWS-WSL-LANE.md"
        awk '/#\[cfg\(test\)\]/{exit} {print}' "$checker" \
            | grep -F -- "$new_usbipd_command"
    } | wc -l | tr -d '[:space:]'
)"
if [[ "$usbipd_command_count" -eq 5 ]] \
    && ! grep -Eq -- 'usbipd attach --wsl --busid|--distribution Ubuntu-24\.04' \
        "$port_root/runbooks/WINDOWS-LIVE-VALIDATION.md" \
        "$port_root/runbooks/WINDOWS-WSL-LANE.md" \
        "$checker"; then
    pass 'all five Windows operator/checker instructions use usbipd-win 5.3 syntax'
else
    fail "expected five usbipd-win 5.3 attach instructions (got $usbipd_command_count)"
fi

# shellcheck disable=SC2016 # literal PowerShell source assertions
job_line="$(grep -nF '$jobHandle = Initialize-KillOnCloseJob' "$launcher" | head -1 | cut -d: -f1 || true)"
# shellcheck disable=SC2016 # literal PowerShell source assertions
app_line="$(grep -nF '$process = [System.Diagnostics.Process]::new()' "$launcher" | tail -1 | cut -d: -f1 || true)"
if [[ -n "$job_line" && -n "$app_line" && "$job_line" -lt "$app_line" ]]; then
    pass 'launcher joins its kill-on-close job before creating the GUI child'
else
    fail 'launcher must join its kill-on-close job before creating the GUI child'
fi

if cmp -s "$repo_root/app/ScanStudio/protocol/PROTOCOL.md" \
    "$port_root/vendor/protocol/PROTOCOL.md" \
    && cmp -s "$repo_root/app/ScanStudio/protocol/BRIDGE.md" \
    "$port_root/vendor/protocol/BRIDGE.md"; then
    pass 'primary and vendored motion-launch protocol documentation match'
else
    fail 'primary and vendored motion-launch protocol documentation must match'
fi

sandbox="$(mktemp -d /tmp/scanstudio-hw-session-test.XXXXXX)"
test_home="$sandbox/home"
state_dir="$test_home/.scanstudio"
latch="$state_dir/hw-motion-armed"
operation_lock="$state_dir/.hw-motion-launcher-operation-lock"
trap 'rm -rf -- "$sandbox"' EXIT

encode_text() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}

expect_rc() {
    local expected="$1" label="$2"
    shift 2
    set +e
    "$@" > "$sandbox/last.stdout" 2> "$sandbox/last.stderr"
    local actual=$?
    set -e
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$label (exit $actual)"
    else
        fail "$label (expected exit $expected, got $actual)"
        sed 's/^/      /' "$sandbox/last.stderr" >&2 || true
    fi
}

invoke_helper() {
    env HOME="$test_home" sh "$helper" "$@"
}

token_a='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
token_b='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
media='junk roll A-01'
media_b64="$(encode_text "$media")"

reject_regex "$helper" 'SCANSTUDIO_STATE_DIR' \
    'production helper has no state-directory override seam'
expect_rc 0 'orphan preflight is clear in the isolated test environment' \
    invoke_helper check-orphans "$token_a" "$media_b64"

expect_rc 64 'invalid ownership token is rejected' \
    invoke_helper acquire short "$media_b64"
expect_rc 64 'empty media name is rejected' \
    invoke_helper acquire "$token_a" "$(encode_text '')"
expect_rc 64 'blank media name is rejected' \
    invoke_helper acquire "$token_a" "$(encode_text '   ')"
control_b64="$(printf 'bad\nlabel' | base64 | tr -d '\r\n')"
expect_rc 64 'media label with a line break is rejected' \
    invoke_helper acquire "$token_a" "$control_b64"
invalid_utf8_b64="$(printf '\377' | base64 | tr -d '\r\n')"
expect_rc 64 'invalid UTF-8 media label is rejected' \
    invoke_helper acquire "$token_a" "$invalid_utf8_b64"
oversize_b64="$(dd if=/dev/zero bs=4097 count=1 2>/dev/null | tr '\000' a | base64 | tr -d '\r\n')"
expect_rc 64 'oversize media label is rejected' \
    invoke_helper acquire "$token_a" "$oversize_b64"

injection_marker="$sandbox/label-was-executed"
injection_label="--exec; touch $injection_marker; \$(touch $injection_marker)"
injection_b64="$(encode_text "$injection_label")"
expect_rc 0 'shell-looking media label is treated as inert data' \
    invoke_helper acquire "$token_a" "$injection_b64"
if [[ ! -e "$injection_marker" ]] && grep -Fq -- "$injection_label" "$latch"; then
    pass 'media-label metacharacters are neither interpreted nor lost'
else
    fail 'media-label metacharacters are neither interpreted nor lost'
fi
expect_rc 0 'matching owner can release injection-label latch' \
    invoke_helper release "$token_a" "$injection_b64"

expect_rc 0 'valid owner acquires latch' \
    invoke_helper acquire "$token_a" "$media_b64"
if [[ -f "$latch" && ! -L "$latch" ]]; then
    pass 'published latch is a regular non-symlink file'
else
    fail 'published latch is a regular non-symlink file'
fi
state_mode="$(stat -c '%a' "$state_dir" 2>/dev/null || stat -f '%Lp' "$state_dir")"
latch_mode="$(stat -c '%a' "$latch" 2>/dev/null || stat -f '%Lp' "$latch")"
if [[ "$state_mode" == '700' ]]; then
    pass 'state directory mode is 0700'
else
    fail "state directory mode is 0700 (got $state_mode)"
fi
if [[ "$latch_mode" == '600' ]]; then
    pass 'latch mode is 0600'
else
    fail "latch mode is 0600 (got $latch_mode)"
fi
latch_size="$(wc -c < "$latch" | tr -d '[:space:]')"
if [[ "$latch_size" -gt 0 && "$latch_size" -le 4096 ]] && iconv -f UTF-8 -t UTF-8 "$latch" >/dev/null 2>&1; then
    pass 'latch is nonblank valid UTF-8 and no larger than 4096 bytes'
else
    fail "latch is nonblank valid UTF-8 and no larger than 4096 bytes (got $latch_size)"
fi
expect_rc 0 'matching token and media verify latch ownership' \
    invoke_helper verify "$token_a" "$media_b64"
expect_rc 73 'second token cannot clobber existing latch' \
    invoke_helper acquire "$token_b" "$(encode_text 'other roll')"
expect_rc 74 'wrong token cannot release another session latch' \
    invoke_helper release "$token_b" "$media_b64"
if [[ -f "$latch" ]]; then
    pass 'wrong-token release leaves latch untouched'
else
    fail 'wrong-token release leaves latch untouched'
fi
expect_rc 0 'matching token releases its latch' \
    invoke_helper release "$token_a" "$media_b64"
if [[ ! -e "$latch" && ! -L "$latch" ]]; then
    pass 'matching release removes latch'
else
    fail 'matching release removes latch'
fi

# Race two acquisitions. Atomic hard-link publication must produce exactly one
# winner and one conflict, with no partial or mixed latch content.
(
    set +e
    invoke_helper acquire "$token_a" "$(encode_text 'race A')" > "$sandbox/race-a.out" 2>&1
    printf '%s\n' "$?" > "$sandbox/race-a.rc"
) &
race_a_pid=$!
(
    set +e
    invoke_helper acquire "$token_b" "$(encode_text 'race B')" > "$sandbox/race-b.out" 2>&1
    printf '%s\n' "$?" > "$sandbox/race-b.rc"
) &
race_b_pid=$!
wait "$race_a_pid" "$race_b_pid"
race_a_rc="$(cat "$sandbox/race-a.rc")"
race_b_rc="$(cat "$sandbox/race-b.rc")"
if [[ "$race_a_rc $race_b_rc" == '0 73' || "$race_a_rc $race_b_rc" == '73 0' ]]; then
    pass 'concurrent acquisitions produce one owner and one conflict'
else
    fail "concurrent acquisitions produce one owner and one conflict (got $race_a_rc/$race_b_rc)"
fi
if [[ "$race_a_rc" == '0' ]]; then
    race_token="$token_a"
    race_media_b64="$(encode_text 'race A')"
else
    race_token="$token_b"
    race_media_b64="$(encode_text 'race B')"
fi
expect_rc 0 'concurrency winner exclusively owns complete latch' \
    invoke_helper verify "$race_token" "$race_media_b64"
expect_rc 0 'concurrency winner releases complete latch' \
    invoke_helper release "$race_token" "$race_media_b64"

expect_rc 0 'owner acquires latch for mutation test' \
    invoke_helper acquire "$token_a" "$media_b64"
printf 'externally changed\n' > "$latch"
expect_rc 74 'changed latch is not deleted by former owner' \
    invoke_helper release "$token_a" "$media_b64"
if grep -Fq 'externally changed' "$latch"; then
    pass 'changed latch remains untouched'
else
    fail 'changed latch remains untouched'
fi
rm -f -- "$latch"

: > "$latch"
expect_rc 73 'pre-existing empty latch blocks acquisition' \
    invoke_helper acquire "$token_a" "$media_b64"
expect_rc 74 'pre-existing empty latch is never removed as owned' \
    invoke_helper release "$token_a" "$media_b64"
if [[ -f "$latch" ]]; then
    pass 'empty latch remains for explicit operator inspection'
else
    fail 'empty latch remains for explicit operator inspection'
fi
rm -f -- "$latch"

symlink_target="$sandbox/symlink-target"
printf 'do not touch\n' > "$symlink_target"
ln -s "$symlink_target" "$latch"
expect_rc 73 'symlink latch blocks acquisition' \
    invoke_helper acquire "$token_a" "$media_b64"
expect_rc 74 'symlink latch is never followed or removed on release' \
    invoke_helper release "$token_a" "$media_b64"
if [[ -L "$latch" ]] && grep -Fq 'do not touch' "$symlink_target"; then
    pass 'symlink and target remain untouched'
else
    fail 'symlink and target remain untouched'
fi
rm -f -- "$latch"

mkfifo "$latch"
expect_rc 73 'FIFO latch blocks acquisition without blocking' \
    invoke_helper acquire "$token_a" "$media_b64"
expect_rc 74 'FIFO latch is never read or removed on release' \
    invoke_helper release "$token_a" "$media_b64"
if [[ -p "$latch" ]]; then
    pass 'FIFO latch remains untouched'
else
    fail 'FIFO latch remains untouched'
fi
rm -f -- "$latch"

mkdir "$latch"
expect_rc 73 'directory latch blocks acquisition' \
    invoke_helper acquire "$token_a" "$media_b64"
expect_rc 74 'directory latch is never removed on release' \
    invoke_helper release "$token_a" "$media_b64"
if [[ -d "$latch" ]]; then
    pass 'directory latch remains untouched'
else
    fail 'directory latch remains untouched'
fi
rmdir "$latch"

mkdir "$operation_lock"
expect_rc 73 'stale launcher-operation lock blocks orphan preflight' \
    invoke_helper check-orphans "$token_a" "$media_b64"
expect_rc 73 'stale launcher-operation lock blocks acquisition' \
    invoke_helper acquire "$token_a" "$media_b64"
expect_rc 73 'stale launcher-operation lock blocks release for inspection' \
    invoke_helper release "$token_a" "$media_b64"
if [[ -d "$operation_lock" ]]; then
    pass 'stale operation lock remains untouched'
else
    fail 'stale operation lock remains untouched'
fi
rmdir "$operation_lock"

if [[ "$failures" -gt 0 ]]; then
    printf 'hardware-session launcher tests: %d check(s) FAILED\n' "$failures" >&2
    exit 1
fi
printf 'hardware-session launcher tests: all checks passed\n'
