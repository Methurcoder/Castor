import ArilsRigPortable
import Foundation
import PetRuntime
import Testing

/// Windows reviews only the four marker rectangles; what the estimator knew
/// about each eye must survive into the build while that marker is untouched.
@Test func untouchedEyeMarkersKeepTheirLidPointsAndHiddenFlag() {
    let lids = (0..<6).map { CGPoint(x: 40 + CGFloat($0 % 3) * 5, y: 50 + CGFloat($0 / 3) * 6) }
    let estimated = FaceLayout(
        headRect: CGRect(x: 10, y: 10, width: 100, height: 100),
        eyeLeftRect: CGRect(x: 30, y: 40, width: 30, height: 20),
        eyeRightRect: CGRect(x: 70, y: 40, width: 30, height: 20),
        mouthRect: CGRect(x: 50, y: 80, width: 20, height: 8),
        confidence: 0.8,
        eyeLeftLandmarks: lids,
        eyeRightHidden: true
    )
    let markers = LayeredRigging.markers(estimated)
    let carried = LayeredRigging.faceLayout(markers, estimated: estimated)
    #expect(carried.eyeLeftLandmarks == lids)
    #expect(carried.eyeRightHidden)
    #expect(!carried.eyeLeftHidden)

    // A marker the person moved is theirs: rectangle only, nothing hidden.
    var moved = markers
    moved.eyeLeft = moved.eyeLeft.offsetBy(dx: 6, dy: 0)
    moved.eyeRight = moved.eyeRight.offsetBy(dx: 0, dy: 3)
    let edited = LayeredRigging.faceLayout(moved, estimated: estimated)
    #expect(edited.eyeLeftLandmarks.isEmpty)
    #expect(!edited.eyeRightHidden)
    #expect(edited.eyeLeftRect == moved.eyeLeft)
}
