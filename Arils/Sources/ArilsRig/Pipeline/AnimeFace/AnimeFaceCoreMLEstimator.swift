import ArilsFaceInference
import CoreGraphics
import Foundation

/// Face layout from the anime face detector and landmark model, in-process on
/// Core ML. Same networks, same steps, and the same calibration as
/// `AnimeFaceServiceEstimator`, without the Python helper.
///
/// Returns nil when the models are not bundled, when no face scores at least
/// `minimumDetectionScore`, or on any error, so `CompositeFaceEstimator` falls
/// through to the heuristic (roadmap 7.1: no ML element without a non-ML
/// fallback).
public struct AnimeFaceCoreMLEstimator: FaceLayoutEstimating {
    public var estimatorSourceLabel: String { Self.sourceLabel }
    public static let sourceLabel = "Anime landmark model"

    /// Whether the compiled models are present in this build.
    public static var isAvailable: Bool { AnimeFaceModels.shared != nil }

    public var minimumDetectionScore: Float

    public init(minimumDetectionScore: Float = 0.5) {
        self.minimumDetectionScore = minimumDetectionScore
    }

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        guard let response = Self.response(for: context.originalImage) else { return nil }
        return AnimeFaceServiceEstimator.layout(from: response, minimumDetectionScore: minimumDetectionScore)
    }

    public func calibratedConfidence(for layout: FaceLayout) -> Float {
        min(max(layout.confidence, 0), 1)
    }

    /// The detector's raw output in the helper's response shape, so both
    /// paths share one conversion and one calibration.
    static func response(for image: CGImage) -> AnimeFaceServiceEstimator.ServiceResponse? {
        guard let models = AnimeFaceModels.shared,
              let face = try? models.detect(image) else { return nil }
        let keypoints = face.keypoints.map { [CGFloat($0.x), CGFloat($0.y), CGFloat($0.score)] }
        let bbox = [face.box.x1, face.box.y1, face.box.x2, face.box.y2].map { CGFloat($0) }
        return AnimeFaceServiceEstimator.ServiceResponse(
            width: CGFloat(image.width),
            height: CGFloat(image.height),
            faces: [.init(bbox: bbox, score: face.score, keypoints: keypoints)]
        )
    }
}
