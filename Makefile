SCHEME := AUv3Probe
PROJECT := AUv3Probe.xcodeproj

.PHONY: generate build clean

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

## clean: remove generated project and build artifacts
clean:
	rm -rf $(PROJECT) build DerivedData
