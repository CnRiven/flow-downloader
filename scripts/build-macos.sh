#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Flow
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/拾流.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flow" "$APP/Contents/MacOS/Flow"
swift scripts/make-icon.swift "$PWD/.build/Flow.iconset"
iconutil -c icns .build/Flow.iconset -o "$APP/Contents/Resources/Flow.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Flow</string>
<key>CFBundleIdentifier</key><string>app.flow.downloader</string>
<key>CFBundleName</key><string>拾流</string>
<key>CFBundleDisplayName</key><string>拾流</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Flow</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Flow contributors. GPL-3.0-or-later.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/Flow-macOS.zip"
echo "已构建：$APP"
