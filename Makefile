# Builds "RNDIS Tether.app" with the Command Line Tools only.
#   make app      universal app in build/ (ARCHS=x86_64 for one architecture)
#   make dist     the archive install.sh downloads: make app with DAEMON_SRC, plus its SHA-256
#   make test     offline tests of the status parser, the menu and settings models, the launch
#                 decisions and helpers
#   make format   formats the code with swift-format (Swift 6 and later), settings in .swift-format
#   make lint     fails on code that make format would change
APP      = RNDIS Tether.app
EXE      = RNDIS Tether
ARCHS   ?= arm64 x86_64
VERSION ?= 0.0.0
# Homebrew's rndis-tether, looked for first. Empty: the app's own, then the usual places.
CLI_PATH ?=
# Through the environment, so any path reaches plutil as it is.
export CLI_PATH
SRCS     = $(wildcard Sources/*.swift)
# CI adds -warnings-as-errors.
SWIFTFLAGS ?=
# The module cache stays in build/: Homebrew's sandbox only allows writes to its temp and cache.
SWIFTC   = xcrun swiftc -O -swift-version 5 -module-cache-path build/ModuleCache $(SWIFTFLAGS)

# The app install.sh installs carries rndis-tether, built from DAEMON_SRC (a checkout of its
# release tag), in Contents/Helpers. SIGN_ID is a Developer ID identity; it also turns on the
# hardened runtime and a secure timestamp, which notarization needs. "-" signs ad hoc.
DAEMON_SRC ?=
SIGN_ID  ?= -
SIGN     = codesign --force $(if $(filter -,$(SIGN_ID)),,--options runtime --timestamp) -s "$(SIGN_ID)"
# Fixed name: install.sh downloads it from .../releases/latest/download/.
ARCHIVE  = build/rndis-tether-app-macos.tar.gz

# The universal binary is named after ARCHS, so changing ARCHS always relinks it.
empty   :=
space   := $(empty) $(empty)
BINARY   = build/universal-$(subst $(space),+,$(strip $(ARCHS)))

.PHONY: app dist test format lint clean

build/arch/%: $(SRCS)
	mkdir -p build/arch
	$(SWIFTC) -target $*-apple-macos13.0 -o $@ $(SRCS)

$(BINARY): $(addprefix build/arch/,$(ARCHS))
	lipo -create -output $@ $^

# Used only inside quotes: APP has a space.
BUNDLE   = build/$(APP)
CONTENTS = $(BUNDLE)/Contents
PLIST    = $(CONTENTS)/Info.plist

app: $(BINARY) Info.plist Resources/AppIcon.icns
	rm -rf "$(BUNDLE)"; mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp Info.plist "$(CONTENTS)/"
	cp $(BINARY) "$(CONTENTS)/MacOS/$(EXE)"
	cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(PLIST)"
	plutil -replace CFBundleVersion -string "$(VERSION)" "$(PLIST)"
	plutil -replace RTCLIPath -string "$$CLI_PATH" "$(PLIST)"
ifneq ($(DAEMON_SRC),)
	# Without this build's MAKEFLAGS: VERSION and the rest are the daemon's own.
	env -u MAKEFLAGS -u MAKELEVEL $(MAKE) -C "$(DAEMON_SRC)" dist WERROR=
	mkdir -p "$(CONTENTS)/Helpers"
	cp "$(DAEMON_SRC)/dist/pkg/rndis-tether" "$(CONTENTS)/Helpers/"
	$(SIGN) --identifier io.github.stlk0.rndis-tether "$(CONTENTS)/Helpers/rndis-tether"
endif
	$(SIGN) "$(BUNDLE)"
	codesign --verify --strict "$(BUNDLE)"

dist: app
	test -x "$(CONTENTS)/Helpers/rndis-tether"  # needs DAEMON_SRC
	tar -czf $(ARCHIVE) -C build "$(APP)"
	cd build && shasum -a 256 $(notdir $(ARCHIVE)) > $(notdir $(ARCHIVE)).sha256

# The logic under test: no AppKit, so it runs without a window or a phone.
TESTED   = Sources/Core.swift Sources/Launch.swift Sources/Prefs.swift Sources/Status.swift Sources/MenuModel.swift \
           Sources/SettingsModel.swift Sources/Privileged.swift Sources/LoginItem.swift

# -Onone, so a crash in a test says where it happened.
test: $(TESTED) Tests/main.swift
	mkdir -p build && $(SWIFTC) -Onone -o build/tests $^ && build/tests

format:
	xcrun swift format format -i -r Sources Tests

lint:
	xcrun swift format lint --strict -r Sources Tests

clean:
	rm -rf build
