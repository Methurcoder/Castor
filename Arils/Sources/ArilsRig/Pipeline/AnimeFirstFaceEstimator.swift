import CoreGraphics
import Foundation

/// The anime landmark model leads; Apple Vision takes over when the model
/// cannot read the face.
///
/// `CompositeFaceEstimator` ranks every estimator on one confidence scale,
/// which leaves photos and unusual proportions with the worst of both: the
/// anime model still answers on a photo, just weakly, and when it finds
/// nothing the illustration heuristic usually outranks Vision's deliberately
/// compressed score. Here the order is a decision instead of a contest:
///
/// 1. the anime model, when it found a face and read it well;
/// 2. otherwise Apple Vision, when it found a face in the subject;
/// 3. otherwise whatever the model found, however weak;
/// 4. otherwise the illustration heuristic.
///
/// Every result is still returned as a candidate, so face review can switch
/// back to any of them.
public struct AnimeFirstFaceEstimator: FaceLayoutCandidatesEstimating {
    /// Below this the model's reading counts as weak. Every upright, open-eyed
    /// illustration in the project set reads 0.81 or higher; a studio portrait
    /// photo reads 0.76. Sleeping and sideways faces also fall below it, but
    /// Vision rarely finds those, so they keep the model's result.
    public static let weakModelConfidence: Float = 0.80

    public var model: any FaceLayoutEstimating
    public var vision: any FaceLayoutEstimating
    public var heuristic: any FaceLayoutEstimating
    public var weakModelConfidence: Float

    public init(
        model: any FaceLayoutEstimating = AnimeFaceCoreMLEstimator(),
        vision: any FaceLayoutEstimating = VisionFaceEstimator(),
        heuristic: any FaceLayoutEstimating = AnimeFaceEstimator(),
        weakModelConfidence: Float = AnimeFirstFaceEstimator.weakModelConfidence
    ) {
        self.model = model
        self.vision = vision
        self.heuristic = heuristic
        self.weakModelConfidence = weakModelConfidence
    }

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        preferredCandidate(from: await estimateCandidates(context: context, subjectMask: subjectMask))?.layout
    }

    public func estimateCandidates(context: AnalysisContext, subjectMask: FloatPlane) async -> [FaceLayoutCandidate] {
        var candidates: [FaceLayoutCandidate] = []
        for (index, estimator) in [model, vision, heuristic].enumerated() {
            guard let layout = await estimator.estimateLayout(context: context, subjectMask: subjectMask) else { continue }
            let calibrated = estimator.calibratedConfidence(for: layout)
            guard calibrated.isFinite, calibrated > 0 else { continue }
            candidates.append(FaceLayoutCandidate(
                id: "\(index)-\(estimator.estimatorSourceLabel)",
                sourceLabel: estimator.estimatorSourceLabel,
                layout: layout,
                calibratedConfidence: calibrated
            ))
        }
        return candidates
    }

    public func preferredCandidate(from candidates: [FaceLayoutCandidate]) -> FaceLayoutCandidate? {
        let fromModel = candidates.first { $0.sourceLabel == model.estimatorSourceLabel }
        let fromVision = candidates.first { $0.sourceLabel == vision.estimatorSourceLabel }
        if let fromModel, !isWeak(fromModel.layout) { return fromModel }
        if let fromVision { return fromVision }
        return fromModel ?? candidates.first { $0.sourceLabel == heuristic.estimatorSourceLabel }
    }

    /// A face with one eye hidden reads low because of that eye alone; the
    /// model has understood it, and Vision would invent the missing eye.
    func isWeak(_ layout: FaceLayout) -> Bool {
        layout.confidence < weakModelConfidence && !layout.eyeLeftHidden && !layout.eyeRightHidden
    }
}
