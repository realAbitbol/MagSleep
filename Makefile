VERSION ?= 1.0.0

APP = dist/MagSleep.app

.PHONY: app dmg install run clean

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
