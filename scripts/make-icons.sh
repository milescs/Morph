#!/bin/sh
# Renders Morph's artwork from the SVG sources in Design/ with resvg (cargo install resvg):
#   - App icon (all macOS sizes) → App/Resources/Assets.xcassets/AppIcon.appiconset
#   - README logo/icon            → docs/
#   - DMG background (1x/2x)      → Design/dmg-background.png, dmg-background@2x.png
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESVG="${RESVG:-$(command -v resvg || echo "$HOME/.cargo/bin/resvg")}"
[ -x "$RESVG" ] || { echo "error: resvg not found. Install it with: cargo install resvg" >&2; exit 1; }
FONTS="--use-fonts-dir /Library/Fonts --use-fonts-dir /System/Library/Fonts"

ICONSET="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET" "$ROOT/docs"
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
    points=${spec%%:*}; scale=${spec##*:}
    pixels=$((points * scale))
    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    "$RESVG" -w "$pixels" -h "$pixels" "$ROOT/Design/AppIcon.svg" "$ICONSET/icon_${points}x${points}${suffix}.png"
done
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

"$RESVG" -w 512 "$ROOT/Design/AppIcon.svg" "$ROOT/docs/icon.png"
cp "$ROOT/Design/Logo.svg" "$ROOT/docs/logo.svg"
"$RESVG" -w 1200 "$ROOT/Design/Logo.svg" "$ROOT/docs/logo.png"
"$RESVG" -w 144 "$ROOT/Design/MenuBarIcon.svg" "$ROOT/docs/menubar-icon.png"
# shellcheck disable=SC2086
"$RESVG" $FONTS -w 660 "$ROOT/Design/DMGBackground.svg" "$ROOT/Design/dmg-background.png"
# shellcheck disable=SC2086
"$RESVG" $FONTS -w 1320 "$ROOT/Design/DMGBackground.svg" "$ROOT/Design/dmg-background@2x.png"
echo "Rendered icons, logo and DMG background."
