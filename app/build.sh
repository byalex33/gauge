#!/bin/bash
# Builds Gauge.app into app/build.
#
#   ./build.sh            build and sign ad hoc (runs on this Mac)
#   ./build.sh --open     build, then launch
#
# Set GAUGE_SIGN_IDENTITY to a "Developer ID Application: …" identity to sign for distribution
# with the hardened runtime (required for notarization).
set -euo pipefail
cd "$(dirname "$0")"
source VERSION.env

swift build -c release

APP=build/Gauge.app
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Gauge "$APP/Contents/MacOS/Gauge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Replace the embedded framework wholesale so stale files never linger (ditto keeps its symlinks).
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  mv "$APP/Contents/Frameworks/Sparkle.framework" "$(mktemp -d)/"
fi
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

if [[ -n "${GAUGE_SIGN_IDENTITY:-}" ]]; then
  # Inside-out signing order from Sparkle's documentation.
  sign() { codesign --force --timestamp --options runtime --sign "$GAUGE_SIGN_IDENTITY" "$@"; }
  FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$FW/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
  sign "$FW/Autoupdate"
  sign "$FW/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign "$APP"
  echo "Signed with $GAUGE_SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Signed ad hoc (set GAUGE_SIGN_IDENTITY for Developer ID)"
fi
codesign --verify --deep --strict "$APP"
echo "Built $(pwd)/$APP · Gauge $VERSION ($BUILD)"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
