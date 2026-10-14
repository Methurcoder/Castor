import CoreGraphics

public extension LayerFactory {
    static func occlusionInpaintingRequest(source: Bitmap, subjectMask: FloatPlane,
        plan: PartPlan, sharpenMaskEdges: Bool = false) -> OcclusionInpaintingRequest? {
        guard let sourceImage = source.cgImage(),
              let mask = occlusionRepairMask(source: source, subjectMask: subjectMask,
                  plan: plan, sharpenMaskEdges: sharpenMaskEdges)?.cgImage() else { return nil }
        return OcclusionInpaintingRequest(sourceImage: sourceImage, maskImage: mask)
    }
}
