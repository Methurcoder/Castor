import CoreGraphics
import Foundation

public struct VisibleFacePoint: Sendable, Equatable {
    public var point: CGPoint
    public var visibility: Float

    public init(point: CGPoint, visibility: Float = 1) {
        self.point = point
        self.visibility = min(max(visibility.isFinite ? visibility : 0, 0), 1)
    }
}

/// Eight visibility-aware points emitted by the head-crop pose model.
/// Eye endpoints preserve viewer-left/viewer-right semantics; the mouth keeps
/// horizontal and vertical extent so it can be reconstructed without a box
/// detector on the full illustration.
public struct FaceLandmarkSet: Sendable, Equatable {
    public var eyeLeftMinX: VisibleFacePoint
    public var eyeLeftMaxX: VisibleFacePoint
    public var eyeRightMinX: VisibleFacePoint
    public var eyeRightMaxX: VisibleFacePoint
    public var mouthMinX: VisibleFacePoint
    public var mouthMaxX: VisibleFacePoint
    public var mouthTop: VisibleFacePoint
    public var mouthBottom: VisibleFacePoint

    public init(
        eyeLeftMinX: VisibleFacePoint,
        eyeLeftMaxX: VisibleFacePoint,
        eyeRightMinX: VisibleFacePoint,
        eyeRightMaxX: VisibleFacePoint,
        mouthMinX: VisibleFacePoint,
        mouthMaxX: VisibleFacePoint,
        mouthTop: VisibleFacePoint,
        mouthBottom: VisibleFacePoint
    ) {
        self.eyeLeftMinX = eyeLeftMinX
        self.eyeLeftMaxX = eyeLeftMaxX
        self.eyeRightMinX = eyeRightMinX
        self.eyeRightMaxX = eyeRightMaxX
        self.mouthMinX = mouthMinX
        self.mouthMaxX = mouthMaxX
        self.mouthTop = mouthTop
        self.mouthBottom = mouthBottom
    }

    public var minimumVisibility: Float {
        [
            eyeLeftMinX, eyeLeftMaxX, eyeRightMinX, eyeRightMaxX,
            mouthMinX, mouthMaxX, mouthTop, mouthBottom,
        ].map(\.visibility).min() ?? 0
    }
}

public enum HeadFirstFaceGeometry {
    /// Matches `tools/export_face_pose.py`: grow each head axis by `context` on
    /// both sides and clamp to the original image.
    public static func contextCrop(
        around headRect: CGRect,
        imageSize: CGSize,
        context: CGFloat = 0.35
    ) -> CGRect {
        guard headRect.width > 0, headRect.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .null }
        let safeContext = min(max(context.isFinite ? context : 0.35, 0), 1)
        let expanded = headRect.insetBy(
            dx: -headRect.width * safeContext,
            dy: -headRect.height * safeContext
        )
        return expanded.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Rebuilds the current rectangle-based `FaceLayout` from pose points in
    /// original-image coordinates. Occluded/missing points abstain instead of
    /// fabricating symmetric eyes.
    public static func layout(
        headRect: CGRect,
        landmarks: FaceLandmarkSet,
        estimatorConfidence: Float,
        minimumVisibility: Float = 0.5
    ) -> FaceLayout? {
        guard headRect.width > 0, headRect.height > 0,
              landmarks.minimumVisibility >= minimumVisibility else { return nil }

        func eyeRect(_ first: VisibleFacePoint, _ second: VisibleFacePoint) -> CGRect {
            let minX = min(first.point.x, second.point.x)
            let maxX = max(first.point.x, second.point.x)
            let width = max(2, maxX - minX)
            let centerY = (first.point.y + second.point.y) * 0.5
            let height = max(2, width * 0.45)
            return CGRect(x: minX, y: centerY - height * 0.5, width: width, height: height)
        }

        let leftEye = eyeRect(landmarks.eyeLeftMinX, landmarks.eyeLeftMaxX)
        let rightEye = eyeRect(landmarks.eyeRightMinX, landmarks.eyeRightMaxX)
        let mouthMinX = min(landmarks.mouthMinX.point.x, landmarks.mouthMaxX.point.x)
        let mouthMaxX = max(landmarks.mouthMinX.point.x, landmarks.mouthMaxX.point.x)
        let mouthMinY = min(landmarks.mouthTop.point.y, landmarks.mouthBottom.point.y)
        let mouthMaxY = max(landmarks.mouthTop.point.y, landmarks.mouthBottom.point.y)
        let mouth = CGRect(
            x: mouthMinX,
            y: mouthMinY,
            width: max(2, mouthMaxX - mouthMinX),
            height: max(2, mouthMaxY - mouthMinY)
        )
        let featureBounds = headRect.insetBy(
            dx: -headRect.width * 0.05,
            dy: -headRect.height * 0.05
        )
        let centers = [leftEye, rightEye, mouth].map { CGPoint(x: $0.midX, y: $0.midY) }
        let eyesAreOrdered = leftEye.midX < rightEye.midX
        let mouthIsBelowEyes = mouth.midY > (leftEye.midY + rightEye.midY) * 0.5
        guard centers.allSatisfy({ featureBounds.contains($0) }),
              eyesAreOrdered,
              mouthIsBelowEyes else {
            return nil
        }
        let confidence = min(
            max(estimatorConfidence.isFinite ? estimatorConfidence : 0, 0),
            landmarks.minimumVisibility
        )
        return FaceLayout(
            headRect: headRect,
            eyeLeftRect: leftEye,
            eyeRightRect: rightEye,
            mouthRect: mouth,
            confidence: confidence
        )
    }
}
