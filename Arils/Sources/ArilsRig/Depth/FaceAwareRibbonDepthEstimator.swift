import CoreGraphics
import Foundation
import simd

import ArilsCore

/// Build-time choice used by the Quality pipeline and comparison tools. The
/// archive stores the resulting mesh depths, so changing this value never
/// mutates an already-rigged character at runtime.
public enum QualityDepthStrategy: String, Codable, Sendable, CaseIterable {
    /// Original Stage-A baseline: inflate each foreground run as an ellipse.
    case rowEllipse
    /// Keep the complete outline flat while landmarks define the facial plate
    /// and a conservative color cue lifts a narrow fringe ribbon.
    case faceAwareRibbon
}

public struct QualityDepthDiagnostics: Sendable, Equatable {
    /// Mean absolute Z on the rotating head's 2D subject boundary. Lower is safer because a
    /// non-zero crown/chin depth becomes a visible cardboard edge during yaw.
    public var boundaryDepth: Float
    /// Mean local Z relief explicitly added to inferred fringe pixels.
    public var fringeFaceSeparation: Float
    /// Fraction of head-mask pixels that contributed to the fringe cue.
    public var fringeCoverage: Float

    public init(
        boundaryDepth: Float,
        fringeFaceSeparation: Float,
        fringeCoverage: Float = 0
    ) {
        self.boundaryDepth = boundaryDepth
        self.fringeFaceSeparation = fringeFaceSeparation
        self.fringeCoverage = fringeCoverage
    }
}

/// Deterministic visible-surface compiler for illustrated faces.
///
/// This is intentionally not a head-volume reconstruction. It adds two
/// topology-oriented constraints to the original row ellipse:
///
/// - a zero-depth ribbon around the complete silhouette, including crown and
///   chin, so the renderer does not expose a thick paper edge; and
/// - a landmark-sized shallow face with a color-aware forward fringe ribbon,
///   which can create small hair/face parallax without cutting or inventing
///   texture when the color guess is wrong.
public struct FaceAwareRibbonDepthEstimator: Sendable {
    public var defaultThickness: Float
    public var boundaryRibbonPixels: Float

    public init(defaultThickness: Float = 0.28, boundaryRibbonPixels: Float = 3.5) {
        self.defaultThickness = max(0, defaultThickness)
        self.boundaryRibbonPixels = max(1, boundaryRibbonPixels)
    }

    public func estimate(
        frontMask: FloatPlane,
        sideThickness: ThicknessProfile?,
        plan: PartPlan,
        source: Bitmap
    ) -> DepthMap {
        let baseline = SilhouetteDepthEstimator(defaultThickness: defaultThickness)
            .estimate(frontMask: frontMask, sideThickness: sideThickness)
        guard frontMask.width > 0, frontMask.height > 0,
              source.width > 0, source.height > 0 else { return baseline }

        let boundaryDistance = Self.insideBoundaryDistance(mask: frontMask)
        var face = FaceGeometry(plan: plan)
        let nose = Self.inferredNoseAnchor(source: source, plan: plan)
        face.noseX = nose.x
        face.noseY = nose.y
        face.noseConfidence = nose.confidence
        let faceReference = Self.faceReferenceColor(source: source, geometry: face)
        let headProfile = Self.depthOwnershipProfile(
            plan: plan,
            sourceWidth: source.width,
            sourceHeight: source.height,
            depthWidth: frontMask.width,
            depthHeight: frontMask.height
        )
        var result = baseline

        for y in 0..<frontMask.height {
            let v = Float(y) / Float(max(1, frontMask.height - 1))
            let imageY = CGFloat(v) * CGFloat(source.height - 1)
            let rowThickness = max(sideThickness?.sample(v: v) ?? defaultThickness, 0)
            for x in 0..<frontMask.width where frontMask[x, y] >= 0.5 {
                let u = Float(x) / Float(max(1, frontMask.width - 1))
                let imageX = CGFloat(u) * CGFloat(source.width - 1)
                let ownership = headProfile.ownershipWeight(x: imageX, y: imageY)
                guard ownership > 0 else { continue }

                let edge = Self.smoothstep(
                    0,
                    boundaryRibbonPixels,
                    boundaryDistance[y * frontMask.width + x]
                )
                let nx = Float((imageX - face.centerX) / max(1, face.radiusX))
                let ny = Float((imageY - face.centerY) / max(1, face.radiusY))
                let radialSquared = nx * nx + ny * ny
                let facialEnvelope = radialSquared < 1 ? sqrt(max(0, 1 - radialSquared)) : 0
                let facePlate = 0.5 * rowThickness * (0.48 + 0.42 * facialEnvelope)

                // A compact local image cue refines the proportional fallback.
                // High confidence narrows the bump around the actual nose mark;
                // low confidence exactly retains a broad conservative prior.
                let noseRadiusX = face.eyeSpan * (0.23 - 0.07 * CGFloat(face.noseConfidence))
                let noseRadiusY = face.eyeToMouth * (0.32 - 0.10 * CGFloat(face.noseConfidence))
                let noseDX = Float((imageX - face.noseX) / max(1, noseRadiusX))
                let noseDY = Float((imageY - face.noseY) / max(1, noseRadiusY))
                let noseRelief = (0.055 + 0.015 * face.noseConfidence) * rowThickness
                    * exp(-(noseDX * noseDX + noseDY * noseDY) * 1.8)
                let fringe = Self.fringeLikelihood(
                    source: source,
                    x: imageX,
                    y: imageY,
                    geometry: face,
                    faceReference: faceReference,
                    plan: plan
                )
                let facialBase = max(baseline[x, y] * 0.72, facePlate + noseRelief)
                // The inferred fringe is an ordering constraint, not merely
                // another candidate for the same surface. Add its small
                // relief after resolving the facial base so it is guaranteed
                // to remain in front locally when the cue is present.
                let fringeRelief = 0.14 * rowThickness * fringe
                let semantic = facialBase + fringeRelief
                let semanticDepth = semantic * edge
                let rowEllipseDepth = baseline[x, y]
                // Match the same curved ownership used to cut the visible
                // head/body layers. A rectangular depth switch here would
                // otherwise leave a Z step underneath their soft alpha seam.
                result[x, y] = rowEllipseDepth
                    + (semanticDepth - rowEllipseDepth) * ownership
            }
        }
        return result
    }

