// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Misland",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MislandCore", targets: ["MislandCore"]),
        .executable(name: "misland-hook", targets: ["HookBridge"]),
    ],
    targets: [
        .target(
            name: "MislandCore",
            path: "Sources/MislandCore"
        ),
        .executableTarget(
            name: "HookBridge",
            dependencies: ["MislandCore"],
            path: "Sources/HookBridge"
        ),
        .testTarget(
            name: "MislandCoreTests",
            dependencies: ["MislandCore"],
            path: "Tests/MislandCoreTests"
        ),
    ]
)
