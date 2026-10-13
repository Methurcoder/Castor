import CoreGraphics
import Foundation
import simd
import Testing

@testable import ArilsRig

@Test func compositeUsesCalibratedConfidenceWithoutDiscardingNativeReadability() async throws {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: try #require(bitmap.cgImage()), analysis: bitmap)
    let anime = regressionLayout(marker: 1, confidence: 0.45)
    let vision = regressionLayout(marker: 2, confidence: 1.0)

    let calibratedVision = VisionFaceEstimator.calibratedLayoutConfidence(
        for: vision.confidence
    )
    #expect(abs(calibratedVision - 0.5) < 0.0001)

    let estimator = CompositeFaceEstimator(estimators: [
        RegressionFaceEstimator(layout: anime, calibration: .identity),
        RegressionFaceEstimator(layout: vision, calibration: .visionObservation),
    ])
    let selected = try #require(await estimator.estimateLayout(
        context: context,
        subjectMask: bitmap.alphaPlane()
    ))

    #expect(selected.headRect.minX == 1)
    #expect(selected.confidence == 0.45)
}

@Test func lowerPriorityVisionMustClearTheReplacementMarginAtEveryAcceptedBoundary() async throws {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: try #require(bitmap.cgImage()), analysis: bitmap)
    let anime = regressionLayout(marker: 1, confidence: 0.45)

    for observationConfidence in [Float(0.7), 0.9, 0.99, 1.0] {
        let vision = regressionLayout(marker: 2, confidence: observationConfidence)
        let estimator = CompositeFaceEstimator(estimators: [
            RegressionFaceEstimator(layout: anime, calibration: .identity),
            RegressionFaceEstimator(layout: vision, calibration: .visionObservation),
        ])
        let selected = try #require(await estimator.estimateLayout(
            context: context,
            subjectMask: bitmap.alphaPlane()
        ))
        #expect(selected.headRect.minX == 1)
    }

    var configurable = CompositeFaceEstimator(estimators: [])
    configurable.replacementConfidenceRatio = 0.5
    #expect(configurable.replacementConfidenceRatio == 1.2)
    configurable.replacementConfidenceRatio = .nan
    #expect(configurable.replacementConfidenceRatio == 1.2)
}

@Test func compositeStillFallsBackToCalibratedVisionWhenAnimeEvidenceIsWeak() async throws {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: try #require(bitmap.cgImage()), analysis: bitmap)
    let anime = regressionLayout(marker: 1, confidence: 0.25)
    let vision = regressionLayout(marker: 2, confidence: 0.9)

    let estimator = CompositeFaceEstimator(estimators: [
        RegressionFaceEstimator(layout: anime, calibration: .identity),
        RegressionFaceEstimator(layout: vision, calibration: .visionObservation),
    ])
    let selected = try #require(await estimator.estimateLayout(
        context: context,
        subjectMask: bitmap.alphaPlane()
    ))

    #expect(selected.headRect.minX == 2)
    // Native confidence remains available to QualityPairInspector/readability
    // checks; only the arbitration score is compressed.
    #expect(selected.confidence == 0.9)
}

@Test func compositeExposesEveryAcceptedCandidateForIndependentReview() async throws {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: try #require(bitmap.cgImage()), analysis: bitmap)
    let anime = regressionLayout(marker: 1, confidence: 0.45)
    let vision = regressionLayout(marker: 2, confidence: 1.0)
    let estimator = CompositeFaceEstimator(estimators: [
        RegressionFaceEstimator(layout: anime, calibration: .identity),
        RegressionFaceEstimator(layout: vision, calibration: .visionObservation),
    ])

    let candidates = await estimator.estimateCandidates(
        context: context,
        subjectMask: bitmap.alphaPlane()
    )

    #expect(candidates.count == 2)
    #expect(candidates.map(\.layout.headRect.minX) == [1, 2])
    #expect(candidates.map(\.calibratedConfidence) == [0.45, 0.5])
    #expect(estimator.preferredCandidate(from: candidates)?.layout.headRect.minX == 1)
}

@Test func approvalPolicyRejectsUncalibratedOrUndersizedEvidence() {
    let insufficient = FaceLayoutApprovalPolicy.calibrated(
        minimumConfidence: 0.7,
        datasetFingerprint: "pilot",
        sampleCount: 15,
        falseAcceptRateUpper95: 0
    )
    #expect(insufficient == .manualOnly)

    let unsafe = FaceLayoutApprovalPolicy.calibrated(
        minimumConfidence: 0.7,
        datasetFingerprint: "held-out-v2",
        sampleCount: 100,
        falseAcceptRateUpper95: 0.08
    )
    #expect(unsafe == .manualOnly)

    let calibrated = FaceLayoutApprovalPolicy.calibrated(
        minimumConfidence: 0.7,
        datasetFingerprint: "held-out-v2",
        sampleCount: 100,
        falseAcceptRateUpper95: 0.04
    )
    #expect(calibrated.minimumConfidence == 0.7)
    #expect(calibrated.calibrationSampleCount == 100)
    #expect(calibrated.automaticApprovalEnabled)

    let forged = FaceLayoutApprovalPolicy(
        minimumConfidence: 0.7,
        datasetFingerprint: "held-out-v2",
        calibrationSampleCount: 5,
        falseAcceptRateUpper95: 0
    )
    #expect(!forged.automaticApprovalEnabled)

    let loosened = FaceLayoutApprovalPolicy.calibrated(
        minimumConfidence: 0.7,
        datasetFingerprint: "held-out-v2",
        sampleCount: 10,
        falseAcceptRateUpper95: 0.2,
        minimumSampleCount: 1,
        maximumFalseAcceptRateUpper95: 1
    )
    #expect(loosened == .manualOnly)
}

