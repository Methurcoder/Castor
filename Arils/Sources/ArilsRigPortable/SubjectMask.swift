import Foundation
#if canImport(simd)
import simd
#endif

public struct SubjectMaskSet: Sendable {
    public var analysis: FloatPlane
    public var extraction: FloatPlane

    public init(analysis: FloatPlane, extraction: FloatPlane) {
        self.analysis = analysis
        self.extraction = extraction
    }
}

/// Produces a soft subject mask (1 = character, 0 = background).
/// Implementations are tried in order until one succeeds, so the segmentation
/// algorithm is swappable without touching the pipeline.
public protocol SubjectMaskProviding: Sendable {
    /// Legacy analysis-resolution entry point. Existing custom providers keep
    /// source compatibility; the default `masks(for:)` implementation expands
    /// this result for extraction.
    func mask(for context: AnalysisContext) async -> FloatPlane?

    /// Returns both the cheap analysis mask and the original-resolution mask
    /// used to cut textures. Implementations that already have a full-size
    /// result should override this to avoid throwing that information away.
    func masks(for context: AnalysisContext) async -> SubjectMaskSet?

    /// True when partial mask values are real coverage (an actual alpha
    /// channel). False for estimated masks (Vision segmentation), whose soft
    /// edges include background pixels — layer extraction then sharpens the
    /// edge so an opaque background doesn't fringe the character.
    var isAuthoritativeAlpha: Bool { get }
}

public extension SubjectMaskProviding {
    func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        guard let analysis = await mask(for: context) else { return nil }
        return SubjectMaskSet(
            analysis: analysis.resized(
                width: context.analysis.width,
                height: context.analysis.height
            ),
            extraction: analysis.resized(
                width: context.imageWidth,
                height: context.imageHeight
            )
        )
    }
}

/// Uses the image's own alpha channel — the best possible mask when the user
/// drops in a transparent-background PNG (the common case for character art).
public struct AlphaSubjectMaskProvider: SubjectMaskProviding {
    /// Fraction of pixels that must be transparent for the alpha channel to be
    /// considered a real cutout rather than a fully opaque photo.
    private static let minimumTransparentFraction: Float = 0.02

    public let isAuthoritativeAlpha = true

    public init() {}

    public func mask(for context: AnalysisContext) async -> FloatPlane? {
        await masks(for: context)?.analysis
    }

    public func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        let analysisPlane = context.analysis.alphaPlane()
        let extractionPlane: FloatPlane
        if let original = context.originalBitmap {
            extractionPlane = original.alphaPlane()
        } else if let original = context.decodedOriginalBitmap {
            extractionPlane = original.alphaPlane()
        } else {
            return nil
        }

        // Provider selection must use the same original-resolution evidence
        // that will cut the texture. A narrow transparent border or a field of
        // fine hair gaps can disappear in the 256 px analysis bitmap; deciding
        // from that downsample would incorrectly discard an exact PNG alpha
        // channel and fall through to an estimated mask.
        var transparent = 0
        for value in extractionPlane.values where value < 0.1 {
            transparent += 1
        }
        let fraction = Float(transparent) / Float(max(1, extractionPlane.values.count))
        guard fraction >= Self.minimumTransparentFraction else { return nil }
        return SubjectMaskSet(analysis: analysisPlane, extraction: extractionPlane)
    }
}

public struct BorderBackgroundSubjectMaskProvider: SubjectMaskProviding {
    public let isAuthoritativeAlpha = false

    public init() {}

    public func mask(for context: AnalysisContext) async -> FloatPlane? {
        analysisMask(for: context)
    }

