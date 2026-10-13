// swift-tools-version: 6.0
import PackageDescription

// The desktop pet for platforms where Castor has no native app yet
// (Windows first). It plays avatars rigged on a Mac: rigging still needs
// Apple's Vision and Core ML.
let package = Package(
    name: "CastorDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CastorPet", targets: ["CastorPet"]),
        .executable(name: "pet-snapshot", targets: ["PetSnapshot"]),
    ],
    dependencies: [
        .package(path: "../Arils"),
    ],
    targets: [
        // stb_image (public domain / MIT), PNG decoding only.
        .target(name: "CStbImage"),

        // Platform-independent: archive loading, motion, deformation and a
        // CPU rasterizer into a premultiplied BGRA canvas.
        .target(
            name: "PetRuntime",
            dependencies: ["CStbImage", .product(name: "ArilsPortable", package: "Arils")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .debug))]
        ),

        // The Windows shell: a layered, always-on-top window. Compiles to a
        // stub elsewhere.
        .executableTarget(
            name: "CastorPet",
            dependencies: ["PetRuntime"],
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
            ]
        ),

        // Renders a few frames of a pet to PPM images, for checking the
        // runtime on any platform without a window.
        .executableTarget(name: "PetSnapshot", dependencies: ["PetRuntime"]),

        .testTarget(name: "PetRuntimeTests", dependencies: ["PetRuntime", .product(name: "ArilsPortable", package: "Arils")]),
    ],
    swiftLanguageModes: [.v5]
)
