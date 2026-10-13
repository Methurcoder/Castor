import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Reaction to head pats: the head squashes under the hand (underdamped, so it
/// bounces a little), tilts into the stroke direction, the body sinks slightly,
/// the eyes narrow into a content squint, and the stroke pumps energy into the
/// hair physics via `hairImpulse` (consumed by the controller each frame).
public final class PettingLayer: MotionLayer {
    /// Bouncy squash — dampingRatio < 1 gives the "boing" on release.
    private var squashSpring = SpringDamper(value: 0, frequency: 2.8, dampingRatio: 0.55)
    private var tiltSpring = SpringDamper(value: 0, frequency: 1.6, dampingRatio: 0.85)
    private var sinkSpring = SpringDamper(value: 0, frequency: 2.0, dampingRatio: 0.75)
    /// Builds up over a sustained stroke, decays after the hand leaves —
    /// drives the lingering squint/smile.
    private var strokeWarmth: Float = 0

    /// Hair-physics excitation contributed by this frame's stroke; the motion
    /// controller reads and clears it every update.
    public private(set) var hairImpulse: Float = 0

    public init() {}

    public func consumeHairImpulse() -> Float {
        defer { hairImpulse = 0 }
        return hairImpulse
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let dt = context.deltaTime
        let squashTarget: Float
        let tiltTarget: Float
        let sinkTarget: Float

        if let petting = context.inputs.petting,
           petting.position.x.isFinite,
           petting.position.y.isFinite,
           petting.velocity.x.isFinite,
           petting.velocity.y.isFinite {
            let speed = simd_length(petting.velocity)
            strokeWarmth = min(1, strokeWarmth + (0.6 + speed * 0.5) * dt)
            hairImpulse = Interpolation.clamp(petting.velocity.x * 0.4, -1.5...1.5)

            squashTarget = Interpolation.clamp(0.3 + 0.4 * min(1, speed * 0.6), 0...0.85)
            // Lean into the hand: stroke position steers the tilt.
            tiltTarget = Interpolation.clamp(petting.position.x * 7 + petting.velocity.x * 1.1, -10...10)
            sinkTarget = -0.3 * strokeWarmth
        } else {
            hairImpulse = 0
            strokeWarmth = max(0, strokeWarmth - dt * 0.7)
            squashTarget = 0
            tiltTarget = 0
            sinkTarget = -0.25 * strokeWarmth // eases back up as warmth fades
        }

        values.add(.touchSquash, squashSpring.step(toward: squashTarget, deltaTime: dt))
        values.add(.angleZ, tiltSpring.step(toward: tiltTarget, deltaTime: dt))
        values.add(.bodyY, sinkSpring.step(toward: sinkTarget, deltaTime: dt))

        // Content squint + tiny smile while warmth lingers.
        values.add(.eyeLeftOpen, -0.35 * strokeWarmth)
        values.add(.eyeRightOpen, -0.35 * strokeWarmth)
        values.add(.mouthForm, 0.4 * strokeWarmth)
    }
}
