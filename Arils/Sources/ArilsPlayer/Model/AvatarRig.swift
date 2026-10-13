#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation

import ArilsCore

/// Configuration for one physics-driven sway output (hair, ribbons, ...).
///
/// The rig only *describes* the oscillator; the motion module integrates it.
/// Keeping the description here means a saved rig fully determines how its
/// hair behaves, while the simulation code stays swappable.
public struct SwayChannel: Codable, Equatable, Sendable {
    /// Parameter the simulated sway is written to (e.g. `hairFrontSway`).
    public var output: ParameterID
    /// Natural frequency in Hz. Light fringes ~1.6, heavy back hair ~0.9.
    public var frequency: Float
    /// Damping ratio; < 1 keeps a little wobble after excitation.
    public var dampingRatio: Float
    /// How strongly head angular velocity excites this channel.
    public var headDrive: Float
    /// Constant low-level noise excitation so hair never freezes solid.
    public var breeze: Float

    public init(
        output: ParameterID,
        frequency: Float,
        dampingRatio: Float,
        headDrive: Float,
        breeze: Float
    ) {
        self.output = output
        self.frequency = frequency
        self.dampingRatio = dampingRatio
        self.headDrive = headDrive
        self.breeze = breeze
    }
}

public struct PhysicsRig: Codable, Equatable, Sendable {
    public var channels: [SwayChannel]

    public init(channels: [SwayChannel] = []) {
        self.channels = channels
    }
}

/// Pose range proven safe by the archive-build integrity sweep.
///
/// Limits are asymmetric because an occluding accessory or side-swept hair can
/// make one direction unsafe before the other. Legacy archives decode to the
/// historically supported ±20° yaw / ±6° pitch range.
public struct ValidatedPoseLimits: Codable, Equatable, Sendable {
    public var minimumYawDegrees: Float
    public var maximumYawDegrees: Float
    public var minimumPitchDegrees: Float
    public var maximumPitchDegrees: Float

    public static let legacyDefault = ValidatedPoseLimits(
        minimumYawDegrees: -20,
        maximumYawDegrees: 20,
        minimumPitchDegrees: -6,
        maximumPitchDegrees: 6
    )

    public init(
        minimumYawDegrees: Float,
        maximumYawDegrees: Float,
        minimumPitchDegrees: Float,
        maximumPitchDegrees: Float
    ) {
        self.minimumYawDegrees = Self.finiteMinimum(minimumYawDegrees)
        self.maximumYawDegrees = Self.finiteMaximum(maximumYawDegrees)
        self.minimumPitchDegrees = Self.finiteMinimum(minimumPitchDegrees)
        self.maximumPitchDegrees = Self.finiteMaximum(maximumPitchDegrees)
    }

    public func clampedYaw(_ degrees: Float) -> Float {
        guard degrees.isFinite else { return 0 }
        return min(max(degrees, minimumYawDegrees), maximumYawDegrees)
    }

    public func clampedPitch(_ degrees: Float) -> Float {
        guard degrees.isFinite else { return 0 }
        return min(max(degrees, minimumPitchDegrees), maximumPitchDegrees)
    }

    public func yawMagnitude(positive: Bool) -> Float {
        positive ? maximumYawDegrees : abs(minimumYawDegrees)
    }

    /// Every limit multiplied by `factor` — for hosts that let the user trade
    /// visual integrity for a wider range. Factors below 1 are ignored.
    public func scaled(by factor: Float) -> ValidatedPoseLimits {
        let factor = factor.isFinite ? max(1, factor) : 1
        return ValidatedPoseLimits(
            minimumYawDegrees: minimumYawDegrees * factor,
            maximumYawDegrees: maximumYawDegrees * factor,
            minimumPitchDegrees: minimumPitchDegrees * factor,
            maximumPitchDegrees: maximumPitchDegrees * factor
        )
    }

    private static func finiteMinimum(_ value: Float) -> Float {
        value.isFinite ? min(value, 0) : 0
    }

    private static func finiteMaximum(_ value: Float) -> Float {
        value.isFinite ? max(value, 0) : 0
    }
}

/// The complete, serializable rig document: everything needed to animate a
/// character except the pixel data itself (see `AvatarArchive` for that).
public struct AvatarRig: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    /// Source image dimensions in pixels; all part rects/meshes live in this space.
    public var imageWidth: Int
    public var imageHeight: Int
    public var parts: [AvatarPart]
    public var parameters: [ParameterDescriptor]
    public var physics: PhysicsRig
    public var validatedPoseLimits: ValidatedPoseLimits

    public init(
        formatVersion: Int = AvatarRig.currentFormatVersion,
        imageWidth: Int,
        imageHeight: Int,
        parts: [AvatarPart],
        parameters: [ParameterDescriptor],
        physics: PhysicsRig = PhysicsRig(),
        validatedPoseLimits: ValidatedPoseLimits = .legacyDefault
    ) {
        self.formatVersion = formatVersion
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.parts = parts
        self.parameters = parameters
        self.physics = physics
        self.validatedPoseLimits = validatedPoseLimits
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case imageWidth
        case imageHeight
        case parts
        case parameters
        case physics
        case validatedPoseLimits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        imageWidth = try container.decode(Int.self, forKey: .imageWidth)
        imageHeight = try container.decode(Int.self, forKey: .imageHeight)
        parts = try container.decode([AvatarPart].self, forKey: .parts)
        parameters = try container.decode([ParameterDescriptor].self, forKey: .parameters)
        physics = try container.decodeIfPresent(PhysicsRig.self, forKey: .physics) ?? PhysicsRig()
        validatedPoseLimits = try container.decodeIfPresent(
            ValidatedPoseLimits.self,
            forKey: .validatedPoseLimits
        ) ?? .legacyDefault
    }

    public func part(withID id: String) -> AvatarPart? {
        parts.first { $0.id == id }
    }

    public func firstPart(ofKind kind: PartKind) -> AvatarPart? {
        parts.first { $0.kind == kind }
    }

    /// Parts in draw order (back to front).
    public var partsInDrawOrder: [AvatarPart] {
        parts.sorted { $0.zOrder < $1.zOrder }
    }
}
