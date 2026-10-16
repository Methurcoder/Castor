#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Per-part textures cut from the source image (each cropped to its part rect).
public struct ExtractedLayers: Sendable {
    public var body: Bitmap
    public var neckSeam: Bitmap
    public var head: Bitmap
    public var eyeLeft: Bitmap
    public var eyeRight: Bitmap
    public var mouth: Bitmap
    /// Hair beside the head that follows it (see `SideHairRegion`), if any.
    public var sideHair: Bitmap? = nil
    public var sideHairRect: CGRect? = nil
}

/// Cuts the source image into part layers and repairs everything a moving part
/// would reveal:
/// - the body keeps a low-frequency collar and slim side underpaint where the
///   head was, while an original-image seam patch bridges that fallback and the
///   moving head without ML-generated pixels;
/// - the head gets diffusion-inpainted skin behind the eyes and mouth, so
///   blinking and speech reveal skin instead of transparency;
/// - eye/mouth cutouts get feathered edges so they blend while moving.
public enum LayerFactory {
    /// Five procedural mouth poses on the existing 4x4 mouth mesh: four
    /// corners of (open, form) plus a neutral center corrective.
    public static func mouthWarpKeyforms(mesh: DeformableMesh) -> [WarpKeyformKey] {
        func offsets(open: Float, form: Float) -> [SIMD2<Float>] {
            let minX = mesh.vertices.map(\.x).min() ?? 0
            let maxX = mesh.vertices.map(\.x).max() ?? minX
            let minY = mesh.vertices.map(\.y).min() ?? 0
            let maxY = mesh.vertices.map(\.y).max() ?? minY
            let height = max(1, maxY - minY)
            let centerX = (minX + maxX) * 0.5
            let pivotY = minY + height * 0.32
            let normalizedForm = min(max(form, -1), 1)
            let normalizedOpen = min(max(open, 0), 1)
            let closedScaleX = 0.94 + normalizedForm * 0.20
            let openScaleX = 0.92 + normalizedForm * 0.22
            let scaleX = closedScaleX
                + (openScaleX - closedScaleX) * normalizedOpen
            let openScaleY = 1.15 - normalizedForm * 0.12
            let scaleY = 0.16 + (openScaleY - 0.16) * normalizedOpen
            let downward = normalizedOpen * height * 0.06
            return mesh.vertices.map { vertex in
                let target = SIMD2(
                    centerX + (vertex.x - centerX) * scaleX,
                    pivotY + (vertex.y - pivotY) * scaleY + downward
                )
                return target - vertex
            }
        }

        return [
            WarpKeyformKey(
                parameterXValue: 0,
                parameterYValue: -1,
                vertexOffsets: offsets(open: 0, form: -1)
            ),
            WarpKeyformKey(
                parameterXValue: 0,
                parameterYValue: 1,
                vertexOffsets: offsets(open: 0, form: 1)
            ),
            WarpKeyformKey(
                parameterXValue: 1,
                parameterYValue: -1,
                vertexOffsets: offsets(open: 1, form: -1)
            ),
            WarpKeyformKey(
                parameterXValue: 1,
                parameterYValue: 1,
                vertexOffsets: offsets(open: 1, form: 1)
            ),
            WarpKeyformKey(
                parameterXValue: 0.5,
                parameterYValue: 0,
                vertexOffsets: offsets(open: 0.5, form: 0)
            ),
        ]
    }

