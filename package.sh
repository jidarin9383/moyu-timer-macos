#!/bin/bash
# Build a drag-to-Applications disk image for the current Mac architecture.
set -euo pipefail
cd "$(dirname "$0")"

bash build.sh

APP_PATH="${MOYU_BUILD_DIR:-build/aquarium-preview}/摸了个鱼.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
ARCH="$(uname -m)"
OUTPUT_DIR="${MOYU_DIST_DIR:-$PWD/dist/aquarium-preview}"
IMAGE_PATH="$OUTPUT_DIR/摸了个鱼-${VERSION}-macOS-${ARCH}.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moyu-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
ditto "$APP_PATH" "$STAGING_DIR/摸了个鱼.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp docs/INSTALL.txt "$STAGING_DIR/安装与安全提示.txt"
codesign --verify --deep --strict "$STAGING_DIR/摸了个鱼.app"

hdiutil create -volname "摸了个鱼" -srcfolder "$STAGING_DIR" \
    -format UDZO -ov "$IMAGE_PATH"
hdiutil verify "$IMAGE_PATH"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$IMAGE_PATH")") > "$IMAGE_PATH.sha256"
echo "Package: $IMAGE_PATH"
