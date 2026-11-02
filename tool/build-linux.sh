#!/usr/bin/env bash
# Build the Linux desktop release: the Go download helper and the Flutter bundle.
#
# Verified on Ubuntu 24.04 (GitHub Actions) and on Deepin 25 when the toolchain
# is reachable (the script only reads PATH; it never configures toolchains).
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT"

GO="${GO:-go}"
FLUTTER="${FLUTTER:-flutter}"
GOOS=linux
GOARCH=amd64
GOTOOLCHAIN="${GOTOOLCHAIN:-go1.24.7}"
NATIVE_BIN="$PROJECT/native/bin"
BUNDLE="$PROJECT/build/linux/x64/release/bundle"

# Never leave build scratch data in the default temp directory: CI runners and
# read-only-root systems both run out of space there.
export TMPDIR="${TMPDIR:-$PROJECT/.local/build-tmp}"
mkdir -p "$TMPDIR"

echo "== building the download helper for $GOOS/$GOARCH"
mkdir -p "$NATIVE_BIN"
(
  cd native/gopeed
  CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" GOTOOLCHAIN="$GOTOOLCHAIN" \
    "$GO" build -tags nosqlite -trimpath \
    -ldflags '-s -w -checklinkname=0 -X github.com/GopeedLab/gopeed/pkg/base.Version=1.8.1' \
    -o "$NATIVE_BIN/asterlink_gopeed" ./cmd/asterlink
)

echo "== collecting build definitions"
defines_file="$TMPDIR/release-defines.txt"
python3 tool/release_defines.py > "$defines_file"
DEFINES=()
while IFS= read -r line; do
  [ -n "$line" ] && DEFINES+=("$line")
done < "$defines_file"

echo "== building the Flutter Linux bundle"
"$FLUTTER" pub get
"$FLUTTER" build linux --release --no-pub ${DEFINES[@]+"${DEFINES[@]}"}

echo "== adding the helper to the bundle"
install -m 0755 "$NATIVE_BIN/asterlink_gopeed" "$BUNDLE/asterlink_gopeed"

for required in asterlink asterlink_gopeed lib/libapp.so lib/libflutter_linux_gtk.so \
                 data/flutter_assets/AssetManifest.bin; do
  if [ ! -e "$BUNDLE/$required" ]; then
    echo "the Linux bundle is incomplete: $required is missing" >&2
    exit 1
  fi
done

echo "== bundle ready: $BUNDLE"
du -sh "$BUNDLE"
