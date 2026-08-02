.PHONY: app-test bridge-sync bridge-sync-scanner bridge-test coolscanpy-test test package dmg

UV ?= uv

app-test:
	$(MAKE) -C app/ScanStudio test

bridge-sync:
	cd bridge && $(UV) sync --locked

bridge-test: bridge-sync
	cd bridge && $(UV) run pytest

coolscanpy-test:
	cd coolscanpy && $(UV) run pytest

test: app-test bridge-test coolscanpy-test

# The packaged bridge retains python-sane for optional plain scan and software
# eject, so packaging needs CoolscanPy's scanner extra even though color-roll
# capture and the bridge test suite do not. See bridge/pyproject.toml.
bridge-sync-scanner:
	cd bridge && $(UV) sync --locked --extra scanner

package: bridge-sync-scanner
	$(MAKE) -C app/ScanStudio package

dmg: bridge-sync-scanner
	$(MAKE) -C app/ScanStudio dmg
