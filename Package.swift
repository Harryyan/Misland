// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MioMini",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MioMiniCore", targets: ["MioMiniCore"]),
        .executable(name: "miomini-hook", targets: ["HookBridge"]),
    ],
    targets: [
        .target(
            name: "MioMiniCore",
            path: "Sources/MioMiniCore"
        ),
        .executableTarget(
            name: "HookBridge",
            dependencies: ["MioMiniCore"],
            path: "Sources/HookBridge"
        ),
        .testTarget(
            name: "MioMiniCoreTests",
            dependencies: ["MioMiniCore"],
            path: "Tests/MioMiniCoreTests"
        ),
    ]
)
