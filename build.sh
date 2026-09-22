#!/bin/bash
# Build ClaudeAwake.app (menu bar only, no Dock icon) into build/.
# Usage: ./build.sh [--install]   # --install copies it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="build/ClaudeAwake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Awake</string>
  <key>CFBundleDisplayName</key><string>Claude Awake</string>
  <key>CFBundleIdentifier</key><string>com.glitchwizard.claude-awake</string>
  <key>CFBundleExecutable</key><string>ClaudeAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict></plist>
PL
plutil -lint "$APP/Contents/Info.plist" >/dev/null

swiftc -swift-version 5 -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/ClaudeAwake" \
  app/ClaudeAwake.swift

# Ad-hoc signature: without one, macOS refuses login-item registration.
codesign --force --sign - --identifier com.glitchwizard.claude-awake "$APP" >/dev/null 2>&1 \
  || echo "note: codesign failed; the app still runs but 'Open at login' may not"

echo "built $APP"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ClaudeAwake.app"
  cp -R "$APP" "$HOME/Applications/ClaudeAwake.app"
  echo "installed $HOME/Applications/ClaudeAwake.app"
fi
