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
    /// The mouth interior shown while speaking (see `mouthCavityKeyforms`).
    public var mouthCavity: Bitmap
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
    /// The drawn mouth at rest; opening lowers the part below the lip line by
    /// the mouth interior's height (`mouthCavityRect`), and the form widens or
    /// narrows it. Closed and neutral is the drawing exactly, so a pet at
    /// rest keeps the mouth it was drawn with.
    public static func mouthWarpKeyforms(mesh: DeformableMesh) -> [WarpKeyformKey] {
        let minX = mesh.vertices.map(\.x).min() ?? 0
        let maxX = mesh.vertices.map(\.x).max() ?? minX
        let minY = mesh.vertices.map(\.y).min() ?? 0
        let maxY = mesh.vertices.map(\.y).max() ?? minY
        let height = max(1, maxY - minY)
        let centerX = (minX + maxX) * 0.5
        let lipLine = minY + height * mouthLipLine
        func offsets(open: Float, form: Float) -> [SIMD2<Float>] {
            let scaleX = 1 + form * 0.08 - open * 0.04
            return mesh.vertices.map { vertex in
                let below = Interpolation.smoothstep(lipLine, lipLine + height * 0.2, vertex.y)
                return SIMD2((vertex.x - centerX) * (scaleX - 1), open * height * mouthCavityDepth * below)
            }
        }
        return [(0, -1), (0, 1), (1, -1), (1, 1)].map { open, form in
            WarpKeyformKey(parameterXValue: open, parameterYValue: form, vertexOffsets: offsets(open: open, form: form))
        }
    }

    /// The mouth interior, drawn over the mouth: collapsed onto the lip line
    /// when closed (no area, so nothing shows), its full height when open.
    public static func mouthCavityKeyforms(mesh: DeformableMesh) -> [WarpKeyformKey] {
        let minX = mesh.vertices.map(\.x).min() ?? 0
        let maxX = mesh.vertices.map(\.x).max() ?? minX
        let minY = mesh.vertices.map(\.y).min() ?? 0
        let centerX = (minX + maxX) * 0.5
        func offsets(open: Float, form: Float) -> [SIMD2<Float>] {
            let scaleX = 1 + form * 0.15
            return mesh.vertices.map { vertex in
                let x = centerX + (vertex.x - centerX) * scaleX
                let y = minY + (vertex.y - minY) * open
                return SIMD2(x, y) - vertex
            }
        }
        return [(0, -1), (0, 1), (1, -1), (1, 1)].map { open, form in
            WarpKeyformKey(parameterXValue: open, parameterYValue: form, vertexOffsets: offsets(open: open, form: form))
        }
    }

    /// Where the lips meet, as a fraction of the mouth box height.
    static let mouthLipLine: Float = 0.5
    /// How far the mouth opens, as a fraction of the mouth box height.
    static let mouthCavityDepth: Float = 0.55

    /// The mouth interior's box: below the lip line, narrower than the mouth.
    public static func mouthCavityRect(for plan: PartPlan) -> CGRect {
        let mouth = plan.mouthRect
        return CGRect(
            x: mouth.midX - mouth.width * 0.32,
            y: mouth.minY + mouth.height * CGFloat(mouthLipLine),
            width: mouth.width * 0.64,
            height: max(2, mouth.height * CGFloat(mouthCavityDepth))
        )
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
        // as a rectangle whenever the head turned. The backing is a heavy blur
        // of the character itself instead: near the head's outline that is
        // the hair's own colour, which is what lies behind it. (Spreading only
        // the colours around the head inward turned it grey under dark hair,
        // from the shirt and collar below.) The background never contributes.
        // The ML repair stays within the supported yaw/pitch envelope, away
        // from the face; this backing covers the rest of the head, so tilt or
        // a larger turn shows blurred hair instead of a hole.
        var diffusedBacking: Bitmap?
        do {
            let reach = plan.headRect.insetBy(dx: -plan.headRect.width * 0.2, dy: -plan.collarHeight)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !reach.isNull, !reach.isEmpty {
                diffusedBacking = SideHairRegion.subjectBlur(
                    source,
                    region: reach,
                    radius: max(4, Int(plan.headRect.width * 0.08)),
                    mask: maskValue
                )
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

        // --- Clear the backing that only background lies behind -------------
        SideHairRegion.clearBacking(
            body: &body, bodyOrigin: (bodyOriginX, bodyOriginY), plan: plan,
            mask: maskValue, headMoves: true, side: nil
        )

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
        /// A dark mouth interior with a softer tongue tone low down; its
        /// edge is feathered so it reads as an opening, not a sticker.
        func mouthCavityLayer() -> Bitmap {
            let rect = mouthCavityRect(for: plan)
            let width = max(2, Int(rect.width.rounded(.up))), height = max(2, Int(rect.height.rounded(.up)))
            var layer = Bitmap(width: width, height: height)
            let throat = SIMD3<Float>(0.10, 0.02, 0.035), tongue = SIMD3<Float>(0.52, 0.16, 0.18)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = (Float(x) + 0.5) / Float(width) * 2 - 1
                    let dy = (Float(y) + 0.5) / Float(height) * 2 - 1
                    let distance = (dx * dx + dy * dy).squareRoot()
                    let alpha = 0.96 * (1 - Interpolation.smoothstep(0.8, 1, distance))
                    guard alpha > 0 else { continue }
                    let tone = throat + (tongue - throat) * Interpolation.smoothstep(0.1, 0.9, dy)
                    layer.setRGBA(x: x, y: y, SIMD4(tone.x * alpha, tone.y * alpha, tone.z * alpha, alpha))
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
            mouth: featureLayer(rect: plan.mouthRect, feather: 0.2),
            mouthCavity: mouthCavityLayer()
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
