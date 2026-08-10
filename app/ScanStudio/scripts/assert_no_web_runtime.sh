#!/bin/zsh
# The optional browser runtime is a separate release payload. The production
# ScanStudio app and DMG must never absorb either reserved resource tree.
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "Usage: assert_no_web_runtime.sh <ScanStudio.app>"
    exit 64
fi

app="$1"
if [[ ! -d "$app" || "${app:t}" != "ScanStudio.app" ]]; then
    print -u2 "ScanStudio app prerequisite missing or misnamed: $app"
    exit 66
fi

for reserved_name in \
    WebRuntime \
    WebFrontend \
    ScanStudioWebRuntime.bundle \
    scanstudio-web-runtime \
    scanstudio-web-runtime.json; do
    reserved_path="$(find "$app" -mindepth 1 -name "$reserved_name" -print -quit)"
    if [[ -n "$reserved_path" ]]; then
        print -u2 "Refusing a ScanStudio app containing optional web payload: $reserved_path"
        exit 1
    fi
done

print "Verified ScanStudio.app contains no optional web runtime or frontend"
