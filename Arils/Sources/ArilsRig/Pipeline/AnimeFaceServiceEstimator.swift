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
    public var estimatorSourceLabel: String { Self.sourceLabel }
    public typealias BoxCalibration = AnimeLandmarkLayout.BoxCalibration
    public typealias Landmarks = AnimeLandmarkLayout.Landmarks

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
        AnimeLandmarkLayout.layout(
            width: response.width, height: response.height,
            faces: response.faces.map { .init(bbox: $0.bbox, score: $0.score, keypoints: $0.keypoints) },
            minimumDetectionScore: minimumDetectionScore
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
