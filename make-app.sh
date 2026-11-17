#!/bin/bash
# Builds Sweep.app next to this script. Then drag it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=Sweep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Sweep "$APP/Contents/MacOS/Sweep"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sweep</string>
  <key>CFBundleDisplayName</key><string>Sweep</string>
  <key>CFBundleIdentifier</key><string>com.sweep.app</string>
  <key>CFBundleExecutable</key><string>Sweep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Sweep asks Finder to empty the Trash.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Sweep looks for large, old and duplicate files.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Sweep looks for large, old and duplicate files.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Sweep looks for large, old and duplicate files.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
