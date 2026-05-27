// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "whisperkit-stress",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "whisperkit-stress",
            dependencies: ["WhisperKit"],
            path: "Sources/stress"
        ),
        .executableTarget(
            name: "whisperkit-benchmark",
            dependencies: ["WhisperKit"],
            path: "Sources/benchmark"
        ),
    ]
)
