import Foundation
#if canImport(simd)
import simd
#endif

/// The projection and alpha-pass constants shared by the CPU integrity
/// evaluator and the Metal renderer.
///
/// Image-space vertices rotate around `center`, are perspective-projected in
/// image pixels, then aspect-fit into the drawable. Keeping this contract in
/// ArilsCore prevents validation from silently drifting away from rendering.
public struct RenderProjectionContract: Equatable, Sendable {
    public struct AspectFitTransform: Equatable, Sendable {
        public var scale: SIMD2<Float>
        public var offset: SIMD2<Float>

        public init(scale: SIMD2<Float>, offset: SIMD2<Float>) {
            self.scale = scale
            self.offset = offset
        }
    }

    public static let cameraDistanceHeightMultiplier: Float = 6.35
    public static let depthRangeMaxDimensionMultiplier: Float = 4
    public static let drawOrderBiasStep: Float = 0.008
    public static let minimumCameraDenominator: Float = 1
    public static let opaqueAlphaThreshold: Float = 0.5
    public static let minimumVisibleAlpha: Float = 0.001

    public var imageSize: SIMD2<Float>

    public init(imageWidth: Int, imageHeight: Int) {
        imageSize = SIMD2(Float(max(0, imageWidth)), Float(max(0, imageHeight)))
    }

    public init(imageSize: SIMD2<Float>) {
        self.imageSize = SIMD2(
            imageSize.x.isFinite ? max(0, imageSize.x) : 0,
            imageSize.y.isFinite ? max(0, imageSize.y) : 0
        )
    }

    public var center: SIMD2<Float> {
        imageSize * 0.5
    }

    public var cameraDistance: Float {
        imageSize.y * Self.cameraDistanceHeightMultiplier
    }

    public var depthRange: Float {
        max(imageSize.x, imageSize.y) * Self.depthRangeMaxDimensionMultiplier
    }

    public func zBias(forDrawOrderIndex index: Int) -> Float {
        Float(max(0, index)) * Self.drawOrderBiasStep
    }

    /// Projects one image-space vertex exactly as `arils_vertex` does before
    /// the final image-to-NDC transform. The returned z is Metal's normalized
    /// depth value after the layer-order bias.
    public func project(_ vertex: SIMD3<Float>, zBias: Float = 0) -> SIMD3<Float> {
        guard cameraDistance > 0, depthRange > 0 else {
            return SIMD3(vertex.x, vertex.y, 0.5)
        }
        let denominator = max(
            Self.minimumCameraDenominator,
            cameraDistance - vertex.z
        )
        let perspective = cameraDistance / denominator
        let projected = center + (SIMD2(vertex.x, vertex.y) - center) * perspective
        let depth = min(max(0.5 - vertex.z / depthRange - zBias, 0), 1)
        return SIMD3(projected.x, projected.y, depth)
    }

    /// Returns the same centered aspect-fit and y-flip used by Metal.
    public func aspectFit(drawableSize: SIMD2<Float>) -> AspectFitTransform {
        guard imageSize.x > 0, imageSize.y > 0,
              drawableSize.x > 0, drawableSize.y > 0 else {
            return AspectFitTransform(scale: .zero, offset: .zero)
        }
        let fit = min(drawableSize.x / imageSize.x, drawableSize.y / imageSize.y)
        let scale = SIMD2(2 * fit / drawableSize.x, -2 * fit / drawableSize.y)
        return AspectFitTransform(
            scale: scale,
            offset: SIMD2(
                -imageSize.x * 0.5 * scale.x,
                -imageSize.y * 0.5 * scale.y
            )
        )
    }
}
