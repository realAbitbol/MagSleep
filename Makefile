VERSION ?= 1.2.9

APP = dist/MagSleep.app

.PHONY: app dmg install run clean test notarize release lint install-hooks

app:
	scripts/build-app.sh $(VERSION)

dmg: app
	scripts/build-dmg.sh $(VERSION)

# install and run reuse the existing dist/MagSleep.app; they do NOT rebuild it,
# so the version produced by `make app VERSION=x` is never silently overwritten
# by the default VERSION. Run `make app VERSION=x` first to build a version.
install: $(APP)
	rm -rf /Applications/MagSleep.app
	cp -R $(APP) /Applications/MagSleep.app
	@echo "installed to /Applications/MagSleep.app"

run: $(APP)
	open $(APP)

# Builds the app only when dist/MagSleep.app is missing (first build).
$(APP):
	scripts/build-app.sh $(VERSION)

clean:
	rm -rf .build dist

test:
	swift test

# Lint + dead-code scan (the same checks the pre-commit hook runs).
lint:
	swiftlint lint --strict
	periphery scan --strict

# Point git at the tracked hooks directory (no copying; every clone gets it).
install-hooks:
	git config core.hooksPath scripts/git-hooks
	@echo "installed git hooks from scripts/git-hooks"

# Notarizes dist/MagSleep.app — requires a Developer ID cert (paid membership).
# Without one it prints guidance and exits 0.
notarize: $(APP)
	scripts/notarize.sh

# Creates a tagged release: tests, builds the DMG, updates README/Makefile
# version references, commits, tags vX.Y.Z, pushes branch + tag, and publishes
# the GitHub Release with the DMG (requires `gh` authenticated). See
# scripts/release.sh.
release:
	scripts/release.sh $(VERSION)
