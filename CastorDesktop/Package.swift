// swift-tools-version: 6.0
import PackageDescription

// Shared image/layer/Quality rigging, playback and services with native shells.
// Full feature and real-device parity remain in progress.
let package = Package(
    name: "CastorDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CastorDesktopRuntime", targets: ["PetRuntime"]),
        .executable(name: "CastorPet", targets: ["CastorPet"]),
        .executable(name: "CastorSetup", targets: ["CastorSetup"]),
        .executable(name: "CastorNeuralTTS", targets: ["CastorNeuralTTS"]),
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
        .target(name: "CPlatformImage", linkerSettings: [
            .linkedLibrary("Ole32",.when(platforms:[.windows])),
            .linkedLibrary("WindowsCodecs",.when(platforms:[.windows])),
            .linkedLibrary("Uuid",.when(platforms:[.windows])),
            .linkedFramework("CoreGraphics",.when(platforms:[.macOS])),
            .linkedFramework("ImageIO",.when(platforms:[.macOS]))]),
        .target(name: "CDesktopUI", exclude: ["vendor/LICENSE-webview2"]),
        .target(name: "CInstallLock"),
        // ONNX Runtime C API bridge (headers MIT, vendored); the runtime
        // library itself is loaded at run time, never linked.
        .target(name: "COnnxRuntime", exclude: ["vendor/LICENSE-onnxruntime"],
                linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]),

        // Platform-independent: archive loading, motion, deformation and a
        // CPU rasterizer into a premultiplied BGRA canvas.
        .target(
            name: "PetRuntime",
            dependencies: ["CStbImage", "CPlatformImage", "CInstallLock", "COnnxRuntime", .product(name: "ArilsPortable", package: "Arils"), .product(name: "CastorCore", package: "CastorCore")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .debug))]
        ),

        // The Windows shell: a layered, always-on-top window. Compiles to a
        // stub elsewhere.
        .executableTarget(
            name: "CastorPet",
            dependencies: ["PetRuntime", "CDesktopUI"],
            resources: [.copy("UI")],
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Comdlg32", .when(platforms: [.windows])),
                .linkedLibrary("Shell32", .when(platforms: [.windows])),
                .linkedLibrary("Ole32", .when(platforms: [.windows])),
                .linkedLibrary("Winmm", .when(platforms: [.windows])),
                .linkedLibrary("Dwmapi", .when(platforms: [.windows])),
                .linkedLibrary("Advapi32", .when(platforms: [.windows])),
            ]
        ),

        .executableTarget(name: "CastorSetup", dependencies: ["PetRuntime", "CDesktopUI"],
            linkerSettings: [.linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Comdlg32", .when(platforms: [.windows])),
                .linkedLibrary("Shell32", .when(platforms: [.windows])),
                .linkedLibrary("Ole32", .when(platforms: [.windows])),
                .linkedLibrary("Dwmapi", .when(platforms: [.windows])),
                .linkedLibrary("Advapi32", .when(platforms: [.windows]))]),

        .executableTarget(name: "CastorNeuralTTS", dependencies: [.product(name: "CastorCore", package: "CastorCore")]),

        // Renders a few frames of a pet to PPM images, for checking the
        // runtime on any platform without a window.
        .executableTarget(name: "PetSnapshot", dependencies: ["PetRuntime"]),
        .executableTarget(name: "PetRig", dependencies: ["PetRuntime"]),

        .testTarget(name: "PetRuntimeTests", dependencies: ["PetRuntime", .product(name: "ArilsPortable", package: "Arils")]),
    ],
    swiftLanguageModes: [.v5]
)
