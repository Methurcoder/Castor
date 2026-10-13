import CoreGraphics

/// The smallest replaceable boundary for ML-assisted backing repair.
///
/// `maskImage` is an opaque black/white image at the same size as
/// `sourceImage`; white pixels are the only pixels the provider may replace.
/// Arils treats the result as color guidance and restores alpha from the
/// original subject mask, so an RGB-only inpainting backend is sufficient.
public struct OcclusionInpaintingRequest: @unchecked Sendable {
    public let sourceImage: CGImage
    public let maskImage: CGImage

    public init(sourceImage: CGImage, maskImage: CGImage) {
        self.sourceImage = sourceImage
        self.maskImage = maskImage
    }
}

/// Optional one-shot image inpainting used while an avatar archive is built.
/// Rendering never calls this protocol and therefore never depends on an ML
/// service being online.
public protocol OcclusionInpaintingProviding: Sendable {
    func inpaint(_ request: OcclusionInpaintingRequest) async throws -> CGImage
}
