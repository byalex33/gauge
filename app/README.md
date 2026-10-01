# Gauge for Mac

A native SwiftUI system monitor for macOS 26 and later, with signed in-app updates via Sparkle.

## Build

Requires the Xcode command line tools (Swift 6.2+).

```bash
./build.sh          # builds build/Gauge.app
./build.sh --open   # builds and launches it
```

## Releasing

```bash
# 1. Write release-notes/<version>.md (one "- " bullet per line)
# 2. Build the DMG, sign the update and add it to website/public/appcast.xml
./release.sh 0.3.0
# 3. Publish: GitHub release with the DMG, then commit and push the appcast (Vercel deploys it)
./release.sh 0.3.0 --publish
```

- The version and build number live in `VERSION.env`. Sparkle compares the build number, so every release increments it.
- Updates are signed with an EdDSA key stored in the login Keychain under the account `gauge`. The public half is `SUPublicEDKey` in `Resources/Info.plist`. Back up the private key (`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account gauge -x gauge-sparkle-key`): without it, existing installs can't accept updates.
- With an Apple Developer ID, set `GAUGE_SIGN_IDENTITY="Developer ID Application: …"` and `GAUGE_NOTARY_PROFILE=<notarytool profile>` to sign with the hardened runtime, notarize and staple.

## What it reads

Gauge samples public macOS counters every 2 seconds, with no administrator access:

| Reading | Source |
| --- | --- |
| CPU load | `host_processor_info` |
| Memory, pressure, swap | `host_statistics64`, `sysctl` |
| GPU utilisation | IOKit `IOAccelerator` performance statistics |
| Disk space and throughput | volume resource values, IOKit `IOBlockStorageDriver` |
| Network | `sysctl` interface counters (Wi-Fi, Ethernet, cellular) |
| Battery | IOKit power sources and `AppleSmartBattery` |
| Apps and processes | `libproc` (your own processes; other users' need admin access) |
| Dev servers | `lsof` listening TCP ports for Node, Python, Ruby and similar |
| Audio, Bluetooth batteries | CoreAudio, IOKit |

Temperature and fan sensors are not read yet; they need a privileged helper.

## History stays on your Mac

Readings are averaged every 10 seconds into a SQLite file at
`~/Library/Application Support/Gauge/history.sqlite` and never uploaded. The only network request is
Sparkle's opt-in update check of `https://gauge.alex.codes/appcast.xml`, with system profiling off.
Retention (1–90 days) and Clear History are in Settings.

## Screenshots without screen recording

`GAUGE_SNAPSHOT=<folder>` makes the app render its overview to PNGs from live data and quit:

```bash
GAUGE_SNAPSHOT=/tmp/shots GAUGE_SNAPSHOT_HEIGHT=900 GAUGE_SNAPSHOT_SHEET=Memory \
  build/Gauge.app/Contents/MacOS/Gauge
```

## Icon

`Resources/AppIcon.svg` is the source. `Resources/AppIcon.icns` is rendered from it.
