import Foundation

import ArilsCore

/// Breathing with organic drift: the cycle length and depth both wander slowly
/// (noise-modulated), so no two breaths are identical — one of the strongest
/// "alive" cues at a glance. Concentration slows and shallows it (a held
/// breath while thinking); a startle quickens it.
public final class BreathingLayer: MotionLayer {
    private let rateNoise: ValueNoise1D
    private let depthNoise: ValueNoise1D
    /// Phase accumulates through a drifting rate, keeping the wave continuous
    /// even as the breathing speed changes.
    private var phase: Double = 0
    private var depthScale = SpringDamper(value: 1, frequency: 0.4, dampingRatio: 1.0)

    public init(seed: UInt64) {
        self.rateNoise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("breath.rate")))
        self.depthNoise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("breath.depth")))
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let t = Float(context.time)
        // ~3.4 s per breath at rest, ±0.7 s of slow wander, faster when excited.
        let behavior = context.inputs.effectiveBehavior
        let tempo: Double = behavior == .thinking ? 1.2 : behavior == .surprised ? 0.7 : 1
        let period = (3.4 + Double(rateNoise.value(at: t * 0.11)) * 0.7)
            / Double(0.85 + 0.3 * context.inputs.energy) * tempo
        phase += Double(context.deltaTime) / max(1.5, period)
        let wave = 0.5 - 0.5 * cos(Float(phase) * 2 * .pi)
        let held = depthScale.step(
            toward: behavior == .thinking ? 0.65 : behavior == .surprised ? 1.2 : 1,
            deltaTime: context.deltaTime
        )
        let depth = (0.75 + 0.25 * depthNoise.value(at: t * 0.05 + 7)) * held
        let breath = wave * depth

        values.add(.breath, breath)
        // Shoulders ride the inhale.
        values.add(.shoulderY, 0.18 * breath)
    }
}
