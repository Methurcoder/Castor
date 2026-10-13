import Foundation

/// Maps automatic-turn progress to the profile-image blend. The frontal v2
/// rig owns the small-angle range; the side reference fades in only after the
/// real 3D yaw is already readable.
public enum QualityHybridTurnModel {
    public static func profileBlend(
        viewTurn: Float,
        sideDirection: QualitySideDirection,
        threeDLimit: Float = 0.35,
        fullProfileAt: Float = 0.85,
        validatedPoseLimits: ValidatedPoseLimits = .legacyDefault
    ) -> Float {
        let direction: Float = sideDirection == .right ? 1 : -1
        let supported = max(0, viewTurn * direction)
        let supportedYaw = validatedPoseLimits.yawMagnitude(positive: direction > 0)
        let validatedThreeDLimit = threeDLimit
            * supportedYaw / max(0.0001, SupportedHeadPose.maximumYawDegrees)
        guard fullProfileAt > validatedThreeDLimit else {
            return supported >= fullProfileAt ? 1 : 0
        }
        let t = min(
            max(
                (supported - validatedThreeDLimit)
                    / (fullProfileAt - validatedThreeDLimit),
                0
            ),
            1
        )
        return t * t * (3 - 2 * t)
    }
}
