// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Gauge",
            path: "Sources/Gauge",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
