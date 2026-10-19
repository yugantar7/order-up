#!/bin/sh
# Builds OrderUp.app (the chef) from OrderUp.swift: one Swift file, ad-hoc signed so
# macOS remembers its permission to bring your terminal tab forward.
#   sh build.sh [where/OrderUp.app]   (default: ~/.claude/order-up/OrderUp.app)
set -e
here=$(cd "$(dirname "$0")" && pwd)
app="${1:-$HOME/.claude/order-up/OrderUp.app}"
command -v swiftc >/dev/null 2>&1 || { echo "swiftc not found: install Apple's Command Line Tools with: xcode-select --install" >&2; exit 1; }
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/OrderUp" "$here/OrderUp.swift"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.order-up.chef</string>
  <key>CFBundleName</key><string>OrderUp</string>
  <key>CFBundleExecutable</key><string>OrderUp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>OrderUp brings the terminal tab of a finished Claude Code session to the front when you click its order.</string>
</dict>
</plist>
PLIST
codesign --force -s - "$app" >/dev/null 2>&1 || true
echo "built $app"
