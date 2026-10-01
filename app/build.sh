#!/bin/bash
# Builds Gauge.app into app/build. Usage: ./build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Gauge.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Gauge "$APP/Contents/MacOS/Gauge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
