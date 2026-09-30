#!/bin/sh
# Builds Vendor/morph-rs (resvg, vtracer, oxipng, quantizr) as an arm64 static
# library and packages it as MorphKit/Binaries/MorphRust.xcframework.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/Vendor/morph-rs"
OUT="$ROOT/MorphKit/Binaries/MorphRust.xcframework"
STAGE="$CRATE/target/xcframework-stage"

export MACOSX_DEPLOYMENT_TARGET=26.0
cargo build --manifest-path "$CRATE/Cargo.toml" --release --target aarch64-apple-darwin

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/headers" "$(dirname "$OUT")"
cp "$CRATE/include/morph_rs.h" "$CRATE/include/module.modulemap" "$STAGE/headers/"
cp "$CRATE/target/aarch64-apple-darwin/release/libmorph_rs.a" "$STAGE/libmorph_rs.a"

xcodebuild -create-xcframework \
    -library "$STAGE/libmorph_rs.a" -headers "$STAGE/headers" \
    -output "$OUT" >/dev/null

echo "built $OUT"
