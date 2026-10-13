import Foundation

import ArilsCore

/// Adds a smoothed, deliberately conservative camera-face bias on top of the
/// authored motion. It never owns a parameter base: blink, lip sync, gaze,
/// idle motion, and transient reactions remain visible because every output is
/// written with `add`.
public final class FaceTrackingLayer: MotionLayer {
    private var yaw = SpringDamper(value: 0, frequency: 4.5, dampingRatio: 1.05)
    private var pitch = SpringDamper(value: 0, frequency: 4.0, dampingRatio: 1.05)
    private var roll = SpringDamper(value: 0, frequency: 4.0, dampingRatio: 1.05)
    private var leftEye = SpringDamper(value: 0, frequency: 7.0, dampingRatio: 1.0)
    private var rightEye = SpringDamper(value: 0, frequency: 7.0, dampingRatio: 1.0)
    private var mouth = SpringDamper(value: 0, frequency: 7.0, dampingRatio: 1.0)

    public init() {}

    public func update(context: MotionContext, values: inout ParameterValues) {
        let target = Self.bias(
            for: context.inputs.faceTracking,
            blend: context.inputs.faceTrackingBlend
        )
        let dt = context.deltaTime
        values.add(.angleX, yaw.step(toward: target.yawDegrees, deltaTime: dt))
        values.add(.angleY, pitch.step(toward: target.pitchDegrees, deltaTime: dt))
        values.add(.angleZ, roll.step(toward: target.rollDegrees, deltaTime: dt))
        values.add(.eyeLeftOpen, leftEye.step(toward: target.leftEyeOpen, deltaTime: dt))
        values.add(.eyeRightOpen, rightEye.step(toward: target.rightEyeOpen, deltaTime: dt))
        values.add(.mouthOpen, mouth.step(toward: target.mouthOpen, deltaTime: dt))
    }

    /// Pure calibration map used by the layer and regression tests.
    public static func bias(for input: FaceTrackingInput?, blend: Float) -> Bias {
        guard let input else {
            return .zero
        }
        let safeBlend = finiteClamp(blend, 0...1)
        let confidence = finiteClamp(input.confidence, 0...1)
        let weight = safeBlend * confidence
        guard weight > 0 else {
            return .zero
        }

        // Pose is intentionally attenuated: camera motion is a secondary
        // performance layer, not a replacement for authored gaze/idle motion.
        let yaw = finiteClamp(input.yawDegrees, -24...24) * 0.55 * weight
        let pitch = finiteClamp(input.pitchDegrees, -16...16) * 0.45 * weight
        let roll = finiteClamp(input.rollDegrees, -18...18) * 0.45 * weight

        // Vision contour ratios vary with illustration/lighting. The neutral
        // anchors and gains therefore leave a broad dead-ish center and only
        // contribute a bounded delta to blink/lip-sync bases.
        let leftEye = finiteClamp(
            (finiteClamp(input.leftEyeAspectRatio, 0...1) - 0.25) * 3.2,
            -0.75...0.18
        ) * weight
        let rightEye = finiteClamp(
            (finiteClamp(input.rightEyeAspectRatio, 0...1) - 0.25) * 3.2,
            -0.75...0.18
        ) * weight
        let mouth = finiteClamp(
            (finiteClamp(input.mouthAspectRatio, 0...1.5) - 0.18) * 1.15,
            0...0.55
        ) * weight

        return Bias(
            yawDegrees: yaw,
            pitchDegrees: pitch,
            rollDegrees: roll,
            leftEyeOpen: leftEye,
            rightEyeOpen: rightEye,
            mouthOpen: mouth
        )
    }

    public struct Bias: Sendable, Equatable {
        public var yawDegrees: Float
        public var pitchDegrees: Float
        public var rollDegrees: Float
        public var leftEyeOpen: Float
        public var rightEyeOpen: Float
        public var mouthOpen: Float

        public static let zero = Bias(
            yawDegrees: 0,
            pitchDegrees: 0,
            rollDegrees: 0,
            leftEyeOpen: 0,
            rightEyeOpen: 0,
            mouthOpen: 0
        )
    }

    private static func finiteClamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        guard value.isFinite else {
            return min(max(0, range.lowerBound), range.upperBound)
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
