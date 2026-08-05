#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")" && pwd)"
app_dir="$repo_root/app"

cd "$app_dir"
npm ci
npm run sync-engine
export SCANSTUDIO_ENGINE_PATH="$repo_root/vendor/engine/target/release/scanstudio-engine"
export SCANSTUDIO_PROTOCOL_DIR="$repo_root/vendor/protocol/fixtures"
npm test
(cd src-tauri && cargo test --locked)
npx tsc --noEmit
npm run build
npm run test:e2e --if-present
echo "verify-app.sh: PASS"
