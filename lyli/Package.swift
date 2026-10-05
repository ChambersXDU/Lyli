// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lyli",


    platforms: [.macOS(.v14)],

    dependencies: [],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "LyliCore",
            dependencies: ["CSQLite"],
            path: "Sources/LyliCore"
        ),
        .executableTarget(
            name: "lyli",
            dependencies: ["LyliCore"],
            path: "Sources/lyli"
        ),
        .executableTarget(
            name: "lyli-selftest",
            dependencies: ["LyliCore"],
            path: "Sources/lyli-selftest"
        ),
    ]
)
