// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QwenStreamingExperiment",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6"
        ),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.32.3"))
    ],
    targets: [
        .executableTarget(name: "qwen-streaming", dependencies: [
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLX", package: "mlx-swift")
        ], path: "Sources")
    ]
)
