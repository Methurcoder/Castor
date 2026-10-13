import CoreGraphics
import Foundation

/// Where the face lives in the source image, in original-image pixels.
///
/// `headRect` is a human/estimator supplied head search region. Layer extraction
/// refines it into a curved subject-aware mask; eye rects are the visible eye units
/// (lashes + iris for anime art), "left" always meaning the *viewer's* left.
public struct FaceLayout: Sendable, Equatable {
    public var headRect: CGRect
    public var eyeLeftRect: CGRect
    public var eyeRightRect: CGRect
    public var mouthRect: CGRect
    /// 0...1 — how readable/trustworthy this layout is on the estimator's
    /// native scale. Downstream review keeps this value; composite arbitration
    /// compares `FaceLayoutEstimating.calibratedConfidence(for:)` instead.
    public var confidence: Float
    /// Eyelid landmarks (three upper, three lower) when the estimator has
    /// them; layer extraction cuts the eyes to their shape instead of the
    /// rectangle. Empty otherwise.
    public var eyeLeftLandmarks: [CGPoint]
    public var eyeRightLandmarks: [CGPoint]

    public init(
        headRect: CGRect,
        eyeLeftRect: CGRect,
        eyeRightRect: CGRect,
        mouthRect: CGRect,
        confidence: Float,
        eyeLeftLandmarks: [CGPoint] = [],
        eyeRightLandmarks: [CGPoint] = []
    ) {
        self.headRect = headRect
        self.eyeLeftRect = eyeLeftRect
        self.eyeRightRect = eyeRightRect
        self.mouthRect = mouthRect
        self.confidence = confidence
        self.eyeLeftLandmarks = eyeLeftLandmarks
        self.eyeRightLandmarks = eyeRightLandmarks
    }

    public func scaled(by factor: CGFloat) -> FaceLayout {
        func scale(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX * factor,
                y: rect.minY * factor,
                width: rect.width * factor,
                height: rect.height * factor
            )
        }
        return FaceLayout(
            headRect: scale(headRect),
            eyeLeftRect: scale(eyeLeftRect),
            eyeRightRect: scale(eyeRightRect),
            mouthRect: scale(mouthRect),
            confidence: confidence,
            eyeLeftLandmarks: eyeLeftLandmarks.map { CGPoint(x: $0.x * factor, y: $0.y * factor) },
            eyeRightLandmarks: eyeRightLandmarks.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
        )
    }
}

/// One face-layout algorithm. The pipeline runs several and arbitrates, so new
/// detectors (an ML anime-face model, say) drop in without touching anything else.
public protocol FaceLayoutEstimating: Sendable {
    /// Layout in *original-image* pixels, or nil if this algorithm found nothing.
    func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout?

    /// Maps estimator-specific confidence onto a common arbitration scale.
    /// The default is identity so existing/custom estimators remain source
    /// compatible. Estimators whose native value means something different
    /// (for example, Vision's face-observation probability) should override it.
    func calibratedConfidence(for layout: FaceLayout) -> Float
}

public extension FaceLayoutEstimating {
    func calibratedConfidence(for layout: FaceLayout) -> Float {
        layout.confidence
    }
}

/// One independently reviewable result from a multi-estimator face search.
/// `calibratedConfidence` is only for arbitration/diagnostics; the layout keeps
/// its estimator-native confidence for readability and UI display.
public struct FaceLayoutCandidate: Sendable, Equatable {
    public var id: String
    public var sourceLabel: String
    public var layout: FaceLayout
    public var calibratedConfidence: Float

    public init(
        id: String,
        sourceLabel: String,
        layout: FaceLayout,
        calibratedConfidence: Float
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.layout = layout
        self.calibratedConfidence = calibratedConfidence
    }
}

/// Optional richer boundary for estimators that can expose competing results.
/// Hosts use this to present alternatives instead of silently accepting a
/// whole-layout winner chosen from incomparable evidence.
public protocol FaceLayoutCandidatesEstimating: FaceLayoutEstimating {
    func estimateCandidates(
        context: AnalysisContext,
        subjectMask: FloatPlane
    ) async -> [FaceLayoutCandidate]

    func preferredCandidate(from candidates: [FaceLayoutCandidate]) -> FaceLayoutCandidate?
}

/// Tries estimators in priority order. A later estimator must beat the current
/// choice by an explicit ratio, rather than merely edging it out on a
/// differently calibrated confidence scale. A minimum-confidence floor keeps
/// garbage out.
public struct CompositeFaceEstimator: FaceLayoutCandidatesEstimating {
    public var estimators: [any FaceLayoutEstimating]
    public var minimumConfidence: Float
    /// Required multiplicative improvement for a later, lower-priority
    /// estimator to replace the current choice.
    public var replacementConfidenceRatio: Float {
        didSet {
            if !replacementConfidenceRatio.isFinite || replacementConfidenceRatio < 1 {
                replacementConfidenceRatio = 1.2
            }
        }
    }

    public init(
        estimators: [any FaceLayoutEstimating],
        minimumConfidence: Float = 0.2,
        replacementConfidenceRatio: Float = 1.2
    ) {
        self.estimators = estimators
        self.minimumConfidence = minimumConfidence
        self.replacementConfidenceRatio = replacementConfidenceRatio.isFinite
            ? max(1, replacementConfidenceRatio)
            : 1.2
    }

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        preferredCandidate(
            from: await estimateCandidates(context: context, subjectMask: subjectMask)
        )?.layout
    }

    public func estimateCandidates(
        context: AnalysisContext,
        subjectMask: FloatPlane
    ) async -> [FaceLayoutCandidate] {
        var candidates: [FaceLayoutCandidate] = []
        for (index, estimator) in estimators.enumerated() {
            guard let layout = await estimator.estimateLayout(
                context: context,
                subjectMask: subjectMask
            ) else { continue }
            let calibratedConfidence = estimator.calibratedConfidence(for: layout)
            guard calibratedConfidence.isFinite,
                  calibratedConfidence >= minimumConfidence else { continue }
            let source = Self.sourceLabel(for: estimator)
            candidates.append(
                FaceLayoutCandidate(
                    id: "\(index)-\(source)",
                    sourceLabel: source,
                    layout: layout,
                    calibratedConfidence: calibratedConfidence
                )
            )
        }
        return candidates
    }

    public func preferredCandidate(
        from candidates: [FaceLayoutCandidate]
    ) -> FaceLayoutCandidate? {
        var best: FaceLayoutCandidate?
        var bestCalibratedConfidence: Float = -.infinity
        let replacementRatio = replacementConfidenceRatio.isFinite
            ? max(1, replacementConfidenceRatio)
            : 1.2
        for candidate in candidates {
            let requiredConfidence = best == nil
                ? -.infinity
                : bestCalibratedConfidence * replacementRatio
            if candidate.calibratedConfidence > requiredConfidence {
                best = candidate
                bestCalibratedConfidence = candidate.calibratedConfidence
            }
        }
        return best
    }

    private static func sourceLabel(for estimator: any FaceLayoutEstimating) -> String {
        switch estimator {
        case is AnimeFaceEstimator:
            return "Illustration heuristic"
        case is VisionFaceEstimator:
            return "Apple Vision"
        case is AnimeFaceCoreMLEstimator:
            return AnimeFaceCoreMLEstimator.sourceLabel
        case is AnimeFaceServiceEstimator:
            return AnimeFaceServiceEstimator.sourceLabel
        default:
            return String(describing: type(of: estimator))
        }
    }
}
