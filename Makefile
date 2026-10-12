# SoundRouter top-level Makefile. See README.md.
#   SIGN_IDENTITY / INSTALLER_IDENTITY / NOTARY_PROFILE are read from the environment.

SHELL := /bin/bash
SWIFT ?= swift
SWIFT_FLAGS ?=
BUILD := build

.PHONY: all app install driver test test-swift test-driver pkg dmg notarize install-driver uninstall \
        run-offline srctl lint clean

all: app

## Universal release build + signed build/SoundRouter.app (driver included).
app:
	Scripts/build.sh

## HAL driver only (build/SoundRouter.driver).
driver:
	$(MAKE) -C Driver

## Unit tests: Swift packages + driver.
test: test-swift test-driver

test-swift:
	$(SWIFT) test --scratch-path .build/test $(SWIFT_FLAGS)

test-driver:
	@if [ -f Driver/Makefile ]; then $(MAKE) -C Driver test; else echo "Driver/Makefile missing, skipping"; fi

## Installer package (requires `make app`).
pkg: $(BUILD)/SoundRouter.app
	Scripts/make-pkg.sh

dmg: $(BUILD)/SoundRouter.app
	Scripts/make-dmg.sh

$(BUILD)/SoundRouter.app:
	Scripts/build.sh

## Notarize + staple every pkg/dmg in build/ (NOTARY_PROFILE required).
notarize:
	Scripts/notarize.sh $(wildcard $(BUILD)/SoundRouter-*.pkg $(BUILD)/SoundRouter-*.dmg)

## Build and install the app in /Applications (visible to Spotlight / Raycast / Alfred).
## Quits the running app, stops the engine agent (the app re-registers it from its new
## location on launch) and removes build/SoundRouter.app so only one copy exists.
install: app
	-osascript -e 'tell application id "io.soundrouter.app" to quit' 2>/dev/null
	-launchctl bootout gui/$$(id -u)/io.soundrouter.engine 2>/dev/null
	rm -rf /Applications/SoundRouter.app
	ditto $(BUILD)/SoundRouter.app /Applications/SoundRouter.app
	rm -rf $(BUILD)/SoundRouter.app
	@echo "Installed /Applications/SoundRouter.app — launch it with: open -a SoundRouter"

## Install the driver built in build/ (asks for your password).
install-driver:
	@test -d $(BUILD)/SoundRouter.driver || $(MAKE) driver
	sudo Scripts/install-driver.sh $(BUILD)/SoundRouter.driver

## Remove agent, driver, support dirs and user config (KEEP_CONFIG=1 keeps config.json).
uninstall:
	sudo Scripts/uninstall.sh $(if $(KEEP_CONFIG),--keep-config,)

## Control app without engine/driver (UI development). Debug build.
run-offline:
	$(SWIFT) build --product SoundRouter --scratch-path .build/debug $(SWIFT_FLAGS)
	SOUNDROUTER_OFFLINE=1 "$$($(SWIFT) build --scratch-path .build/debug $(SWIFT_FLAGS) --show-bin-path)/SoundRouter"

## XPC command-line client for integration tests (build/srctl).
srctl:
	@mkdir -p $(BUILD)
	xcrun swiftc -O -parse-as-library -module-name srctl \
		Sources/SoundRouterKit/*.swift IntegrationTests/Tools/srctl.swift -o $(BUILD)/srctl
	codesign --force --sign "$${SIGN_IDENTITY:--}" $(BUILD)/srctl

## Static checks of scripts and plists.
lint:
	@for f in Scripts/*.sh IntegrationTests/*.sh Resources/pkg/scripts/*; do bash -n "$$f" || exit 1; done
	@plutil -lint Resources/App/Info.plist Resources/Engine/Info.plist Resources/io.soundrouter.engine.plist \
		Resources/App/*.entitlements Resources/Engine/*.entitlements Resources/Driver.entitlements
	@echo "lint ok"

clean:
	rm -rf $(BUILD)/SoundRouter.app $(BUILD)/stubs $(BUILD)/pkg-work $(BUILD)/dmg-stage \
		$(BUILD)/SoundRouter-*.pkg $(BUILD)/SoundRouter-*.dmg $(BUILD)/srctl
	rm -rf .build/release .build/test .build/debug
	@if [ -f Driver/Makefile ]; then $(MAKE) -C Driver clean; fi
