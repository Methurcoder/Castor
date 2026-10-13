// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArilsEx",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ArilsEx", targets: ["ArilsEx"]),
        .executable(name: "arils-ex-demo", targets: ["ArilsExDemo"]),
        .executable(name: "arils-ex-visibility", targets: ["ArilsExVisibility"]),
    ],
    dependencies: [
        .package(path: "../Arils"),
    ],
    targets: [
        .target(
            name: "ArilsEx",
            dependencies: [
                .product(name: "Arils", package: "Arils"),
            ]
        ),
        .executableTarget(
            name: "ArilsExDemo",
            dependencies: ["ArilsEx"]
        ),
        .executableTarget(
            name: "ArilsExVisibility",
            dependencies: ["ArilsEx"],
            path: "Tools/ArilsExVisibility",
            exclude: ["BASELINE.md"]
        ),
        .testTarget(
            name: "ArilsExTests",
            dependencies: ["ArilsEx"]
        ),
    ]
)
