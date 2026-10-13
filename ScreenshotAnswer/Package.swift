// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScreenshotAnswer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScreenshotAnswerCore", targets: ["ScreenshotAnswerCore"]),
        .executable(name: "ScreenshotAnswer", targets: ["ScreenshotAnswerApp"]),
        .executable(name: "screenshot-answer-cli", targets: ["ScreenshotAnswerCLI"]),
    ],
    targets: [
        .target(
            name: "ScreenshotAnswerCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "ScreenshotAnswerApp",
            dependencies: ["ScreenshotAnswerCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
            ]
        ),
        .executableTarget(
            name: "ScreenshotAnswerCLI",
            dependencies: ["ScreenshotAnswerCore"]
        ),
        .testTarget(
            name: "ScreenshotAnswerCoreTests",
            dependencies: ["ScreenshotAnswerCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
