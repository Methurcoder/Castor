import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Face layout from the optional localhost anime landmark service.
///
/// The service (`scripts/anime_face_server.py`) wraps an anime-trained face and
/// 28-point landmark model. It is off unless the user starts it, it binds
/// 127.0.0.1 only, and every failure path returns nil so `CompositeFaceEstimator`
/// falls through to `AnimeFaceEstimator`. Nothing in the pipeline depends on it
/// being present, which is the same arrangement the optional LaMa underpaint and
/// local speech services use.
///
/// Why it exists: measured against the hand-verified set, the shipped heuristic
/// reaches a mean head-rectangle IoU of 0.310 and fails outright on one image,
/// while this path reaches 0.671 on all sixteen. Since `AnimeFaceEstimator`
/// derives its eye and mouth search windows from the head rectangle's width and
/// height, a better head rectangle is expected to carry the other parts with it.
public struct AnimeFaceServiceEstimator: FaceLayoutEstimating {
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

    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8131/v1/face-landmarks")!
    /// How `CompositeFaceEstimator` names candidates from this estimator, so a
    /// host can tell whether the landmark model took part in a proposal.
    public static let sourceLabel = "Anime landmark model (local helper)"

    public var endpoint: URL
    public var timeout: TimeInterval
    /// Face detections below this score are ignored entirely.
    public var minimumDetectionScore: Float

    public init(
        endpoint: URL = AnimeFaceServiceEstimator.defaultEndpoint,
        timeout: TimeInterval = 30,
        minimumDetectionScore: Float = 0.5
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.minimumDetectionScore = minimumDetectionScore
    }

    /// Localhost only, matching the other optional local services. A remote
    /// endpoint would send the user's artwork off the machine.
    public static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = url.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - FaceLayoutEstimating

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        guard Self.isAllowedEndpoint(endpoint),
              let png = Self.pngData(from: context.originalImage) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["image": png.base64EncodedString()])
        guard request.httpBody != nil else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONDecoder().decode(ServiceResponse.self, from: data) else {
            return nil
        }
        return Self.layout(from: payload, minimumDetectionScore: minimumDetectionScore)
    }

    /// The service reports detection probability, which is not the same thing as
    /// "this layout is usable". A confident detection whose landmarks are weak
    /// should not outrank the heuristic, so both are folded in, and the result
    /// stays inside a band that still lets a strong heuristic result compete.
    public func calibratedConfidence(for layout: FaceLayout) -> Float {
        min(max(layout.confidence, 0), 1)
    }

    // MARK: - Pure conversion (unit tested)

    struct ServiceResponse: Decodable {
        struct Face: Decodable {
            var bbox: [CGFloat]
            var score: Float
            var keypoints: [[CGFloat]]
        }
        var width: CGFloat
        var height: CGFloat
        var faces: [Face]
    }

    static func layout(from response: ServiceResponse, minimumDetectionScore: Float) -> FaceLayout? {
        guard response.width > 0, response.height > 0 else { return nil }
        guard let face = response.faces
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

        let bounds = CGRect(x: 0, y: 0, width: response.width, height: response.height)
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

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
