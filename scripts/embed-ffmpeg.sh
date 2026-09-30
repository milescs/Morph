#!/bin/sh
# Copies the static ffmpeg/ffprobe into Morph.app/Contents/MacOS and signs them with the
# hardened runtime (Code Sign On Copy would keep the binaries' own flags and fail notarization).
set -eu

SRC="${SRCROOT}/Vendor/ffmpeg/bin"
DEST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"

# License texts shipped inside the app (Morph is MIT; the bundled FFmpeg is GPL-3.0).
LICENSES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Licenses"
mkdir -p "$LICENSES"
cp -f "${SRCROOT}/LICENSE" "$LICENSES/Morph-LICENSE.txt"
cp -f "${SRCROOT}/THIRD_PARTY_NOTICES.md" "$LICENSES/THIRD_PARTY_NOTICES.md"
cp -f "${SRCROOT}/Licenses/FFmpeg-GPL-3.0.txt" "$LICENSES/FFmpeg-GPL-3.0.txt"

if [ ! -x "$SRC/ffmpeg" ] || [ ! -x "$SRC/ffprobe" ]; then
    if [ "${CONFIGURATION}" = "Release" ]; then
        echo "error: Vendor/ffmpeg/bin is missing. Run 'make deps' to build the static FFmpeg."
        exit 1
    fi
    echo "warning: Bundled FFmpeg not built yet (run 'make deps'); Debug builds use Homebrew's ffmpeg."
    exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
TIMESTAMP="--timestamp=none"
if [ "${CONFIGURATION}" = "Release" ]; then TIMESTAMP="--timestamp"; fi

for tool in ffmpeg ffprobe; do
    ditto "$SRC/$tool" "$DEST/$tool"
    chmod 755 "$DEST/$tool"
    if [ "$IDENTITY" = "-" ] || [ -z "$IDENTITY" ]; then
        codesign --force --sign - "$DEST/$tool"
    else
        codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$DEST/$tool"
    fi
done
echo "Embedded ffmpeg/ffprobe ($( "$DEST/ffmpeg" -hide_banner -version | head -1 | cut -d' ' -f3 ))"
