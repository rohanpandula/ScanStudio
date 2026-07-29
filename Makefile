.PHONY: app-test bridge-sync bridge-sync-scanner bridge-test test package

UV ?= uv

app-test:
	$(MAKE) -C app/ScanStudio test

bridge-sync:
	cd bridge && $(UV) sync --locked

bridge-test: bridge-sync
	cd bridge && $(UV) run pytest

test: app-test bridge-test

# The packaged bridge ships python-sane for real hardware access, so
# packaging needs coolscanpy's scanner extra even though the bridge's own
# test suite (bridge-test, above) does not. See bridge/pyproject.toml.
bridge-sync-scanner:
	cd bridge && $(UV) sync --locked --extra scanner

package: bridge-sync-scanner
	$(MAKE) -C app/ScanStudio package
