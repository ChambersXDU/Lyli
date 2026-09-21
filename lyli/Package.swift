// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lyli",

    defaultLocalization: "zh-Hans",

    platforms: [.macOS(.v14)],

    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),

    ],
    targets: [
        .target(
            name: "LyliCore",
            path: "Sources/LyliCore"
        ),
        .executableTarget(
            name: "lyli",
            dependencies: ["LyliCore", "KeyboardShortcuts"],
            path: "Sources/lyli",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "lyli-selftest",
            dependencies: ["LyliCore"],
            path: "Sources/lyli-selftest"
        ),
    ]
)
