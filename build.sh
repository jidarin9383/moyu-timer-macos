#!/bin/bash
# Build the native app and prefer a stable Apple signing identity for TCC.
# Usage: ./build.sh, then open "build/aquarium-preview/摸了个鱼.app"
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="摸了个鱼"
EXEC_NAME="MoyuTimer"
MIN_MACOS="13.0"
BUILD_DIR="${MOYU_BUILD_DIR:-build/aquarium-preview}"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> 清理旧构建"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "==> 编译 Swift 源码（目标 macOS ${MIN_MACOS}）"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
swiftc -O \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  -sdk "$SDK_PATH" \
  $(find App -name "*.swift") \
  -framework Cocoa -framework ApplicationServices -framework SwiftUI -framework Charts \
  -framework IOKit -framework ServiceManagement -framework CoreAudio \
  -lsqlite3 \
  -o "$APP_DIR/Contents/MacOS/$EXEC_NAME"

echo "==> 写入 Info.plist"
cp App/Info.plist "$APP_DIR/Contents/Info.plist"
cp App/Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"
cp App/Resources/public_suffix_list.dat "$APP_DIR/Contents/Resources/"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE-MIT.txt"
cp docs/licenses/MPL-2.0.txt "$APP_DIR/Contents/Resources/"
ditto App/Resources/Aquarium "$APP_DIR/Contents/Resources/Aquarium"

# A stable certificate keeps Automation grants valid across rebuilds. Ad hoc
# signatures identify one binary version and cannot retain those grants reliably.
SIGNING_IDENTITY="${MOYU_CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITIES=()
  while IFS= read -r IDENTITY; do
    [[ -n "$IDENTITY" ]] && SIGNING_IDENTITIES+=("$IDENTITY")
  done < <(/usr/bin/security find-identity -v -p codesigning | \
    awk '/"(Apple Development|Developer ID Application):/ {print $2}')
  if [[ ${#SIGNING_IDENTITIES[@]} -eq 1 ]]; then
    SIGNING_IDENTITY="${SIGNING_IDENTITIES[0]}"
  else
    SIGNING_IDENTITY="-"
    echo "==> 未找到唯一的 Apple 签名身份；使用临时签名（重建后可能需要重新授权）"
    echo "    可通过 MOYU_CODE_SIGN_IDENTITY 指定签名身份。"
  fi
fi

echo "==> 签名"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo ""
echo "==> 构建完成: $APP_DIR"
echo "    运行: open \"$APP_DIR\""
