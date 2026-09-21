// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lyli",


    platforms: [.macOS(.v14)],

    dependencies: [],
    targets: [
        .target(
            name: "LyliCore",
            path: "Sources/LyliCore"
        ),
        .executableTarget(
            name: "lyli",
            dependencies: ["LyliCore"],
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
