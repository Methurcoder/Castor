import CoreGraphics
import Foundation
import simd
import Testing

@testable import ArilsRig
@testable import ArilsRigPortable
import ArilsPlayer

// MARK: - Hidden eyes

@Test func oneUnreadEyeNextToAClearOneIsHidden() {
    #expect(AnimeLandmarkLayout.hiddenEye(leftEyeScore: 0.56, rightEyeScore: 0.95) == (true, false))
    #expect(AnimeLandmarkLayout.hiddenEye(leftEyeScore: 0.95, rightEyeScore: 0.60) == (false, true))
    // Both weak (a sleeping face): unclear, not hidden.
    #expect(AnimeLandmarkLayout.hiddenEye(leftEyeScore: 0.67, rightEyeScore: 0.82) == (false, false))
    #expect(AnimeLandmarkLayout.hiddenEye(leftEyeScore: 0.90, rightEyeScore: 0.92) == (false, false))
}

@Test func landmarkLayoutMarksTheUnseenEyeAndIgnoresItsScores() throws {
    let box = CGRect(x: 400, y: 300, width: 200, height: 220)
    func keypoints(leftEyeScore: CGFloat) -> [[CGFloat]] {
        (0..<AnimeLandmarkLayout.Landmarks.count).map { index in
            let x = box.minX + CGFloat(index % 7) * 25 + 10
            let y = box.minY + CGFloat(index / 7) * 50 + 20
            let score: CGFloat = AnimeLandmarkLayout.Landmarks.eyeLeft.contains(index) ? leftEyeScore : 0.95
            return [x, y, score]
        }
    }
    func layout(leftEyeScore: CGFloat) -> FaceLayout? {
        AnimeLandmarkLayout.layout(
            width: 1000, height: 1000,
            faces: [.init(bbox: [box.minX, box.minY, box.maxX, box.maxY], score: 0.99,
                          keypoints: keypoints(leftEyeScore: leftEyeScore))],
            minimumDetectionScore: 0.5
        )
    }
    let hidden = try #require(layout(leftEyeScore: 0.5))
    #expect(hidden.eyeLeftHidden)
    #expect(!hidden.eyeRightHidden)
    #expect(hidden.eyeLeftLandmarks.isEmpty)
    #expect(hidden.eyeRightLandmarks.count == 6)
    // The guessed eye does not drag the reading of the rest of the face down.
    let clear = try #require(layout(leftEyeScore: 0.95))
    #expect(!clear.eyeLeftHidden)
    #expect(abs(hidden.confidence - clear.confidence) < 0.001)
}

@Test func aHiddenEyeKeepsTheSourcePixelsAndRepaintsNothing() {
    var source = Bitmap(width: 260, height: 220)
    for y in 0..<220 {
        for x in 0..<260 {
            let isEye = abs(x - 130) < 30 && abs(y - 115) < 12
            source.setRGBA(x: x, y: y, isEye ? SIMD4(0.1, 0.1, 0.3, 1) : SIMD4(0.95, 0.85, 0.8, 1))
        }
    }
    var plan = PartPlan(
        imageWidth: 260, imageHeight: 220,
        subjectRect: CGRect(x: 0, y: 0, width: 260, height: 220),
        headRect: CGRect(x: 20, y: 20, width: 220, height: 180),
        eyeLeftRect: CGRect(x: 90, y: 95, width: 80, height: 40),
        eyeRightRect: CGRect(x: 200, y: 160, width: 30, height: 20),
        mouthRect: CGRect(x: 120, y: 175, width: 20, height: 10),
        collarHeight: 20
    )
    plan.eyeLeftHidden = true
    let layers = LayerFactory.extract(source: source, subjectMask: FloatPlane(width: 260, height: 220, fill: 1), plan: plan)
    let eyeAlpha = (0..<layers.eyeLeft.height).flatMap { y in
        (0..<layers.eyeLeft.width).map { layers.eyeLeft.alpha(x: $0, y: y) }
    }
    #expect(eyeAlpha.allSatisfy { $0 == 0 })
    // The head still shows the dark eye where it was drawn.
    let head = layers.head.rgba(x: 130 - 20, y: 115 - 20)
    #expect(simd_distance(head, source.rgba(x: 130, y: 115)) < 0.02)
}

// MARK: - Vision takes over when the model cannot read the face

