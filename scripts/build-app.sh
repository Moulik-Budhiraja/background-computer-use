#!/bin/bash
# Build "Background Computer Use.app" into ./build and sign it.
#   scripts/build-app.sh            release build, Developer ID signature
#   scripts/build-app.sh --install  also copy it to /Applications and relaunch it
#
# Signing identity: $BCU_SIGN_IDENTITY, else the first "Developer ID Application"
# identity in the keychain, else ad hoc (permissions then reset on every rebuild).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Background Computer Use"
BUNDLE_ID="dev.moulik.BackgroundComputerUse"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="build/$APP_NAME.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/BackgroundComputerUse" "$OUT/Contents/MacOS/BackgroundComputerUse"
cp "$BIN/bcu" "$OUT/Contents/MacOS/bcu"
mkdir -p "$OUT/Contents/Resources/skills"
cp -R skills/background-computer-use "$OUT/Contents/Resources/skills/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>BackgroundComputerUse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Background Computer Use</string>
  <key>NSAudioCaptureUsageDescription</key><string>Sound from apps only the agent is using is kept off your speakers and saved to a file for the session.</string>
</dict>
</plist>
PLIST

IDENTITY="${BCU_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)}"
if [ -z "$IDENTITY" ]; then
  echo "warning: no Developer ID identity found; signing ad hoc" >&2
  IDENTITY="-"
fi
SIGN_FLAGS=(--force --options runtime --timestamp)
[ "$IDENTITY" = "-" ] && SIGN_FLAGS=(--force)
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$OUT/Contents/MacOS/bcu"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$OUT"
codesign --verify --strict "$OUT"
echo "built $OUT (signed: $IDENTITY)"

if [ "${1:-}" = "--install" ]; then
  # SIGTERM makes the app release its windows and remove its display; wait for it.
  pkill -x BackgroundComputerUse 2>/dev/null || true
  for _ in $(seq 1 150); do pgrep -x BackgroundComputerUse >/dev/null || break; sleep 0.1; done
  # Opening the new copy while the old one is still quitting does nothing.
  if pgrep -x BackgroundComputerUse >/dev/null; then echo "error: the old app didn't quit" >&2; exit 1; fi
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$OUT" "/Applications/"
  open -g "/Applications/$APP_NAME.app"
  echo "installed to /Applications and launched"
fi