    /// Builds the bounded mask an optional ML backend may repair. Coverage is
    /// derived from the maximum supported yaw/pitch displacement rather than a
    /// fixed-width rectangle. A safety overlap keeps the mask's straight edge
    /// hidden underneath the head at every intermediate pose; the face itself
    /// is never handed to the model for wholesale regeneration.
    public static func occlusionRepairMask(
        source: Bitmap,
        subjectMask: FloatPlane,
        plan: PartPlan,
        sharpenMaskEdges: Bool = false
    ) -> Bitmap? {
        guard source.width > 1, source.height > 1 else {
            return nil
        }

        let headProfile = HeadRegionProfile(plan: plan)
        let envelope = underpaintEnvelope(for: plan)
        var maskImage = Bitmap(width: source.width, height: source.height)
        var containsRepairPixels = false
        for y in 0..<source.height {
            for x in 0..<source.width {
                let rawMask: Float
                if subjectMask.width == source.width,
                   subjectMask.height == source.height {
                    rawMask = subjectMask[x, y]
                } else {
                    rawMask = subjectMask.sample(
                        u: Float(x) / Float(source.width - 1),
                        v: Float(y) / Float(source.height - 1)
                    )
                }
                let subject = sharpenMaskEdges
                    ? Interpolation.smoothstep(0.55, 0.9, rawMask)
                    : rawMask
                let weights = underpaintWeights(
                    x: x,
                    y: y,
                    plan: plan,
                    envelope: envelope
                )
                let ownership = headProfile.ownershipWeight(x: CGFloat(x), y: CGFloat(y))
                let shouldRepair = subject > 0.08
                    && ownership > 0.02
                    && max(weights.collar, weights.side) > 0.02
                maskImage.setRGBA(
                    x: x,
                    y: y,
                    shouldRepair ? SIMD4(repeating: 1) : SIMD4(0, 0, 0, 1)
                )
                containsRepairPixels = containsRepairPixels || shouldRepair
            }
        }
        guard containsRepairPixels else { return nil }
        return maskImage
    }

