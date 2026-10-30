// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Talkless",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6"
        ),
        // Package.resolved pins 7ede4fd6d05f63305c1c0ebf4f8c1909a637c574.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.33.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Talkless",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Talkless",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
