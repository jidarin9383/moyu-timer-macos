#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PREVIEW_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moyu-native-preview.XXXXXX")"
trap 'rm -rf "$PREVIEW_BUILD_DIR"' EXIT
PREVIEW_SOURCE="Tests/UIPreview.swift"
PREVIEW_OUTPUT="$PWD/docs/ui-redesign/native/screenshots"
if [[ "${1:-}" == "--static" ]]; then
  PREVIEW_SOURCE="Tests/AquariumStaticPreview.swift"
  PREVIEW_OUTPUT="$PWD/docs/ui-redesign/native/static"
  shift
fi
SOURCES=()
for source in App/*.swift; do
  [[ "$source" == "App/main.swift" ]] || SOURCES+=("$source")
done
swiftc "${SOURCES[@]}" "$PREVIEW_SOURCE" \
  -framework Cocoa -framework ApplicationServices -framework SwiftUI -framework Charts -framework IOKit \
  -framework ServiceManagement -framework CoreAudio -lsqlite3 -o "$PREVIEW_BUILD_DIR/UIPreview"
MOYU_ASSET_DIR="$PWD/App/Resources/Aquarium" \
MOYU_PUBLIC_SUFFIX_LIST="$PWD/App/Resources/public_suffix_list.dat" \
  "$PREVIEW_BUILD_DIR/UIPreview" "${1:-$PREVIEW_OUTPUT}"
