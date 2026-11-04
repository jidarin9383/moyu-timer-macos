#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_APP_DIR="$PWD/build/aquarium-qa/MoyuUIPreview.app"
mkdir -p "$QA_APP_DIR/Contents/MacOS" "$QA_APP_DIR/Contents/Resources"
SOURCES=()
for source in App/*.swift; do
  [[ "$source" == "App/main.swift" ]] || SOURCES+=("$source")
done
swiftc "${SOURCES[@]}" Tests/UIPreview.swift \
  -framework Cocoa -framework ApplicationServices -framework SwiftUI -framework Charts -framework IOKit \
  -framework ServiceManagement -framework CoreAudio -lsqlite3 -o "$QA_APP_DIR/Contents/MacOS/MoyuUIPreview"
ditto App/Resources/Aquarium "$QA_APP_DIR/Contents/Resources/Aquarium"
cp App/Resources/public_suffix_list.dat "$QA_APP_DIR/Contents/Resources/"
cat > "$QA_APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.darinji.moyutimer.uiqa</string>
<key>CFBundleExecutable</key><string>MoyuUIPreview</string>
<key>CFBundleName</key><string>Moyu UI Preview</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$QA_APP_DIR"
echo "$QA_APP_DIR"
