#!/usr/bin/env bash
# Visible UI regression using synthetic history; no hotkey or clipboard monitor.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paster-motion.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/PasterMotionCheck.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp -R Paster/Resources/en.lproj Paster/Resources/zh-Hans.lproj "$APP/Resources/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.paster.motioncheck</string>
<key>CFBundleExecutable</key><string>PasterMotionCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find Paster -name '*.swift' ! -name PasterApp.swift | sort)
xcrun swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target "$(uname -m)-apple-macosx14.0" \
  -plugin-path "$(xcrun --show-sdk-platform-path)/Developer/usr/lib/swift/host/plugins" \
  -module-cache-path "$TEST_DIR/modules" -parse-as-library \
  "${SOURCES[@]}" tests/macOSMotionCheck.swift -o "$APP/MacOS/PasterMotionCheck"
"$APP/MacOS/PasterMotionCheck" "$@"
