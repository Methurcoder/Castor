import Foundation

/// The view angles owned by the frontal depth rig.
///
/// These values are shared by the runtime turn controller and archive-build
/// underpaint planning. Keeping them in one place prevents the repair mask from
/// covering less area than the renderer can reveal.
public enum SupportedHeadPose {
    public static let maximumYawDegrees = ValidatedPoseLimits.legacyDefault.maximumYawDegrees
    public static let maximumPitchDegrees = ValidatedPoseLimits.legacyDefault.maximumPitchDegrees
    public static let rotationParallaxStrength = HeadPoseRendering.rotationParallaxStrength
    public static let sweepPlan = PoseSweepPlan.supportedHead
}

/// Conservative rest-space coverage required behind the moving head.
///
/// The displacement combines the depth-driven translation and the planar
/// foreshortening at the supported extreme pose. `safetyPixels` keeps the hard
/// edge of an inpainting mask underneath the head even at that extreme;
/// `featherPixels` then returns the backing alpha smoothly to zero farther in.
struct HeadDisocclusionEnvelope: Equatable, Sendable {
    var maximumHorizontalDisplacement: Float
    var maximumVerticalDisplacement: Float
    var safetyPixels: Float
    var featherPixels: Float

    var horizontalOpaqueDepth: Float {
        maximumHorizontalDisplacement + safetyPixels
    }

    var verticalOpaqueDepth: Float {
        maximumVerticalDisplacement + safetyPixels
    }

    var horizontalExtent: Float {
        horizontalOpaqueDepth + featherPixels
    }

    var verticalExtent: Float {
        verticalOpaqueDepth + featherPixels
    }

    static func supported(plan: PartPlan) -> Self {
        let headWidth = Float(max(1, plan.headRect.width))
        let headHeight = Float(max(1, plan.headRect.height))
        let depth = BindingSynthesizer.recommendedHeadDepthCap(plan: plan)
        let yaw = SupportedHeadPose.maximumYawDegrees * .pi / 180
        let pitch = SupportedHeadPose.maximumPitchDegrees * .pi / 180
        let strength = SupportedHeadPose.rotationParallaxStrength

        // At yaw, depth produces the main lateral translation while the
        // (1-cos) term covers the outermost point's foreshortening.
        let horizontal = (
            abs(sin(yaw)) * depth
                + (1 - cos(yaw)) * headWidth * 0.5
        ) * strength

        // Pitch pivots close to the neck, so the crown-to-pivot distance is a
        // safer foreshortening bound than half the head height.
        let vertical = (
            abs(sin(pitch)) * depth
                + (1 - cos(pitch)) * headHeight
        ) * strength

        // Scale margins with the artwork but keep enough physical texels for
        // bilinear filtering and a binary LaMa mask at small resolutions.
        let rasterMargin = min(4, headWidth * 0.08)
        let safety = min(9, max(1, max(rasterMargin, headWidth * 0.015)))
        let feather = min(12, max(1, max(rasterMargin, headWidth * 0.02)))
        return Self(
            maximumHorizontalDisplacement: horizontal,
            maximumVerticalDisplacement: vertical,
            safetyPixels: safety,
            featherPixels: feather
        )
    }
}
