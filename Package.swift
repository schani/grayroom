// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "grayroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GrayroomCore", targets: ["GrayroomCore"]),
        .executable(name: "grayroom", targets: ["grayroom"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "GrayroomCore",
            exclude: ["README.md"],
            resources: [
                .copy("Shaders/Common.metal"),
                .copy("Shaders/Tone.metal"),
                .copy("Shaders/BWMix.metal"),
                .copy("Shaders/Clarity.metal"),
                .copy("Shaders/Mask.metal"),
                .copy("Shaders/Toning.metal"),
                .copy("Shaders/Output.metal"),
                .copy("Shaders/Histogram.metal"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "GrayroomUI",
            dependencies: ["GrayroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "grayroom",
            dependencies: [
                "GrayroomCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The canvas view lives in its own library, not in the app executable,
        // for one reason: an executable target cannot be imported by a test
        // target, and the canvas is where the input/display coordinate contract
        // lives — exactly the code that most needs a real-AppKit regression test.
        .target(
            name: "GrayroomCanvas",
            dependencies: ["GrayroomCore", "GrayroomUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GrayroomApp",
            dependencies: ["GrayroomCore", "GrayroomUI", "GrayroomCanvas"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrayroomCoreTests",
            dependencies: ["GrayroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrayroomUITests",
            dependencies: ["GrayroomUI", "GrayroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrayroomCanvasTests",
            dependencies: ["GrayroomCanvas", "GrayroomUI", "GrayroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