    /// - Parameter sharpenMaskEdges: pass true for *estimated* masks (Vision
    ///   segmentation of an opaque image). Their soft edges include background
    ///   pixels, so a gentle cut would leave a bright fringe around the
    ///   character; a steep remap makes edge pixels commit to in or out.
    ///   Keep false for real alpha channels, whose anti-aliasing is correct.
    public static func extract(
        source: Bitmap,
        subjectMask: FloatPlane,
        plan: PartPlan,
        sharpenMaskEdges: Bool = false,
        inpaintedSource: Bitmap? = nil
    ) -> ExtractedLayers {
        let width = source.width
        let height = source.height

        func maskValue(x: Int, y: Int) -> Float {
            guard width > 1, height > 1 else { return 0 }
            let raw: Float
            if subjectMask.width == width, subjectMask.height == height {
                raw = subjectMask[x, y]
            } else {
                raw = subjectMask.sample(
                    u: Float(x) / Float(width - 1),
                    v: Float(y) / Float(height - 1)
                )
            }
            return sharpenMaskEdges ? Interpolation.smoothstep(0.55, 0.9, raw) : raw
        }

        /// Subject masks cap source coverage rather than multiplying it. This
        /// matters for authoritative PNG alpha: applying the same 0.5 coverage
        /// twice would turn a correct antialiased edge into 0.25.
        func capAlpha(
            _ bitmap: inout Bitmap,
            x: Int,
            y: Int,
            to mask: Float
        ) {
            let current = bitmap.alpha(x: x, y: y)
            let target = min(current, min(max(mask, 0), 1))
            if target <= 0 {
                bitmap.setRGBA(x: x, y: y, .zero)
            } else if target < current, current > 0 {
                bitmap.scaleAlpha(x: x, y: y, by: target / current)
            }
        }

        let neckY = Int(plan.neckY)
        let headProfile = HeadRegionProfile(plan: plan)
        let envelope = underpaintEnvelope(for: plan)

        // --- Body layer -----------------------------------------------------
        var body = source.cropped(to: plan.subjectRect)
        let bodyOriginX = max(0, Int(plan.subjectRect.minX))
        let bodyOriginY = max(0, Int(plan.subjectRect.minY))

        // A single broad palette per repair region avoids the old per-column
        // mirrored sampling. That old path preserved vertical hair/collar
        // stripes and turned them into visible blocky "mosaic" columns when
        // the head moved.
        func averagedSubjectColor(in rect: CGRect, fallback: SIMD4<Float>) -> SIMD4<Float> {
            let minX = max(0, Int(rect.minX))
            let minY = max(0, Int(rect.minY))
            let maxX = min(width, Int(rect.maxX.rounded(.up)))
            let maxY = min(height, Int(rect.maxY.rounded(.up)))
            guard minX < maxX, minY < maxY else { return fallback }
            var sum = SIMD4<Float>.zero
            var count: Float = 0
            for yy in minY..<maxY {
                for xx in minX..<maxX {
                    guard maskValue(x: xx, y: yy) > 0.3 else { continue }
                    let pixel = source.rgba(x: xx, y: yy)
                    guard pixel.w > 0.02 else { continue }
                    sum += SIMD4(pixel.x / pixel.w, pixel.y / pixel.w, pixel.z / pixel.w, 1)
                    count += 1
                }
            }
            return count > 0 ? sum / count : fallback
        }

        let broadFallback = averagedSubjectColor(
            in: CGRect(
                x: plan.headRect.midX - plan.headRect.width * 0.28,
                y: plan.neckY - plan.collarHeight,
                width: plan.headRect.width * 0.56,
                height: plan.collarHeight * 2.5
            ),
            fallback: SIMD4(0.5, 0.5, 0.5, 1)
        )
        let centerPalette = averagedSubjectColor(
            in: CGRect(
                x: plan.headRect.midX - max(plan.mouthRect.width, plan.headRect.width * 0.18),
                y: plan.neckY,
                width: max(plan.mouthRect.width * 2, plan.headRect.width * 0.36),
                height: plan.collarHeight * 1.5
            ),
            fallback: broadFallback
        )
        let sidePaletteWidth = max(CGFloat(4), plan.headRect.width * 0.16)
        let leftPalette = averagedSubjectColor(
            in: CGRect(
                x: plan.headRect.minX,
                y: plan.headRect.minY,
                width: sidePaletteWidth,
                height: plan.headRect.height
            ),
            fallback: broadFallback
        )
        let rightPalette = averagedSubjectColor(
            in: CGRect(
                x: plan.headRect.maxX - sidePaletteWidth,
                y: plan.headRect.minY,
                width: sidePaletteWidth,
                height: plan.headRect.height
            ),
            fallback: broadFallback
        )

        func premultiplied(_ color: SIMD4<Float>, alpha: Float) -> SIMD4<Float> {
            let sourceAlpha = max(0.001, color.w)
            let safeAlpha = min(max(alpha, 0), 1)
            return SIMD4(
                color.x / sourceAlpha * safeAlpha,
                color.y / sourceAlpha * safeAlpha,
                color.z / sourceAlpha * safeAlpha,
                safeAlpha
            )
        }

        // Without an ML inpainter the backing used one averaged palette colour
        // per side: a flat grey slab with crisp subject-mask edges that read
        // as a rectangle whenever the head turned. Diffuse the source around
        // the head inward instead, so the backing continues the neighbouring
        // hair and collar colours.
        // The ML repair stays within the supported yaw/pitch envelope, away
        // from the face; the diffused backing covers the rest of the head, so
        // tilt or a larger turn shows blurred hair instead of a hole.
        var diffusedBacking: Bitmap?
        do {
            let reach = plan.headRect.insetBy(dx: -plan.headRect.width * 0.2, dy: -plan.collarHeight)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !reach.isNull, !reach.isEmpty {
                var canvas = source
                let reachMinX = max(0, Int(reach.minX))
                let reachMinY = max(0, Int(reach.minY))
                HoleFiller.fillHole(in: &canvas, region: reach) { x, y in
                    headProfile.ownershipWeight(x: CGFloat(reachMinX + x), y: CGFloat(reachMinY + y)) > 0.01
                }
                diffusedBacking = canvas
            }
        }

        for y in 0..<body.height {
            let sourceY = bodyOriginY + y
            for x in 0..<body.width {
                let sourceX = bodyOriginX + x
                let mask = maskValue(x: sourceX, y: sourceY)
                capAlpha(&body, x: x, y: y, to: mask)
                guard body.alpha(x: x, y: y) > 0 else { continue }
                let ownership = headProfile.ownershipWeight(
                    x: CGFloat(sourceX),
                    y: CGFloat(sourceY)
                )
                guard ownership > 0.001 else { continue }
                let originalBodyPixel = body.rgba(x: x, y: y)
                // Head alpha feathers gradually, but its backing must commit
                // to low-frequency repair much earlier. Blending the original
                // hair/collar texture in proportion to head alpha preserves
                // vertical stripes, which reappear as a moving dark seam.
                let backingCoverage = Interpolation.smoothstep(0.01, 0.10, ownership)

                let weights = Self.underpaintWeights(
                    x: sourceX,
                    y: sourceY,
                    plan: plan,
                    envelope: envelope
                )
                func interiorBacking() -> SIMD4<Float> {
                    let t = Float((CGFloat(sourceX) - plan.headRect.minX) / max(1, plan.headRect.width))
                    let palette = leftPalette + (rightPalette - leftPalette) * min(max(t, 0), 1)
                    let diffused = diffusedBacking?.rgba(x: sourceX, y: sourceY)
                    let color = diffused.flatMap { $0.w > 0.05 ? $0 : nil } ?? palette
                    return premultiplied(color, alpha: originalBodyPixel.w)
                }
                guard weights.collar > 0.001 || weights.side > 0.001 else {
                    body.setRGBA(x: x, y: y, originalBodyPixel + (interiorBacking() - originalBodyPixel) * backingCoverage)
                    continue
                }

                let belowY = min(height - 1, neckY + 1)
                let belowMask = maskValue(x: sourceX, y: belowY)
                // Preserve meaningful soft alpha below the neck, but do not
                // let a gap in that row punch a new hole into the repair.
                let collarSupport = belowMask > 0.3 ? belowMask : mask
                let repairAlpha = max(
                    weights.collar * collarSupport,
                    weights.side * mask
                )
                guard repairAlpha > 0.01 else {
                    body.setRGBA(x: x, y: y, originalBodyPixel + (interiorBacking() - originalBodyPixel) * backingCoverage)
                    continue
                }

                let sidePalette = sourceX < Int(plan.headRect.midX) ? leftPalette : rightPalette
                let fallbackMix = weights.collar / max(0.001, weights.collar + weights.side)
                let fallbackColor = sidePalette + (centerPalette - sidePalette) * fallbackMix
                let generatedColor: SIMD4<Float>?
                if let inpaintedSource,
                   inpaintedSource.width == width,
                   inpaintedSource.height == height {
                    generatedColor = inpaintedSource.rgba(x: sourceX, y: sourceY)
                } else if let diffusedBacking {
                    let diffused = diffusedBacking.rgba(x: sourceX, y: sourceY)
                    generatedColor = diffused.w > 0.05 ? diffused : nil
                } else {
                    generatedColor = nil
                }
                let repaired = premultiplied(generatedColor ?? fallbackColor, alpha: repairAlpha)
                // Over the interior backing, so the side band's feathered edge
                // fades into it rather than into a transparent seam. The collar
                // keeps its own alpha, which follows the soft edge below the neck.
                let interiorShare = (1 - repaired.w) * (1 - min(1, weights.collar))
                let backed = repaired + interiorBacking() * interiorShare
                body.setRGBA(
                    x: x,
                    y: y,
                    originalBodyPixel + (backed - originalBodyPixel) * backingCoverage
                )
            }
        }

        // --- Side hair ------------------------------------------------------
        // Hair beside the head moves with it; the body keeps a blurred copy so
        // the moving strands reveal hair colour, not a sharp duplicate.
        var sideHair: Bitmap?
        var sideHairRect: CGRect?
        let sideRegion = SideHairRegion.detect(source: source, plan: plan, mask: maskValue)
        if let region = sideRegion {
            var layer = source.cropped(to: region.rect)
            let originX = Int(region.rect.minX)
            let originY = Int(region.rect.minY)
            for y in 0..<layer.height {
                for x in 0..<layer.width {
                    capAlpha(&layer, x: x, y: y, to: maskValue(x: originX + x, y: originY + y))
                    let ownership = region.ownership[x, y]
                    if ownership <= 0.001 {
                        layer.setRGBA(x: x, y: y, .zero)
                    } else if ownership < 1 {
                        layer.scaleAlpha(x: x, y: y, by: ownership)
                    }
                }
            }
            let localRect = region.rect.offsetBy(dx: -CGFloat(bodyOriginX), dy: -CGFloat(bodyOriginY))
            let blurred = SideHairRegion.blurredBacking(
                body,
                region: localRect,
                radius: max(3, Int(plan.headRect.width * 0.03))
            )
            for y in 0..<layer.height {
                for x in 0..<layer.width {
                    let ownership = region.ownership[x, y]
                    let bodyX = originX + x - bodyOriginX
                    let bodyY = originY + y - bodyOriginY
                    guard ownership > 0.001, bodyX >= 0, bodyX < body.width, bodyY >= 0, bodyY < body.height else { continue }
                    // The body keeps exactly what the side hair layer does not
                    // cover at rest, so semi-transparent hair or a veil does not
                    // double up. Under opaque hair that remainder is empty and
                    // the blurred copy fills in for when the hair moves away.
                    let original = body.rgba(x: bodyX, y: bodyY)
                    let front = layer.rgba(x: x, y: y)
                    let remainder = (original - front) / max(0.02, 1 - front.w)
                    let opaque = Interpolation.smoothstep(0.9, 0.98, front.w)
                    let backing = remainder + (blurred.rgba(x: bodyX, y: bodyY) - remainder) * opaque
                    body.setRGBA(x: bodyX, y: bodyY, simd_clamp(backing, SIMD4(repeating: 0), SIMD4(repeating: 1)))
                }
            }
            sideHair = layer
            sideHairRect = region.rect
        }

        // --- Clear the backing that only background lies behind -------------
        // Near the outline of the upper head, what the moving head and hair
        // uncover is the background, not more hair. A backing there reads as
        // a grey ghost of the old outline, so it fades out within the distance
        // the head can move. From the eyes down, the neck, hair and shoulders
        // behind the face stay backed.
        let eyeY = Float(plan.eyeLeftRect.midY + plan.eyeRightRect.midY) / 2
        let ghostReach = SideHairRegion.reach(plan)
        let ghostRect = plan.headRect
            .insetBy(dx: -ghostReach, dy: 0)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if !ghostRect.isNull, !ghostRect.isEmpty {
            let distanceRect = ghostRect.insetBy(dx: 0, dy: -plan.headRect.height * 0.2)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let backgroundDistance = BackgroundDistance(rect: distanceRect, mask: maskValue)
            let pivot = SIMD2(Float(plan.headRect.midX), Float(plan.neckY))
            let baseReach = max(envelope.horizontalOpaqueDepth, envelope.verticalOpaqueDepth)
            let ghostMinX = Int(ghostRect.minX), ghostMaxX = Int(ghostRect.maxX)
            let ghostMinY = Int(ghostRect.minY), ghostMaxY = min(Int(ghostRect.maxY), Int(plan.neckY))
            for sourceY in ghostMinY..<ghostMaxY {
                // Behind the face from the eyes down lies neck and hair; behind
                // side hair, background reaches down to the mouth.
                let headFade = 1 - Interpolation.smoothstep(eyeY, Float(plan.mouthRect.minY), Float(sourceY))
                let sideFade = 1 - Interpolation.smoothstep(Float(plan.mouthRect.maxY), Float(plan.neckY), Float(sourceY))
                guard headFade > 0 || sideFade > 0 else { continue }
                for sourceX in ghostMinX..<ghostMaxX {
                    let x = sourceX - bodyOriginX, y = sourceY - bodyOriginY
                    guard x >= 0, x < body.width, y >= 0, y < body.height, body.alpha(x: x, y: y) > 0 else { continue }
                    let point = SIMD2(Float(sourceX) + 0.5, Float(sourceY) + 0.5)
                    let headShare = headProfile.ownershipWeight(x: CGFloat(sourceX), y: CGFloat(sourceY))
                    var sideShare: Float = 0
                    var sideFollow: Float = 0
                    if let region = sideRegion, region.rect.contains(CGPoint(x: sourceX, y: sourceY)) {
                        sideShare = region.ownership[sourceX - Int(region.rect.minX), sourceY - Int(region.rect.minY)]
                        sideFollow = sideShare * SideHairRegion.followWeight(at: point, plan: plan)
                    }
                    guard headShare > 0.001 || sideFollow > 0.001 else { continue }
                    let offset = point - pivot
                    let motion = baseReach + (offset * offset).sum().squareRoot() * 0.26
                    func exposure(_ follow: Float, _ distance: Float) -> Float {
                        guard follow > 0.001 else { return 0 }
                        let travel = follow * motion
                        return 1 - Interpolation.smoothstep(travel * 0.7, travel, distance)
                    }
                    let distance = backgroundDistance[sourceX, sourceY]
                    let exposed = max(
                        headShare > 0.001 ? headFade * exposure(1, distance) : 0,
                        sideFade * exposure(sideFollow, distance)
                    )
                    // At rest the moving layers must still cover what is cleared.
                    let uncovered = max(0, 1 - headShare - sideShare)
                    let keep = max(uncovered, 1 - exposed)
                    if keep < 0.999 { body.scaleAlpha(x: x, y: y, by: keep) }
                }
            }
        }

        // --- Head layer -----------------------------------------------------
        var head = source.cropped(to: plan.headRect)
        let headOriginX = max(0, Int(plan.headRect.minX))
        let headOriginY = max(0, Int(plan.headRect.minY))
        for y in 0..<head.height {
            let sourceY = headOriginY + y
            for x in 0..<head.width {
                let sourceX = headOriginX + x
                let ownership = headProfile.ownershipWeight(
                    x: CGFloat(sourceX),
                    y: CGFloat(sourceY)
                )
                if ownership <= 0.001 {
                    head.setRGBA(x: x, y: y, .zero)
                    continue
                }
                let mask = maskValue(x: sourceX, y: sourceY)
                capAlpha(&head, x: x, y: y, to: mask)
                if ownership < 0.999 {
                    head.scaleAlpha(x: x, y: y, by: ownership)
                }
            }
        }

        // --- Original-image neck seam ---------------------------------------
        // This patch sits above the synthesized backing but below the head. Its
        // upper half deforms toward the head while the neck row stays fixed, so
        // the visible transition always comes from real source pixels instead
        // of the rectangular palette repair underneath.
        let neckSeamRect = plan.neckSeamRect
        var neckSeam = source.cropped(to: neckSeamRect)
        let seamOriginX = max(0, Int(neckSeamRect.minX))
        let seamOriginY = max(0, Int(neckSeamRect.minY))
        for y in 0..<neckSeam.height {
            let v = neckSeam.height > 1 ? Float(y) / Float(neckSeam.height - 1) : 0
            for x in 0..<neckSeam.width {
                let u = neckSeam.width > 1 ? Float(x) / Float(neckSeam.width - 1) : 0
                let subject = maskValue(x: seamOriginX + x, y: seamOriginY + y)
                let curvedBand = headProfile.seamWeight(
                    x: CGFloat(seamOriginX + x),
                    y: CGFloat(seamOriginY + y)
                )
                let edgeFade = Interpolation.smoothstep(0, 0.06, u)
                    * Interpolation.smoothstep(0, 0.06, 1 - u)
                    * Interpolation.smoothstep(0, 0.10, v)
                    * Interpolation.smoothstep(0, 0.10, 1 - v)
                capAlpha(&neckSeam, x: x, y: y, to: subject)
                let edgeFactor = edgeFade * curvedBand
                if edgeFactor < 1 {
                    neckSeam.scaleAlpha(x: x, y: y, by: edgeFactor)
                }
            }
        }

        // Inpaint skin behind the eyes and mouth on the head layer. The hole is
        // slightly smaller than the cutout rect: the feathered feature layer
        // covers its own edges at rest, so only the interior (revealed while
        // blinking / opening) needs synthesized skin — smaller holes mean less
        // visible smearing when the estimate ran wide.
        func inpaintEllipse(rect fullRect: CGRect) {
            let rect = fullRect.insetBy(dx: fullRect.width * 0.075, dy: fullRect.height * 0.075)
            let local = CGRect(
                x: rect.minX - CGFloat(headOriginX),
                y: rect.minY - CGFloat(headOriginY),
                width: rect.width,
                height: rect.height
            )
            // Give the solver context beyond the hole itself — clamped to the
            // layer, because HoleFiller clamps too and the hole predicate's
            // coordinates are relative to the *clamped* origin.
            let layerBounds = CGRect(x: 0, y: 0, width: head.width, height: head.height)
            let context = local
                .insetBy(dx: -local.width * 0.4, dy: -local.height * 0.4)
                .intersection(layerBounds)
            guard !context.isNull, !context.isEmpty else { return }
            let clampedOrigin = SIMD2(Float(Int(context.minX)), Float(Int(context.minY)))
            let holeCenterX = Float(local.midX) - clampedOrigin.x
            let holeCenterY = Float(local.midY) - clampedOrigin.y
            let radiusX = Float(local.width) / 2
            let radiusY = Float(local.height) / 2
            guard radiusX > 1, radiusY > 1 else { return }
            HoleFiller.fillHole(in: &head, region: context) { x, y in
                let dx = (Float(x) - holeCenterX) / radiusX
                let dy = (Float(y) - holeCenterY) / radiusY
                return dx * dx + dy * dy <= 1
            }
        }
        // Eyes with landmarks are cut to their own shape; the repaint behind
        // them must then follow that shape too (see `EyeShape`).
        let eyeLeftShape = EyeShape.shape(landmarks: plan.eyeLeftLandmarks, within: plan.eyeLeftRect)
        let eyeRightShape = EyeShape.shape(landmarks: plan.eyeRightLandmarks, within: plan.eyeRightRect)
        func inpaintEye(rect: CGRect, shape: EyeShape?) {
            guard let shape else {
                inpaintEllipse(rect: rect)
                return
            }
            let layerBounds = CGRect(x: 0, y: 0, width: head.width, height: head.height)
            let bounds = shape.bounds.offsetBy(dx: -CGFloat(headOriginX), dy: -CGFloat(headOriginY))
            let context = bounds
                .insetBy(dx: -bounds.width * 0.4, dy: -bounds.height * 0.4)
                .intersection(layerBounds)
            guard !context.isNull, !context.isEmpty else { return }
            let originX = CGFloat(Int(context.minX)) + CGFloat(headOriginX)
            let originY = CGFloat(Int(context.minY)) + CGFloat(headOriginY)
            HoleFiller.fillHole(in: &head, region: context) { x, y in
                shape.holeContains(x: originX + CGFloat(x) + 0.5, y: originY + CGFloat(y) + 0.5)
            }
        }
        inpaintEye(rect: plan.eyeLeftRect, shape: eyeLeftShape)
        inpaintEye(rect: plan.eyeRightRect, shape: eyeRightShape)
        inpaintEllipse(rect: plan.mouthRect)

        // --- Feature cutouts --------------------------------------------------
        func featureLayer(rect: CGRect, feather: Float, shape: EyeShape? = nil) -> Bitmap {
            var layer = source.cropped(to: rect)
            let originX = max(0, Int(rect.minX))
            let originY = max(0, Int(rect.minY))
            for y in 0..<layer.height {
                let v = layer.height > 1 ? Float(y) / Float(layer.height - 1) : 0
                for x in 0..<layer.width {
                    let u = layer.width > 1 ? Float(x) / Float(layer.width - 1) : 0
                    let mask = maskValue(x: originX + x, y: originY + y)
                    let edgeFade = shape.map {
                        $0.coverage(x: CGFloat(originX + x) + 0.5, y: CGFloat(originY + y) + 0.5)
                    } ?? Interpolation.smoothstep(0, feather, u)
                        * Interpolation.smoothstep(0, feather, 1 - u)
                        * Interpolation.smoothstep(0, feather, v)
                        * Interpolation.smoothstep(0, feather, 1 - v)
                    capAlpha(&layer, x: x, y: y, to: mask)
                    if edgeFade < 1 {
                        layer.scaleAlpha(x: x, y: y, by: edgeFade)
                    }
                }
            }
            return layer
        }

        /// Builds a dark, filled oral cavity in the lower center of the mouth
        /// crop. The closed keyform compresses this region to a lip line; open
        /// keyforms reveal it without requiring a second authored texture.
        func synthesizedMouthLayer() -> Bitmap {
            var layer = featureLayer(rect: plan.mouthRect, feather: 0.2)
            guard layer.width >= 4, layer.height >= 4 else { return layer }
            var cavity = Bitmap(width: layer.width, height: layer.height)
            let center = SIMD2(Float(layer.width) * 0.5, Float(layer.height) * 0.64)
            let radius = SIMD2(
                max(2, Float(layer.width) * 0.34),
                max(2, Float(layer.height) * 0.27)
            )
            let dark = SIMD4<Float>(0.10, 0.018, 0.035, 0.96)
            for y in 0..<cavity.height {
                for x in 0..<cavity.width {
                    let dx = (Float(x) - center.x) / radius.x
                    let dy = (Float(y) - center.y) / radius.y
                    let distance = dx * dx + dy * dy
                    if distance >= 0.68, distance <= 1 {
                        cavity.setRGBA(x: x, y: y, dark)
                    }
                }
            }
            HoleFiller.fillHole(
                in: &cavity,
                region: CGRect(x: 0, y: 0, width: cavity.width, height: cavity.height)
            ) { x, y in
                let dx = (Float(x) - center.x) / radius.x
                let dy = (Float(y) - center.y) / radius.y
                return dx * dx + dy * dy < 0.68
            }
            for y in 0..<layer.height {
                for x in 0..<layer.width {
                    let replacement = cavity.rgba(x: x, y: y)
                    guard replacement.w > 0.01 else { continue }
                    let dx = (Float(x) - center.x) / radius.x
                    let dy = (Float(y) - center.y) / radius.y
                    // Preserve the source upper lip while replacing the region
                    // that becomes visible only as the lower mesh opens.
                    if dx * dx + dy * dy <= 1, Float(y) >= center.y - radius.y * 0.35 {
                        layer.setRGBA(x: x, y: y, replacement)
                    }
                }
            }
            return layer
        }

        return ExtractedLayers(
            body: body,
            neckSeam: neckSeam,
            head: head,
            eyeLeft: featureLayer(rect: plan.eyeLeftRect, feather: 0.16, shape: eyeLeftShape),
            eyeRight: featureLayer(rect: plan.eyeRightRect, feather: 0.16, shape: eyeRightShape),
            mouth: synthesizedMouthLayer(),
            sideHair: sideHair,
            sideHairRect: sideHairRect
        )
    }

