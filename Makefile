VERSION ?= 1.0.0

.PHONY: app dmg install run clean

app:
	scripts/build-app.sh $(VERSION)

dmg: app
	scripts/build-dmg.sh $(VERSION)

install: app
	rm -rf /Applications/MagSleep.app
	cp -R dist/MagSleep.app /Applications/MagSleep.app
	@echo "installed to /Applications/MagSleep.app"

run: app
	open dist/MagSleep.app

clean:
	rm -rf .build dist
