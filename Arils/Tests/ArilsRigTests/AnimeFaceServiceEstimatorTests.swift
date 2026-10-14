import CoreGraphics
import Foundation
import Testing

@testable import ArilsRig
@testable import ArilsRigPortable

/// A response shaped like the service's, with landmarks laid out on a
/// plausible face so the conversion can be checked without a running server.
private func makeResponse(
    imageSize: CGSize = CGSize(width: 1000, height: 1000),
    faceBox: CGRect = CGRect(x: 400, y: 300, width: 200, height: 220),
    score: Float = 0.99,
    landmarkScore: Float = 0.95,
    keypointCount: Int = AnimeFaceServiceEstimator.Landmarks.count
) -> AnimeFaceServiceEstimator.ServiceResponse {
    var keypoints: [[CGFloat]] = []
    for index in 0..<keypointCount {
        // Outline low, brows high, eyes in the upper half, mouth near the chin.
        let point: CGPoint
        switch index {
        case 0...4:
            point = CGPoint(x: faceBox.minX + CGFloat(index) * faceBox.width / 4, y: faceBox.maxY - 10)
        case 5...10:
            point = CGPoint(x: faceBox.minX + CGFloat(index - 5) * 20 + 20, y: faceBox.minY + 40)
        case 11...16:  // viewer's left eye
            point = CGPoint(x: faceBox.minX + 40 + CGFloat(index - 11) * 6, y: faceBox.minY + 90 + CGFloat((index - 11) % 2) * 8)
        case 17...22:  // viewer's right eye
            point = CGPoint(x: faceBox.minX + 130 + CGFloat(index - 17) * 6, y: faceBox.minY + 90 + CGFloat((index - 17) % 2) * 8)
        case 23:
            point = CGPoint(x: faceBox.midX, y: faceBox.minY + 140)
        default:  // mouth
            point = CGPoint(x: faceBox.midX - 18 + CGFloat(index - 24) * 12, y: faceBox.minY + 175)
        }
        keypoints.append([point.x, point.y, CGFloat(landmarkScore)])
    }
    return AnimeFaceServiceEstimator.ServiceResponse(
        width: imageSize.width,
        height: imageSize.height,
        faces: [.init(bbox: [faceBox.minX, faceBox.minY, faceBox.maxX, faceBox.maxY], score: score, keypoints: keypoints)]
    )
}

@Test func serviceEstimatorRejectsNonLocalhostEndpoints() {
    #expect(AnimeFaceServiceEstimator.isAllowedEndpoint(URL(string: "http://127.0.0.1:8131/v1/face-landmarks")!))
    #expect(AnimeFaceServiceEstimator.isAllowedEndpoint(URL(string: "http://localhost:8131/v1/face-landmarks")!))
    #expect(!AnimeFaceServiceEstimator.isAllowedEndpoint(URL(string: "https://127.0.0.1:8131/v1/face-landmarks")!))
    #expect(!AnimeFaceServiceEstimator.isAllowedEndpoint(URL(string: "http://example.com/v1/face-landmarks")!))
}

@Test func serviceLayoutPlacesPartsInsideTheHeadAndInReadingOrder() throws {
    let response = makeResponse()
    let layout = try #require(AnimeFaceServiceEstimator.layout(from: response, minimumDetectionScore: 0.5))

    // The head rectangle is an expanded face box, so it contains the features.
    #expect(layout.headRect.contains(CGPoint(x: layout.eyeLeftRect.midX, y: layout.eyeLeftRect.midY)))
    #expect(layout.headRect.contains(CGPoint(x: layout.eyeRightRect.midX, y: layout.eyeRightRect.midY)))
    #expect(layout.headRect.contains(CGPoint(x: layout.mouthRect.midX, y: layout.mouthRect.midY)))
    // Eyes above the mouth, and the viewer's left eye left of the right one.
    #expect(layout.eyeLeftRect.midY < layout.mouthRect.midY)
    #expect(layout.eyeRightRect.midY < layout.mouthRect.midY)
    #expect(layout.eyeLeftRect.midX < layout.eyeRightRect.midX)
    // Every rectangle is real and finite.
    for rect in [layout.headRect, layout.eyeLeftRect, layout.eyeRightRect, layout.mouthRect] {
        #expect(rect.width > 0 && rect.height > 0)
        #expect(rect.minX.isFinite && rect.minY.isFinite)
    }
}

@Test func serviceHeadRectangleIsLargerThanTheDetectedFaceBox() throws {
    let faceBox = CGRect(x: 400, y: 300, width: 200, height: 220)
    let layout = try #require(
        AnimeFaceServiceEstimator.layout(from: makeResponse(faceBox: faceBox), minimumDetectionScore: 0.5)
    )
    // The hand-drawn head box includes hair, so the fit expands the face box
    // and sits it higher. Both are what the measured calibration encodes.
    #expect(layout.headRect.width > faceBox.width * 1.5)
    #expect(layout.headRect.height > faceBox.height * 1.5)
    #expect(layout.headRect.midY < faceBox.midY)
}

