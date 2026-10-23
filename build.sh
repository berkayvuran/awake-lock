#!/bin/zsh
# Builds AwakeLock.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AwakeLock.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$APP/Contents/MacOS/AwakeLock" main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AwakeLock</string>
    <key>CFBundleIdentifier</key><string>com.local.awakelock</string>
    <key>CFBundleExecutable</key><string>AwakeLock</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

pkill -x AwakeLock 2>/dev/null || true
rm -rf ~/Applications/AwakeLock.app
cp -R "$APP" ~/Applications/
open ~/Applications/AwakeLock.app
echo "Installed: ~/Applications/AwakeLock.app"
