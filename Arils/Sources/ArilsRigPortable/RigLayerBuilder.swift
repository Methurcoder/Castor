import Foundation

/// Decoded layers before the platform's PNG/CGImage conversion. Both hosts use
/// this exact construction path; no rendering, network or model dependency.
public struct RigLayerBuild: Sendable {
    public var rig: AvatarRig
    public let plan: PartPlan
    public let layers: [String: Bitmap]
    public let alphaCoverage: [String: FloatPlane]

    public func archive(encoding: (Bitmap) throws -> Data) throws -> AvatarArchive {
        let textures = try layers.mapValues(encoding)
        return AvatarArchive(rig: rig, texturePNGs: textures)
    }
}

public enum RigLayerBuilder {
    public static func build(source: Bitmap, analysisMask: FloatPlane, extractionMask: FloatPlane,
                             layout: FaceLayout, maskIsAuthoritative: Bool,
                             inpaintedSource: Bitmap? = nil, poseSweep: PoseSweepPlan = .supportedHead) -> RigLayerBuild {
        let plan = PartPlanner.plan(layout: layout, subjectMask: analysisMask,
                                    imageWidth: source.width, imageHeight: source.height)
        return build(source: source, extractionMask: extractionMask, plan: plan,
                     maskIsAuthoritative: maskIsAuthoritative, inpaintedSource: inpaintedSource, poseSweep: poseSweep)
    }

    /// A host can prepare its optional inpainting request from this same plan.
    public static func build(source: Bitmap, extractionMask: FloatPlane, plan: PartPlan,
                             maskIsAuthoritative: Bool, inpaintedSource: Bitmap? = nil,
                             poseSweep: PoseSweepPlan = .supportedHead) -> RigLayerBuild {
        // An estimated cut-out of a picture on a background loses the gaps
        // and the colour fringe the background leaves behind.
        let (source, extractionMask) = maskIsAuthoritative
            ? (source, extractionMask)
            : MatteCleanup.apply(source: source, mask: extractionMask, plan: plan)
        let cut = LayerFactory.extract(source: source, subjectMask: extractionMask, plan: plan,
                                       sharpenMaskEdges: !maskIsAuthoritative, inpaintedSource: inpaintedSource)
        let layers = ["body": cut.body, "neckSeam": cut.neckSeam, "head": cut.head,
                      "eyeLeft": cut.eyeLeft, "eyeRight": cut.eyeRight, "mouth": cut.mouth,
                      "mouthCavity": cut.mouthCavity]
        let alpha = layers.mapValues { $0.alphaPlane() }
        var rig = BindingSynthesizer.makeRig(plan: plan)
        rig.validatedPoseLimits = PoseSweepValidator.validate(rig: rig, plan: poseSweep,
                                                             alphaCoverageByPartID: alpha).validatedPoseLimits
        return RigLayerBuild(rig: rig, plan: plan, layers: layers, alphaCoverage: alpha)
    }

    /// Adds the same front depth rig used by the Mac Quality pipeline. The
    /// profile image constrains thickness, never invents an opposite view.
    public static func addQualityDepth(front: RigLayerBuild, side: RigLayerBuild,
                                       frontSource: Bitmap, sideSource: Bitmap,
                                       frontMask: FloatPlane, sideMask: FloatPlane,
                                       strategy: QualityDepthStrategy = .faceAwareRibbon,
                                       headMeshResolution: Int = 24,
                                       poseSweep: PoseSweepPlan = .supportedHead) -> (front: RigLayerBuild, registration: QualityViewRegistration) {
        let registration = QualityViewRegistration.automatic(front: front.rig, side: side.rig)
        let thickness = ThicknessProfile.fromSideMask(sideMask).alignedToFront(rowCount: frontMask.height,
            frontImageHeight: frontSource.height, sideImageHeight: sideSource.height, registration: registration)
        let depth: DepthMap
        switch strategy {
        case .rowEllipse:
            depth = SilhouetteDepthEstimator().estimate(frontMask: frontMask, sideThickness: thickness)
        case .faceAwareRibbon:
            depth = FaceAwareRibbonDepthEstimator().estimate(frontMask: frontMask, sideThickness: thickness,
                                                            plan: front.plan, source: frontSource)
        }
        var result = front
        result.rig = BindingSynthesizer.makeDepthRig(plan: front.plan, depthMap: depth,
            depthScalePixels: Float(sideSource.width) * registration.sideScale,
            maximumHeadDepthPixels: BindingSynthesizer.recommendedHeadDepthCap(plan: front.plan),
            headMeshResolution: strategy == .faceAwareRibbon ? min(max(headMeshResolution, 12), 48) : 12)
        result.rig.validatedPoseLimits = PoseSweepValidator.validate(rig: result.rig, plan: poseSweep,
            alphaCoverageByPartID: result.alphaCoverage).validatedPoseLimits
        return (result, registration)
    }
}