    public func diagnostics(
        depth: DepthMap,
        frontMask: FloatPlane,
        plan: PartPlan,
        source: Bitmap,
        sideThickness: ThicknessProfile? = nil,
        includesFringeRelief: Bool = false
    ) -> QualityDepthDiagnostics {
        guard depth.width == frontMask.width, depth.height == frontMask.height,
              depth.width > 0, depth.height > 0 else {
            return QualityDepthDiagnostics(boundaryDepth: 0, fringeFaceSeparation: 0)
        }
        let face = FaceGeometry(plan: plan)
        let faceReference = Self.faceReferenceColor(source: source, geometry: face)
        let headProfile = Self.depthOwnershipProfile(
            plan: plan,
            sourceWidth: source.width,
            sourceHeight: source.height,
            depthWidth: frontMask.width,
            depthHeight: frontMask.height
        )
        var boundarySum: Float = 0
        var boundaryWeight: Float = 0
        var fringeReliefSum: Float = 0
        var fringeReliefWeight: Float = 0
        var fringeWeight: Float = 0
        var headWeight: Float = 0
        let boundaryDistance = includesFringeRelief
            ? Self.insideBoundaryDistance(mask: frontMask)
            : []

        for y in 0..<frontMask.height {
            let imageY = CGFloat(y) / CGFloat(max(1, frontMask.height - 1)) * CGFloat(source.height - 1)
            for x in 0..<frontMask.width where frontMask[x, y] >= 0.5 {
                let imageX = CGFloat(x) / CGFloat(max(1, frontMask.width - 1)) * CGFloat(source.width - 1)
                // Body/clothing still use the original row-ellipse depth. Use
                // the same curved ownership as compilation so this diagnostic
                // does not mistake the fixed body side of the blend for the
                // rotating head outline.
                let ownership = headProfile.ownershipWeight(x: imageX, y: imageY)
                guard ownership > 0 else { continue }
                headWeight += ownership
                if Self.isBoundary(x: x, y: y, mask: frontMask) {
                    boundarySum += abs(depth[x, y]) * ownership
                    boundaryWeight += ownership
                }
                let fringe = Self.fringeLikelihood(
                    source: source,
                    x: imageX,
                    y: imageY,
                    geometry: face,
                    faceReference: faceReference,
                    plan: plan
                )
                fringeWeight += fringe * ownership
                if includesFringeRelief, fringe > 0.05 {
                    let v = Float(y) / Float(max(1, frontMask.height - 1))
                    let rowThickness = max(sideThickness?.sample(v: v) ?? defaultThickness, 0)
                    let edge = Self.smoothstep(
                        0,
                        boundaryRibbonPixels,
                        boundaryDistance[y * frontMask.width + x]
                    )
                    fringeReliefSum += 0.14 * rowThickness * fringe * edge * ownership
                    fringeReliefWeight += ownership
                }
            }
        }
        let meanBoundary = boundaryWeight > 0 ? boundarySum / boundaryWeight : 0
        let meanRelief = fringeReliefWeight > 0
            ? fringeReliefSum / fringeReliefWeight
            : 0
        return QualityDepthDiagnostics(
            boundaryDepth: meanBoundary,
            fringeFaceSeparation: meanRelief,
            fringeCoverage: headWeight > 0 ? fringeWeight / headWeight : 0
        )
    }