@Test func serviceLayoutStaysInsideTheImage() throws {
    // A face against the top-left corner: the expanded head box would run off
    // the image, and must be clipped rather than returned with negative origin.
    let response = makeResponse(
        imageSize: CGSize(width: 400, height: 400),
        faceBox: CGRect(x: 10, y: 10, width: 160, height: 170)
    )
    let layout = try #require(AnimeFaceServiceEstimator.layout(from: response, minimumDetectionScore: 0.5))
    for rect in [layout.headRect, layout.eyeLeftRect, layout.eyeRightRect, layout.mouthRect] {
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= 400.001)
        #expect(rect.maxY <= 400.001)
    }
}

@Test func serviceIgnoresWeakDetectionsAndMalformedPayloads() {
    #expect(AnimeFaceServiceEstimator.layout(from: makeResponse(score: 0.2), minimumDetectionScore: 0.5) == nil)
    #expect(AnimeFaceServiceEstimator.layout(from: makeResponse(keypointCount: 20), minimumDetectionScore: 0.5) == nil)
    let noFaces = AnimeFaceServiceEstimator.ServiceResponse(width: 100, height: 100, faces: [])
    #expect(AnimeFaceServiceEstimator.layout(from: noFaces, minimumDetectionScore: 0.5) == nil)
    let zeroSize = AnimeFaceServiceEstimator.ServiceResponse(width: 0, height: 0, faces: [])
    #expect(AnimeFaceServiceEstimator.layout(from: zeroSize, minimumDetectionScore: 0.5) == nil)
}

@Test func serviceConfidenceRisesWithLandmarkQuality() throws {
    let weak = try #require(
        AnimeFaceServiceEstimator.layout(from: makeResponse(landmarkScore: 0.45), minimumDetectionScore: 0.5)
    )
    let strong = try #require(
        AnimeFaceServiceEstimator.layout(from: makeResponse(landmarkScore: 0.98), minimumDetectionScore: 0.5)
    )
    #expect(strong.confidence > weak.confidence)
    #expect(weak.confidence >= 0.4)
    #expect(strong.confidence <= 1.0)
}

@Test func serviceCalibrationIsScaleFree() {
    let calibration = AnimeFaceServiceEstimator.BoxCalibration.head
    let small = calibration.apply(to: CGRect(x: 0, y: 0, width: 100, height: 100))
    let large = calibration.apply(to: CGRect(x: 0, y: 0, width: 200, height: 200))
    // Doubling the source doubles the result; offsets are in source units.
    #expect(abs(large.width - small.width * 2) < 0.001)
    #expect(abs(large.height - small.height * 2) < 0.001)
    #expect(abs(large.midX - small.midX * 2) < 0.001)
    #expect(abs(large.midY - small.midY * 2) < 0.001)
}

@Test func serviceEyeCalibrationKeepsEachEyeOverItsLandmarks() {
    // The landmarks already sit on the eye; calibration only has to grow the
    // box to the lashes. A mean fit skewed by three left/right-swapped labels
    // once shifted both boxes half an eye width toward the nose, so the two
    // eyes overlapped.
    for calibration in [AnimeFaceServiceEstimator.BoxCalibration.eyeLeft, .eyeRight] {
        #expect(abs(calibration.centreOffsetX) < 0.25)
    }
}

@Test func serviceEstimatorReturnsNilWithoutAServer() async {
    // Nothing is listening on this port in tests; the estimator must fail soft
    // so CompositeFaceEstimator falls through to the heuristic.
    let estimator = AnimeFaceServiceEstimator(
        endpoint: URL(string: "http://127.0.0.1:59999/v1/face-landmarks")!,
        timeout: 2
    )
    var bitmap = Bitmap(width: 32, height: 32)
    bitmap.setRGBA(x: 1, y: 1, SIMD4(1, 1, 1, 1))
    guard let image = bitmap.cgImage() else { return }
    let context = AnalysisContext(originalImage: image, analysis: bitmap, originalBitmap: bitmap)
    let layout = await estimator.estimateLayout(
        context: context,
        subjectMask: FloatPlane(width: 32, height: 32, fill: 1)
    )
    #expect(layout == nil)
}

@Test func coreMLEstimatorFailsSoftOnABlankImage() async {
    var bitmap = Bitmap(width: 64, height: 64)
    for y in 0..<64 { for x in 0..<64 { bitmap.setRGBA(x: x, y: y, SIMD4(1, 1, 1, 1)) } }
    guard let image = bitmap.cgImage() else { return }
    let context = AnalysisContext(originalImage: image, analysis: bitmap, originalBitmap: bitmap)
    let layout = await AnimeFaceCoreMLEstimator().estimateLayout(
        context: context, subjectMask: FloatPlane(width: 64, height: 64, fill: 1)
    )
    // With or without the bundled models: a blank image has no face.
    #expect(layout == nil)
}
