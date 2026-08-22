// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "grayroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GrayroomCore", targets: ["GrayroomCore"]),
        .library(name: "GrayroomLibrary", targets: ["GrayroomLibrary"]),
        .executable(name: "grayroom", targets: ["grayroom"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
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
                .copy("Shaders/Downsample.metal"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "GrayroomLibrary",
            dependencies: [
                "GrayroomCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "GrayroomUI",
            dependencies: ["GrayroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The commands live in a library, not in the executable, for the same
        // reason `GrayroomCanvas` does: an executable target cannot be imported
        // by a test target, and the argument parsing, photo-reference
        // resolution and edit-source precedence all want direct tests.
        .target(
            name: "GrayroomCLI",
            dependencies: [
                "GrayroomCore",
                "GrayroomLibrary",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "grayroom",
            dependencies: ["GrayroomCLI"],
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
            dependencies: ["GrayroomCore", "GrayroomLibrary", "GrayroomUI", "GrayroomCanvas"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrayroomCoreTests",
            dependencies: ["GrayroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrayroomCLITests",
            dependencies: [
                "GrayroomCLI",
                "GrayroomLibrary",
                "GrayroomCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrayroomLibraryTests",
            dependencies: ["GrayroomLibrary", "GrayroomCore"],
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
