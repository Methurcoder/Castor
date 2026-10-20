import CoreGraphics
import Foundation
import Testing

@testable import ArilsRig
@testable import ArilsRigPortable

/// A mochi: a light oval body with a dark outline, two dark dot eyes with a
/// highlight, a pink mouth between and below them, pink cheeks outside.
private func mochi(body: SIMD4<Float> = SIMD4(0.98, 0.95, 0.9, 1), eyes: Bool = true) -> (Bitmap, FloatPlane) {
    let width = 240, height = 160
    var bitmap = Bitmap(width: width, height: height)
    var mask = FloatPlane(width: width, height: height)
    func inEllipse(_ x: Int, _ y: Int, _ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float) -> Float {
        let dx = (Float(x) + 0.5 - cx) / rx, dy = (Float(y) + 0.5 - cy) / ry
        return dx * dx + dy * dy
    }
    for y in 0..<height {
        for x in 0..<width {
            let d = inEllipse(x, y, 120, 85, 100, 65)
            guard d <= 1 else {
                bitmap.setRGBA(x: x, y: y, SIMD4(0.93, 0.9, 0.88, 1))
                continue
            }
            mask[x, y] = 1
            var color = d > 0.9 ? SIMD4<Float>(0.35, 0.22, 0.18, 1) : body
            if inEllipse(x, y, 70, 92, 12, 8) <= 1 || inEllipse(x, y, 170, 92, 12, 8) <= 1 {
                color = SIMD4(0.98, 0.78, 0.78, 1) // cheeks
            }
            if eyes {
                for cx: Float in [90, 150] where inEllipse(x, y, cx, 75, 8, 9) <= 1 {
                    color = inEllipse(x, y, cx - 2, 72, 2.5, 2.5) <= 1 ? SIMD4(1, 1, 1, 1) : SIMD4(0.25, 0.15, 0.12, 1)
                }
                if inEllipse(x, y, 120, 92, 7, 5) <= 1 { color = SIMD4(0.9, 0.5, 0.5, 1) }
            }
            bitmap.setRGBA(x: x, y: y, color)
        }
    }
    return (bitmap, mask)
}

@Test func dotEyesAndMouthOfAMascotAreFound() throws {
    let (bitmap, mask) = mochi()
    let layout = try #require(MascotFaceEstimator.layout(
        bitmap: bitmap, subjectMask: mask, scaleToOriginal: 2, imageWidth: 480, imageHeight: 320
    ))
    // Source pixels are twice the analysis pixels.
    #expect(layout.eyeLeftRect.contains(CGPoint(x: 180, y: 150)))
    #expect(layout.eyeRightRect.contains(CGPoint(x: 300, y: 150)))
    #expect(layout.mouthRect.contains(CGPoint(x: 240, y: 184)))
    #expect(!layout.mouthRect.contains(CGPoint(x: 140, y: 184))) // not a cheek
    #expect(layout.headRect.contains(layout.mouthRect))
    #expect(layout.eyeLeftLandmarks.count == 6 && layout.eyeRightLandmarks.count == 6)
    #expect(layout.confidence > 0.6)
}

@Test func aMascotWithoutDotEyesOrOnADarkBodyIsLeftToOthers() {
    let (blank, blankMask) = mochi(eyes: false)
    #expect(MascotFaceEstimator.layout(bitmap: blank, subjectMask: blankMask, scaleToOriginal: 1,
                                       imageWidth: 240, imageHeight: 160) == nil)
    // The same face on a tall figure belongs to the other estimators.
    let (face, faceMask) = mochi()
    var tall = Bitmap(width: 240, height: 480)
    var tallMask = FloatPlane(width: 240, height: 480)
    for y in 0..<160 { for x in 0..<240 { tall.setRGBA(x: x, y: y, face.rgba(x: x, y: y)); tallMask[x, y] = faceMask[x, y] } }
    for y in 150..<480 { for x in 80..<160 { tall.setRGBA(x: x, y: y, SIMD4(0.5, 0.5, 0.7, 1)); tallMask[x, y] = 1 } }
    #expect(MascotFaceEstimator.layout(bitmap: tall, subjectMask: tallMask, scaleToOriginal: 1,
                                       imageWidth: 240, imageHeight: 480) == nil)
    let (dark, darkMask) = mochi(body: SIMD4(0.2, 0.2, 0.22, 1))
    #expect(MascotFaceEstimator.layout(bitmap: dark, subjectMask: darkMask, scaleToOriginal: 1,
                                       imageWidth: 240, imageHeight: 160) == nil)
}

@Test func theMascotEstimatorComesAfterTheModelAndVisionButBeforeTheHeuristic() {
    func candidate(_ label: String, _ confidence: Float) -> FaceLayoutCandidate {
        FaceLayoutCandidate(id: label, sourceLabel: label, layout: FaceLayout(
            headRect: CGRect(x: 0, y: 0, width: 20, height: 20), eyeLeftRect: CGRect(x: 5, y: 8, width: 3, height: 2),
            eyeRightRect: CGRect(x: 13, y: 8, width: 3, height: 2), mouthRect: CGRect(x: 9, y: 15, width: 4, height: 2),
            confidence: confidence), calibratedConfidence: confidence)
    }
    let estimator = AnimeFirstFaceEstimator()
    let mascot = MascotFaceEstimator.sourceLabel
    let heuristic = AnimeFaceEstimator().estimatorSourceLabel
    #expect(estimator.preferredCandidate(from: [candidate(mascot, 0.6), candidate(heuristic, 0.9)])?.sourceLabel == mascot)
    #expect(estimator.preferredCandidate(from: [
        candidate(AnimeFaceCoreMLEstimator.sourceLabel, 0.6), candidate(mascot, 0.7),
    ])?.sourceLabel == AnimeFaceCoreMLEstimator.sourceLabel)
    #expect(estimator.preferredCandidate(from: [
        candidate(VisionFaceEstimator.sourceLabel, 0.9), candidate(mascot, 0.7),
    ])?.sourceLabel == VisionFaceEstimator.sourceLabel)
}
