import CoreGraphics
import Foundation
import simd
import Testing

@testable import ArilsRig

/// Upper lid (left, top, right) then lower lid (left, bottom, right), as the
/// anime landmark model places them on a 60 px wide eye.
private let landmarks = [
    CGPoint(x: 100, y: 110), CGPoint(x: 130, y: 98), CGPoint(x: 160, y: 108),
    CGPoint(x: 104, y: 124), CGPoint(x: 130, y: 132), CGPoint(x: 156, y: 124),
]

@Test func eyeShapeCoversTheEyeAndFadesOutside() throws {
    let shape = try #require(EyeShape(landmarks: landmarks))
    #expect(shape.coverage(x: 130, y: 115) == 1)        // iris
    #expect(shape.coverage(x: 130, y: 88) > 0.9)        // lashes above the lid
    #expect(shape.coverage(x: 60, y: 115) == 0)         // cheek / temple
    #expect(shape.coverage(x: 130, y: 160) == 0)        // well below the eye
    // The repaint stays inside the fully opaque part.
    for y in stride(from: 70, through: 160, by: 2) {
        for x in stride(from: 70, through: 190, by: 2) where shape.holeContains(x: CGFloat(x), y: CGFloat(y)) {
            #expect(shape.coverage(x: CGFloat(x), y: CGFloat(y)) > 0.999)
        }
    }
}

@Test func eyeShapeIgnoresLandmarkOrderWithinEachLid() throws {
    let shuffled = [landmarks[2], landmarks[0], landmarks[1], landmarks[5], landmarks[3], landmarks[4]]
    #expect(EyeShape(landmarks: shuffled) == EyeShape(landmarks: landmarks))
}

@Test func eyeShapeIsRejectedWhenTheRectNoLongerMatches() {
    let rect = CGRect(x: 70, y: 70, width: 120, height: 90)
    #expect(EyeShape.shape(landmarks: landmarks, within: rect) != nil)
    // A person moved the eye rect in review: the landmarks describe another place.
    #expect(EyeShape.shape(landmarks: landmarks, within: rect.offsetBy(dx: 80, dy: 0)) == nil)
    #expect(EyeShape.shape(landmarks: [], within: rect) == nil)
    #expect(EyeShape(landmarks: Array(repeating: CGPoint(x: 5, y: 5), count: 6)) == nil)
}

@Test func faceLayoutScalingCarriesTheLandmarks() {
    let layout = FaceLayout(
        headRect: .zero, eyeLeftRect: .zero, eyeRightRect: .zero, mouthRect: .zero,
        confidence: 1, eyeLeftLandmarks: landmarks, eyeRightLandmarks: []
    )
    let scaled = layout.scaled(by: 2)
    #expect(scaled.eyeLeftLandmarks.first == CGPoint(x: 200, y: 220))
    #expect(scaled.eyeRightLandmarks.isEmpty)
}

@Test func eyeLayersFollowTheShapeAndTheRepaintStaysInside() {
    // A flat face with one dark eye; with landmarks the eye layer keeps the
    // eye and drops the rect corners, and the head repaint covers only the eye.
    var source = Bitmap(width: 260, height: 220)
    for y in 0..<220 {
        for x in 0..<260 {
            let isEye = ((CGFloat(x) - 130) / 34) * ((CGFloat(x) - 130) / 34)
                + ((CGFloat(y) - 115) / 16) * ((CGFloat(y) - 115) / 16) <= 1
            source.setRGBA(x: x, y: y, isEye ? SIMD4(0.1, 0.1, 0.3, 1) : SIMD4(0.95, 0.85, 0.8, 1))
        }
    }
    let mask = FloatPlane(width: 260, height: 220, fill: 1)
    var plan = PartPlan(
        imageWidth: 260, imageHeight: 220,
        subjectRect: CGRect(x: 0, y: 0, width: 260, height: 220),
        headRect: CGRect(x: 20, y: 20, width: 220, height: 180),
        eyeLeftRect: CGRect(x: 70, y: 70, width: 120, height: 90),
        eyeRightRect: CGRect(x: 200, y: 160, width: 30, height: 20),
        mouthRect: CGRect(x: 120, y: 175, width: 20, height: 10),
        collarHeight: 20
    )
    let rectLayers = LayerFactory.extract(source: source, subjectMask: mask, plan: plan)
    plan.eyeLeftLandmarks = landmarks
    let shapedLayers = LayerFactory.extract(source: source, subjectMask: mask, plan: plan)

    // Rect corner (inside the old rect's opaque interior, far from the eye).
    #expect(rectLayers.eyeLeft.alpha(x: 22, y: 75) > 0.5)
    #expect(shapedLayers.eyeLeft.alpha(x: 22, y: 75) < 0.01)
    #expect(shapedLayers.eyeLeft.alpha(x: 60, y: 45) > 0.99) // the eye itself
    // Head layer: the old ellipse repainted the corner region; the shape does not.
    let headX = 70 + 22 - 20
    let headY = 70 + 75 - 20
    let original = source.rgba(x: 70 + 22, y: 70 + 75)
    #expect(simd_distance(shapedLayers.head.rgba(x: headX, y: headY), original) < 0.02)
}
