import Foundation

/// Identifier of one animatable scalar (Live2D-style parameter).
///
/// Parameters are the contract between the motion system (which writes them)
/// and the rig (whose deformation bindings read them). Using open string IDs
/// instead of an enum lets custom rigs introduce parameters the engine has
/// never heard of without recompiling either side.
public struct ParameterID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible, Comparable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: ParameterID, rhs: ParameterID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The standard parameter vocabulary produced by the automatic rig and the
/// built-in motion layers. Angles are in degrees, everything else normalized.
extension ParameterID {
    /// Head yaw: negative looks to the viewer's left. Degrees.
    public static let angleX: ParameterID = "angleX"
    /// Head pitch: positive looks up. Degrees.
    public static let angleY: ParameterID = "angleY"
    /// Head roll (tilt). Degrees.
    public static let angleZ: ParameterID = "angleZ"

    /// Eye openness, 1 = fully open, 0 = closed. Slightly above 1 = widened.
    public static let eyeLeftOpen: ParameterID = "eyeLeftOpen"
    public static let eyeRightOpen: ParameterID = "eyeRightOpen"
    /// Eyeball offset -1...1; x positive looks to the viewer's right, y positive looks up.
    public static let eyeBallX: ParameterID = "eyeBallX"
    public static let eyeBallY: ParameterID = "eyeBallY"

    /// Mouth openness 0...1.
    public static let mouthOpen: ParameterID = "mouthOpen"
    /// Mouth shape: -1 round ("o/u"), +1 wide ("i/e").
    public static let mouthForm: ParameterID = "mouthForm"

    /// Torso lean. Degrees, smaller range than the head.
    public static let bodyAngleX: ParameterID = "bodyAngleX"
    public static let bodyAngleZ: ParameterID = "bodyAngleZ"
    /// Vertical body settle: negative sinks, positive lifts. Normalized.
    public static let bodyY: ParameterID = "bodyY"

    /// Breathing cycle 0...1 (0 = exhaled).
    public static let breath: ParameterID = "breath"
    /// Shoulder rise -1...1.
    public static let shoulderY: ParameterID = "shoulderY"

    /// Physics-driven hair sway -1...1.
    public static let hairFrontSway: ParameterID = "hairFrontSway"
    public static let hairBackSway: ParameterID = "hairBackSway"

    /// Subtle arm/hand drift -1...1.
    public static let armLeftSway: ParameterID = "armLeftSway"
    public static let armRightSway: ParameterID = "armRightSway"

    /// Head-pat compression 0...1 (squashes the head, sinks the body).
    public static let touchSquash: ParameterID = "touchSquash"
}
