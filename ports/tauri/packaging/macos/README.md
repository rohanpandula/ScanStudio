# ScanStudio Tauri port for macOS

`build-and-smoke.sh` builds the cross-platform Tauri port, supplies an ad-hoc
signing identity to Tauri before it creates the DMG, mounts the resulting DMG,
and verifies the mounted app with `codesign --verify --deep --strict`. It then
smoke-tests the bundled engine sidecar over NDJSON.

This artifact is a prerelease proof of the Tauri port. It is not the existing
production Apple-silicon ScanStudio beta, and it must not replace or be labeled
as that beta.
