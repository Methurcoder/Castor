#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Face layout for mascot-style characters: a light round body whose face is
/// two dark dot eyes and a small mouth, often a single "one head tall" shape.
///
/// Neither the anime landmark model (trained on faces with hair, lids and a
/// jaw) nor Apple Vision answers on such a drawing, and the illustration
/// heuristic looks for a head on top of a body, so it puts the eyes on the
/// forehead. Here the eyes are found directly:
///
/// 1. the body tone is the median of the silhouette's interior, well away
///    from the outline;
/// 2. eye candidates are compact dark blobs inside it (thin lines such as the
///    outline, arm creases or a mouth's edge are not compact);
/// 3. the eyes are the best pair: similar size, level, side by side at a
///    plausible distance, near the middle of the body;
/// 4. the mouth is whatever differs from the body tone between and below them.
///
/// The whole silhouette above the lower body is the head. Returns nil for tall
/// figures and when no convincing pair exists, so other estimators keep the
/// image.
public struct MascotFaceEstimator: FaceLayoutEstimating {
    public static let sourceLabel = "Dot-eye mascot"
    /// Tallest silhouette, as height over width, still treated as a mascot.
    static let maximumAspect: Float = 1.6
    public var estimatorSourceLabel: String { Self.sourceLabel }

    public init() {}

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        Self.layout(
            bitmap: context.analysis,
            subjectMask: subjectMask,
            scaleToOriginal: context.scaleToOriginal,
            imageWidth: context.imageWidth,
            imageHeight: context.imageHeight
        )
    }

    struct Blob {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var count: Int
        var sumX: Float, sumY: Float
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var centerX: Float { sumX / Float(count) }
        var centerY: Float { sumY / Float(count) }
        var fill: Float { Float(count) / Float(width * height) }
    }

    /// 4-connected components of `mask`, row-major.
    static func components(_ mask: [Bool], width: Int, height: Int) -> [Blob] {
        var seen = [Bool](repeating: false, count: mask.count)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            var blob = Blob(minX: width, minY: height, maxX: -1, maxY: -1, count: 0, sumX: 0, sumY: 0)
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % width
                let y = i / width
                blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
                blob.count += 1
                blob.sumX += Float(x); blob.sumY += Float(y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let n = ny * width + nx
                    if mask[n], !seen[n] {
                        seen[n] = true
                        stack.append(n)
                    }
                }
            }
            blobs.append(blob)
        }
        return blobs
    }

    static func layout(
        bitmap: Bitmap,
        subjectMask: FloatPlane,
        scaleToOriginal: CGFloat,
        imageWidth: Int,
        imageHeight: Int
    ) -> FaceLayout? {
        let width = bitmap.width
        let height = bitmap.height
        guard width >= 16, height >= 16, subjectMask.width == width, subjectMask.height == height else { return nil }

        // --- Subject and its interior --------------------------------------
        var minX = width, minY = height, maxX = -1, maxY = -1, subjectArea = 0
        for y in 0..<height {
            for x in 0..<width where subjectMask[x, y] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                subjectArea += 1
            }
        }
        guard subjectArea >= 256 else { return nil }
        let subjectWidth = maxX - minX + 1
        let subjectHeight = maxY - minY + 1
        // Only squat, one-head-tall shapes. A tall figure has a head on a
        // body, which the other estimators handle, and its buttons, shoes or
        // patterns could otherwise pass for a pair of dots.
        guard Float(subjectHeight) <= Self.maximumAspect * Float(subjectWidth) else { return nil }
        // Far enough inside that the outline is gone.
        let inset = max(2, Int((Float(min(subjectWidth, subjectHeight)) * 0.025).rounded()))
        let interior = subjectMask.boxBlurred(radius: inset)

        var interiorLuminance: [Float] = []
        for y in minY...maxY {
            for x in minX...maxX where interior[x, y] > 0.98 {
                interiorLuminance.append(bitmap.luminance(x: x, y: y))
            }
        }
        guard interiorLuminance.count >= 128 else { return nil }
        interiorLuminance.sort()
        let bodyLuminance = interiorLuminance[interiorLuminance.count / 2]
        let darkLimit = min(0.42, bodyLuminance * 0.55)
        // A dark body leaves dark eyes nothing to stand out against.
        guard bodyLuminance - darkLimit > 0.2 else { return nil }

        // Body colour, for finding the mouth later.
        var bodySum = SIMD3<Float>(repeating: 0)
        var bodyCount: Float = 0
        func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let c = bitmap.rgba(x: x, y: y)
            return c.w > 0.001 ? SIMD3(c.x, c.y, c.z) / c.w : .zero
        }
        for y in minY...maxY {
            for x in minX...maxX where interior[x, y] > 0.98
                && abs(bitmap.luminance(x: x, y: y) - bodyLuminance) < 0.06 {
                bodySum += color(x, y)
                bodyCount += 1
            }
        }
        guard bodyCount > 0 else { return nil }
        let bodyColor = bodySum / bodyCount

        // --- Eye candidates -------------------------------------------------
        var dark = [Bool](repeating: false, count: width * height)
        for y in minY...maxY {
            for x in minX...maxX where interior[x, y] > 0.98 && bitmap.luminance(x: x, y: y) < darkLimit {
                dark[y * width + x] = true
            }
        }
        let minimumBlob = max(4, subjectArea / 5000)
        let maximumBlob = subjectArea / 25
        let candidates = components(dark, width: width, height: height).filter { blob in
            let aspect = Float(blob.width) / Float(blob.height)
            return blob.count >= minimumBlob && blob.count <= maximumBlob
                && blob.width <= subjectWidth / 4 && blob.height <= subjectHeight * 3 / 10
                && aspect >= 0.4 && aspect <= 2.5
                && blob.fill >= 0.45
        }
        guard candidates.count >= 2 else { return nil }

        // --- The pair -------------------------------------------------------
        let subjectCenterX = Float(minX + maxX) / 2
        var best: (left: Blob, right: Blob, score: Float, quality: Float)?
        for i in candidates.indices {
            for j in candidates.indices where j != i {
                let left = candidates[i]
                let right = candidates[j]
                guard left.centerX < right.centerX else { continue }
                let sizeRatio = Float(min(left.count, right.count)) / Float(max(left.count, right.count))
                let meanWidth = Float(left.width + right.width) / 2
                let meanHeight = Float(left.height + right.height) / 2
                let dy = abs(left.centerY - right.centerY)
                let dx = right.centerX - left.centerX
                let middleX = (left.centerX + right.centerX) / 2
                let offCenter = abs(middleX - subjectCenterX) / Float(subjectWidth)
                let middleY = (left.centerY + right.centerY) / 2
                guard sizeRatio >= 0.45,
                      dy <= 0.5 * meanHeight,
                      dx >= 1.6 * meanWidth, dx <= 9 * meanWidth, dx <= 0.8 * Float(subjectWidth),
                      offCenter <= 0.25,
                      middleY <= Float(minY) + 0.8 * Float(subjectHeight) else { continue }
                let level = 1 - dy / meanHeight
                let centred = 1 - 2 * offCenter
                let quality = sizeRatio * level * centred
                let score = (Float(left.count) * Float(right.count)).squareRoot() * quality
                    * (left.fill + right.fill) / 2
                if score > (best?.score ?? 0) { best = (left, right, score, quality) }
            }
        }
        guard let pair = best else { return nil }
        let left = pair.left
        let right = pair.right
        let eyeDistance = right.centerX - left.centerX
        let eyeBottom = Float(max(left.maxY, right.maxY))

        // --- The mouth: off-body colour between and below the eyes ---------
        let mouthMinX = Int(left.centerX + eyeDistance * 0.2)
        let mouthMaxX = Int(right.centerX - eyeDistance * 0.2)
        let mouthMinY = Int(eyeBottom)
        let mouthMaxY = min(maxY, Int(eyeBottom + eyeDistance * 0.8))
        var feature = [Bool](repeating: false, count: width * height)
        if mouthMaxX > mouthMinX, mouthMaxY > mouthMinY {
            for y in mouthMinY...mouthMaxY {
                for x in mouthMinX...mouthMaxX where interior[x, y] > 0.5 {
                    let difference = color(x, y) - bodyColor
                    if (difference * difference).sum().squareRoot() > 0.18 {
                        feature[y * width + x] = true
                    }
                }
            }
        }
        let mouthBlob = components(feature, width: width, height: height)
            .filter { $0.count >= 3 }
            .max { $0.count < $1.count }
        let mouthBox: CGRect
        if let mouthBlob {
            mouthBox = CGRect(x: mouthBlob.minX, y: mouthBlob.minY, width: mouthBlob.width, height: mouthBlob.height)
        } else {
            let middleX = CGFloat(left.centerX + right.centerX) / 2
            let size = CGFloat(eyeDistance) * 0.3
            mouthBox = CGRect(x: middleX - size / 2, y: CGFloat(eyeBottom) + size * 0.4, width: size, height: size * 0.5)
        }

        // --- Back to source pixels -----------------------------------------
        let scale = scaleToOriginal
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        func source(_ rect: CGRect, padding: CGFloat) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                .insetBy(dx: -rect.width * scale * padding, dy: -rect.height * scale * padding)
                .intersection(bounds)
        }
        func eyeRect(_ blob: Blob) -> CGRect {
            source(CGRect(x: blob.minX, y: blob.minY, width: blob.width, height: blob.height), padding: 0.3)
        }
        /// Six lid points on the dot's outline, so the eye is cut to its own
        /// shape and closes to a line when it blinks.
        func lids(_ blob: Blob) -> [CGPoint] {
            let center = CGPoint(x: (CGFloat(blob.minX) + CGFloat(blob.maxX) + 1) / 2 * scale,
                                 y: (CGFloat(blob.minY) + CGFloat(blob.maxY) + 1) / 2 * scale)
            let radiusX = CGFloat(blob.width) / 2 * scale
            let radiusY = CGFloat(blob.height) / 2 * scale
            let offsets: [CGFloat] = [-0.8, 0, 0.8]
            let upper = offsets.map { CGPoint(x: center.x + $0 * radiusX, y: center.y - radiusY * (1 - $0 * $0).squareRoot()) }
            let lower = offsets.map { CGPoint(x: center.x + $0 * radiusX, y: center.y + radiusY * (1 - $0 * $0).squareRoot()) }
            return upper + lower
        }
        // The lower body (feet, the part resting on the ground) stays still;
        // everything above it moves as the head.
        let mouthBottom = mouthBox.maxY
        let neck = min(CGFloat(maxY + 1), mouthBottom + (CGFloat(maxY + 1) - mouthBottom) * 0.55)
        let head = source(CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(subjectWidth), height: neck - CGFloat(minY)), padding: 0)

        return FaceLayout(
            headRect: head,
            eyeLeftRect: eyeRect(left),
            eyeRightRect: eyeRect(right),
            mouthRect: source(mouthBox, padding: 0.25),
            confidence: 0.45 + 0.3 * pair.quality,
            eyeLeftLandmarks: lids(left),
            eyeRightLandmarks: lids(right)
        )
    }
}
