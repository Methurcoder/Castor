// swift-tools-version: 6.2
import PackageDescription

// Mirrors the app target's Swift settings (Swift 5 mode, MainActor default isolation, and the
// Approachable Concurrency feature set) so code behaves the same after moving out of the app.
let coreSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "CastorCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CastorCore", targets: ["CastorCore"]),
    ],
    targets: [
        // Platform-independent Castor logic: semantic state (Hesitate Core), the motion
        // bridge (Cherry Connection), local LLM clients, agent routing, and pure speech/voice
        // helpers. Foundation and Observation only, so it builds on macOS, Windows, and Linux.
        .target(
            name: "CastorCore",
            swiftSettings: coreSwiftSettings
        ),
        .testTarget(
            name: "CastorCoreTests",
            dependencies: ["CastorCore"],
            swiftSettings: coreSwiftSettings
        ),
    ]
)
