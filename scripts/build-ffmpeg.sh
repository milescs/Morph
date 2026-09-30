#!/bin/sh
# Builds static ffmpeg/ffprobe (arm64, macOS 26+) from source using
# Martin Riedl's open-source build-script (Apache-2.0), pinned to a commit.
# Output: Vendor/ffmpeg/bin/{ffmpeg,ffprobe} + Vendor/ffmpeg/BUILDINFO.txt
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_REPO="https://git.martin-riedl.de/ffmpeg/build-script.git"
SCRIPT_COMMIT="f63b8aab8f5ce1a067da86ba69e34a36a7e217e5" # "ffmpeg update (version 9.0.1)"
SCRIPT_DIR="$ROOT/Vendor/ffmpeg-build-script"
WORK_DIR="$ROOT/Vendor/ffmpeg-build"
OUT_DIR="$ROOT/Vendor/ffmpeg"

if [ ! -d "$SCRIPT_DIR/.git" ]; then
    git clone -q "$SCRIPT_REPO" "$SCRIPT_DIR"
fi
git -C "$SCRIPT_DIR" fetch -q origin || true
git -C "$SCRIPT_DIR" checkout -q "$SCRIPT_COMMIT"

export MACOSX_DEPLOYMENT_TARGET=26.0
# zimg needs autotools; Homebrew installs libtoolize as glibtoolize. Expose only libtoolize
# (x265 needs Apple's own `libtool -static`, so GNU libtool must not shadow it).
SHIM_DIR="$ROOT/Vendor/ffmpeg-build-shims"
mkdir -p "$SHIM_DIR"
if command -v glibtoolize >/dev/null 2>&1; then
    ln -sf "$(command -v glibtoolize)" "$SHIM_DIR/libtoolize"
fi
export PATH="$SHIM_DIR:$PATH"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Keep: zimg dav1d svt-av1 vpx libwebp x264 x265(8/10/12-bit) lame opus.
"$SCRIPT_DIR/build.sh" \
    -SKIP_BUNDLE=YES -SKIP_TEST=YES \
    -SKIP_LIBKLVANC=YES -SKIP_LIBBLURAY=YES -SKIP_SNAPPY=YES -SKIP_SRT=YES \
    -SKIP_LIBVMAF=YES -SKIP_ZVBI=YES -SKIP_AOM=YES -SKIP_OPEN_H264=YES \
    -SKIP_OPEN_JPEG=YES -SKIP_RAV1E=YES -SKIP_VVENC=YES -SKIP_LIBTHEORA=YES \
    -SKIP_LIBVORBIS=YES

mkdir -p "$OUT_DIR/bin"
cp "$WORK_DIR/out/bin/ffmpeg" "$WORK_DIR/out/bin/ffprobe" "$OUT_DIR/bin/"
chmod 755 "$OUT_DIR/bin/ffmpeg" "$OUT_DIR/bin/ffprobe"

# Verify: only system libraries are linked.
for bin in ffmpeg ffprobe; do
    if otool -L "$OUT_DIR/bin/$bin" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/Library/)' | grep -q .; then
        echo "error: $bin links non-system libraries:" >&2
        otool -L "$OUT_DIR/bin/$bin" >&2
        exit 1
    fi
done

# Verify: required encoders are present.
ENCODERS="$("$OUT_DIR/bin/ffmpeg" -hide_banner -encoders 2>/dev/null)"
for enc in h264_videotoolbox hevc_videotoolbox prores_videotoolbox libx264 libx265 libsvtav1 libvpx-vp9 libwebp libwebp_anim libmp3lame libopus aac_at; do
    echo "$ENCODERS" | grep -q " $enc " || { echo "error: missing encoder $enc" >&2; exit 1; }
done

{
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Build script: $SCRIPT_REPO @ $SCRIPT_COMMIT"
    echo
    "$OUT_DIR/bin/ffmpeg" -hide_banner -version
    echo
    echo "Library versions:"
    for f in "$SCRIPT_DIR"/version/*; do printf "  %-12s %s\n" "$(basename "$f")" "$(cat "$f")"; done
} > "$OUT_DIR/BUILDINFO.txt"

echo "ffmpeg built: $OUT_DIR/bin"
