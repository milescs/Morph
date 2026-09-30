#!/bin/sh
# Collects the complete corresponding source of the bundled ffmpeg/ffprobe (GPL-3.0) into one tar:
# the unmodified upstream source archives the build used, the pinned build-script, Morph's build
# wrapper and the build info. Usage: scripts/package-ffmpeg-source.sh <output.tar>
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: package-ffmpeg-source.sh <output.tar>}"
SOURCES="$ROOT/Vendor/ffmpeg-build/source"
[ -d "$SOURCES" ] || { echo "error: run 'make deps' first (no downloaded sources)" >&2; exit 1; }

STAGE="$(mktemp -d)/ffmpeg-corresponding-source"
mkdir -p "$STAGE/upstream"

# Libraries linked into ffmpeg/ffprobe (build tools like cmake, nasm, ninja, pkg-config and
# SDL, which is only used for ffplay, are not shipped and not included).
for lib in ffmpeg x264 x265 svt-av1 vpx dav1d libwebp opus lame zimg libass freetype harfbuzz fribidi \
           fontconfig libxml2 libogg openssl zlib; do
    for archive in "$SOURCES/$lib"/*.tar "$SOURCES/$lib"/*.tar.gz "$SOURCES/$lib"/*.tar.xz "$SOURCES/$lib"/*.tar.bz2; do
        [ -f "$archive" ] || continue
        name="$(basename "$archive")"
        case "$name" in
            *.tar) xz -T0 -c "$archive" > "$STAGE/upstream/$lib-$name.xz" ;;
            *) cp "$archive" "$STAGE/upstream/$lib-$name" ;;
        esac
    done
done

git -C "$ROOT/Vendor/ffmpeg-build-script" archive --format=tar --prefix=build-script/ HEAD \
    > "$STAGE/build-script.tar"
cp "$ROOT/scripts/build-ffmpeg.sh" "$STAGE/"
cp "$ROOT/Vendor/ffmpeg/BUILDINFO.txt" "$STAGE/" 2>/dev/null || true
cp "$ROOT/Licenses/FFmpeg-GPL-3.0.txt" "$STAGE/COPYING.GPLv3"
cat > "$STAGE/README.txt" <<'EOF'
Corresponding source for the ffmpeg and ffprobe executables bundled with Morph.

These executables are licensed under the GNU General Public License v3.0 or later (see COPYING.GPLv3).
They were built from the unmodified upstream sources in upstream/, using the build-script in
build-script.tar (Martin Riedl, Apache-2.0) driven by build-ffmpeg.sh. BUILDINFO.txt lists the exact
versions and FFmpeg configure line.

To rebuild: extract build-script.tar, then run build-ffmpeg.sh from a Morph checkout (`make deps`).
EOF

tar -C "$(dirname "$STAGE")" -cf "$OUT" "$(basename "$STAGE")"
rm -rf "$(dirname "$STAGE")"
echo "wrote $OUT"