private func candidate(_ label: String, confidence: Float, hiddenLeft: Bool = false) -> FaceLayoutCandidate {
    FaceLayoutCandidate(
        id: label,
        sourceLabel: label,
        layout: FaceLayout(
            headRect: CGRect(x: 0, y: 0, width: 20, height: 20),
            eyeLeftRect: CGRect(x: 5, y: 8, width: 3, height: 2),
            eyeRightRect: CGRect(x: 13, y: 8, width: 3, height: 2),
            mouthRect: CGRect(x: 9, y: 15, width: 4, height: 2),
            confidence: confidence,
            eyeLeftHidden: hiddenLeft
        ),
        calibratedConfidence: confidence
    )
}

@Test func visionReplacesTheModelOnlyWhenTheModelReadsWeakly() {
    let estimator = AnimeFirstFaceEstimator()
    let model = AnimeFaceCoreMLEstimator.sourceLabel
    let vision = VisionFaceEstimator.sourceLabel
    let heuristic = AnimeFaceEstimator().estimatorSourceLabel

    // A clear illustration: the model stays, even though Vision also fired.
    #expect(estimator.preferredCandidate(from: [
        candidate(model, confidence: 0.84), candidate(vision, confidence: 1), candidate(heuristic, confidence: 0.4),
    ])?.sourceLabel == model)
    // A photo: the model answers weakly, Vision takes over.
    #expect(estimator.preferredCandidate(from: [
        candidate(model, confidence: 0.76), candidate(vision, confidence: 1), candidate(heuristic, confidence: 0.48),
    ])?.sourceLabel == vision)
    // No model result: Vision before the heuristic, whatever their scores.
    #expect(estimator.preferredCandidate(from: [
        candidate(vision, confidence: 0.7), candidate(heuristic, confidence: 0.9),
    ])?.sourceLabel == vision)
    // Weak, and Vision found nothing: keep the model.
    #expect(estimator.preferredCandidate(from: [
        candidate(model, confidence: 0.6), candidate(heuristic, confidence: 0.45),
    ])?.sourceLabel == model)
    // A profile reads low because of its hidden eye; the model understood it.
    #expect(estimator.preferredCandidate(from: [
        candidate(model, confidence: 0.62, hiddenLeft: true), candidate(vision, confidence: 1),
    ])?.sourceLabel == model)
    #expect(estimator.preferredCandidate(from: [candidate(heuristic, confidence: 0.3)])?.sourceLabel == heuristic)
}

@Test func visionEyeContourBecomesSixLidPoints() throws {
    // An almond eye ring, 40 px wide, as Vision lists it.
    let contour = (0..<8).map { index -> CGPoint in
        let angle = Double(index) / 8 * 2 * .pi
        return CGPoint(x: 100 + 20 * cos(angle), y: 50 + 7 * sin(angle))
    }
    let lids = VisionFaceEstimator.lidLandmarks(fromContour: contour)
    try #require(lids.count == 6)
    for index in 0..<3 {
        #expect(lids[index].x == lids[index + 3].x)
        #expect(lids[index].y < lids[index + 3].y) // upper lid above the lower
    }
    #expect(abs(lids[0].x - 84) < 0.01)
    #expect(abs(lids[1].x - 100) < 0.01)
    #expect(abs(lids[2].x - 116) < 0.01)
    #expect(EyeShape(landmarks: lids) != nil)
    #expect(VisionFaceEstimator.lidLandmarks(fromContour: [CGPoint(x: 1, y: 1)]).isEmpty)
}

// MARK: - Moving irises

/// An eye drawn on skin: white opening, a round iris with a highlight, a
/// dark lash line along the top. Returns the cut eye layer and its lids.
private func syntheticEye(irisRadius: CGFloat = 13) -> (layer: Bitmap, landmarks: [CGPoint]) {
    let width = 90, height = 50
    let center = CGPoint(x: 45, y: 26)
    var layer = Bitmap(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            let dx = (CGFloat(x) + 0.5 - center.x) / 34
            let dy = (CGFloat(y) + 0.5 - center.y) / 13
            let inOpening = dx * dx + dy * dy <= 1
            let lash = dx * dx + dy * dy <= 1.35 && CGFloat(y) < center.y - 9
            let iris = hypot(CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y) <= irisRadius
            let highlight = hypot(CGFloat(x) + 0.5 - (center.x + 4), CGFloat(y) + 0.5 - (center.y - 5)) <= 2.5
            var color = SIMD4<Float>(0.95, 0.84, 0.78, 1) // skin
            if inOpening { color = SIMD4(0.97, 0.97, 0.98, 1) }
            if inOpening && iris { color = SIMD4(0.55, 0.25, 0.45, 1) }
            if inOpening && iris && highlight { color = SIMD4(1, 1, 1, 1) }
            if lash { color = SIMD4(0.12, 0.08, 0.08, 1) }
            layer.setRGBA(x: x, y: y, color)
        }
    }
    let landmarks = [
        CGPoint(x: 15, y: 21), CGPoint(x: 45, y: 13), CGPoint(x: 75, y: 21),
        CGPoint(x: 18, y: 32), CGPoint(x: 45, y: 39), CGPoint(x: 72, y: 32),
    ]
    return (layer, landmarks)
}

