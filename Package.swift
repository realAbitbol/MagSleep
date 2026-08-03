// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MagSleep",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "MagSleepCore", targets: ["MagSleepCore"]),
    ],
    targets: [
        .target(
            name: "MagSleepCore",
            path: "Sources/MagSleepCore"
        ),
        .executableTarget(
            name: "MagSleep",
            dependencies: ["MagSleepCore"],
            path: "Sources/MagSleep"
        ),
        .executableTarget(
            name: "magsleep-helper",
            dependencies: ["MagSleepCore"],
            path: "Sources/MagSleepHelper"
        ),
    ]
)
