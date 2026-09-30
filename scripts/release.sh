#!/bin/sh
# Builds a notarized Morph.app, packages it as a styled DMG, signs a Sparkle update feed
# (appcast.xml) for it, and bundles the FFmpeg corresponding source (GPL) for the GitHub release.
#
# Default: Xcode signs with a cloud-managed "Developer ID Application" certificate and sends the
# build to Apple's notary service using the Apple ID signed in to Xcode (no passwords needed):
#   ./scripts/release.sh
#
# With a local Developer ID certificate and a notarytool keychain profile instead:
#   xcrun notarytool store-credentials morph-notary --apple-id you@example.com --team-id NWTRA7934U
#   DEVELOPER_ID="Developer ID Application: Your Name (NWTRA7934U)" NOTARY_PROFILE=morph-notary ./scripts/release.sh
#
# NOTARIZE=0 skips notarization (local testing only: downloaded copies will need "Open Anyway").
# Sparkle's EdDSA private key must be in the login keychain (see generate_keys in README).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEAM_ID="NWTRA7934U"
REPO="milescs/Morph"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Morph.xcarchive"
EXPORT="$BUILD/export"
PACKAGES="$ROOT/build/SourcePackages"
NOTARIZE="${NOTARIZE:-1}"

command -v create-dmg >/dev/null || { echo "error: brew install create-dmg" >&2; exit 1; }
[ -x Vendor/ffmpeg/bin/ffmpeg ] || { echo "error: run 'make deps' first to build the static FFmpeg." >&2; exit 1; }
[ -f MorphKit/Binaries/MorphRust.xcframework/Info.plist ] || ./scripts/build-rust.sh
xcodegen generate --quiet

VERSION=$(grep -E '^\s+MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
BUILD_NUMBER=$(grep -E '^\s+CURRENT_PROJECT_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Archiving Morph $VERSION ($BUILD_NUMBER)"
xcodebuild -project Morph.xcodeproj -scheme Morph -configuration Release -archivePath "$ARCHIVE" \
    -clonedSourcePackagesDirPath "$PACKAGES" -allowProvisioningUpdates -quiet archive
SPARKLE_BIN="$PACKAGES/artifacts/sparkle/Sparkle/bin"

export_options() { # $1 = destination (export|upload), $2 = signing style
    cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>$1</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>$2</string>
</dict>
</plist>
PLIST
}

if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "==> Exporting with $DEVELOPER_ID"
    export_options export manual
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
        -exportOptionsPlist "$BUILD/ExportOptions.plist" -quiet
    APP="$EXPORT/Morph.app"
    if [ "$NOTARIZE" = 1 ]; then
        : "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials) or NOTARIZE=0}"
        echo "==> Notarizing the app (this can take a few minutes)"
        ditto -c -k --keepParent "$APP" "$BUILD/Morph-notarize.zip"
        xcrun notarytool submit "$BUILD/Morph-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
    fi
elif [ "$NOTARIZE" = 1 ]; then
    echo "==> Signing with Developer ID and uploading to Apple's notary service"
    export_options upload automatic
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD/upload" \
        -exportOptionsPlist "$BUILD/ExportOptions.plist" -allowProvisioningUpdates -quiet
    echo "==> Waiting for notarization (usually 2–10 minutes)"
    attempt=0
    until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT" >"$BUILD/notary.log" 2>&1; do
        attempt=$((attempt + 1))
        if grep -qiE "invalid|rejected|failed to notarize" "$BUILD/notary.log" || [ $attempt -ge 90 ]; then
            cat "$BUILD/notary.log" >&2
            echo "error: notarization didn't finish; see Xcode › Organizer for the log" >&2
            exit 1
        fi
        sleep 20
    done
    APP="$EXPORT/Morph.app"
else
    echo "    (NOTARIZE=0: signing with Developer ID but skipping notarization)"
    export_options export automatic
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
        -exportOptionsPlist "$BUILD/ExportOptions.plist" -allowProvisioningUpdates -quiet
    APP="$EXPORT/Morph.app"
fi

echo "==> Verifying signatures"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
    || { echo "error: Morph.app isn't signed with Developer ID" >&2; exit 1; }
for tool in ffmpeg ffprobe; do
    info=$(codesign -dvv "$APP/Contents/MacOS/$tool" 2>&1)
    echo "$info" | grep -q "Authority=Developer ID Application" \
        || { echo "error: $tool isn't signed with Developer ID" >&2; exit 1; }
    echo "$info" | grep -q "Timestamp=" || { echo "error: $tool has no secure timestamp" >&2; exit 1; }
    codesign -d --verbose=2 "$APP/Contents/MacOS/$tool" 2>&1 | grep -q "flags=0x10000(runtime)" \
        || { echo "error: $tool is not signed with the hardened runtime" >&2; exit 1; }
    if otool -L "$APP/Contents/MacOS/$tool" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/Library/)' | grep -q .; then
        echo "error: $tool links non-system libraries" >&2; exit 1
    fi
done
[ -f "$APP/Contents/Resources/Licenses/FFmpeg-GPL-3.0.txt" ] || { echo "error: license texts missing" >&2; exit 1; }
[ -d "$APP/Contents/PlugIns/MorphCompressAction.appex" ] || { echo "error: Finder Quick Actions missing" >&2; exit 1; }
if [ "$NOTARIZE" = 1 ]; then
    xcrun stapler validate "$APP"
    spctl -a -vv -t exec "$APP" 2>&1 | tee "$BUILD/spctl.log" | grep -q "source=Notarized Developer ID" \
        || { cat "$BUILD/spctl.log" >&2; echo "error: Gatekeeper doesn't accept the app" >&2; exit 1; }
fi

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
fi

echo "==> Signing the Sparkle update feed"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG")   # sparkle:edSignature="…" length="…"
NOTES="$ROOT/build/release-notes.md"
NOTES_HTML=""
if [ -f "$NOTES" ]; then
    # Minimal Markdown → HTML for Sparkle's update window (headings, bullet lists, paragraphs).
    NOTES_HTML=$(sed -E -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/\*\*([^*]+)\*\*/<b>\1<\/b>/g' -e 's/`([^`]+)`/<code>\1<\/code>/g' "$NOTES" | awk '
        /^- / { if (!list) { print "<ul>"; list = 1 } sub(/^- /, ""); print "<li>" $0 "</li>"; next }
        { if (list) { print "</ul>"; list = 0 } }
        /^### / { sub(/^### /, ""); print "<h3>" $0 "</h3>"; next }
        /^## / { sub(/^## /, ""); print "<h2>" $0 "</h2>"; next }
        /^$/ { next }
        { print "<p>" $0 "</p>" }
        END { if (list) print "</ul>" }')
fi
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > "$ROOT/build/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Morph</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Morph $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Morph-$VERSION.dmg" $SIGNATURE type="application/x-apple-diskimage"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$ROOT/build/appcast.xml"

echo "==> Packaging FFmpeg corresponding source"
./scripts/package-ffmpeg-source.sh "$ROOT/build/Morph-$VERSION-ffmpeg-source.tar"

(cd "$ROOT/build" && shasum -a 256 "Morph-$VERSION.dmg" "Morph-$VERSION-ffmpeg-source.tar" > "Morph-$VERSION-SHA256.txt")
echo "==> Done:"
ls -lh "$DMG" "$ROOT/build/appcast.xml" "$ROOT/build/Morph-$VERSION-ffmpeg-source.tar"
