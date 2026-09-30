#!/bin/sh
# Builds a Release Morph.app, packages it as a styled DMG, and bundles the FFmpeg corresponding
# source (GPL) for the GitHub release.
#
# Notarized release (needs a "Developer ID Application" certificate and a notarytool profile):
#   xcrun notarytool store-credentials morph-notary --apple-id you@example.com --team-id NWTRA7934U
#   DEVELOPER_ID="Developer ID Application: Your Name (NWTRA7934U)" NOTARY_PROFILE=morph-notary ./scripts/release.sh
#
# Without DEVELOPER_ID the app is signed with your Apple Development identity. Downloaded copies then
# need "Open Anyway" in System Settings › Privacy & Security the first time (see README).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEAM_ID="NWTRA7934U"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Morph.xcarchive"
EXPORT="$BUILD/export"

command -v create-dmg >/dev/null || { echo "error: brew install create-dmg" >&2; exit 1; }
[ -x Vendor/ffmpeg/bin/ffmpeg ] || { echo "error: run 'make deps' first to build the static FFmpeg." >&2; exit 1; }
[ -f MorphKit/Binaries/MorphRust.xcframework/Info.plist ] || ./scripts/build-rust.sh
xcodegen generate --quiet

VERSION=$(grep -E '^\s+MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Archiving Morph $VERSION"
if [ -n "${DEVELOPER_ID:-}" ]; then
    xcodebuild -project Morph.xcodeproj -scheme Morph -configuration Release -archivePath "$ARCHIVE" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet archive
    cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
    echo "==> Exporting"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
        -exportOptionsPlist "$BUILD/ExportOptions.plist" -quiet
    APP="$EXPORT/Morph.app"
else
    echo "    (no DEVELOPER_ID set: signing with Apple Development; the DMG won't be notarized)"
    xcodebuild -project Morph.xcodeproj -scheme Morph -configuration Release -archivePath "$ARCHIVE" -quiet archive
    APP="$ARCHIVE/Products/Applications/Morph.app"
fi

echo "==> Verifying signatures"
codesign --verify --deep --strict "$APP"
for tool in ffmpeg ffprobe; do
    codesign -d --verbose=2 "$APP/Contents/MacOS/$tool" 2>&1 | grep -q "flags=0x10000(runtime)" \
        || { echo "error: $tool is not signed with the hardened runtime" >&2; exit 1; }
    if otool -L "$APP/Contents/MacOS/$tool" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/Library/)' | grep -q .; then
        echo "error: $tool links non-system libraries" >&2; exit 1
    fi
done
[ -f "$APP/Contents/Resources/Licenses/FFmpeg-GPL-3.0.txt" ] || { echo "error: license texts missing" >&2; exit 1; }

echo "==> Creating DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Morph.app"
BACKGROUND="$BUILD/dmg-background.tiff"
tiffutil -cathidpicheck Design/dmg-background.png Design/dmg-background@2x.png -out "$BACKGROUND" >/dev/null
DMG="$ROOT/build/Morph-$VERSION.dmg"
rm -f "$DMG"
create-dmg \
    --volname "Morph $VERSION" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$BACKGROUND" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 112 \
    --text-size 13 \
    --icon "Morph.app" 170 190 \
    --hide-extension "Morph.app" \
    --app-drop-link 490 190 \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null

if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "==> Notarizing (this can take a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl -a -t open --context context:primary-signature -vv "$DMG"
    else
        echo "    (NOTARY_PROFILE not set: skipping notarization)"
    fi
fi

echo "==> Packaging FFmpeg corresponding source"
./scripts/package-ffmpeg-source.sh "$ROOT/build/Morph-$VERSION-ffmpeg-source.tar"

shasum -a 256 "$DMG" "$ROOT/build/Morph-$VERSION-ffmpeg-source.tar" > "$ROOT/build/Morph-$VERSION-SHA256.txt"
echo "==> Done:"
ls -lh "$DMG" "$ROOT/build/Morph-$VERSION-ffmpeg-source.tar"
