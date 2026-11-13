#!/bin/bash
# Build the invisibility lab into build/lab: `lab` (observer and simulated
# user) and "BCU Fixture.app" (the app the simulated user is in).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=build/lab
mkdir -p "$OUT"
swiftc -O -o "$OUT/lab" Tools/Lab/Lab.swift
APP="$OUT/BCU Fixture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/Fixture" Tools/Lab/Fixture.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BCU Fixture</string>
  <key>CFBundleIdentifier</key><string>dev.moulik.bcu-fixture</string>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1
echo "built $OUT/lab and $APP"
