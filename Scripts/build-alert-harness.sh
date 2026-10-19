#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
swift build --product AlertHarness --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache"
BIN_DIR="$(swift build --show-bin-path --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache")"
APP="$PROJECT_ROOT/.build/MacDiskTemp-NotificationTest.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AlertHarness" "$APP/Contents/MacOS/AlertHarness"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AlertHarness</string>
<key>CFBundleIdentifier</key><string>dev.local.MacDiskTemp.NotificationTest</string>
<key>CFBundleName</key><string>MacDiskTemp Notification Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
