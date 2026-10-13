import Foundation

/// Declares one parameter's valid range and neutral value.
///
/// Deformation bindings interpret parameter values as *deviation from
/// `defaultValue`*, so a descriptor is required for every parameter a rig
/// binds — it is what makes "eyes open by default, blink toward 0" and
/// "mouth closed by default, speech opens it" both expressible by the same
/// binding math.
public struct ParameterDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: ParameterID
    public var minimum: Float
    public var maximum: Float
    public var defaultValue: Float

    public init(id: ParameterID, minimum: Float, maximum: Float, defaultValue: Float) {
        precondition(minimum <= maximum, "Invalid range for \(id)")
        self.id = id
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = min(max(defaultValue, minimum), maximum)
    }

    public var range: ClosedRange<Float> { minimum...maximum }

    public func clamp(_ value: Float) -> Float {
        min(max(value, minimum), maximum)
    }
}

/// The descriptor set for the standard parameter vocabulary.
public enum StandardParameters {
    public static let all: [ParameterDescriptor] = [
        ParameterDescriptor(id: .angleX, minimum: -30, maximum: 30, defaultValue: 0),
        ParameterDescriptor(id: .angleY, minimum: -30, maximum: 30, defaultValue: 0),
        ParameterDescriptor(id: .angleZ, minimum: -30, maximum: 30, defaultValue: 0),
        ParameterDescriptor(id: .eyeLeftOpen, minimum: 0, maximum: 1.2, defaultValue: 1),
        ParameterDescriptor(id: .eyeRightOpen, minimum: 0, maximum: 1.2, defaultValue: 1),
        ParameterDescriptor(id: .eyeBallX, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .eyeBallY, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .mouthOpen, minimum: 0, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .mouthForm, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .bodyAngleX, minimum: -10, maximum: 10, defaultValue: 0),
        ParameterDescriptor(id: .bodyAngleZ, minimum: -10, maximum: 10, defaultValue: 0),
        ParameterDescriptor(id: .bodyY, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .breath, minimum: 0, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .shoulderY, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .hairFrontSway, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .hairBackSway, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .armLeftSway, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .armRightSway, minimum: -1, maximum: 1, defaultValue: 0),
        ParameterDescriptor(id: .touchSquash, minimum: 0, maximum: 1, defaultValue: 0),
    ]

    public static func descriptor(for id: ParameterID) -> ParameterDescriptor? {
        all.first { $0.id == id }
    }
}
