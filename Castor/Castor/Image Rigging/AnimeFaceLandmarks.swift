import Arils
import Foundation

enum AnimeFaceLandmarksSettingsStore {
    static let enabledKey = "Pomegranate.Arils.AnimeFaceLandmarks.Enabled.v1"
    /// On by default, unlike LaMa: this only changes the face markers the user
    /// already reviews before every build, and it runs inside the app. LaMa
    /// changes the built avatar itself, so it stays opt-in.
    static let defaultEnabled = true

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else {
                return defaultEnabled
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    /// The models are generated rather than checked in, so a build can lack
    /// them; face review then uses the built-in estimator as before.
    static var modelsAreInstalled: Bool { AnimeFaceCoreMLEstimator.isAvailable }

    /// True when face review should say the landmark model took no part:
    /// the setting is on, yet no candidate came from it.
    static func landmarkModelWasMissing(enabled: Bool, candidateSources: [String]) -> Bool {
        enabled && !candidateSources.contains(AnimeFaceCoreMLEstimator.sourceLabel)
    }
}

enum ArilsRiggingPipelines {
    /// Every pipeline the rigging view builds goes through here, so face
    /// review, the Quality pair check, and the archive build all see the same
    /// estimator order and cannot disagree about where the face is.
    static func make(
        occlusionInpainter: (any OcclusionInpaintingProviding)? = nil
    ) -> AutoRigPipeline {
        guard AnimeFaceLandmarksSettingsStore.isEnabled else {
            return AutoRigPipeline(occlusionInpainter: occlusionInpainter)
        }
        return AutoRigPipeline(
            faceEstimator: CompositeFaceEstimator(estimators: [
                AnimeFaceCoreMLEstimator(),
                AnimeFaceEstimator(),
                VisionFaceEstimator(),
            ]),
            occlusionInpainter: occlusionInpainter
        )
    }
}
