// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConnectProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../CastorCore")],
    targets: [
        .executableTarget(name: "ConnectProbe", dependencies: [.product(name: "CastorCore", package: "CastorCore")])
    ],
    swiftLanguageModes: [.v5]
)
