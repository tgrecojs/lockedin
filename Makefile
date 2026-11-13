# LockedIn — build, test, and install from source.
# `make install` builds as you, then runs only the install step under sudo.

BUILD_DIR = .build/release
APP = build/LockedIn.app
DAEMON_LABEL = com.tgreco.lockedin.daemon

.PHONY: build test app install uninstall restart-daemon logs doctor smoke lint run-app clean

build:
	swift build -c release

test:
	swift test

app: build
	scripts/make-app.sh $(BUILD_DIR)/LockedInApp $(APP)

install: app
	@echo "The daemon install needs root; sudo will ask for your password."
	sudo $(BUILD_DIR)/lockedin install --from $(BUILD_DIR) --app $(APP)

uninstall:
	sudo /usr/local/bin/lockedin uninstall

restart-daemon:
	sudo launchctl kickstart -k system/$(DAEMON_LABEL)

logs:
	tail -n 50 -f /Library/Logs/LockedIn/lockedind.log

doctor:
	lockedin doctor

smoke:
	sudo scripts/smoke-test.sh

lint:
	swift format lint --strict --recursive Sources Tests

run-app: build
	$(BUILD_DIR)/LockedInApp

clean:
	swift package clean
	rm -rf build
