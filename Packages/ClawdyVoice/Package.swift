// swift-tools-version: 5.9
//
// ClawdyVoice — Clawdy's bundled, fully local voice: the Misaki English G2P (a fork of
// MisakiSwift with the MLX dependency replaced by a plain-Swift fallback network so it
// runs on Intel Macs and macOS 14) and the Kokoro-82M synthesizer on ONNX Runtime.
//
import PackageDescription

let package = Package(
    name: "ClawdyVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClawdyVoice", targets: ["ClawdyVoice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "ClawdyVoice",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(name: "g2pdump", dependencies: ["ClawdyVoice"]),
        .testTarget(
            name: "ClawdyVoiceTests",
            dependencies: ["ClawdyVoice"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
