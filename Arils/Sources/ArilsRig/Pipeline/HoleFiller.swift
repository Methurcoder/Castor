import CoreGraphics
import Foundation
import simd

/// Diffusion-based inpainting: fills a hole by iteratively averaging inward
/// from the surrounding known pixels (Jacobi relaxation on the color field).
///
/// This is the "use the original image to complete occluded regions" idea from
/// the design brief: the skin behind an eye or mouth is recovered from the skin
/// around it, so blinking or opening the mouth never reveals a transparent
/// hole. Diffusion produces smooth gradients — ideal for anime skin, adequate
/// for photos. A patch-based or ML inpainter can replace this by implementing
/// the same function shape.
///
/// Cost is kept resolution-independent: regions larger than `workingMaxDimension`
/// are solved on a downscaled copy and the solution is bilinearly upsampled into
/// the hole pixels only.
public enum HoleFiller {
    static let workingMaxDimension = 128
    static let iterations = 170

    /// Fills `hole` (true = pixel to synthesize) in-place within `region` of
    /// the bitmap. `hole` receives coordinates relative to `region`'s origin.
    public static func fillHole(
        in bitmap: inout Bitmap,
        region: CGRect,
        hole: (Int, Int) -> Bool
    ) {
        let minX = max(0, Int(region.minX))
        let minY = max(0, Int(region.minY))
        let maxX = min(bitmap.width - 1, Int(region.maxX.rounded(.up)))
        let maxY = min(bitmap.height - 1, Int(region.maxY.rounded(.up)))
        guard maxX > minX, maxY > minY else { return }
        let regionWidth = maxX - minX + 1
        let regionHeight = maxY - minY + 1

        // Choose the working (possibly downscaled) grid.
        let longest = max(regionWidth, regionHeight)
        let scale = longest > workingMaxDimension
            ? Float(workingMaxDimension) / Float(longest)
            : 1
        let gridWidth = max(2, Int(Float(regionWidth) * scale))
        let gridHeight = max(2, Int(Float(regionHeight) * scale))

        var colors = [SIMD4<Float>](repeating: .zero, count: gridWidth * gridHeight)
        var isHole = [Bool](repeating: false, count: gridWidth * gridHeight)
        var knownSum = SIMD4<Float>.zero
        var knownCount: Float = 0

        // Downsample by area-averaging; a grid cell is a hole when the majority
        // of its source pixels are.
        for gy in 0..<gridHeight {
            let y0 = gy * regionHeight / gridHeight
            let y1 = max(y0 + 1, (gy + 1) * regionHeight / gridHeight)
            for gx in 0..<gridWidth {
                let x0 = gx * regionWidth / gridWidth
                let x1 = max(x0 + 1, (gx + 1) * regionWidth / gridWidth)
                var sum = SIMD4<Float>.zero
                var holeCount = 0
                var total = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        sum += bitmap.rgba(x: minX + x, y: minY + y)
                        if hole(x, y) { holeCount += 1 }
                        total += 1
                    }
                }
                let index = gy * gridWidth + gx
                let average = sum / Float(max(1, total))
                if holeCount * 2 >= total {
                    isHole[index] = true
                } else {
                    colors[index] = average
                    if average.w > 0.5 {
                        knownSum += average
                        knownCount += 1
                    }
                }
            }
        }
        guard knownCount > 0 else { return }

        // Seed holes with the mean known color so convergence is fast.
        let seed = knownSum / knownCount
        for index in colors.indices where isHole[index] {
            colors[index] = seed
        }

        var next = colors
        for _ in 0..<iterations {
            for gy in 0..<gridHeight {
                for gx in 0..<gridWidth {
                    let index = gy * gridWidth + gx
                    guard isHole[index] else { continue }
                    var sum = SIMD4<Float>.zero
                    var count: Float = 0
                    if gx > 0 { sum += colors[index - 1]; count += 1 }
                    if gx < gridWidth - 1 { sum += colors[index + 1]; count += 1 }
                    if gy > 0 { sum += colors[index - gridWidth]; count += 1 }
                    if gy < gridHeight - 1 { sum += colors[index + gridWidth]; count += 1 }
                    if count > 0 {
                        next[index] = sum / count
                    }
                }
            }
            swap(&colors, &next)
        }

        // Bilinear sample of the solved grid.
        func solved(atX x: Float, y: Float) -> SIMD4<Float> {
            let gx = min(max(x, 0), Float(gridWidth - 1))
            let gy = min(max(y, 0), Float(gridHeight - 1))
            let x0 = Int(gx), y0 = Int(gy)
            let x1 = min(x0 + 1, gridWidth - 1)
            let y1 = min(y0 + 1, gridHeight - 1)
            let fx = gx - Float(x0), fy = gy - Float(y0)
            let top = colors[y0 * gridWidth + x0] * (1 - fx) + colors[y0 * gridWidth + x1] * fx
            let bottom = colors[y1 * gridWidth + x0] * (1 - fx) + colors[y1 * gridWidth + x1] * fx
            return top * (1 - fy) + bottom * fy
        }

        let inverseScaleX = Float(gridWidth) / Float(regionWidth)
        let inverseScaleY = Float(gridHeight) / Float(regionHeight)
        for y in 0..<regionHeight {
            for x in 0..<regionWidth {
                guard hole(x, y) else { continue }
                // Alpha diffuses along with color (premultiplied), so holes in
                // opaque skin heal opaque while holes near the silhouette edge
                // stay appropriately soft.
                let color = simd_clamp(
                    solved(atX: (Float(x) + 0.5) * inverseScaleX - 0.5, y: (Float(y) + 0.5) * inverseScaleY - 0.5),
                    SIMD4(repeating: 0),
                    SIMD4(repeating: 1)
                )
                bitmap.setRGBA(x: minX + x, y: minY + y, color)
            }
        }
    }
}