    /// The visible layers evaluate `HeadRegionProfile` in source pixels, while
    /// Quality depth is normally compiled on the much smaller analysis grid.
    /// Keep the same curved boundary but guarantee that its transition spans
    /// at least two depth-grid intervals; otherwise an 8 px source-space
    /// feather can collapse back to a binary switch on a 2K/4K illustration.
    static func depthOwnershipProfile(
        plan: PartPlan,
        sourceWidth: Int,
        sourceHeight: Int,
        depthWidth: Int,
        depthHeight: Int
    ) -> HeadRegionProfile {
        var profile = HeadRegionProfile(plan: plan)
        let sourcePixelsPerDepthX = CGFloat(max(1, sourceWidth - 1))
            / CGFloat(max(1, depthWidth - 1))
        let sourcePixelsPerDepthY = CGFloat(max(1, sourceHeight - 1))
            / CGFloat(max(1, depthHeight - 1))
        profile.horizontalFeather = max(
            profile.horizontalFeather,
            sourcePixelsPerDepthX * 2
        )
        profile.lowerFeather = max(
            profile.lowerFeather,
            sourcePixelsPerDepthY * 2
        )
        return profile
    }

    private struct FaceGeometry {
        var centerX: CGFloat
        var centerY: CGFloat
        var radiusX: CGFloat
        var radiusY: CGFloat
        var eyeY: CGFloat
        var noseX: CGFloat
        var noseY: CGFloat
        var noseConfidence: Float
        var eyeSpan: CGFloat
        var eyeToMouth: CGFloat
        var fringeBottomY: CGFloat

        init(plan: PartPlan) {
            let left = CGPoint(x: plan.eyeLeftRect.midX, y: plan.eyeLeftRect.midY)
            let right = CGPoint(x: plan.eyeRightRect.midX, y: plan.eyeRightRect.midY)
            let mouth = CGPoint(x: plan.mouthRect.midX, y: plan.mouthRect.midY)
            eyeY = (left.y + right.y) * 0.5
            eyeSpan = max(2, abs(right.x - left.x))
            eyeToMouth = max(2, mouth.y - eyeY)
            centerX = ((left.x + right.x) * 0.5) * 0.84 + mouth.x * 0.16
            centerY = eyeY + eyeToMouth * 0.12
            radiusX = min(plan.headRect.width * 0.39, max(eyeSpan * 1.12, plan.mouthRect.width * 2.1))
            radiusY = min(plan.headRect.height * 0.48, max(eyeToMouth * 1.72, plan.headRect.height * 0.30))
            noseX = centerX
            noseY = eyeY + eyeToMouth * 0.52
            noseConfidence = 0
            fringeBottomY = eyeY + eyeToMouth * 0.42
        }
    }

    struct NoseAnchor: Sendable, Equatable {
        var x: CGFloat
        var y: CGFloat
        var confidence: Float
    }

