# ScanStudio desktop port

This is the Tauri and React desktop interface used by the Windows and Linux
previews. It speaks the same frozen NDJSON protocol as the native macOS app and
bundles the Rust engine as a platform-specific sidecar.

From the parent `ports/tauri` directory, run `./verify-app.sh` for the locked
frontend, Rust, sidecar-handshake, type-check, and production-build gates.
Platform resource assembly and package verification live under `packaging/`.
Real scanner actions are intentionally documented only in the operator
runbooks; ordinary builds and tests use the explicit simulator.