    public func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        guard let analysis = analysisMask(for: context) else { return nil }
        let extraction: FloatPlane
        if let original = context.originalBitmap {
            extraction = SubjectMaskResampling.guidedUpsampled(
                analysis,
                lowResolutionGuide: context.analysis,
                fullResolutionGuide: original
            )
        } else if let original = context.decodedOriginalBitmap {
            extraction = SubjectMaskResampling.guidedUpsampled(
                analysis,
                lowResolutionGuide: context.analysis,
                fullResolutionGuide: original
            )
        } else {
            return nil
        }
        return SubjectMaskSet(analysis: analysis, extraction: extraction)
    }

    private func analysisMask(for context: AnalysisContext) -> FloatPlane? {
        let bitmap = context.analysis
        guard bitmap.width >= 8, bitmap.height >= 8 else { return nil }

        var borderColors: [SIMD3<Float>] = []
        borderColors.reserveCapacity((bitmap.width + bitmap.height) * 2)

        func straightColor(x: Int, y: Int) -> SIMD3<Float>? {
            let pixel = bitmap.rgba(x: x, y: y)
            guard pixel.w > 0.98 else { return nil }
            return SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
        }

        for x in 0..<bitmap.width {
            if let color = straightColor(x: x, y: 0) { borderColors.append(color) }
            if let color = straightColor(x: x, y: bitmap.height - 1) { borderColors.append(color) }
        }
        if bitmap.height > 2 {
            for y in 1..<(bitmap.height - 1) {
                if let color = straightColor(x: 0, y: y) { borderColors.append(color) }
                if let color = straightColor(x: bitmap.width - 1, y: y) { borderColors.append(color) }
            }
        }
        guard borderColors.count >= 16 else { return nil }

        let mean = borderColors.reduce(SIMD3<Float>.zero, +) / Float(borderColors.count)
        let variance = borderColors.reduce(Float.zero) { partial, color in
            let delta = color - mean
            return partial + simd_dot(delta, delta)
        } / Float(borderColors.count)
        let deviation = sqrt(max(0, variance))

        // A highly varied border is not a flat-background illustration. Let
        // the pipeline report that it cannot isolate the subject instead of
        // manufacturing a full-frame silhouette.
        guard deviation <= 0.10 else { return nil }
        let threshold = min(0.18, max(0.055, 0.055 + deviation * 2.5))

        var isBackground = [Bool](repeating: false, count: bitmap.width * bitmap.height)
        var queue: [Int] = []
        queue.reserveCapacity(bitmap.width * bitmap.height / 2)

        func isBackgroundColor(x: Int, y: Int) -> Bool {
            guard let color = straightColor(x: x, y: y) else { return false }
            return simd_distance(color, mean) <= threshold
        }

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, x < bitmap.width, y >= 0, y < bitmap.height else { return }
            let index = y * bitmap.width + x
            guard !isBackground[index], isBackgroundColor(x: x, y: y) else { return }
            isBackground[index] = true
            queue.append(index)
        }

        for x in 0..<bitmap.width {
            enqueue(x, 0)
            enqueue(x, bitmap.height - 1)
        }
        for y in 0..<bitmap.height {
            enqueue(0, y)
            enqueue(bitmap.width - 1, y)
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % bitmap.width
            let y = index / bitmap.width
            enqueue(x - 1, y)
            enqueue(x + 1, y)
            enqueue(x, y - 1)
            enqueue(x, y + 1)
        }

        var result = FloatPlane(width: bitmap.width, height: bitmap.height)
        var foregroundCount = 0
        for index in result.values.indices where !isBackground[index] {
            result.values[index] = 1
            foregroundCount += 1
        }
        let coverage = Float(foregroundCount) / Float(max(1, result.values.count))
        guard coverage >= 0.02, coverage <= 0.90 else { return nil }
        return result
    }
}

/// Last-resort mask: the whole image is "subject". Keeps the pipeline total.
public struct FullFrameSubjectMaskProvider: SubjectMaskProviding {
    /// The constant all-ones mask has no partial edges; sharpening is a no-op,
    /// so it may as well be authoritative.
    public let isAuthoritativeAlpha = true

    public init() {}

    public func mask(for context: AnalysisContext) async -> FloatPlane? {
        FloatPlane(width: context.analysis.width, height: context.analysis.height, fill: 1)
    }

    public func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        SubjectMaskSet(
            analysis: FloatPlane(
                width: context.analysis.width,
                height: context.analysis.height,
                fill: 1
            ),
            extraction: FloatPlane(
                width: context.imageWidth,
                height: context.imageHeight,
                fill: 1
            )
        )
    }
}

