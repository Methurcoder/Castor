import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public nonisolated struct TrilobiteInputSnapshot: Sendable {
    public var cameraEnabled: Bool
    public var microphoneEnabled: Bool
    public var cameraPermission: TrilobitePermissionState
    public var microphonePermission: TrilobitePermissionState
    public var audioLevel: Double
    public var faceDetected: Bool
    public var faceBoundingBox: CGRect?
    public var gazeX: Double
    public var gazeY: Double
    public var faceArea: Double
    public var faceYawDegrees: Double
    public var facePitchDegrees: Double
    public var faceRollDegrees: Double
    public var leftEyeAspectRatio: Double
    public var rightEyeAspectRatio: Double
    public var mouthAspectRatio: Double
    public var faceTrackingConfidence: Double
    public var faceLandmarksAvailable: Bool
    /// Exponentially smoothed wall-clock cost of the local Vision request.
    public var faceAnalysisDurationMilliseconds: Double
    public var updatedAt: Date

    public var isListening: Bool {
        microphoneEnabled && audioLevel > 0.18
    }

    public var faceIsClose: Bool {
        faceDetected && faceArea > 0.22
    }

    /// The request is scheduled at 7 Hz; this reports whether its measured
    /// wall-clock cost still fits inside one scheduling interval.
    public var faceAnalysisFitsSevenHertzBudget: Bool {
        faceAnalysisDurationMilliseconds == 0
            || faceAnalysisDurationMilliseconds <= 1_000 / TrilobiteFaceMetrics.targetAnalysisHertz
    }

    public static let inactive = TrilobiteInputSnapshot(
        cameraEnabled: false,
        microphoneEnabled: false,
        cameraPermission: .notDetermined,
        microphonePermission: .notDetermined,
        audioLevel: 0,
        faceDetected: false,
        faceBoundingBox: nil,
        gazeX: 0,
        gazeY: 0,
        faceArea: 0,
        faceYawDegrees: 0,
        facePitchDegrees: 0,
        faceRollDegrees: 0,
        leftEyeAspectRatio: 0,
        rightEyeAspectRatio: 0,
        mouthAspectRatio: 0,
        faceTrackingConfidence: 0,
        faceLandmarksAvailable: false,
        faceAnalysisDurationMilliseconds: 0,
        updatedAt: .now
    )

    public init(
        cameraEnabled: Bool,
        microphoneEnabled: Bool,
        cameraPermission: TrilobitePermissionState,
        microphonePermission: TrilobitePermissionState,
        audioLevel: Double,
        faceDetected: Bool,
        faceBoundingBox: CGRect? = nil,
        gazeX: Double,
        gazeY: Double,
        faceArea: Double,
        faceYawDegrees: Double,
        facePitchDegrees: Double,
        faceRollDegrees: Double,
        leftEyeAspectRatio: Double,
        rightEyeAspectRatio: Double,
        mouthAspectRatio: Double,
        faceTrackingConfidence: Double,
        faceLandmarksAvailable: Bool,
        faceAnalysisDurationMilliseconds: Double,
        updatedAt: Date
    ) {
        self.cameraEnabled = cameraEnabled
        self.microphoneEnabled = microphoneEnabled
        self.cameraPermission = cameraPermission
        self.microphonePermission = microphonePermission
        self.audioLevel = audioLevel
        self.faceDetected = faceDetected
        self.faceBoundingBox = faceBoundingBox
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.faceArea = faceArea
        self.faceYawDegrees = faceYawDegrees
        self.facePitchDegrees = facePitchDegrees
        self.faceRollDegrees = faceRollDegrees
        self.leftEyeAspectRatio = leftEyeAspectRatio
        self.rightEyeAspectRatio = rightEyeAspectRatio
        self.mouthAspectRatio = mouthAspectRatio
        self.faceTrackingConfidence = faceTrackingConfidence
        self.faceLandmarksAvailable = faceLandmarksAvailable
        self.faceAnalysisDurationMilliseconds = faceAnalysisDurationMilliseconds
        self.updatedAt = updatedAt
    }
}

public nonisolated enum TrilobiteFaceMetrics {
    public static let targetAnalysisHertz = 7.0

    /// Landmark contour bounding-height / bounding-width. This is invariant
    /// to the face observation's image-space scale and is shared by eyes and
    /// outer lips.
    public static func aspectRatio(points: [CGPoint]) -> Double {
        guard points.count >= 2 else {
            return 0
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return 0
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, width.isFinite, height.isFinite else {
            return 0
        }
        return max(0, Double(height / width))
    }
}

public nonisolated enum TrilobitePermissionState: String, Sendable {
    case notDetermined
    case granted
    case denied

    public var label: String {
        switch self {
        case .notDetermined:
            "not determined"
        case .granted:
            "granted"
        case .denied:
            "denied"
        }
    }
}
