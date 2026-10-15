#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Face layout from the anime face detector's box and 28 landmarks: the
/// calibrated mapping onto the rectangles an annotator would draw. Shared by
/// the in-process models (Core ML on the Mac, ONNX Runtime on Windows) and the
/// optional localhost helper, so every path lands on the same calibration.
public enum AnimeLandmarkLayout {
    /// Maps the service's face box or landmark hull onto the rectangle an
    /// annotator would draw. The offsets are in units of the source box, so the
    /// mapping is scale free.
    ///
    /// Fitted on the sixteen hand-verified images as the median ratio, not the
    /// mean: on the three faces lying sideways the hand labels name the eyes by
    /// screen side and the landmark groups by the character's side, so they are
    /// swapped, and a mean let those three pull both eye boxes half an eye width
    /// toward the nose on every image. Leave-one-out IoU against those labels: head 0.695, mouth
    /// 0.513, eyes 0.52-0.53 (0.35-0.37 with the mean fit). Re-fit with
    /// `Tools/FaceLabels/measure_detector.py` whenever that set grows; the
    /// eye and mouth figures are limited by how consistently a thin feature's
    /// box height is drawn by hand, not by the model's placement, whose centre
    /// error is about a thousandth of the image diagonal.
    public struct BoxCalibration: Sendable, Equatable {
        public var centreOffsetX: CGFloat
        public var centreOffsetY: CGFloat
        public var widthScale: CGFloat
        public var heightScale: CGFloat

        public init(centreOffsetX: CGFloat, centreOffsetY: CGFloat, widthScale: CGFloat, heightScale: CGFloat) {
            self.centreOffsetX = centreOffsetX
            self.centreOffsetY = centreOffsetY
            self.widthScale = max(0.01, widthScale)
            self.heightScale = max(0.01, heightScale)
        }

        public func apply(to source: CGRect) -> CGRect {
            let width = source.width * widthScale
            let height = source.height * heightScale
            let centreX = source.midX + centreOffsetX * source.width
            let centreY = source.midY + centreOffsetY * source.height
            return CGRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height)
        }

        public static let head = BoxCalibration(centreOffsetX: 0.0443, centreOffsetY: -0.3656, widthScale: 1.8395, heightScale: 1.6966)
        public static let eyeLeft = BoxCalibration(centreOffsetX: -0.0720, centreOffsetY: -0.5340, widthScale: 1.9879, heightScale: 2.5747)
        public static let eyeRight = BoxCalibration(centreOffsetX: -0.1256, centreOffsetY: -0.5479, widthScale: 1.8251, heightScale: 2.5383)
        public static let mouth = BoxCalibration(centreOffsetX: -0.0213, centreOffsetY: 0.0404, widthScale: 1.7465, heightScale: 2.6017)
    }

    /// Landmark index groups, per the model's own ordering.
    public enum Landmarks {
        public static let count = 28
        public static let outline = 0...4
        /// Group A is the viewer's left eye. Determined by measurement, not by
        /// assumption: scoring both readings against the hand labels gave a
        /// combined IoU of 0.182 this way and 0.041 the other way.
        public static let eyeLeft = 11...16
        public static let eyeRight = 17...22
        public static let mouth = 24...27
    }

    /// One detection: `bbox` is `[x1, y1, x2, y2]`, `keypoints` are
    /// `[x, y, score]` in source pixels.
    public struct Detection: Sendable {
        public var bbox: [CGFloat]
        public var score: Float
        public var keypoints: [[CGFloat]]

        public init(bbox: [CGFloat], score: Float, keypoints: [[CGFloat]]) {
            self.bbox = bbox
            self.score = score
            self.keypoints = keypoints
        }
    }

    public static func layout(width: CGFloat, height: CGFloat, faces: [Detection], minimumDetectionScore: Float) -> FaceLayout? {
        guard width > 0, height > 0 else { return nil }
        guard let face = faces
            .filter({ $0.score >= minimumDetectionScore })
            .max(by: { $0.score < $1.score }),
            face.bbox.count >= 4,
            face.keypoints.count == Landmarks.count
        else { return nil }

        let points = face.keypoints.compactMap { entry -> (point: CGPoint, score: Float)? in
            guard entry.count >= 2, entry[0].isFinite, entry[1].isFinite else { return nil }
            return (CGPoint(x: entry[0], y: entry[1]), entry.count > 2 ? Float(entry[2]) : 1)
        }
        guard points.count == Landmarks.count else { return nil }

        let faceBox = CGRect(
            x: face.bbox[0], y: face.bbox[1],
            width: face.bbox[2] - face.bbox[0],
            height: face.bbox[3] - face.bbox[1]
        )
        guard faceBox.width > 1, faceBox.height > 1 else { return nil }

        func hull(_ range: ClosedRange<Int>) -> CGRect? {
            let selected = points[range.clamped(to: 0...(points.count - 1))].map(\.point)
            guard let first = selected.first else { return nil }
            var rect = CGRect(origin: first, size: .zero)
            for point in selected.dropFirst() {
                rect = rect.union(CGRect(origin: point, size: .zero))
            }
            // A perfectly flat hull (a closed eye, a straight mouth) has zero
            // height; give it a floor so the calibration has something to scale.
            return CGRect(
                x: rect.minX, y: rect.minY,
                width: max(rect.width, 1), height: max(rect.height, 1)
            )
        }
        guard let eyeLeftHull = hull(Landmarks.eyeLeft),
              let eyeRightHull = hull(Landmarks.eyeRight),
              let mouthHull = hull(Landmarks.mouth) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func clamped(_ rect: CGRect) -> CGRect { rect.intersection(bounds) }

        let head = clamped(BoxCalibration.head.apply(to: faceBox))
        guard head.width > 1, head.height > 1 else { return nil }

        let landmarkScore = points.map(\.score).reduce(0, +) / Float(points.count)
        let weakest = points.map(\.score).min() ?? 0
        // Detection probability saturates near 1 on almost anything face-like,
        // so it only gates; the landmark scores carry the actual signal about
        // whether the features were readable.
        let quality = 0.45 + 0.35 * min(max((landmarkScore - 0.5) / 0.5, 0), 1)
            + 0.10 * min(max((weakest - 0.3) / 0.7, 0), 1)

        return FaceLayout(
            headRect: head,
            eyeLeftRect: clamped(BoxCalibration.eyeLeft.apply(to: eyeLeftHull)),
            eyeRightRect: clamped(BoxCalibration.eyeRight.apply(to: eyeRightHull)),
            mouthRect: clamped(BoxCalibration.mouth.apply(to: mouthHull)),
            confidence: min(max(quality, 0), 1),
            eyeLeftLandmarks: Landmarks.eyeLeft.map { points[$0].point },
            eyeRightLandmarks: Landmarks.eyeRight.map { points[$0].point }
        )
    }
}
