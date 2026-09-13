// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClarifyKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ClarifyKit", targets: ["ClarifyKit"]),
        .executable(name: "clarify-eval", targets: ["ClarifyEval"]),
    ],
    targets: [
        .target(
            name: "ClarifyKit",
            resources: [.copy("Prompts")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ClarifyEval",
            dependencies: ["ClarifyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClarifyKitTests",
            dependencies: ["ClarifyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
