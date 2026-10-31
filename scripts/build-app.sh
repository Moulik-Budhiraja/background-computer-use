#!/bin/bash
# Build "Background Computer Use.app" into ./build.
#   scripts/build-app.sh            release build, signed ad hoc
#   scripts/build-app.sh --install  signed with your Developer ID, copied to
#                                   /Applications and relaunched
#
# Releases: the release workflow (apps.json, see Moulik-Budhiraja/app-hosting)
# runs the plain build with VERSION and BUILD set, then signs it with the
# Developer ID, notarizes it and publishes it.
#
# VERSION defaults to the VERSION file. BUILD defaults to the release scheme,
# X*100000000 + Y*100000 + Z*100, so a local build and a release of the same
# version compare equal and Sparkle offers the next release to both.
#
# --install signs with $BCU_SIGN_IDENTITY, else the first "Developer ID
# Application" identity in the keychain, else ad hoc. Accessibility and Screen
# Recording stay granted only while the bundle ID and Developer ID team stay
# the same, so an ad hoc build asks for them again.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Background Computer Use"
BUNDLE_ID="dev.moulik.BackgroundComputerUse"
FEED_URL="https://apps.moulik.dev/background-computer-use/appcast.xml"
SPARKLE_PUBLIC_KEY="+k+OitC0q+Sidp2n59PQ0mjvjzUsW0VhCUWQ2a4ifS0="
OUT="build/$APP_NAME.app"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
if ! [[ $VERSION =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: VERSION must look like 1.2.3, not '$VERSION'" >&2
  exit 1
fi
BUILD="${BUILD:-$(( 10#${BASH_REMATCH[1]} * 100000000 + 10#${BASH_REMATCH[2]} * 100000 + 10#${BASH_REMATCH[3]} * 100 ))}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
cp "$BIN/BackgroundComputerUse" "$OUT/Contents/MacOS/BackgroundComputerUse"
cp "$BIN/bcu" "$OUT/Contents/MacOS/bcu"
mkdir -p "$OUT/Contents/Resources/skills"
cp -R skills/background-computer-use "$OUT/Contents/Resources/skills/"

# Sparkle, with its symlinks intact, and the rpath the app finds it by.
ditto "$BIN/Sparkle.framework" "$OUT/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$OUT/Contents/MacOS/BackgroundComputerUse" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$OUT/Contents/MacOS/BackgroundComputerUse"
fi

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
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Background Computer Use</string>
  <key>NSAudioCaptureUsageDescription</key><string>Sound from apps only the agent is using is kept off your speakers and saved to a file for the session.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <!-- Download updates silently; Updater.swift installs them once no agent is working. -->
  <key>SUAutomaticallyUpdate</key><true/>
</dict>
</plist>
PLIST

IDENTITY="-"
if [ $INSTALL = 1 ]; then
  IDENTITY="${BCU_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)}"
  if [ -z "$IDENTITY" ]; then
    echo "warning: no Developer ID identity found; signing ad hoc" >&2
    IDENTITY="-"
  fi
fi
SIGN_FLAGS=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN_FLAGS+=(--options runtime --timestamp)
sign() { codesign "${SIGN_FLAGS[@]}" "$@"; }

# Nested code first, from the inside out, as Sparkle's docs list it. The XPC
# services keep their own entitlements.
FW="$OUT/Contents/Frameworks/Sparkle.framework"
FWV="$FW/Versions/$(readlink "$FW/Versions/Current")"
for xpc in "$FWV"/XPCServices/*.xpc; do sign --preserve-metadata=entitlements "$xpc"; done
sign "$FWV/Autoupdate"
sign "$FWV/Updater.app"
sign "$FW"
sign "$OUT/Contents/MacOS/bcu"
sign "$OUT"
codesign --verify --deep --strict "$OUT"
echo "built $OUT $VERSION ($BUILD), signed: $IDENTITY"

if [ $INSTALL = 1 ]; then
  # SIGTERM makes the app release its windows and remove its display; wait for it.
  pkill -x BackgroundComputerUse 2>/dev/null || true
  for _ in $(seq 1 150); do pgrep -x BackgroundComputerUse >/dev/null || break; sleep 0.1; done
  # Opening the new copy while the old one is still quitting does nothing.
  if pgrep -x BackgroundComputerUse >/dev/null; then echo "error: the old app didn't quit" >&2; exit 1; fi
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$OUT" "/Applications/$APP_NAME.app"
  open -g "/Applications/$APP_NAME.app"
  echo "installed to /Applications and launched"
fi
