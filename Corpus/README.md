# Real-world test corpus

`manifest.tsv` lists public sample files that exercise the cases synthetic test media misses, such as:
- iPhone Dolby Vision, HDR10 and HLG video, rotated and variable-frame-rate recordings
- camera RAW (including iPhone ProRAW), HEIC grids and bursts, CMYK JPEGs, 16-bit PNGs, JPEG XL
- old containers (AVI, WMV, FLV, MPEG-2, VOB), ProRes 4444 with alpha, 5.1 audio
- scanned and form-filled PDFs, and damaged files that must fail with a readable message

The files aren't stored in this repository. `make corpus` downloads them (checksums verified) into
`~/Library/Caches/MorphCorpus`, converts each one to its common formats with default settings, and
checks every output: it has to decode, keep the right size, orientation, duration and page count.
The report is written to `build/corpus-report.txt`.

Columns: `name`, `kind`, `url` (or `derived:<op>:<source>:<arg>` for files made from another corpus
file, e.g. a truncated video), `sha256`, `bytes`, `covers` (what the file exercises; `expect-failure`
marks files that must fail gracefully) and `source_license`.

Sources (GitHub links are pinned to commits):
- FFmpeg's [FATE suite](https://fate-suite.ffmpeg.org) and [samples archive](https://samples.ffmpeg.org)
- [Wikimedia Commons](https://commons.wikimedia.org) (see each file's page for its license)
- [metadata-extractor-images](https://github.com/drewnoakes/metadata-extractor-images) (camera JPEGs, TIFFs, HEIF)
- [AndroidX Media test data](https://github.com/androidx/media) (phone HDR, Dolby Vision, VFR and rotated video)
- [pdf.js test PDFs](https://github.com/mozilla/pdf.js/tree/master/test/pdfs) and [py-pdf sample files](https://github.com/py-pdf/sample-files)
- [AOM AVIF test files](https://github.com/AOMediaCodec/av1-avif), [libjxl conformance](https://github.com/libjxl/conformance),
  [Nokia HEIF conformance](https://github.com/nokiatech/heif_conformance) and [libvips test images](https://github.com/libvips/libvips)
- [raw.pixls.us](https://raw.pixls.us) (CC0), [PngSuite](http://www.schaik.com/pngsuite/) and
  [McGill's audio format samples](https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/)

Licenses vary: the `source_license` column records each file's terms. A few are non-commercial
(CC BY-NC/-ND) or state no formal license, which is why they're referenced rather than redistributed
here; they're only downloaded to test Morph locally.
