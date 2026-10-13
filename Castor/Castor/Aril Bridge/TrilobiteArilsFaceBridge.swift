import Arils
import simd
import CastorCore

/// Permission-gated conversion from the app's local Vision snapshot into the
/// framework-neutral Arils motion input. No image or landmark points leave the
/// process; only pose/ratio scalars are retained.
enum TrilobiteArilsFaceBridge {
    struct Input: Equatable {
        var gazeTarget: SIMD2<Float>?
        var faceTracking: FaceTrackingInput?
    }

    static func input(from snapshot: TrilobiteInputSnapshot) -> Input {
        guard snapshot.cameraEnabled,
              snapshot.cameraPermission == .granted,
              snapshot.faceDetected else {
            return Input(gazeTarget: nil, faceTracking: nil)
        }

        let gaze = SIMD2<Float>(
            Float(snapshot.gazeX / 14),
            Float(snapshot.gazeY / 9)
        )
        let gazeTarget = simd_clamp(gaze, SIMD2(-1, -1), SIMD2(1, 1))

        guard snapshot.faceLandmarksAvailable else {
            return Input(gazeTarget: gazeTarget, faceTracking: nil)
        }

        return Input(
            gazeTarget: gazeTarget,
            faceTracking: FaceTrackingInput(
                yawDegrees: Float(snapshot.faceYawDegrees),
                pitchDegrees: Float(snapshot.facePitchDegrees),
                rollDegrees: Float(snapshot.faceRollDegrees),
                leftEyeAspectRatio: Float(snapshot.leftEyeAspectRatio),
                rightEyeAspectRatio: Float(snapshot.rightEyeAspectRatio),
                mouthAspectRatio: Float(snapshot.mouthAspectRatio),
                confidence: Float(snapshot.faceTrackingConfidence)
            )
        )
    }

    @MainActor
    static func apply(_ snapshot: TrilobiteInputSnapshot, to engine: CharacterEngine) {
        let input = input(from: snapshot)
        engine.externalGazeTarget = input.gazeTarget
        engine.faceTrackingInput = input.faceTracking
    }

    @MainActor
    static func apply(_ snapshot: TrilobiteInputSnapshot, to engine: QualityCharacterEngine) {
        let input = input(from: snapshot)
        engine.externalGazeTarget = input.gazeTarget
        engine.faceTrackingInput = input.faceTracking
    }
}
