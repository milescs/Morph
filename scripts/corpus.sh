#!/bin/sh
# Real-world media regression run. Downloads the public sample files listed in Corpus/manifest.tsv
# (camera files, HDR video, odd containers, scans, damaged files …) into a cache, verifies their
# checksums, then converts each one to its common targets and checks every output.
#   make corpus            # or: scripts/corpus.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${MORPH_CORPUS:-$HOME/Library/Caches/MorphCorpus}"
MANIFEST="$ROOT/Corpus/manifest.tsv"
mkdir -p "$DIR"

TAB="$(printf '\t')"
tail -n +2 "$MANIFEST" | while IFS="$TAB" read -r name kind url sha bytes covers license; do
    [ -n "$name" ] || continue
    file="$DIR/$name"
    if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
        continue
    fi
    case "$url" in
        derived:*)
            # Made locally from another corpus file, e.g. "derived:truncate:source.mov:60"
            IFS=: read -r _ op source arg <<EOF
$url
EOF
            case "$op" in
                truncate)
                    size=$(stat -f %z "$DIR/$source")
                    head -c $((size * arg / 100)) "$DIR/$source" > "$file" ;;
                *) echo "unknown derivation $op" >&2; exit 1 ;;
            esac ;;
        *)
            echo "downloading $name"
            curl -fsSL --retry 2 -o "$file.part" "$url"
            mv "$file.part" "$file" ;;
    esac
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    [ "$actual" = "$sha" ] || { echo "checksum mismatch for $name: $actual" >&2; exit 1; }
done
cp "$MANIFEST" "$DIR/manifest.tsv"

cd "$ROOT/MorphKit"
MORPH_CORPUS="$DIR" swift test --filter CorpusTests 2>&1 | tee "$ROOT/build/corpus-report.txt" | grep -E "^(✓|✗|====)|passed|failed"
