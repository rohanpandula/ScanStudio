.PHONY: engine app package package-check test run smoke launcher-check parity render-color-candidates render-geometry-candidates render-ice-candidates clean check-cargo check-swift check-tools

# Tool paths are discovered from the caller's PATH. Override CARGO or SWIFT
# explicitly when using a non-standard toolchain installation.
CARGO ?= $(shell command -v cargo 2>/dev/null)
SWIFT ?= $(shell command -v swift 2>/dev/null)

define require_tool
	@if [ -z "$(strip $($(1)))" ] || ! command -v "$(strip $($(1)))" >/dev/null 2>&1; then \
		echo "ScanStudio prerequisite missing: install $(2) and make sure it is on PATH (or set $(1)=/path/to/$(3))." >&2; \
		exit 127; \
	fi
endef

check-cargo:
	$(call require_tool,CARGO,Rust Cargo,cargo)

check-swift:
	$(call require_tool,SWIFT,the Swift toolchain,swift)

check-tools: check-cargo check-swift

# Absolute path to the release engine binary `make run` hands the app via
# SCANSTUDIO_ENGINE_PATH.
ENGINE_RELEASE_BIN := $(abspath engine/target/release/scanstudio-engine)

engine: check-cargo
	cd engine && $(CARGO) build --release

app: check-swift
	$(SWIFT) build

package: check-tools
	./scripts/package_app.sh
	./scripts/test_packaged_bridge.sh .build/ScanStudio.app

# Runs the relocation/mock smoke independently after an already-built bundle.
# It never opens a scanner, enables motion, or writes the armed latch.
package-check:
	./scripts/test_packaged_bridge.sh .build/ScanStudio.app

# Both suites must pass: the Rust engine's own cargo tests, then the Swift
# package's tests (fixture decoding, line framing, unknown-event tolerance,
# state raw-value mapping).
test: check-tools
	cd engine && $(CARGO) test
	$(SWIFT) test

run: engine
	SCANSTUDIO_ENGINE_PATH=$(ENGINE_RELEASE_BIN) $(if $(SCANSTUDIO_BRIDGE_CMD),SCANSTUDIO_BRIDGE_CMD=$(SCANSTUDIO_BRIDGE_CMD),) $(SWIFT) run ScanStudio

# scripts/smoke_engine.sh builds the engine itself (D-17), so this target
# does not also depend on `engine` — that would be a redundant double-build.
smoke: check-cargo
	./scripts/smoke_engine.sh

launcher-check:
	./scripts/test_launcher.sh

# Reads SCANSTUDIO_PARITY_CORPUS from the environment and hard-fails if
# it's unset — unlike `make test`, this target's whole purpose is
# comparing against real corpus data. Pass JSON=1 for machine-readable
# output. See app/ScanStudio/PARITY.md for corpus setup.
# @-prefixed (unlike every other target here) because JSON=1 output must be
# clean enough to pipe straight into a JSON parser — Make's default recipe
# echo would otherwise land as `--json`'s first, non-JSON line of stdout.
parity: check-cargo
	@cd engine && $(CARGO) run --release --bin parity -- $(if $(JSON),--json,)

render-color-candidates: check-cargo
	cd engine && $(CARGO) run --release --bin render_color_candidates -- $(if $(CANDIDATES),--candidate-dir $(CANDIDATES),)

render-geometry-candidates: check-cargo
	cd engine && $(CARGO) run --release --bin render_geometry_candidates -- $(if $(CANDIDATES),--candidate-dir $(CANDIDATES),)

render-ice-candidates: check-cargo
	cd engine && $(CARGO) run --release --bin render_ice_candidates -- $(if $(CANDIDATES),--candidate-dir $(CANDIDATES),)

clean:
	cd engine && $(CARGO) clean
	rm -rf .build
