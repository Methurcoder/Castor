import Foundation

import ArilsCore
import ArilsRig

/// Pure logic behind automatic view turning: maps the gaze target to horizontal
/// `viewTurn` and vertical `viewPitch` values.
///
/// - A **dead zone** keeps the character frontal while the target is near
///   center, so small gaze wander never flickers the profile in and out.
/// - Beyond it, the turn ramps smoothly and saturates before the target
///   reaches the edge, so "looking clearly to the side" reads as a full turn.
/// - The archive's declared side can reach the full profile. The unsupported
///   side is capped at the frontal depth rig's small-angle range and never
///   reveals or mirrors the profile image.
/// - A soft spring smooths the transitions; losing the target eases back to
///   frontal instead of snapping.
struct QualityTurnModel {
    var poseLimits: ValidatedPoseLimits
    /// |gazeX| toward the supported side below this stays frontal.
    var deadZone: Float = 0.3
    /// |gazeX| at which the turn saturates to the full profile.
    var fullTurnAt: Float = 0.75
    private var spring = SpringDamper(value: 0, frequency: 1.1, dampingRatio: 1.0)
    /// Vertical tracking starts sooner than a profile turn because it never
    /// crosses to a different reference image.
    var pitchDeadZone: Float = 0.16
    var fullPitchAt: Float = 0.72
    private var pitchSpring = SpringDamper(value: 0, frequency: 1.1, dampingRatio: 1.0)

    /// Current smoothed turn value (matches `QualityCharacterEngine.viewTurn`).
    var value: Float { spring.value }

    init(poseLimits: ValidatedPoseLimits = .legacyDefault) {
        self.poseLimits = poseLimits
    }

    /// Advances the model. `gazeX` is the horizontal gaze target (-1...1,
    /// positive = viewer's right) or nil when nothing is being watched.
    @discardableResult
    mutating func step(
        gazeX: Float?,
        sideDirection: QualitySideDirection,
        deltaTime: Float
    ) -> Float {
        let direction: Float = sideDirection == .right ? 1 : -1
        let target: Float
        if let gazeX, gazeX.isFinite {
            // Positive when looking toward the side we actually have art for.
            let towardSupportedSide = gazeX * direction
            if towardSupportedSide >= 0 {
                let magnitude = Interpolation.smoothstep(deadZone, fullTurnAt, towardSupportedSide)
                target = magnitude * direction
            } else {
                // No profile art exists here, but the frontal depth rig can
                // safely cover the opposite small-angle range.
                let magnitude = Interpolation.smoothstep(deadZone, fullTurnAt, -towardSupportedSide)
                let positiveYaw = direction < 0
                let validatedYaw = poseLimits.yawMagnitude(positive: positiveYaw)
                let normalizedDepthLimit = 0.35
                    * validatedYaw / max(0.0001, SupportedHeadPose.maximumYawDegrees)
                target = magnitude * -direction * normalizedDepthLimit
            }
        } else {
            target = 0
        }
        return spring.step(toward: target, deltaTime: deltaTime)
    }

    /// Advances vertical tracking. `gazeY` follows the public gaze convention
    /// (-1...1, positive = up); the result uses the same normalized range.
    @discardableResult
    mutating func stepPitch(gazeY: Float?, deltaTime: Float) -> Float {
        let target: Float
        if let gazeY, gazeY.isFinite {
            let sign: Float = gazeY < 0 ? -1 : 1
            let available = sign < 0
                ? abs(poseLimits.minimumPitchDegrees)
                : poseLimits.maximumPitchDegrees
            target = available > 0
                ? Interpolation.smoothstep(pitchDeadZone, fullPitchAt, abs(gazeY)) * sign
                : 0
        } else {
            target = 0
        }
        return pitchSpring.step(toward: target, deltaTime: deltaTime)
    }

    mutating func snap(turn: Float, pitch: Float) {
        spring.snap(to: turn.isFinite ? min(max(turn, -1), 1) : 0)
        pitchSpring.snap(to: pitch.isFinite ? min(max(pitch, -1), 1) : 0)
    }
}
