import CoreGraphics
import Foundation
import Vision

/// Face layout from Apple Vision's landmark detection — the auxiliary path for
/// photo-like images. Anime illustrations rarely trigger it, which is fine:
/// returning nil hands arbitration back to `CompositeFaceEstimator`.
public struct VisionFaceEstimator: FaceLayoutEstimating {
    /// Vision confidences on real faces are high; anything below this is more
    /// likely a false positive on stylized art, so we bow out.
    public var minimumObservationConfidence: Float

    public init(minimumObservationConfidence: Float = 0.7) {
        self.minimumObservationConfidence = minimumObservationConfidence
    }

    /// Vision reports the probability that its observation is a face. That is
    /// not the same thing as the quality of the `FaceLayout` we derive from it:
    /// the head rectangle is still only an expanded photo-face box and cannot
    /// see illustration hair or a hidden neck. Compress the accepted Vision
    /// range onto the same conservative layout-quality scale as the anime
    /// heuristic so a marginal photo-model hit does not automatically replace
    /// a stronger illustration result.
    static func calibratedLayoutConfidence(for observationConfidence: Float) -> Float {
        let clamped = min(max(observationConfidence, 0), 1)
        if clamped < 0.7 {
            return clamped * (0.3 / 0.7)
        }
        let normalized = (clamped - 0.7) / 0.3
        return 0.3 + 0.2 * normalized
    }

    public func calibratedConfidence(for layout: FaceLayout) -> Float {
        Self.calibratedLayoutConfidence(for: layout.confidence)
    }

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: context.originalImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        // A selected candidate supplies its own mask. Do not let an unrelated,
        // higher-confidence face elsewhere in the source image win selection.
        let facesInSubject = request.results?.filter { face in
            let centerX = face.boundingBox.midX
            let centerY = 1 - face.boundingBox.midY // Vision bottom-left → mask top-left
            return subjectMask.sample(u: Float(centerX), v: Float(centerY)) >= 0.25
        }
        guard let face = facesInSubject?.max(by: { $0.confidence < $1.confidence }),
              face.confidence >= minimumObservationConfidence,
              let landmarks = face.landmarks else {
            return nil
        }

        let imageWidth = context.originalImage.width
        let imageHeight = context.originalImage.height
        let imageSize = CGSize(width: imageWidth, height: imageHeight)

        /// Vision uses a bottom-left origin; convert to top-left image pixels.
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: CGFloat(imageHeight) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }

        func rect(of region: VNFaceLandmarkRegion2D?) -> CGRect? {
            guard let region, region.pointCount > 0 else { return nil }
            let points = region.pointsInImage(imageSize: imageSize)
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for point in points {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return flip(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }

        let faceRect = flip(VNImageRectForNormalizedRect(face.boundingBox, imageWidth, imageHeight))

        // Vision names eyes from the *subject's* perspective; FaceLayout uses
        // the viewer's. Subject-right appears on the viewer's left.
        guard let viewerLeftEye = rect(of: landmarks.rightEye),
              let viewerRightEye = rect(of: landmarks.leftEye),
              let mouth = rect(of: landmarks.outerLips) else {
            return nil
        }

        // Vision's box hugs the face; grow it to cover hair and reach the neck.
        let headRect = CGRect(
            x: faceRect.minX - faceRect.width * 0.25,
            y: faceRect.minY - faceRect.height * 0.55,
            width: faceRect.width * 1.5,
            height: faceRect.height * 1.75
        )

        func padded(_ rect: CGRect, factor: CGFloat) -> CGRect {
            rect.insetBy(dx: -rect.width * factor, dy: -rect.height * factor)
        }

        return FaceLayout(
            headRect: headRect,
            eyeLeftRect: padded(viewerLeftEye, factor: 0.3),
            eyeRightRect: padded(viewerRightEye, factor: 0.3),
            mouthRect: padded(mouth, factor: 0.25),
            confidence: face.confidence
        )
    }
}
