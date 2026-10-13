/// Rendering constants for the frontal depth rig, shared with the rigging
/// side through `SupportedHeadPose`.
public enum HeadPoseRendering {
    /// Fraction of the depth-driven parallax applied while the head rotates.
    public static let rotationParallaxStrength: Float = 0.5
}
