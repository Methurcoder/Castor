import Foundation

import ArilsCore

/// Slow, never-repeating posture drift: head angles, torso lean, arm micro
/// motion. Multi-octave value noise supplies the "random but intentional"
/// wander; a soft spring on every channel adds inertia so changes of direction
/// ease in instead of pivoting instantly.
///
/// The drift calms down while the character is focused (thinking, listening,
/// startled) and scales with the personality. Deliberate posture changes
/// (weight shifts) are micro-actions in `MicroActionLayer`, with anticipation
/// and settle, rather than an envelope here.
public final class IdleSwayLayer: MotionLayer {
    private struct Channel {
        let parameter: ParameterID
        let noise: ValueNoise1D
        let frequency: Float
        let amplitude: Float
        var spring: SpringDamper

        init(parameter: ParameterID, seed: UInt64, frequency: Float, amplitude: Float) {
            self.parameter = parameter
            self.noise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash(parameter.rawValue)))
            self.frequency = frequency
            self.amplitude = amplitude
            self.spring = SpringDamper(value: 0, frequency: 0.5, dampingRatio: 1.0)
        }
    }

    private var channels: [Channel]
    private let personality: MotionPersonality
    /// Behavior-dependent amplitude, eased so a state change never pops.
    private var focusSpring = SpringDamper(value: 1, frequency: 0.5, dampingRatio: 1.0)

    public init(seed: UInt64, personality: MotionPersonality = .standard) {
        self.personality = personality.sanitized
        self.channels = [
            Channel(parameter: .angleX, seed: seed, frequency: 0.13, amplitude: 4.5),
            Channel(parameter: .angleY, seed: seed, frequency: 0.11, amplitude: 2.5),
            Channel(parameter: .angleZ, seed: seed, frequency: 0.09, amplitude: 3.2),
            Channel(parameter: .bodyAngleX, seed: seed, frequency: 0.07, amplitude: 2.0),
            Channel(parameter: .bodyAngleZ, seed: seed, frequency: 0.06, amplitude: 1.4),
            Channel(parameter: .bodyY, seed: seed, frequency: 0.10, amplitude: 0.05),
            Channel(parameter: .armLeftSway, seed: seed, frequency: 0.08, amplitude: 0.45),
            Channel(parameter: .armRightSway, seed: seed, frequency: 0.085, amplitude: 0.45),
        ]
    }

    /// Drift amplitude per behavior: focus quiets the body.
    static func focusScale(for behavior: MotionBehavior) -> Float {
        switch behavior {
        case .idle: 1
        case .listening: 0.75
        case .thinking: 0.6
        case .speaking: 0.9
        case .surprised: 0.5
        }
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let t = Float(context.time)
        let focus = focusSpring.step(
            toward: Self.focusScale(for: context.inputs.effectiveBehavior),
            deltaTime: context.deltaTime
        )
        let energyScale = (0.6 + 0.8 * context.inputs.energy) * personality.idleAmplitude * focus

        for index in channels.indices {
            let target = channels[index].noise.fbm(at: t * channels[index].frequency, octaves: 3)
                * channels[index].amplitude * energyScale
            let value = channels[index].spring.step(toward: target, deltaTime: context.deltaTime)
            values.add(channels[index].parameter, value)
        }
    }
}