@Test func headFirstCropMatchesTrainingExporterContract() {
    let crop = HeadFirstFaceGeometry.contextCrop(
        around: CGRect(x: 0, y: 0, width: 20, height: 20),
        imageSize: CGSize(width: 100, height: 80),
        context: 0.5
    )
    #expect(crop == CGRect(x: 0, y: 0, width: 30, height: 30))
}

@Test func headFirstLandmarksRebuildLayoutAndAbstainOnOcclusion() throws {
    let head = CGRect(x: 30, y: 10, width: 140, height: 160)
    let visible = FaceLandmarkSet(
        eyeLeftMinX: VisibleFacePoint(point: CGPoint(x: 65, y: 80)),
        eyeLeftMaxX: VisibleFacePoint(point: CGPoint(x: 90, y: 80)),
        eyeRightMinX: VisibleFacePoint(point: CGPoint(x: 112, y: 80)),
        eyeRightMaxX: VisibleFacePoint(point: CGPoint(x: 138, y: 80)),
        mouthMinX: VisibleFacePoint(point: CGPoint(x: 90, y: 125)),
        mouthMaxX: VisibleFacePoint(point: CGPoint(x: 116, y: 125)),
        mouthTop: VisibleFacePoint(point: CGPoint(x: 103, y: 120)),
        mouthBottom: VisibleFacePoint(point: CGPoint(x: 103, y: 132))
    )
    let layout = try #require(HeadFirstFaceGeometry.layout(
        headRect: head,
        landmarks: visible,
        estimatorConfidence: 0.9
    ))
    #expect(layout.eyeLeftRect.width == 25)
    #expect(layout.eyeRightRect.width == 26)
    #expect(layout.mouthRect == CGRect(x: 90, y: 120, width: 26, height: 12))
    #expect(layout.confidence == 0.9)

    var occluded = visible
    occluded.eyeRightMaxX.visibility = 0
    #expect(HeadFirstFaceGeometry.layout(
        headRect: head,
        landmarks: occluded,
        estimatorConfidence: 0.9
    ) == nil)
}

@Test func fullBodyHeuristicsChangeContinuouslyAroundTheFormerAspectCliff() {
    let below = AnimeFaceEstimator.fullBodyBlend(forSubjectAspect: 2.19)
    let above = AnimeFaceEstimator.fullBodyBlend(forSubjectAspect: 2.21)

    #expect(AnimeFaceEstimator.fullBodyBlend(forSubjectAspect: 2.0) == 0)
    #expect(AnimeFaceEstimator.fullBodyBlend(forSubjectAspect: 2.4) == 1)
    #expect(above > below)
    #expect(above - below < 0.1)
}

@Test func eyePairRescalesFeatureGeometryWithoutShrinkingTheHeadSearchRegion() async throws {
    let bitmap = WideHairFace.bitmap()
    let context = AnalysisContext(originalImage: try #require(bitmap.cgImage()), analysis: bitmap)
    let layout = try #require(await AnimeFaceEstimator().estimateLayout(
        context: context,
        subjectMask: bitmap.alphaPlane()
    ))

    #expect(layout.headRect.width > 240)
    #expect(layout.eyeLeftRect.width < layout.headRect.width * 0.085)
    #expect(layout.eyeRightRect.width < layout.headRect.width * 0.085)

    let actualLeft = SIMD2(Float(layout.eyeLeftRect.midX), Float(layout.eyeLeftRect.midY))
    let actualRight = SIMD2(Float(layout.eyeRightRect.midX), Float(layout.eyeRightRect.midY))
    let actualMouth = SIMD2(Float(layout.mouthRect.midX), Float(layout.mouthRect.midY))
    #expect(simd_distance(actualLeft, WideHairFace.eyeLeftCenter) < 15)
    #expect(simd_distance(actualRight, WideHairFace.eyeRightCenter) < 15)
    #expect(simd_distance(actualMouth, WideHairFace.mouthCenter) < 15)
}

