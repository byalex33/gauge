// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Sparkle: signed, opt-in update checks (the only network request Gauge makes).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Gauge",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Gauge",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
