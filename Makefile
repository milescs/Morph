# Morph — build helpers. `make bootstrap` once, then `make run`.
PROJECT = Morph.xcodeproj
SCHEME = Morph
DERIVED = build/DerivedData
APP = $(DERIVED)/Build/Products/Debug/Morph.app

.PHONY: bootstrap rust deps project build release run test test-kit clean

bootstrap: rust project
	@command -v meson >/dev/null || brew install meson
	@command -v autoreconf >/dev/null || brew install autoconf automake libtool
	@echo "Next: 'make deps' to build the static FFmpeg (~20-30 min), then 'make run'."

rust:
	./scripts/build-rust.sh

deps:
	./scripts/build-ffmpeg.sh

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet build

release: project
	./scripts/release.sh

run: build
	open "$(APP)"

test: test-kit

test-kit:
	cd MorphKit && swift test

clean:
	rm -rf build MorphKit/.build
