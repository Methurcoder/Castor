import CoreGraphics
import Foundation
import simd

struct QualityPairInspector {
    /// Per-axis bin count for the quantized RGB color histogram (4x4x4 = 64
    /// bins total). Coarse on purpose: this is an advisory same-character
    /// heuristic, not a precise color-matching tool.
    private static let histogramBinsPerAxis = 4
    private static let histogramBinCount = histogramBinsPerAxis * histogramBinsPerAxis * histogramBinsPerAxis

    private struct Metrics {
        var faceConfidence: Float
        var headWidthRatio: Float
        var foregroundCoverage: Float
        /// Mask-weighted, normalized (sums to 1) quantized RGB color
        /// histogram of the subject, straight (non-premultiplied) color.
        var colorHistogram: [Float]
    }

    static func assess(
        front: (context: AnalysisContext, mask: FloatPlane),
        side: (context: AnalysisContext, mask: FloatPlane),
        faceEstimator: any FaceLayoutEstimating,
        sideFileName: String
    ) async -> QualityPairAssessment {
        let frontMetrics = await metrics(for: front, faceEstimator: faceEstimator)
        let sideMetrics = await metrics(for: side, faceEstimator: faceEstimator)

        // Histogram intersection: sum of the per-bin minimum. Both
        // histograms are normalized to sum to 1, so the result is in 0...1.
        var colorSimilarity: Float = 0
        for bin in 0..<histogramBinCount {
            colorSimilarity += min(frontMetrics.colorHistogram[bin], sideMetrics.colorHistogram[bin])
        }
        colorSimilarity = min(max(colorSimilarity, 0), 1)
        let coverageSimilarity = 1 - min(1, abs(frontMetrics.foregroundCoverage - sideMetrics.foregroundCoverage) / 0.45)
        let headSimilarity: Float
        if frontMetrics.headWidthRatio > 0.01, sideMetrics.headWidthRatio > 0.01 {
            headSimilarity = 1 - min(1, abs(frontMetrics.headWidthRatio - sideMetrics.headWidthRatio) / 0.30)
        } else {
            headSimilarity = 0.35
        }
        // Advisory heuristic only: this never claims certainty either way,
        // it just weights the signals that are cheap to compute from the two
        // still images (see `QualityPairAssessment`'s doc comment).
        let sameCharacterConfidence = min(max(
            colorSimilarity * 0.60 + headSimilarity * 0.25 + coverageSimilarity * 0.15,
            0
        ), 1)
        let faceReadabilityConfidence = min(frontMetrics.faceConfidence, sideMetrics.faceConfidence)

        var warnings: [QualityPairWarning] = []
        if faceReadabilityConfidence < 0.55 {
            warnings.append(.expressionNotReliable(confidence: faceReadabilityConfidence))
        }
        let differentCharacterProbability = 1 - sameCharacterConfidence
        if differentCharacterProbability >= 0.50 {
            warnings.append(.possibleDifferentCharacter(
                fileName: sideFileName,
                probability: differentCharacterProbability
            ))
        }
        return QualityPairAssessment(
            sameCharacterConfidence: sameCharacterConfidence,
            faceReadabilityConfidence: faceReadabilityConfidence,
            warnings: warnings
        )
    }

    private static func metrics(
        for input: (context: AnalysisContext, mask: FloatPlane),
        faceEstimator: any FaceLayoutEstimating
    ) async -> Metrics {
        let layout = await faceEstimator.estimateLayout(context: input.context, subjectMask: input.mask)
        let bitmap = input.context.analysis
        var maskedPixelCount: Float = 0
        var histogram = [Float](repeating: 0, count: histogramBinCount)
        var histogramWeight: Float = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let weight = input.mask[x, y]
                if weight >= 0.5 { maskedPixelCount += 1 }
                guard weight > 0.01 else { continue }
                let pixel = bitmap.rgba(x: x, y: y)
                // Premultiplied alpha; near-transparent pixels are excluded
                // rather than divided by a tiny alpha.
                guard pixel.w > 0.01 else { continue }
                let straightColor = SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
                histogram[histogramBin(for: straightColor)] += weight
                histogramWeight += weight
            }
        }
        let normalizedHistogram = histogramWeight > 0 ? histogram.map { $0 / histogramWeight } : histogram
        // FaceLayout is expressed in original-image pixels, while `bitmap` is
        // the downscaled analysis copy. Mixing those units made large source
        // images appear to have impossibly wide heads and distorted pair
        // confidence when front/side resolutions differed.
        let headWidthRatio = layout.map {
            Float($0.headRect.width / CGFloat(max(1, input.context.originalImage.width)))
        } ?? 0
        return Metrics(
            faceConfidence: layout?.confidence ?? 0,
            headWidthRatio: headWidthRatio,
            foregroundCoverage: maskedPixelCount / Float(max(1, bitmap.width * bitmap.height)),
            colorHistogram: normalizedHistogram
        )
    }

    /// Maps a straight RGB color (each channel 0...1) to its bin in the
    /// flattened 4x4x4 histogram.
    private static func histogramBin(for straightColor: SIMD3<Float>) -> Int {
        func axisBin(_ value: Float) -> Int {
            min(histogramBinsPerAxis - 1, max(0, Int(min(max(value, 0), 1) * Float(histogramBinsPerAxis))))
        }
        let r = axisBin(straightColor.x)
        let g = axisBin(straightColor.y)
        let b = axisBin(straightColor.z)
        return (r * histogramBinsPerAxis + g) * histogramBinsPerAxis + b
    }
}
