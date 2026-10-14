// swift-tools-version: 6.0
import PackageDescription

// Portable playback and initial Windows image-to-pet rigging. Mac feature parity
// remains in progress; full depth/Quality rigging still uses Apple backends.
let package = Package(
    name: "CastorDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CastorPet", targets: ["CastorPet"]),
        .executable(name: "pet-snapshot", targets: ["PetSnapshot"]),
        .executable(name: "pet-rig", targets: ["PetRig"]),
    ],
    dependencies: [
        .package(path: "../Arils"),
        .package(path: "../CastorCore"),
    ],
    targets: [
        // stb_image (public domain / MIT), PNG decoding only.
        .target(name: "CStbImage"),
        .target(name: "CDesktopUI"),

        // Platform-independent: archive loading, motion, deformation and a
        // CPU rasterizer into a premultiplied BGRA canvas.
        .target(
            name: "PetRuntime",
            dependencies: ["CStbImage", .product(name: "ArilsPortable", package: "Arils"), .product(name: "CastorCore", package: "CastorCore")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .debug))]
        ),

        // The Windows shell: a layered, always-on-top window. Compiles to a
        // stub elsewhere.
        .executableTarget(
            name: "CastorPet",
            dependencies: ["PetRuntime", "CDesktopUI"],
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Comdlg32", .when(platforms: [.windows])),
                .linkedLibrary("Shell32", .when(platforms: [.windows])),
                .linkedLibrary("Ole32", .when(platforms: [.windows])),
            ]
        ),

        // Renders a few frames of a pet to PPM images, for checking the
        // runtime on any platform without a window.
        .executableTarget(name: "PetSnapshot", dependencies: ["PetRuntime"]),
        .executableTarget(name: "PetRig", dependencies: ["PetRuntime"]),

        .testTarget(name: "PetRuntimeTests", dependencies: ["PetRuntime", .product(name: "ArilsPortable", package: "Arils")]),
    ],
    swiftLanguageModes: [.v5]
)