    /// Refines the proportional nose prior from one compact, confidence-gated
    /// image cue. Anime noses are often only a short line or a few shaded
    /// pixels, so this deliberately looks for a *local* color discontinuity
    /// inside a landmark-bounded ROI rather than attempting another face model.
    ///
    /// Broad shadows, hair, and skin gradients score poorly because the center
    /// patch is compared with eight nearby samples. If the best response is not
    /// both strong and locally prominent, the exact proportional fallback is
    /// returned. This prevents a weak cue from moving the nose toward clothing
    /// or a bang.
    static func inferredNoseAnchor(source: Bitmap, plan: PartPlan) -> NoseAnchor {
        let geometry = FaceGeometry(plan: plan)
        let fallback = NoseAnchor(x: geometry.centerX, y: geometry.noseY, confidence: 0)
        guard source.width > 2, source.height > 2,
              geometry.eyeSpan > 2, geometry.eyeToMouth > 2 else { return fallback }

        let halfWidth = max(CGFloat(2), min(geometry.eyeSpan * 0.24, plan.headRect.width * 0.13))
        let minY = geometry.eyeY + geometry.eyeToMouth * 0.36
        let maxY = geometry.eyeY + geometry.eyeToMouth * 0.72
        let minX = max(CGFloat(1), geometry.centerX - halfWidth)
        let maxX = min(CGFloat(source.width - 2), geometry.centerX + halfWidth)
        let clampedMinY = max(CGFloat(1), minY)
        let clampedMaxY = min(CGFloat(source.height - 2), maxY)
        guard minX < maxX, clampedMinY < clampedMaxY else { return fallback }

        let innerRadius = max(1, Int((geometry.eyeSpan * 0.012).rounded()))
        let outerRadius = max(innerRadius + 2, Int((geometry.eyeSpan * 0.055).rounded()))
        let step = max(1, Int((geometry.eyeSpan / 96).rounded(.down)))

        func color(x: Int, y: Int) -> SIMD3<Float>? {
            let rgba = source.rgba(x: x, y: y)
            guard rgba.w > 0.5 else { return nil }
            return SIMD3(rgba.x, rgba.y, rgba.z) / rgba.w
        }

        func patchMean(x: Int, y: Int, radius: Int) -> SIMD3<Float>? {
            var sum = SIMD3<Float>.zero
            var count: Float = 0
            for yy in (y - radius)...(y + radius) {
                for xx in (x - radius)...(x + radius) {
                    if let sample = color(x: xx, y: yy) {
                        sum += sample
                        count += 1
                    }
                }
            }
            return count > 0 ? sum / count : nil
        }

        let directions = [
            SIMD2<Int>(-1, 0), SIMD2<Int>(1, 0),
            SIMD2<Int>(0, -1), SIMD2<Int>(0, 1),
            SIMD2<Int>(-1, -1), SIMD2<Int>(1, -1),
            SIMD2<Int>(-1, 1), SIMD2<Int>(1, 1),
        ]
        var bestPoint = SIMD2<Float>(Float(fallback.x), Float(fallback.y))
        var bestScore: Float = 0
        var bestSalience: Float = 0
        var salienceSum: Float = 0
        var sampleCount: Float = 0
        let scale = sqrt(Float(3))

        for y in stride(
            from: Int(clampedMinY.rounded(.up)),
            through: Int(clampedMaxY.rounded(.down)),
            by: step
        ) {
            for x in stride(
                from: Int(minX.rounded(.up)),
                through: Int(maxX.rounded(.down)),
                by: step
            ) {
                let point = CGPoint(x: x, y: y)
                guard plan.headRect.contains(point),
                      !plan.eyeLeftRect.contains(point),
                      !plan.eyeRightRect.contains(point),
                      !plan.mouthRect.contains(point),
                      let center = patchMean(x: x, y: y, radius: innerRadius) else { continue }

                var surround = SIMD3<Float>.zero
                var surroundCount: Float = 0
                for direction in directions {
                    let sampleX = x + direction.x * outerRadius
                    let sampleY = y + direction.y * outerRadius
                    if let sample = patchMean(x: sampleX, y: sampleY, radius: innerRadius) {
                        surround += sample
                        surroundCount += 1
                    }
                }
                guard surroundCount >= 4 else { continue }
                let salience = simd_length(center - surround / surroundCount) / scale
                let dx = Float((CGFloat(x) - geometry.centerX) / halfWidth)
                let dy = Float(
                    (CGFloat(y) - geometry.noseY)
                        / max(CGFloat(1), geometry.eyeToMouth * 0.20)
                )
                let spatialPrior = exp(-(dx * dx + dy * dy) * 1.35)
                let score = salience * (0.30 + 0.70 * spatialPrior)
                salienceSum += salience
                sampleCount += 1
                if score > bestScore {
                    bestScore = score
                    bestSalience = salience
                    bestPoint = SIMD2(Float(x), Float(y))
                }
            }
        }

        guard sampleCount > 0 else { return fallback }
        let meanSalience = salienceSum / sampleCount
        let contrastConfidence = smoothstep(0.025, 0.12, bestSalience)
        let prominence = bestSalience / max(0.015, meanSalience)
        let prominenceConfidence = smoothstep(1.15, 2.4, prominence)
        let confidence = contrastConfidence * prominenceConfidence
        guard confidence >= 0.12 else { return fallback }

        // Confidence controls displacement as well as relief sharpness. Even a
        // strong mark cannot drag the semantic nose all the way to an ROI edge.
        let blend = CGFloat(min(0.85, confidence * 0.85))
        return NoseAnchor(
            x: fallback.x + (CGFloat(bestPoint.x) - fallback.x) * blend,
            y: fallback.y + (CGFloat(bestPoint.y) - fallback.y) * blend,
            confidence: confidence
        )
    }