    /// Returns independent collar and side-reveal weights in 0...1 for a
    /// source-space pixel. Keeping this geometry shared guarantees the ML mask
    /// and the compositor apply exactly the same bounded repair area.
    static func underpaintEnvelope(for plan: PartPlan) -> HeadDisocclusionEnvelope {
        HeadDisocclusionEnvelope.supported(plan: plan)
    }

    static func underpaintWeights(
        x: Int,
        y: Int,
        plan: PartPlan
    ) -> (collar: Float, side: Float) {
        underpaintWeights(
            x: x,
            y: y,
            plan: plan,
            envelope: underpaintEnvelope(for: plan)
        )
    }

    static func underpaintWeights(
        x: Int,
        y: Int,
        plan: PartPlan,
        envelope: HeadDisocclusionEnvelope
    ) -> (collar: Float, side: Float) {
        let px = Float(x)
        let py = Float(y)
        let minX = Float(plan.headRect.minX)
        let maxX = Float(plan.headRect.maxX)
        let minY = Float(plan.headRect.minY)
        let neckY = Float(plan.neckY)
        guard px >= minX, px < maxX, py >= minY, py < neckY else {
            return (0, 0)
        }

        let headWidth = max(1, maxX - minX)
        let edgeDistance = min(px - minX, maxX - px)
        let side: Float
        if edgeDistance <= envelope.horizontalOpaqueDepth {
            side = 1
        } else if edgeDistance < envelope.horizontalExtent {
            side = 1 - Interpolation.smoothstep(
                envelope.horizontalOpaqueDepth,
                envelope.horizontalExtent,
                edgeDistance
            )
        } else {
            side = 0
        }

        let collarHeight = max(2, Float(plan.collarHeight))
        let depth = neckY - py
        let halfWidth = min(
            headWidth * 0.34,
            max(Float(plan.mouthRect.width) * 1.35, headWidth * 0.20)
        )
        let horizontalDistance = abs(px - Float(plan.headRect.midX))
        let horizontal = max(0, 1 - horizontalDistance / max(1, halfWidth))
        let horizontalFade = Interpolation.smoothstep(0, 0.28, horizontal)
        // Preserve the proven curved collar grade at ordinary sizes. If the
        // supported pitch can expose farther, only extend its hidden tail; the
        // original source neckSeam remains the visible transition at rest.
        let originalHeight = collarHeight * (0.60 + 0.40 * horizontal)
        let localExtent = max(originalHeight, envelope.verticalExtent)
        let vertical = depth <= localExtent
            ? Interpolation.smoothstep(0, 0.35, 1 - depth / max(1, localExtent))
            : 0
        return (horizontalFade * vertical, side)
    }
}
