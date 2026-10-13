import CoreGraphics
import Foundation
import simd

/// Which side of the character is represented by the second reference image.
public enum QualitySideDirection: String, Codable, Sendable {
    case left
    case right
}

public enum QualityPresentationMode: String, Codable, Sendable {
    case twoD
    case threeD
}

/// A user-visible caveat produced before building a two-view character.
public enum QualityPairWarning: Codable, Equatable, Sendable {
    // Case name kept as `expressionNotReliable` for backward compatibility
    // with persisted archives (the identifier is part of the encoded
    // format); the associated confidence is face (eye/mouth) detection
    // confidence, not an expression-difference measurement — see `message`.
    case expressionNotReliable(confidence: Float)
    case possibleDifferentCharacter(fileName: String, probability: Float)

    public var message: String {
        switch self {
        case let .expressionNotReliable(confidence):
            return "顔（目・口）をはっきり読み取れない画像があります（検出信頼度: \(Self.percent(confidence))%）。リギング結果を確認してください。"
        case let .possibleDifferentCharacter(fileName, probability):
            return "同一人物ではない可能性のある画像（\(fileName)）が混ざっています（可能性: \(Self.percent(probability))%）。"
        }
    }

    private static func percent(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }
}

/// Confidence report for a front/profile reference pair. It is deliberately a
/// conservative heuristic: it reports uncertainty instead of claiming that
/// two illustrations are definitely the same character.
public struct QualityPairAssessment: Codable, Equatable, Sendable {
    public var sameCharacterConfidence: Float
    /// Minimum of the front/side face (eye/mouth) detection confidence. This
    /// is a readability measurement, not an evaluation of expression
    /// difference between the two images — Quality has no expression-variant
    /// switching (see README).
    public var faceReadabilityConfidence: Float
    public var warnings: [QualityPairWarning]

    public init(
        sameCharacterConfidence: Float,
        faceReadabilityConfidence: Float,
        warnings: [QualityPairWarning]
    ) {
        self.sameCharacterConfidence = sameCharacterConfidence
        self.faceReadabilityConfidence = faceReadabilityConfidence
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case sameCharacterConfidence
        case faceReadabilityConfidence
        case expressionConfidence
        case warnings
    }

    // Backward compatible with archives encoded before the
    // `expressionConfidence` -> `faceReadabilityConfidence` rename: reads the
    // old key if the new one is absent. Always encodes the new key only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sameCharacterConfidence = try container.decode(Float.self, forKey: .sameCharacterConfidence)
        if let renamed = try container.decodeIfPresent(Float.self, forKey: .faceReadabilityConfidence) {
            faceReadabilityConfidence = renamed
        } else {
            faceReadabilityConfidence = try container.decode(Float.self, forKey: .expressionConfidence)
        }
        warnings = try container.decode([QualityPairWarning].self, forKey: .warnings)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sameCharacterConfidence, forKey: .sameCharacterConfidence)
        try container.encode(faceReadabilityConfidence, forKey: .faceReadabilityConfidence)
        try container.encode(warnings, forKey: .warnings)
    }
}

/// Alignment metadata for rendering two independently rigged views in one
/// coordinate space. Both points are normalized image coordinates at the neck
/// pivot; `sideScale` makes the two heads agree in apparent size.
public struct QualityViewRegistration: Codable, Equatable, Sendable {
    public var frontNeck: SIMD2<Float>
    public var sideNeck: SIMD2<Float>
    public var sideScale: Float

    public init(frontNeck: SIMD2<Float>, sideNeck: SIMD2<Float>, sideScale: Float) {
        self.frontNeck = frontNeck
        self.sideNeck = sideNeck
        self.sideScale = sideScale
    }

    static func automatic(front: AvatarRig, side: AvatarRig) -> QualityViewRegistration {
        func neck(for rig: AvatarRig) -> (point: SIMD2<Float>, headWidth: Float) {
            let imageWidth = Float(max(1, rig.imageWidth))
            let imageHeight = Float(max(1, rig.imageHeight))
            guard let head = rig.firstPart(ofKind: .head) else {
                return (SIMD2(0.5, 0.5), imageWidth * 0.4)
            }
            return (
                SIMD2(head.pivotInImage.x / imageWidth, head.pivotInImage.y / imageHeight),
                Float(head.rect.width)
            )
        }
        let frontMetrics = neck(for: front)
        let sideMetrics = neck(for: side)
        return QualityViewRegistration(
            frontNeck: frontMetrics.point,
            sideNeck: sideMetrics.point,
            sideScale: min(max(frontMetrics.headWidth / max(1, sideMetrics.headWidth), 0.45), 2.2)
        )
    }
}

/// Persistent two-view asset. Rendering support can evolve independently while
/// old one-view `AvatarArchive` files remain fully compatible.
public struct QualityAvatarArchive: Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var front: AvatarArchive
    public var side: AvatarArchive
    public var sideDirection: QualitySideDirection
    public var registration: QualityViewRegistration
    public var assessment: QualityPairAssessment
    /// Saved user choice. Archives that predate this field retain their
    /// original 2D cross-fade instead of silently changing visual behavior.
    public var preferredPresentationMode: QualityPresentationMode

    public init(
        front: AvatarArchive,
        side: AvatarArchive,
        sideDirection: QualitySideDirection,
        registration: QualityViewRegistration? = nil,
        assessment: QualityPairAssessment,
        preferredPresentationMode: QualityPresentationMode = .threeD
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.front = front
        self.side = side
        self.sideDirection = sideDirection
        self.registration = registration ?? .automatic(front: front.rig, side: side.rig)
        self.assessment = assessment
        self.preferredPresentationMode = preferredPresentationMode
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, front, side, sideDirection, registration, assessment
        case preferredPresentationMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        front = try container.decode(AvatarArchive.self, forKey: .front)
        side = try container.decode(AvatarArchive.self, forKey: .side)
        sideDirection = try container.decode(QualitySideDirection.self, forKey: .sideDirection)
        registration = try container.decode(QualityViewRegistration.self, forKey: .registration)
        assessment = try container.decode(QualityPairAssessment.self, forKey: .assessment)
        preferredPresentationMode = try container.decodeIfPresent(
            QualityPresentationMode.self,
            forKey: .preferredPresentationMode
        ) ?? .twoD
    }

    public func data() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try PropertyListDecoder().decode(QualityAvatarArchive.self, from: data)
    }
}

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
