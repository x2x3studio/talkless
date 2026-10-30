// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReleaseTool",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ReleaseTool", targets: ["ReleaseTool"])],
    targets: [
        .executableTarget(name: "ReleaseTool"),
        .testTarget(name: "ReleaseToolTests", dependencies: ["ReleaseTool"]),
    ]
)