@Test func blackLineMouthBeatsAWideSaturatedCollarRidge() async throws {
    let bitmap = blackMouthWithSaturatedCollar()
    let context = AnalysisContext(originalImage: try #require(bitmap.cgImage()), analysis: bitmap)
    let layout = try #require(await AnimeFaceEstimator().estimateLayout(
        context: context,
        subjectMask: bitmap.alphaPlane()
    ))

    let actualMouth = SIMD2(Float(layout.mouthRect.midX), Float(layout.mouthRect.midY))
    #expect(simd_distance(actualMouth, SIMD2<Float>(100, 112)) < 8)
    #expect(layout.mouthRect.maxY < 116)
}

private enum RegressionCalibration: Sendable {
    case identity
    case visionObservation
}

private struct RegressionFaceEstimator: FaceLayoutEstimating {
    var layout: FaceLayout
    var calibration: RegressionCalibration

    func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        layout
    }

    func calibratedConfidence(for layout: FaceLayout) -> Float {
        switch calibration {
        case .identity:
            layout.confidence
        case .visionObservation:
            VisionFaceEstimator.calibratedLayoutConfidence(for: layout.confidence)
        }
    }
}

private func regressionLayout(marker: CGFloat, confidence: Float) -> FaceLayout {
    FaceLayout(
        headRect: CGRect(x: marker, y: 2, width: 20, height: 20),
        eyeLeftRect: CGRect(x: 5, y: 8, width: 3, height: 2),
        eyeRightRect: CGRect(x: 13, y: 8, width: 3, height: 2),
        mouthRect: CGRect(x: 9, y: 15, width: 4, height: 2),
        confidence: confidence
    )
}

private enum WideHairFace {
    static let eyeLeftCenter = SIMD2<Float>(125, 85)
    static let eyeRightCenter = SIMD2<Float>(175, 85)
    static let mouthCenter = SIMD2<Float>(150, 115)

    static func bitmap() -> Bitmap {
        var bitmap = Bitmap(width: 320, height: 280)
        let skin = SIMD4<Float>(0.98, 0.86, 0.76, 1)
        // Keep this fixture focused on scale contamination: the silhouette is
        // very wide, but no hair/skin color boundary competes with the eyes.
        let hair = skin
        let shirt = SIMD4<Float>(0.45, 0.60, 0.88, 1)
        let eye = SIMD4<Float>(0.10, 0.12, 0.28, 1)
        let mouth = SIMD4<Float>(0.05, 0.05, 0.05, 1)

        fillRect(&bitmap, CGRect(x: 90, y: 150, width: 140, height: 125), color: shirt)
        fillRect(&bitmap, CGRect(x: 145, y: 128, width: 30, height: 30), color: skin)
        fillRect(&bitmap, CGRect(x: 20, y: 10, width: 280, height: 130), color: hair)
        fillEllipse(
            &bitmap,
            center: SIMD2(150, 75),
            radiusX: 62,
            radiusY: 62,
            color: skin
        )
        fillEllipse(&bitmap, center: eyeLeftCenter, radiusX: 11, radiusY: 7, color: eye)
        fillEllipse(&bitmap, center: eyeRightCenter, radiusX: 11, radiusY: 7, color: eye)
        fillEllipse(&bitmap, center: mouthCenter, radiusX: 9, radiusY: 3, color: mouth)
        return bitmap
    }
}

private func blackMouthWithSaturatedCollar() -> Bitmap {
    var bitmap = SyntheticCharacter.bitmap()
    let skin = SIMD4<Float>(0.98, 0.86, 0.76, 1)
    let black = SIMD4<Float>(0.03, 0.03, 0.03, 1)
    let saturatedCollar = SIMD4<Float>(0.95, 0.10, 0.62, 1)

    // Remove the original warm mouth, then draw a compact achromatic line.
    fillEllipse(
        &bitmap,
        center: SyntheticCharacter.mouthCenter,
        radiusX: 11,
        radiusY: 5,
        color: skin
    )
    fillRect(&bitmap, CGRect(x: 93, y: 111, width: 15, height: 3), color: black)
    // Its upper edge is close enough to the expected mouth row to be a strong
    // color-based decoy, but its horizontal ridge continues across the face.
    fillRect(&bitmap, CGRect(x: 55, y: 115, width: 90, height: 6), color: saturatedCollar)
    return bitmap
}

private func fillRect(_ bitmap: inout Bitmap, _ rect: CGRect, color: SIMD4<Float>) {
    let minX = max(0, Int(rect.minX))
    let maxX = min(bitmap.width, Int(rect.maxX))
    let minY = max(0, Int(rect.minY))
    let maxY = min(bitmap.height, Int(rect.maxY))
    guard maxX > minX, maxY > minY else { return }
    for y in minY..<maxY {
        for x in minX..<maxX {
            bitmap.setRGBA(x: x, y: y, color)
        }
    }
}

private func fillEllipse(
    _ bitmap: inout Bitmap,
    center: SIMD2<Float>,
    radiusX: Float,
    radiusY: Float,
    color: SIMD4<Float>
) {
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
            let dx = (Float(x) - center.x) / radiusX
            let dy = (Float(y) - center.y) / radiusY
            if dx * dx + dy * dy <= 1 {
                bitmap.setRGBA(x: x, y: y, color)
            }
        }
    }
}
