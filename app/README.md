# Gauge for Mac

A native SwiftUI system monitor for macOS 26 and later.

## Build

Requires the Xcode command line tools (Swift 6.2+).

```bash
./build.sh          # builds build/Gauge.app
./build.sh --open   # builds and launches it
```

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
`~/Library/Application Support/Gauge/history.sqlite`. Gauge makes no network connections.
Retention (1–90 days) and Clear History are in Settings.

## Screenshots without screen recording

`GAUGE_SNAPSHOT=<folder>` makes the app render its overview to PNGs from live data and quit:

```bash
GAUGE_SNAPSHOT=/tmp/shots GAUGE_SNAPSHOT_HEIGHT=900 GAUGE_SNAPSHOT_SHEET=Memory \
  build/Gauge.app/Contents/MacOS/Gauge
```

## Icon

`Resources/AppIcon.svg` is the source. `Resources/AppIcon.icns` is rendered from it.
