.PHONY: app-test bridge-sync bridge-test test package

UV ?= uv

app-test:
	$(MAKE) -C app/ScanStudio test

bridge-sync:
	cd bridge && $(UV) sync --locked

bridge-test: bridge-sync
	cd bridge && $(UV) run pytest

test: app-test bridge-test

package: bridge-sync
	$(MAKE) -C app/ScanStudio package
