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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "MagSleepCore",
            path: "Sources/MagSleepCore"
        ),
        .executableTarget(
            name: "MagSleep",
            dependencies: [
                "MagSleepCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MagSleep",
            // The app bundle is assembled manually (build-app.sh), so the
            // Sparkle framework must be found at @executable_path/../Frameworks.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "magsleep-helper",
            dependencies: ["MagSleepCore"],
            path: "Sources/MagSleepHelper"
        ),
        .testTarget(
            name: "MagSleepCoreTests",
            dependencies: ["MagSleepCore"],
            path: "Tests/MagSleepCoreTests"
        ),
    ]
)
