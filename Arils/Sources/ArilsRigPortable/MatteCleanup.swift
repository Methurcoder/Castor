#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Cleans an estimated cut-out of a picture drawn on a background.
///
/// A segmentation mask keeps the background that shows between strands of
/// hair (and between a twin tail and the face) as part of the character, and
/// the outline's soft pixels carry the background's colour as a fringe. Both
/// show as grey or green once the pet stands on the desktop. This
///
/// - makes those gaps transparent: near the outline, a pixel that matches the
///   background behind it and not the character around it is background;
/// - unmixes the outline: a soft pixel is split into the background colour and
///   the nearby character colour, and keeps only the character's part.
///
/// The background behind each pixel is the visible background spread inward,
/// so gradients work. A character drawn in its background's colours (white
/// hair on white) is left alone, because it matches the character around it
/// too. Real alpha channels never come here.
public enum MatteCleanup {
    public static func apply(source: Bitmap, mask: FloatPlane, plan: PartPlan) -> (source: Bitmap, mask: FloatPlane) {
        let width = source.width, height = source.height
        guard width > 2, height > 2 else { return (source, mask) }
        var alpha = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                alpha[y * width + x] = mask.width == width && mask.height == height
                    ? mask[x, y]
                    : mask.sample(u: Float(x) / Float(width - 1), v: Float(y) / Float(height - 1))
            }
        }
        func colour(_ bitmap: Bitmap, _ x: Int, _ y: Int) -> SIMD3<Float> {
            let pixel = bitmap.rgba(x: x, y: y)
            return pixel.w > 0.001 ? SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w : .zero
        }
        func length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }

        // The background behind every pixel: the visible background spread inward.
        guard alpha.contains(where: { $0 < 0.15 }) else { return (source, mask) }
        var background = source
        HoleFiller.fillHole(in: &background, region: CGRect(x: 0, y: 0, width: width, height: height)) { x, y in
            alpha[y * width + x] > 0.15
        }

        // The character's colour around each pixel, from its solid pixels.
        // Excluding background-like colours here would erase a character
        // drawn in them (pale hair on white), so every solid pixel counts.
        let radius = max(3, Int(Float(max(width, height)) * 0.008))
        var solid = source
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] <= 0.9 {
                solid.setRGBA(x: x, y: y, .zero)
            }
        }
        let character = SideHairRegion.subjectBlur(
            solid, region: CGRect(x: 0, y: 0, width: width, height: height), radius: radius
        ) { x, y in solid.alpha(x: x, y: y) }

        // Only near the outline, and never in the face itself.
        let outline = BackgroundDistance(rect: CGRect(x: 0, y: 0, width: width, height: height)) { x, y in
            x >= 0 && y >= 0 && x < width && y < height ? alpha[y * width + x] : 0
        }
        let reach = Float(max(width, height)) * 0.04
        // The face, from the head box (estimated eyes can be misplaced).
        let faceCentre = SIMD2(Float(plan.headRect.midX), Float(plan.headRect.minY + plan.headRect.height * 0.6))
        let faceRadius = SIMD2(Float(plan.headRect.width) * 0.28, Float(plan.headRect.height) * 0.34)
        func inFace(_ x: Int, _ y: Int) -> Bool {
            let d = (SIMD2(Float(x), Float(y)) - faceCentre) / faceRadius
            return (d * d).sum() < 1
        }
        // Only the head and the hair beside it, down to the neck: a fringe or
        // gap there shows as the parts shift. Clothing from the neck down
        // keeps the cut-out as it was, since its colours are easily mistaken
        // for the background.
        let moving = plan.headRect.insetBy(dx: -SideHairRegion.reach(plan), dy: 0)
        let movingBottom = Float(plan.neckY)
        func inMovingArea(_ x: Int, _ y: Int) -> Bool {
            Float(x) >= Float(moving.minX) && Float(x) < Float(moving.maxX) && Float(y) < movingBottom
        }

        // How much of the moving area is drawn in the background's own colours.
        // Pictures on a distinct backdrop share almost none (under 4% in the
        // test set); pale characters on pale backdrops share 10-35%, and
        // there no colour test can tell a gap from the drawing, so the
        // cleanup fades out between 4% and 8%.
        var shared = 0, solidCount = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where alpha[y * width + x] > 0.9 && inMovingArea(x, y) {
                solidCount += 1
                if length(colour(source, x, y) - colour(background, x, y)) < 0.07 { shared += 1 }
            }
        }
        let strength = 1 - Interpolation.smoothstep(0.04, 0.08, Float(shared) / Float(max(1, solidCount)))
        guard strength > 0.01 else { return (source, mask) }

        var cleaned = alpha
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard alpha[index] > 0.02, outline[x, y] <= reach, inMovingArea(x, y),
                      !inFace(x, y), character.alpha(x: x, y: y) > 0.5 else { continue }
                let c = colour(source, x, y), b = colour(background, x, y), f = colour(character, x, y)
                let toBackground = length(c - b), toCharacter = length(c - f)
                // A flat background matches its estimate closely; a drawn
                // pixel that happens to be near it also matches the character.
                let backgroundLike = (1 - Interpolation.smoothstep(0.03, 0.07, toBackground))
                    * (1 - Interpolation.smoothstep(0.3, 0.6, toBackground / (toCharacter + 0.001)))
                cleaned[index] = alpha[index] * (1 - backgroundLike * strength)
            }
        }

        // Unmix the outline: pixels the cut-out left soft, and those next to a
        // gap made transparent above. A solid pixel elsewhere is left alone:
        // a colour between the background and the hair (a beige cardigan on
        // cream, next to brown hair) is not a mixture just because it could be.
        var result = source
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard cleaned[index] > 0.02, outline[x, y] <= reach, inMovingArea(x, y), !inFace(x, y),
                      character.alpha(x: x, y: y) > 0.5 else { continue }
                let soft = alpha[index] < 0.95
                var besideGap = false
                if !soft {
                    search: for dy in -2...2 {
                        for dx in -2...2 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                            let neighbour = ny * width + nx
                            if alpha[neighbour] >= 0.5, cleaned[neighbour] < 0.5 { besideGap = true; break search }
                        }
                    }
                }
                guard soft || besideGap else { continue }
                let c = colour(source, x, y), b = colour(background, x, y), f = colour(character, x, y)
                let span = f - b
                let spanLength = (span * span).sum()
                guard spanLength > 0.0225 else { continue }  // too alike to separate
                let mix = min(max(((c - b) * span).sum() / spanLength, 0), 1)
                // Only a colour that really lies between the two is a mixture.
                guard mix < 0.97, length(c - (b + span * mix)) < 0.05 else { continue }
                let unmixed = simd_clamp((c - b * (1 - mix)) / max(mix, 0.2), SIMD3(repeating: 0), SIMD3(repeating: 1))
                let opacity = result.alpha(x: x, y: y)
                let restored = c + (unmixed - c) * strength
                result.setRGBA(x: x, y: y, SIMD4(restored.x * opacity, restored.y * opacity, restored.z * opacity, opacity))
                if soft {
                    let mixed = min(cleaned[index], Interpolation.smoothstep(0.05, 0.6, mix))
                    cleaned[index] += (mixed - cleaned[index]) * strength
                }
            }
        }
        return (result, FloatPlane(width: width, height: height, values: cleaned))
    }
}