/// Shared mask resampling. The guided path only spends bilateral work in the
/// fractional transition band; unambiguous interior/background pixels remain a
/// cheap bilinear copy even for multi-megapixel illustrations.
public enum SubjectMaskResampling {
    /// Joint-bilateral upsampling for the flat-background fallback. The
    /// low-resolution flood decides topology; original-resolution color edges
    /// steer its fractional boundary back onto the source silhouette.
    public static func guidedUpsampled(
        _ source: FloatPlane,
        lowResolutionGuide: Bitmap,
        fullResolutionGuide: Bitmap
    ) -> FloatPlane {
        let width = fullResolutionGuide.width
        let height = fullResolutionGuide.height
        guard width > 0, height > 0, source.width > 0, source.height > 0 else {
            return FloatPlane(width: 0, height: 0)
        }
        guard source.width != width || source.height != height else { return source }
        guard lowResolutionGuide.width == source.width,
              lowResolutionGuide.height == source.height else {
            return source.resized(width: width, height: height)
        }

        var result = source.resized(width: width, height: height)
        let radius = 2
        let spatialSigma: Float = 1.15
        let inverseSpatialVariance = 1 / (2 * spatialSigma * spatialSigma)
        let rangeSigma: Float = 0.12
        let inverseRangeVariance = 1 / (2 * rangeSigma * rangeSigma)
        var boundarySupport = FloatPlane(width: source.width, height: source.height)
        for y in 0..<source.height {
            for x in 0..<source.width {
                var minimum = source[x, y]
                var maximum = minimum
                for offsetY in -radius...radius {
                    let sampleY = min(max(y + offsetY, 0), source.height - 1)
                    for offsetX in -radius...radius {
                        let sampleX = min(max(x + offsetX, 0), source.width - 1)
                        let value = source[sampleX, sampleY]
                        minimum = min(minimum, value)
                        maximum = max(maximum, value)
                    }
                }
                if maximum - minimum > 0.001 {
                    boundarySupport[x, y] = 1
                }
            }
        }

        func straightRGB(_ bitmap: Bitmap, x: Int, y: Int) -> SIMD3<Float> {
            let pixel = bitmap.rgba(x: x, y: y)
            guard pixel.w > 0.001 else { return .zero }
            return SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
        }

        for y in 0..<height {
            let v = height > 1 ? Float(y) / Float(height - 1) : 0
            let lowY = v * Float(source.height - 1)
            let centerY = Int(lowY.rounded())
            for x in 0..<width {
                let baseline = result[x, y]

                let u = width > 1 ? Float(x) / Float(width - 1) : 0
                let lowX = u * Float(source.width - 1)
                let centerX = Int(lowX.rounded())
                if baseline <= 0.001 || baseline >= 0.999 {
                    guard boundarySupport[centerX, centerY] > 0 else { continue }
                }
                let targetColor = straightRGB(fullResolutionGuide, x: x, y: y)
                var weightedMask: Float = 0
                var totalWeight: Float = 0

                for offsetY in -radius...radius {
                    let sampleY = min(max(centerY + offsetY, 0), source.height - 1)
                    for offsetX in -radius...radius {
                        let sampleX = min(max(centerX + offsetX, 0), source.width - 1)
                        let dx = Float(sampleX) - lowX
                        let dy = Float(sampleY) - lowY
                        let spatialWeight = exp(-(dx * dx + dy * dy) * inverseSpatialVariance)
                        let colorDelta = straightRGB(
                            lowResolutionGuide,
                            x: sampleX,
                            y: sampleY
                        ) - targetColor
                        let rangeWeight = exp(-simd_dot(colorDelta, colorDelta) * inverseRangeVariance)
                        let weight = spatialWeight * rangeWeight
                        weightedMask += source[sampleX, sampleY] * weight
                        totalWeight += weight
                    }
                }
                if totalWeight > 0.000_001 {
                    result[x, y] = min(max(weightedMask / totalWeight, 0), 1)
                }
            }
        }
        return result
    }
}
