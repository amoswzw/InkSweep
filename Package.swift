// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InkSweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InkSweepCore", targets: ["InkSweepCore"]),
        .executable(name: "inksweep", targets: ["inksweep"]),
        .executable(name: "InkSweepApp", targets: ["InkSweepApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amoswzw/InkKit.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "InkSweepCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "inksweep",
            dependencies: ["InkSweepCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "InkSweepApp",
            dependencies: ["InkSweepCore", .product(name: "InkKit", package: "InkKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "InkSweepCoreTests",
            dependencies: ["InkSweepCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
