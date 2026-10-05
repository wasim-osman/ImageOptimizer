// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ImageOptimizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageOptimizerCore", targets: ["ImageOptimizerCore"]),
        .executable(name: "ImageOptimizerCLI", targets: ["ImageOptimizerCLI"]),
        .executable(name: "ImageOptimizerApp", targets: ["ImageOptimizerApp"]),
    ],
    targets: [
        .target(name: "ImageOptimizerCore"),
        .executableTarget(name: "ImageOptimizerCLI", dependencies: ["ImageOptimizerCore"]),
        .executableTarget(name: "ImageOptimizerApp", dependencies: ["ImageOptimizerCore"]),
        .testTarget(
            name: "ImageOptimizerCoreTests",
            dependencies: ["ImageOptimizerCore"],
            swiftSettings: [
                // swift-testing ships with the Command Line Tools, but SwiftPM only looks for
                // its macro plugin under a full Xcode. Point at it so `swift test` works
                // without installing Xcode.
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ]),
            ]
        ),
    ]
)
