# Third-party software in Morph

- **Morph's own source code** is licensed under the **MIT License** (see `LICENSE`).
- **The Morph app executable** links only permissively licensed code: MIT, BSD, Apache-2.0 and zlib.
- **macOS system frameworks** are used alongside that code: SwiftUI, AppKit, ImageIO, Core Graphics, PDFKit, VideoToolbox, AudioToolbox and Quick Look.

**Binary downloads also include two separate programs, `ffmpeg` and `ffprobe`.** Morph starts them as child processes and talks to them only through command-line arguments and pipes.
- They are **not** covered by Morph's MIT license.
- They are licensed under the **GNU GPL v3.0-or-later**; a copy is included in the download as `FFmpeg-License.txt`.
- Their complete corresponding source is attached to every GitHub release as `Morph-<version>-ffmpeg-source.tar`, and is described below.

## Bundled command-line tools: `ffmpeg` and `ffprobe`

Morph ships statically linked `ffmpeg` / `ffprobe` executables inside `Morph.app/Contents/MacOS`.
They run as separate processes.

- **FFmpeg 9.0.1** — https://ffmpeg.org — built with `--enable-gpl --enable-version3`, so the
  binaries are licensed **GPL-3.0-or-later**.
- **Build recipe:** Martin Riedl's build-script (Apache-2.0),
  https://git.martin-riedl.de/ffmpeg/build-script, pinned to commit
  `f63b8aab8f5ce1a067da86ba69e34a36a7e217e5`. Morph's wrapper is `scripts/build-ffmpeg.sh`.
- **Configure line:**
  ```
  --pkg-config-flags=--static --enable-gray --enable-libxml2 --enable-version3 --enable-gpl
  --enable-openssl --enable-libfreetype --enable-fontconfig --enable-libharfbuzz --enable-libass
  --enable-libzimg --enable-libdav1d --enable-libsvtav1 --enable-libvpx --enable-libwebp
  --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus
  ```
  VideoToolbox and AudioToolbox are enabled automatically on macOS.

### Libraries statically linked into ffmpeg/ffprobe

| Library | Version | License | Source |
|---|---|---|---|
| x264 | stable branch | GPL-2.0-or-later | https://code.videolan.org/videolan/x264 |
| x265 | 4.2 | GPL-2.0-or-later | https://bitbucket.org/multicoreware/x265_git |
| SVT-AV1 | 3.1.2 | BSD-3-Clause-Clear + AOM patent license | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| libvpx | 1.16.0 | BSD-3-Clause | https://chromium.googlesource.com/webm/libvpx |
| dav1d | 1.5.4 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |
| libwebp | 1.6.0 | BSD-3-Clause | https://chromium.googlesource.com/webm/libwebp |
| Opus | 1.6.1 | BSD-3-Clause | https://opus-codec.org |
| LAME | 3.100 | LGPL-2.0-or-later | https://lame.sourceforge.io |
| zimg | 3.0.6 | WTFPL | https://github.com/sekrit-twc/zimg |
| libass | 0.17.5 | ISC | https://github.com/libass/libass |
| FreeType | 2.13.0 | FreeType License (FTL) / GPL-2.0 | https://freetype.org |
| HarfBuzz | 14.3.0 | MIT | https://github.com/harfbuzz/harfbuzz |
| FriBidi | 1.0.16 | LGPL-2.1-or-later | https://github.com/fribidi/fribidi |
| Fontconfig | 2.17.1 | MIT-style | https://www.freedesktop.org/wiki/Software/fontconfig/ |
| libxml2 | 2.15.3 | MIT | https://gitlab.gnome.org/GNOME/libxml2 |
| libogg | 1.3.6 | BSD-3-Clause | https://xiph.org/ogg/ |
| OpenSSL | 3.6.1 | Apache-2.0 | https://www.openssl.org |
| zlib | 1.3.2 | zlib | https://zlib.net |

### Corresponding source (GPL §6)

Everything is built from the unmodified upstream source releases listed above, using the pinned
build-script and `scripts/build-ffmpeg.sh`.

Each GitHub release includes `Morph-<version>-ffmpeg-source.tar`. It contains:
- the exact source archives the build used
- the build-script at the pinned commit
- Morph's build wrapper

You can rebuild the binaries yourself with `make deps`. `Vendor/ffmpeg/BUILDINFO.txt` records the versions used for each build.

## Image codecs linked into Morph

### `morph-rs`
Built from `Vendor/morph-rs` by `scripts/build-rust.sh`, then linked into the app.

| Crate | Version | License |
|---|---|---|
| resvg / usvg / tiny-skia | 0.48.1 / 0.48.1 / 0.12 | Apache-2.0 OR MIT (tiny-skia: BSD-3-Clause) |
| vtracer / visioncortex | 0.6.5 / 0.8.10 | MIT |
| oxipng (with libdeflate, zopfli) | 10.2.1 | MIT (libdeflate: MIT; zopfli: Apache-2.0) |
| quantizr | 1.4.3 | MIT |

All transitive Rust dependencies can be listed with `cargo tree --manifest-path Vendor/morph-rs/Cargo.toml`.

### libwebp
libwebp 1.6.0 (BSD-3-Clause) is compiled from source through the
[SDWebImage/libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode) Swift package.

## Build tools (not shipped)

These are used only to build Morph:
- XcodeGen (MIT)
- Rust / cargo (MIT/Apache-2.0)
- CMake (BSD-3-Clause)
- Meson (Apache-2.0)
- Ninja (Apache-2.0)
- NASM (BSD-2-Clause)
- GNU Autotools (GPL, with exceptions)
