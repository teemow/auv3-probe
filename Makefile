SCHEME := AUv3Probe
PROJECT := AUv3Probe.xcodeproj

# Linux (xtool) build/deploy uses the home-installed Swift toolchain. env.sh sets
# PATH/LD_LIBRARY_PATH so `swift`/`xtool` resolve and the SDK Swift version
# matches (see docs/building-on-linux.md). Override if yours lives elsewhere:
#   make deploy SWIFT_ENV=/path/to/env.sh
# If the file is absent we assume swift/xtool are already on PATH.
SWIFT_ENV ?= $(HOME)/swift-toolchain/env.sh
load_env = if [ -f "$(SWIFT_ENV)" ]; then . "$(SWIFT_ENV)"; fi;

.PHONY: help generate build clean deploy xtool-build devices

## help: list available targets
help:
	@echo "auv3-probe make targets:"
	@echo
	@echo "  macOS / Xcode (canonical, see README):"
	@echo "    generate     regenerate AUv3Probe.xcodeproj from project.yml (needs xcodegen)"
	@echo "    build        build-only sanity check for iOS, no code signing (needs Xcode)"
	@echo
	@echo "  Linux, no Mac (xtool, see docs/building-on-linux.md):"
	@echo "    xtool-build  cross-compile the app with xtool (surfaces source errors, no signing)"
	@echo "    deploy       build -> sign -> install -> launch on the USB-connected device"
	@echo "    devices      list devices xtool can see (usbmuxd)"
	@echo
	@echo "    clean        remove generated project and all build artifacts"

# ---------------------------------------------------------------------------
# macOS / Xcode path (canonical) — builds via the XcodeGen-generated project.
# ---------------------------------------------------------------------------

## generate: regenerate AUv3Probe.xcodeproj from project.yml (requires xcodegen)
generate:
	xcodegen generate

## build: build-only sanity check for iOS, no code signing
build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO \
		build

# ---------------------------------------------------------------------------
# Linux path (no Mac) — builds/signs/installs straight from Linux with xtool,
# reusing the in-repo Package.swift / xtool.yml (see docs/building-on-linux.md).
# Requires a one-time setup: Swift toolchain, `xtool sdk install`, `xtool auth
# login` (free Apple ID). Signing certs expire after 7 days; re-run `make deploy`.
# ---------------------------------------------------------------------------

## devices: list devices xtool can reach over USB (requires usbmuxd)
devices:
	@$(load_env) xtool devices

## xtool-build: cross-compile only (no signing) — surfaces source errors fast
xtool-build:
	@$(load_env) xtool dev build

## deploy: build, sign, install, and launch on the USB-connected device
deploy:
	@$(load_env) xtool dev run --usb

# ---------------------------------------------------------------------------

## clean: remove generated project and all build artifacts (Xcode + xtool)
clean:
	rm -rf $(PROJECT) build DerivedData xtool .build
