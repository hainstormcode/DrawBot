#!/usr/bin/env bash
# Builds build/DrawBotTestRig.app, the Colour Learn test rig (a development tool; see Tools/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product DrawBotTestRig
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/DrawBotTestRig.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DrawBotTestRig" "$APP/Contents/MacOS/DrawBotTestRig"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>DrawBotTestRig</string>
	<key>CFBundleIdentifier</key><string>local.drawbot.testrig</string>
	<key>CFBundleName</key><string>DrawBotTestRig</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
