#!/bin/bash
# Makes a Gauge release: build, DMG, (optionally) notarize, sign the update, and add it to the appcast.
#
#   ./release.sh 0.3.0                 prepare dist/Gauge-0.3.0.dmg and update website/public/appcast.xml
#   ./release.sh 0.3.0 --publish       …then create the GitHub release and push the appcast (Vercel deploys it)
#
# Release notes come from release-notes/<version>.md: one "- " bullet per line.
# Optional environment:
#   GAUGE_SIGN_IDENTITY   "Developer ID Application: …" to sign for distribution
#   GAUGE_NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials) to notarize and staple
set -euo pipefail
cd "$(dirname "$0")"

NEW_VERSION="${1:?usage: ./release.sh <version> [--publish]}"
PUBLISH="${2:-}"
NOTES="release-notes/$NEW_VERSION.md"
REPO="byalex33/gauge"
BIN=.build/artifacts/sparkle/Sparkle/bin
[[ -f "$NOTES" ]] || { echo "Missing $NOTES"; exit 1; }
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3"; exit 1; }

# Bump the version and build number (Sparkle compares the build number).
source VERSION.env
if [[ "$VERSION" != "$NEW_VERSION" ]]; then BUILD=$((BUILD + 1)); fi   # re-running a release keeps its build number
VERSION="$NEW_VERSION"
printf 'VERSION=%s\nBUILD=%s\n' "$VERSION" "$BUILD" > VERSION.env
./build.sh

# Disk image: Gauge.app next to an Applications shortcut.
mkdir -p dist
STAGE="$(mktemp -d)/Gauge"
mkdir -p "$STAGE"
ditto build/Gauge.app "$STAGE/Gauge.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Gauge-$VERSION.dmg"
hdiutil create -quiet -volname "Gauge $VERSION" -srcfolder "$STAGE" -fs APFS -format UDZO -ov "$DMG"

if [[ -n "${GAUGE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$GAUGE_SIGN_IDENTITY" "$DMG"
  if [[ -n "${GAUGE_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$GAUGE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

# EdDSA signature for Sparkle, using the private key in the login Keychain (account "gauge").
SIGNATURE=$("$BIN/sign_update" --account gauge "$DMG")
echo "Signed update: $SIGNATURE"

python3 - "$VERSION" "$BUILD" "$NOTES" "$SIGNATURE" "$REPO" <<'PY'
import html, re, sys
from email.utils import formatdate
version, build, notes_path, signature, repo = sys.argv[1:]
items = [l[2:].strip() for l in open(notes_path) if l.startswith("- ")]
notes = "<ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>"
attrs = dict(re.findall(r'(sparkle:edSignature|length)="([^"]+)"', signature))
item = f"""    <item>
      <title>Gauge {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="https://github.com/{repo}/releases/download/v{version}/Gauge-{version}.dmg"
                 type="application/octet-stream"
                 sparkle:edSignature="{attrs['sparkle:edSignature']}"
                 length="{attrs['length']}"/>
    </item>
"""
path = "../website/public/appcast.xml"
feed = open(path).read()
feed = re.sub(r"\s*<item>\s*<title>Gauge " + re.escape(version) + r"</title>.*?</item>\n?", "\n", feed, flags=re.S)
marker = "<!-- Newest release first. release.sh inserts items here. -->\n"
feed = feed.replace(marker, marker + item)
open(path, "w").write(feed)
print(f"Appcast updated: Gauge {version} ({build})")
PY

cp "$DMG" dist/Gauge.dmg
echo "Ready: $DMG"

if [[ "$PUBLISH" == "--publish" ]]; then
  # Assets go up first, so the appcast never points at a missing file.
  gh release create "v$VERSION" "$DMG" dist/Gauge.dmg --repo "$REPO" --title "Gauge $VERSION" --notes-file "$NOTES"
  git -C .. add app/VERSION.env "app/$NOTES" website/public/appcast.xml
  git -C .. commit -m "Release Gauge $VERSION"
  git -C .. push
  echo "Published v$VERSION. Vercel deploys the new appcast from main."
fi