    private static func faceReferenceColor(source: Bitmap, geometry: FaceGeometry) -> SIMD3<Float>? {
        let sampleCenters = [
            CGPoint(x: geometry.centerX - geometry.eyeSpan * 0.28, y: geometry.eyeY + geometry.eyeToMouth * 0.48),
            CGPoint(x: geometry.centerX + geometry.eyeSpan * 0.28, y: geometry.eyeY + geometry.eyeToMouth * 0.48),
            CGPoint(x: geometry.centerX, y: geometry.eyeY + geometry.eyeToMouth * 0.30),
        ]
        let radius = max(1, Int((geometry.eyeSpan * 0.055).rounded()))
        var sum = SIMD3<Float>.zero
        var count: Float = 0
        for center in sampleCenters {
            for y in (Int(center.y) - radius)...(Int(center.y) + radius) {
                for x in (Int(center.x) - radius)...(Int(center.x) + radius) {
                    let rgba = source.rgba(x: x, y: y)
                    guard rgba.w > 0.5 else { continue }
                    sum += SIMD3(rgba.x, rgba.y, rgba.z) / rgba.w
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : nil
    }

    private static func fringeLikelihood(
        source: Bitmap,
        x: CGFloat,
        y: CGFloat,
        geometry: FaceGeometry,
        faceReference: SIMD3<Float>?,
        plan: PartPlan
    ) -> Float {
        guard y <= geometry.fringeBottomY,
              abs(x - geometry.centerX) <= geometry.radiusX * 1.08 else { return 0 }
        let point = CGPoint(x: x, y: y)
        let eyeExclusion = plan.eyeLeftRect.union(plan.eyeRightRect).insetBy(
            dx: -geometry.eyeSpan * 0.09,
            dy: -geometry.eyeToMouth * 0.10
        )
        guard !eyeExclusion.contains(point), !plan.mouthRect.contains(point) else { return 0 }
        guard let faceReference else {
            return y < geometry.eyeY - geometry.eyeToMouth * 0.2 ? 0.35 : 0
        }
        let rgba = source.rgba(x: Int(x.rounded()), y: Int(y.rounded()))
        guard rgba.w > 0.5 else { return 0 }
        let color = SIMD3(rgba.x, rgba.y, rgba.z) / rgba.w
        let distance = simd_length(color - faceReference) / sqrt(3)
        let colorCue = smoothstep(0.10, 0.30, distance)
        let topConnection = 1 - smoothstep(
            Float(geometry.eyeY - geometry.eyeToMouth * 0.28),
            Float(geometry.fringeBottomY),
            Float(y)
        )
        return min(max(colorCue * (0.42 + 0.58 * topConnection), 0), 1)
    }

    private static func insideBoundaryDistance(mask: FloatPlane) -> [Float] {
        let width = mask.width, height = mask.height
        guard width > 0, height > 0 else { return [] }
        let far = Float(width + height)
        var distance = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where mask[x, y] >= 0.5 {
                distance[y * width + x] = isBoundary(x: x, y: y, mask: mask) ? 0 : far
            }
        }
        let diagonal = sqrt(Float(2))
        for y in 0..<height {
            for x in 0..<width where mask[x, y] >= 0.5 {
                let index = y * width + x
                if x > 0 { distance[index] = min(distance[index], distance[index - 1] + 1) }
                if y > 0 { distance[index] = min(distance[index], distance[index - width] + 1) }
                if x > 0, y > 0 { distance[index] = min(distance[index], distance[index - width - 1] + diagonal) }
                if x + 1 < width, y > 0 { distance[index] = min(distance[index], distance[index - width + 1] + diagonal) }
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where mask[x, y] >= 0.5 {
                let index = y * width + x
                if x + 1 < width { distance[index] = min(distance[index], distance[index + 1] + 1) }
                if y + 1 < height { distance[index] = min(distance[index], distance[index + width] + 1) }
                if x + 1 < width, y + 1 < height { distance[index] = min(distance[index], distance[index + width + 1] + diagonal) }
                if x > 0, y + 1 < height { distance[index] = min(distance[index], distance[index + width - 1] + diagonal) }
            }
        }
        return distance
    }

    private static func isBoundary(x: Int, y: Int, mask: FloatPlane) -> Bool {
        guard mask[x, y] >= 0.5 else { return false }
        return x == 0 || y == 0 || x + 1 == mask.width || y + 1 == mask.height
            || mask[x - 1, y] < 0.5 || mask[x + 1, y] < 0.5
            || mask[x, y - 1] < 0.5 || mask[x, y + 1] < 0.5
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