private func over(_ top: SIMD4<Float>, _ bottom: SIMD4<Float>) -> SIMD4<Float> {
    top + bottom * (1 - top.w)
}

@Test func splitEyeRecomposesTheOriginalAtRest() throws {
    let eye = syntheticEye()
    let split = try #require(PupilSplit.split(eyeLayer: eye.layer, origin: SIMD2(0, 0), landmarks: eye.landmarks))
    var worst: Float = 0
    for y in 0..<eye.layer.height {
        for x in 0..<eye.layer.width {
            let composite = over(split.overlay.rgba(x: x, y: y), over(split.iris.rgba(x: x, y: y), split.white.rgba(x: x, y: y)))
            let d = simd_reduce_max(abs(composite - eye.layer.rgba(x: x, y: y)))
            worst = max(worst, d)
        }
    }
    // Only the faded outer columns of the iris band may differ, and they
    // are white over white.
    #expect(worst < 0.04)
    #expect(split.travel.x > 3)
    #expect(split.travel.y >= 0)
    // The highlight moves with the iris rather than staying as "white".
    #expect(split.iris.alpha(x: 49, y: 21) > 0.99)
    // Where the iris was, the white layer shows white, not iris.
    let behind = split.white.rgba(x: 45, y: 28)
    #expect(behind.x > 0.85 && behind.y > 0.85)
    // Lashes outside the iris stay with the overlay.
    #expect(split.overlay.alpha(x: 22, y: 15) > 0.99)
}

@Test func anIrisThatFillsTheEyeIsNotSplit() {
    let eye = syntheticEye(irisRadius: 40)
    #expect(PupilSplit.split(eyeLayer: eye.layer, origin: SIMD2(0, 0), landmarks: eye.landmarks) == nil)
}

@Test func splitIrisesGetTheirOwnPartsAndTheEyeStopsSliding() throws {
    var plan = PartPlan(
        imageWidth: 400, imageHeight: 400,
        subjectRect: CGRect(x: 0, y: 0, width: 400, height: 400),
        headRect: CGRect(x: 100, y: 50, width: 200, height: 200),
        eyeLeftRect: CGRect(x: 140, y: 120, width: 50, height: 30),
        eyeRightRect: CGRect(x: 210, y: 120, width: 50, height: 30),
        mouthRect: CGRect(x: 185, y: 190, width: 30, height: 12),
        collarHeight: 20
    )
    plan.eyeLeftPupilTravel = SIMD2(5, 1)
    plan.eyeRightPupilTravel = SIMD2(5, 1)
    let rig = BindingSynthesizer.makeRig(plan: plan)
    #expect(rig.firstPart(ofKind: .eyeLeft)?.id == "eyeLeft")
    let iris = try #require(rig.parts.first { $0.id == BindingSynthesizer.PupilPartID.leftIris })
    let white = try #require(rig.parts.first { $0.id == BindingSynthesizer.PupilPartID.leftWhite })
    let eye = try #require(rig.parts.first { $0.id == "eyeLeft" })
    #expect(white.zOrder < iris.zOrder && iris.zOrder < eye.zOrder)
    func gazeGain(_ part: AvatarPart) -> Float {
        part.deformations.reduce(0) { sum, op in
            if case let .translate(parameter, gainX, _) = op, parameter == .eyeBallX { return sum + gainX }
            return sum
        }
    }
    #expect(abs(gazeGain(iris) - 0.1) < 0.0001)
    #expect(gazeGain(eye) == 0)
    #expect(gazeGain(white) == 0)
    // Without a split the eye keeps following the gaze as one piece.
    let plain = BindingSynthesizer.makeRig(plan: PartPlan(
        imageWidth: 400, imageHeight: 400, subjectRect: plan.subjectRect, headRect: plan.headRect,
        eyeLeftRect: plan.eyeLeftRect, eyeRightRect: plan.eyeRightRect, mouthRect: plan.mouthRect, collarHeight: 20
    ))
    #expect(plain.parts.allSatisfy { $0.id != BindingSynthesizer.PupilPartID.leftIris })
    #expect(gazeGain(try #require(plain.firstPart(ofKind: .eyeLeft))) > 0)
}
