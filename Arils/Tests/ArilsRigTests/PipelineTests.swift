import CoreGraphics
import Foundation
import simd
import Testing

import ArilsCore

@Test func sideMaskProducesNormalizedThicknessByRow() {
    var mask = FloatPlane(width: 10, height: 3)
    for x in 2...7 { mask[x, 1] = 1 }
    let profile = ThicknessProfile.fromSideMask(mask)
    #expect(profile.rows == [0, 0.6, 0])
    #expect(abs(profile.sample(v: 0.5) - 0.6) < 0.001)
}

@Test func thicknessProfileAlignmentMapsRegisteredNecksToTheSameRow() {
    let profile = ThicknessProfile(rows: [0, 0.25, 0.5, 0.75, 1])
    let registration = QualityViewRegistration(
        frontNeck: SIMD2(0.5, 0.5),
        sideNeck: SIMD2(0.5, 0.75),
        sideScale: 1
    )
    let aligned = profile.alignedToFront(
        rowCount: 5,
        frontImageHeight: 100,
        sideImageHeight: 100,
        registration: registration
    )
    #expect(abs(aligned.rows[2] - 0.75) < 0.001)
}

@Test func silhouetteDepthIsZeroOutsideAndRisesSymmetricallyInward() {
    var front = FloatPlane(width: 9, height: 3)
    for x in 1...7 { front[x, 1] = 1 }
    let depth = SilhouetteDepthEstimator(defaultThickness: 0.4).estimate(frontMask: front, sideThickness: nil)
    #expect(depth[0, 1] == 0)
    #expect(depth[1, 1] == 0)
    #expect(depth[4, 1] > depth[3, 1])
    #expect(abs(depth[2, 1] - depth[6, 1]) < 0.0001)
    #expect(abs(depth[3, 1] - depth[5, 1]) < 0.0001)
}

@Test func faceAwareRibbonForcesTheCompleteSilhouetteBoundaryToZeroDepth() {
    var mask = FloatPlane(width: 32, height: 32)
    for y in 3...28 {
        for x in 4...27 { mask[x, y] = 1 }
    }
    var source = Bitmap(width: 32, height: 32)
    for y in 3...28 {
        for x in 4...27 { source.setRGBA(x: x, y: y, SIMD4(0.9, 0.75, 0.65, 1)) }
    }
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 4, y: 3, width: 24, height: 26),
            eyeLeftRect: CGRect(x: 9, y: 12, width: 4, height: 3),
            eyeRightRect: CGRect(x: 19, y: 12, width: 4, height: 3),
            mouthRect: CGRect(x: 14, y: 21, width: 4, height: 2),
            confidence: 1
        ),
        subjectMask: mask,
        imageWidth: 32,
        imageHeight: 32
    )
    let thickness = ThicknessProfile(rows: [Float](repeating: 0.5, count: 32))
    let baseline = SilhouetteDepthEstimator().estimate(frontMask: mask, sideThickness: thickness)
    let estimator = FaceAwareRibbonDepthEstimator()
    let ribbon = estimator.estimate(frontMask: mask, sideThickness: thickness, plan: plan, source: source)

    #expect(baseline[16, 3] > 0.1)
    #expect(ribbon[16, 3] == 0)
    let baselineMetric = estimator.diagnostics(depth: baseline, frontMask: mask, plan: plan, source: source)
    let ribbonMetric = estimator.diagnostics(depth: ribbon, frontMask: mask, plan: plan, source: source)
    #expect(ribbonMetric.boundaryDepth < baselineMetric.boundaryDepth * 0.2)
}

@Test func faceAwareRibbonPlacesAnInferredFringeInFrontOfTheLocalFaceSurface() {
    var mask = FloatPlane(width: 32, height: 32)
    var skin = Bitmap(width: 32, height: 32)
    var fringe = Bitmap(width: 32, height: 32)
    for y in 3...28 {
        for x in 4...27 {
            mask[x, y] = 1
            let color = SIMD4<Float>(0.88, 0.70, 0.60, 1)
            skin.setRGBA(x: x, y: y, color)
            fringe.setRGBA(x: x, y: y, color)
        }
    }
    for y in 6...10 {
        for x in 11...20 {
            fringe.setRGBA(x: x, y: y, SIMD4<Float>(0.08, 0.05, 0.04, 1))
        }
    }
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 4, y: 3, width: 24, height: 26),
            eyeLeftRect: CGRect(x: 9, y: 12, width: 4, height: 3),
            eyeRightRect: CGRect(x: 19, y: 12, width: 4, height: 3),
            mouthRect: CGRect(x: 14, y: 21, width: 4, height: 2),
            confidence: 1
        ),
        subjectMask: mask,
        imageWidth: 32,
        imageHeight: 32
    )
    let thickness = ThicknessProfile(rows: [Float](repeating: 0.5, count: 32))
    let estimator = FaceAwareRibbonDepthEstimator()
    let skinDepth = estimator.estimate(frontMask: mask, sideThickness: thickness, plan: plan, source: skin)
    let fringeDepth = estimator.estimate(frontMask: mask, sideThickness: thickness, plan: plan, source: fringe)

    #expect(fringeDepth[16, 8] > skinDepth[16, 8] + 0.02)
}

@Test func faceAwareRibbonRefinesTheNoseOnlyFromAProminentLocalCue() {
    let plan = PartPlan(
        imageWidth: 64,
        imageHeight: 64,
        subjectRect: CGRect(x: 4, y: 2, width: 56, height: 60),
        headRect: CGRect(x: 8, y: 4, width: 48, height: 52),
        eyeLeftRect: CGRect(x: 17, y: 21, width: 10, height: 7),
        eyeRightRect: CGRect(x: 37, y: 21, width: 10, height: 7),
        mouthRect: CGRect(x: 27, y: 45, width: 10, height: 5),
        collarHeight: 7
    )
    var flat = Bitmap(width: 64, height: 64)
    for y in 0..<64 {
        for x in 0..<64 {
            flat.setRGBA(x: x, y: y, SIMD4(0.88, 0.72, 0.64, 1))
        }
    }
    var marked = flat
    let mark = SIMD2<Int>(37, 35)
    for y in (mark.y - 1)...(mark.y + 1) {
        for x in (mark.x - 1)...(mark.x + 1) {
            marked.setRGBA(x: x, y: y, SIMD4(0.20, 0.13, 0.12, 1))
        }
    }

    let fallback = FaceAwareRibbonDepthEstimator.inferredNoseAnchor(source: flat, plan: plan)
    let refined = FaceAwareRibbonDepthEstimator.inferredNoseAnchor(source: marked, plan: plan)
    let fallbackDistance = hypot(fallback.x - CGFloat(mark.x), fallback.y - CGFloat(mark.y))
    let refinedDistance = hypot(refined.x - CGFloat(mark.x), refined.y - CGFloat(mark.y))

    #expect(fallback.confidence == 0)
    #expect(refined.confidence > 0.35)
    #expect(refinedDistance < fallbackDistance)
}

@Test func depthMapRoundTripsAndProducesDebugDump() throws {
    var map = DepthMap(width: 2, height: 2)
    map[1, 1] = 0.5
    let restored = try JSONDecoder().decode(DepthMap.self, from: JSONEncoder().encode(map))
    #expect(restored == map)
    #expect(String(decoding: map.debugPGMData().prefix(2), as: UTF8.self) == "P5")
}
@testable import ArilsRig
@testable import ArilsRigPortable

// MARK: - Bitmap & planes

@Test func bitmapRoundTripsPixels() {
    var bitmap = Bitmap(width: 4, height: 4)
    bitmap.setRGBA(x: 1, y: 2, SIMD4(0.5, 0.25, 1, 1))
    let read = bitmap.rgba(x: 1, y: 2)
    #expect(abs(read.x - 0.5) < 0.01)
    #expect(abs(read.z - 1) < 0.01)
    #expect(bitmap.rgba(x: -1, y: 0) == .zero)
}

@Test func bitmapDownscaleHalvesDimensions() {
    let bitmap = Bitmap(width: 100, height: 50)
    let small = bitmap.downscaled(maxDimension: 50)
    #expect(small.width == 50)
    #expect(small.height == 25)
}

@Test func bitmapCropClamps() {
    let bitmap = SyntheticCharacter.bitmap()
    let crop = bitmap.cropped(to: CGRect(x: -10, y: -10, width: 60, height: 60))
    #expect(crop.width == 50)
    #expect(crop.height == 50)
}

@Test func cgImageRoundTripPreservesSize() {
    let bitmap = SyntheticCharacter.bitmap()
    let image = bitmap.cgImage()!
    let reloaded = Bitmap(image: image)!
    #expect(reloaded.width == bitmap.width)
    #expect(reloaded.height == bitmap.height)
    // A known interior pixel survives.
    let skin = reloaded.rgba(x: 100, y: 60)
    #expect(skin.w > 0.9)
    #expect(skin.x > 0.8)
}

@Test func floatPlaneBilinearSampling() {
    var plane = FloatPlane(width: 2, height: 2)
    plane[1, 0] = 1
    plane[1, 1] = 1
    #expect(abs(plane.sample(u: 0.5, v: 0.5) - 0.5) < 0.001)
    #expect(abs(plane.sample(u: 1, v: 1) - 1) < 0.001)
}

@Test func partOwnershipFieldFollowsACurvedBoneAndReportsOnlyItsSoftBandAsAmbiguous() {
    let field = PartOwnershipField(
        start: SIMD2(20, 20),
        control: SIMD2(55, 65),
        end: SIMD2(80, 80),
        startRadius: 12,
        endRadius: 8,
        feather: 3
    )
    #expect(field.ownershipWeight(x: 55, y: 60) > 0.8)
    #expect(field.ownershipWeight(x: 5, y: 90) < 0.01)

    var subject = FloatPlane(width: 20, height: 20, fill: 1)
    subject[11, 12] = 0
    let raster = field.rasterized(
        subjectMask: subject,
        imageWidth: 100,
        imageHeight: 100
    )
    #expect(raster.weights[11, 12] == 0)
    #expect(raster.ambiguity.values.contains { $0 > 0 })
    for index in raster.weights.values.indices where raster.ambiguity.values[index] > 0 {
        #expect(raster.weights.values[index] > 0.05)
        #expect(raster.weights.values[index] < 0.95)
    }
}

@Test func gradientDetectsEdges() {
    var plane = FloatPlane(width: 10, height: 10)
    for y in 0..<10 {
        for x in 5..<10 {
            plane[x, y] = 1
        }
    }
    let gradient = plane.gradientMagnitude()
    #expect(gradient[5, 5] > 0.3)
    #expect(gradient[1, 5] < 0.01)
}

// MARK: - Hole filling

@Test func holeFillerHealsWithSurroundingColor() {
    var bitmap = Bitmap(width: 40, height: 40)
    let red = SIMD4<Float>(0.8, 0.2, 0.1, 1)
    for y in 0..<40 {
        for x in 0..<40 {
            bitmap.setRGBA(x: x, y: y, red)
        }
    }
    // Punch a transparent hole and heal it.
    for y in 15..<25 {
        for x in 15..<25 {
            bitmap.setRGBA(x: x, y: y, .zero)
        }
    }
    HoleFiller.fillHole(in: &bitmap, region: CGRect(x: 5, y: 5, width: 30, height: 30)) { x, y in
        (10..<20).contains(x) && (10..<20).contains(y)
    }
    let healed = bitmap.rgba(x: 19, y: 19)
    #expect(healed.w > 0.9)
    #expect(abs(healed.x - red.x) < 0.1)
}

// MARK: - Face estimation

@Test func animeEstimatorFindsSyntheticFace() async {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)
    let mask = await AlphaSubjectMaskProvider().mask(for: context)
    #expect(mask != nil)
    guard let mask else { return }

    let layout = await AnimeFaceEstimator().estimateLayout(context: context, subjectMask: mask)
    #expect(layout != nil)
    guard let layout else { return }

    // Head covers the drawn circle.
    #expect(layout.headRect.minY < 30)
    #expect(layout.headRect.maxY > 100)

    // Eyes near their true centers (generous tolerance for the heuristic).
    let eyeLeft = SIMD2(Float(layout.eyeLeftRect.midX), Float(layout.eyeLeftRect.midY))
    let eyeRight = SIMD2(Float(layout.eyeRightRect.midX), Float(layout.eyeRightRect.midY))
    #expect(simd_distance(eyeLeft, SyntheticCharacter.eyeLeftCenter) < 20)
    #expect(simd_distance(eyeRight, SyntheticCharacter.eyeRightCenter) < 20)

    // Mouth near its true center.
    let mouth = SIMD2(Float(layout.mouthRect.midX), Float(layout.mouthRect.midY))
    #expect(simd_distance(mouth, SyntheticCharacter.mouthCenter) < 22)

    #expect(layout.confidence > 0.2)
}

@Test func animeEstimatorFindsSlightlyTurnedFace() async {
    // Regression: on a slightly turned (three-quarter) drawing, the head-mask
    // centroid sits inside the hair mass, right of the actual face axis.
    // Splitting the eye search at that centroid used to put both eyes into
    // one half (the "left eye" landed between the real eyes) and left the
    // other half grabbing hair contrast.
    let bitmap = SyntheticTurnedCharacter.bitmap()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)
    let mask = await AlphaSubjectMaskProvider().mask(for: context)
    #expect(mask != nil)
    guard let mask else { return }

    let layout = await AnimeFaceEstimator().estimateLayout(context: context, subjectMask: mask)
    #expect(layout != nil)
    guard let layout else { return }

    let eyeLeft = SIMD2(Float(layout.eyeLeftRect.midX), Float(layout.eyeLeftRect.midY))
    let eyeRight = SIMD2(Float(layout.eyeRightRect.midX), Float(layout.eyeRightRect.midY))
    #expect(simd_distance(eyeLeft, SyntheticTurnedCharacter.eyeLeftCenter) < 12)
    #expect(simd_distance(eyeRight, SyntheticTurnedCharacter.eyeRightCenter) < 12)
    #expect(layout.eyeLeftRect.intersection(layout.eyeRightRect).isNull)

    let mouth = SIMD2(Float(layout.mouthRect.midX), Float(layout.mouthRect.midY))
    #expect(simd_distance(mouth, SyntheticTurnedCharacter.mouthCenter) < 18)
}

@Test func animeEstimatorDoesNotRigTheCollarAsTheMouth() async throws {
    let bitmap = SyntheticCharacter.bitmapWithStrongCollarDecoy()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)
    let layout = try #require(await AnimeFaceEstimator().estimateLayout(
        context: context,
        subjectMask: bitmap.alphaPlane()
    ))

    let mouth = SIMD2(Float(layout.mouthRect.midX), Float(layout.mouthRect.midY))
    #expect(simd_distance(mouth, SyntheticCharacter.mouthCenter) < 12)
    #expect(layout.mouthRect.maxY < 120)
}

@Test func flatOpaqueBackgroundIsSeparatedBeforeFaceEstimation() async throws {
    let bitmap = SyntheticCharacter.bitmapOnOpaqueBackground()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)

    let alphaMask = await AlphaSubjectMaskProvider().mask(for: context)
    #expect(alphaMask == nil)

    let mask = await BorderBackgroundSubjectMaskProvider().mask(for: context)
    #expect(mask != nil)
    guard let mask else { return }
    #expect(mask[0, 0] == 0)
    #expect(mask[Int(SyntheticCharacter.headCenter.x), Int(SyntheticCharacter.headCenter.y)] == 1)

    let avatar = try await AutoRigPipeline(
        maskProviders: [BorderBackgroundSubjectMaskProvider()]
    ).makeAvatar(from: bitmap.cgImage()!)
    let head = try #require(avatar.rig.firstPart(ofKind: .head))
    let leftEye = try #require(avatar.rig.firstPart(ofKind: .eyeLeft))
    let rightEye = try #require(avatar.rig.firstPart(ofKind: .eyeRight))
    #expect(head.rect.width < CGFloat(bitmap.width) * 0.8)
    let overlap = leftEye.rect.intersection(rightEye.rect)
    #expect(overlap.isNull || overlap.width < 1)
}

@Test func tallLongHairDoesNotMoveTheHeadOrEyesIntoTheTorso() async throws {
    let bitmap = SyntheticCharacter.tallLongHairedBitmapOnOpaqueBackground()
    let avatar = try await AutoRigPipeline(
        maskProviders: [BorderBackgroundSubjectMaskProvider()]
    ).makeAvatar(from: bitmap.cgImage()!)
    let head = try #require(avatar.rig.firstPart(ofKind: .head))
    let leftEye = try #require(avatar.rig.firstPart(ofKind: .eyeLeft))
    let rightEye = try #require(avatar.rig.firstPart(ofKind: .eyeRight))

    #expect(head.rect.maxY < CGFloat(bitmap.height) * 0.4)
    #expect(abs(leftEye.rect.midY - CGFloat(SyntheticCharacter.eyeLeftCenter.y)) < 24)
    #expect(abs(rightEye.rect.midY - CGFloat(SyntheticCharacter.eyeRightCenter.y)) < 24)
    #expect(leftEye.rect.intersection(rightEye.rect).isNull)
}

@Test func compactTallHatKeepsTheLegacyLowerEyeBand() async throws {
    let bitmap = SyntheticCharacter.bitmapWithTallHat()
    let mask = bitmap.alphaPlane()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)
    let layout = try #require(await AnimeFaceEstimator().estimateLayout(context: context, subjectMask: mask))

    let expectedLeft = SIMD2(SyntheticCharacter.eyeLeftCenter.x, SyntheticCharacter.eyeLeftCenter.y + 25)
    let expectedRight = SIMD2(SyntheticCharacter.eyeRightCenter.x, SyntheticCharacter.eyeRightCenter.y + 25)
    let actualLeft = SIMD2(Float(layout.eyeLeftRect.midX), Float(layout.eyeLeftRect.midY))
    let actualRight = SIMD2(Float(layout.eyeRightRect.midX), Float(layout.eyeRightRect.midY))
    #expect(simd_distance(actualLeft, expectedLeft) < 20)
    #expect(simd_distance(actualRight, expectedRight) < 20)
}

@Test func missingSubjectMaskReportsSubjectNotFound() async {
    let pipeline = AutoRigPipeline(maskProviders: [])
    do {
        _ = try await pipeline.makeAvatar(from: SyntheticCharacter.cgImage())
        Issue.record("Expected subjectNotFound when no mask provider can isolate the subject")
    } catch let error as RiggingError {
        #expect(error == .subjectNotFound)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func alphaMaskProviderRejectsOpaqueImages() async {
    var opaque = Bitmap(width: 32, height: 32)
    for y in 0..<32 {
        for x in 0..<32 {
            opaque.setRGBA(x: x, y: y, SIMD4(0.5, 0.5, 0.5, 1))
        }
    }
    let context = AnalysisContext(originalImage: opaque.cgImage()!, analysis: opaque)
    let mask = await AlphaSubjectMaskProvider().mask(for: context)
    #expect(mask == nil)
}

@Test func compositeFaceEstimatorRejectsLowConfidenceFallbacks() async {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)
    let mask = bitmap.alphaPlane()
    let estimator = CompositeFaceEstimator(estimators: [LowConfidenceFaceEstimator()])
    let layout = await estimator.estimateLayout(context: context, subjectMask: mask)
    #expect(layout == nil)
}

@Test func disconnectedSubjectCandidatesCanBeIsolated() {
    var mask = FloatPlane(width: 40, height: 24)
    for y in 3..<21 {
        for x in 3..<15 { mask[x, y] = 1 }
        for x in 25..<37 { mask[x, y] = 1 }
    }

    let candidates = SubjectCandidates.candidates(in: mask)
    #expect(candidates.count == 2)
    #expect(candidates[0].normalizedBounds.midX < 0.5)
    #expect(candidates[1].normalizedBounds.midX > 0.5)
    #expect(candidates.allSatisfy { $0.normalizedBounds.maxX <= 1 && $0.normalizedBounds.maxY <= 1 })

    let selected = SubjectCandidates.mask(in: mask, selecting: candidates[1].id)
    #expect(selected != nil)
    guard let selected else { return }
    #expect(selected[8, 12] == 0)   // unselected left person becomes transparent
    #expect(selected[30, 12] == 1)  // selected right person remains
}

@Test func qualityPairAssessmentKeepsUncertaintyAndNamesSuspectFile() async throws {
    let pipeline = AutoRigPipeline()
    let same = try await pipeline.assessQualityPair(
        front: SyntheticCharacter.cgImage(),
        side: SyntheticCharacter.cgImage(),
        sideFileName: "same-character-side.png"
    )
    #expect(same.sameCharacterConfidence > 0.9)
    #expect(!same.warnings.contains {
        if case .possibleDifferentCharacter = $0 { return true }
        return false
    })

    var unrelated = SyntheticCharacter.bitmap()
    for y in 0..<unrelated.height {
        for x in 0..<unrelated.width where unrelated.alpha(x: x, y: y) > 0.5 {
            unrelated.setRGBA(x: x, y: y, SIMD4(0.05, 0.9, 0.1, 1))
        }
    }
    let different = try await pipeline.assessQualityPair(
        front: SyntheticCharacter.cgImage(),
        side: unrelated.cgImage()!,
        sideFileName: "unrelated.png"
    )
    #expect(different.warnings.contains {
        if case let .possibleDifferentCharacter(fileName, probability) = $0 {
            return fileName == "unrelated.png" && probability >= 0.5
        }
        return false
    })
}

@Test func qualityPairAssessmentDecodesLegacyExpressionConfidenceKey() throws {
    // Backward compatibility: archives saved before the
    // `expressionConfidence` -> `faceReadabilityConfidence` rename must still
    // decode, from both plist (the archive's real persistence format) and
    // JSON (easier to eyeball the key names in this test).
    let legacy = QualityPairAssessmentLegacy(
        sameCharacterConfidence: 0.82,
        expressionConfidence: 0.61,
        warnings: []
    )

    let plistEncoder = PropertyListEncoder()
    plistEncoder.outputFormat = .binary
    let plistData = try plistEncoder.encode(legacy)
    let decodedFromPlist = try PropertyListDecoder().decode(QualityPairAssessment.self, from: plistData)
    #expect(abs(decodedFromPlist.sameCharacterConfidence - 0.82) < 0.001)
    #expect(abs(decodedFromPlist.faceReadabilityConfidence - 0.61) < 0.001)
    #expect(decodedFromPlist.warnings.isEmpty)

    let jsonData = try JSONEncoder().encode(legacy)
    let decodedFromJSON = try JSONDecoder().decode(QualityPairAssessment.self, from: jsonData)
    #expect(abs(decodedFromJSON.faceReadabilityConfidence - 0.61) < 0.001)

    // Re-encoding writes the new key only, not the legacy one.
    let reencoded = try JSONEncoder().encode(decodedFromJSON)
    let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
    #expect(reencodedObject?["faceReadabilityConfidence"] != nil)
    #expect(reencodedObject?["expressionConfidence"] == nil)
}

/// Mirrors the pre-rename `QualityPairAssessment` shape (the
/// `expressionConfidence` key), used only to produce a legacy-format payload
/// for the decode test above.
private struct QualityPairAssessmentLegacy: Codable {
    var sameCharacterConfidence: Float
    var expressionConfidence: Float
    var warnings: [QualityPairWarning]
}

private actor FaceEstimatorCallCounter {
    private var value = 0
    func increment() { value += 1 }
    func read() -> Int { value }
}

private struct CountingFaceEstimator: FaceLayoutEstimating {
    let counter: FaceEstimatorCallCounter

    func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        await counter.increment()
        let width = CGFloat(context.originalImage.width)
        let height = CGFloat(context.originalImage.height)
        return FaceLayout(
            headRect: CGRect(x: width * 0.2, y: height * 0.05, width: width * 0.6, height: height * 0.5),
            eyeLeftRect: CGRect(x: width * 0.32, y: height * 0.25, width: width * 0.12, height: height * 0.07),
            eyeRightRect: CGRect(x: width * 0.56, y: height * 0.25, width: width * 0.12, height: height * 0.07),
            mouthRect: CGRect(x: width * 0.43, y: height * 0.42, width: width * 0.14, height: height * 0.05),
            confidence: 1
        )
    }
}

private struct LowConfidenceFaceEstimator: FaceLayoutEstimating {
    func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        FaceLayout(
            headRect: CGRect(x: 45, y: 15, width: 110, height: 120),
            eyeLeftRect: CGRect(x: 63, y: 77, width: 24, height: 16),
            eyeRightRect: CGRect(x: 113, y: 77, width: 24, height: 16),
            mouthRect: CGRect(x: 90, y: 108, width: 20, height: 8),
            confidence: 0.19
        )
    }
}

private struct StaticFaceEstimator: FaceLayoutEstimating {
    var layout: FaceLayout

    func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        layout
    }
}

@Test func faceLayoutReviewFlagsTorsoFeaturesEvenWhenEstimatorIsConfident() {
    let layout = FaceLayout(
        headRect: CGRect(x: 30, y: 10, width: 140, height: 330),
        eyeLeftRect: CGRect(x: 65, y: 230, width: 24, height: 16),
        eyeRightRect: CGRect(x: 112, y: 230, width: 24, height: 16),
        mouthRect: CGRect(x: 90, y: 300, width: 20, height: 8),
        confidence: 0.99
    )
    let review = FaceLayoutReviewer.review(
        layout: layout,
        subjectMask: FloatPlane(width: 100, height: 250, fill: 1),
        imageWidth: 200,
        imageHeight: 500,
        approvalPolicy: .calibrated(
            minimumConfidence: 0.65,
            datasetFingerprint: "held-out-v2",
            sampleCount: 100,
            falseAcceptRateUpper95: 0.04
        )
    )
    #expect(review.requiresReview)
    #expect(review.issues.contains(.headExtendsTooLow))
    #expect(review.issues.contains(.headIsTooLarge))
    #expect(review.confidence < layout.confidence)
}

@Test func faceProposalKeepsCompositeAlternativesAndDefaultsToManualReview() async throws {
    let first = FaceLayout(
        headRect: CGRect(x: 45, y: 15, width: 110, height: 120),
        eyeLeftRect: CGRect(x: 63, y: 70, width: 24, height: 16),
        eyeRightRect: CGRect(x: 113, y: 70, width: 24, height: 16),
        mouthRect: CGRect(x: 90, y: 105, width: 20, height: 8),
        confidence: 0.4
    )
    var second = first
    second.headRect.origin.x += 3
    second.confidence = 0.41
    let pipeline = AutoRigPipeline(
        faceEstimator: CompositeFaceEstimator(estimators: [
            StaticFaceEstimator(layout: first),
            StaticFaceEstimator(layout: second),
        ])
    )

    let proposal = try await pipeline.faceLayoutProposal(from: SyntheticCharacter.cgImage())

    #expect(proposal.layout == first)
    #expect(proposal.alternatives.count == 1)
    #expect(proposal.alternatives[0].layout == second)
    #expect(proposal.review.requiresReview)
    #expect(proposal.alternatives[0].review.requiresReview)
}

@Test func faceLayoutReviewAcceptsPlausibleGeometry() {
    let layout = FaceLayout(
        headRect: CGRect(x: 45, y: 15, width: 110, height: 120),
        eyeLeftRect: CGRect(x: 63, y: 70, width: 24, height: 16),
        eyeRightRect: CGRect(x: 113, y: 70, width: 24, height: 16),
        mouthRect: CGRect(x: 90, y: 105, width: 20, height: 8),
        confidence: 0.7
    )
    let review = FaceLayoutReviewer.review(
        layout: layout,
        subjectMask: FloatPlane(width: 100, height: 250, fill: 1),
        imageWidth: 200,
        imageHeight: 500,
        approvalPolicy: .calibrated(
            minimumConfidence: 0.65,
            datasetFingerprint: "held-out-v2",
            sampleCount: 100,
            falseAcceptRateUpper95: 0.04
        )
    )
    #expect(!review.requiresReview)
    #expect(review.issues.isEmpty)
}

@Test func plausibleButUncalibratedAnimeConfidenceStillRequiresReview() {
    let layout = FaceLayout(
        headRect: CGRect(x: 45, y: 15, width: 110, height: 120),
        eyeLeftRect: CGRect(x: 63, y: 70, width: 24, height: 16),
        eyeRightRect: CGRect(x: 113, y: 70, width: 24, height: 16),
        mouthRect: CGRect(x: 90, y: 105, width: 20, height: 8),
        confidence: 0.48
    )
    let review = FaceLayoutReviewer.review(
        layout: layout,
        subjectMask: FloatPlane(width: 100, height: 250, fill: 1),
        imageWidth: 200,
        imageHeight: 500
    )

    #expect(review.issues.isEmpty)
    #expect(review.requiresReview)
}

@Test func faceProposalUsesDedicatedHighResolutionAnalysis() async throws {
    let counter = FaceAnalysisSizeRecorder()
    let pipeline = AutoRigPipeline(
        options: .init(analysisMaxDimension: 64, faceAnalysisMaxDimension: 192),
        faceEstimator: RecordingFaceEstimator(recorder: counter)
    )
    _ = try await pipeline.faceLayoutProposal(from: SyntheticCharacter.cgImage())
    let size = await counter.read()
    #expect(max(size.width, size.height) == 192)
}

@Test func manualFaceLayoutBypassesEstimatorAndBuildsAtSuppliedHead() async throws {
    let counter = FaceEstimatorCallCounter()
    let pipeline = AutoRigPipeline(faceEstimator: CountingFaceEstimator(counter: counter))
    let layout = FaceLayout(
        headRect: CGRect(x: 48, y: 18, width: 104, height: 116),
        eyeLeftRect: CGRect(x: 65, y: 72, width: 22, height: 14),
        eyeRightRect: CGRect(x: 113, y: 72, width: 22, height: 14),
        mouthRect: CGRect(x: 91, y: 106, width: 18, height: 7),
        confidence: 0.1
    )
    let avatar = try await pipeline.makeAvatar(
        from: SyntheticCharacter.cgImage(),
        faceLayout: layout
    )
    #expect(await counter.read() == 0)
    // The supplied box is kept; only its top may climb to include hair above it.
    let head = try #require(avatar.rig.firstPart(ofKind: .head)?.rect)
    #expect(head.minX == layout.headRect.minX && head.maxX == layout.headRect.maxX)
    #expect(head.maxY == layout.headRect.maxY && head.minY <= layout.headRect.minY)
}

private actor FaceAnalysisSizeRecorder {
    private var size = (width: 0, height: 0)
    func record(width: Int, height: Int) { size = (width, height) }
    func read() -> (width: Int, height: Int) { size }
}

private struct RecordingFaceEstimator: FaceLayoutEstimating {
    let recorder: FaceAnalysisSizeRecorder

    func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        await recorder.record(width: context.analysis.width, height: context.analysis.height)
        let width = CGFloat(context.originalImage.width)
        let height = CGFloat(context.originalImage.height)
        return FaceLayout(
            headRect: CGRect(x: width * 0.2, y: height * 0.05, width: width * 0.6, height: height * 0.45),
            eyeLeftRect: CGRect(x: width * 0.32, y: height * 0.22, width: width * 0.12, height: height * 0.07),
            eyeRightRect: CGRect(x: width * 0.56, y: height * 0.22, width: width * 0.12, height: height * 0.07),
            mouthRect: CGRect(x: width * 0.43, y: height * 0.38, width: width * 0.14, height: height * 0.05),
            confidence: 0.8
        )
    }
}

@Test func qualityBuildReusesTheFrontPlanInsteadOfEstimatingItAgain() async throws {
    let counter = FaceEstimatorCallCounter()
    let pipeline = AutoRigPipeline(faceEstimator: CountingFaceEstimator(counter: counter))
    let archive = try await pipeline.makeQualityArchive(
        front: SyntheticCharacter.cgImage(), side: SyntheticCharacter.cgImage(),
        sideDirection: .right, sideFileName: "side.png"
    )
    // Pair assessment evaluates front+side once, then each avatar build once.
    // A fifth call would mean the depth-rig plan was recomputed separately.
    #expect(await counter.read() == 4)

    // The production Quality path must apply the face-scale cap, not merely
    // expose it on BindingSynthesizer for direct callers.
    let head = try #require(archive.front.rig.firstPart(ofKind: .head))
    let leftEye = try #require(archive.front.rig.firstPart(ofKind: .eyeLeft))
    let rightEye = try #require(archive.front.rig.firstPart(ofKind: .eyeRight))
    let headWidth = Float(head.rect.width)
    let eyeSpan = abs(Float(rightEye.rect.midX - leftEye.rect.midX))
    let expectedCap = min(headWidth * 0.40, max(headWidth * 0.22, eyeSpan))
    #expect(head.mesh.depths.allSatisfy { $0 <= expectedCap + 0.001 })
    #expect(head.mesh.columns == 24)
    #expect(head.mesh.rows == 24)
}

@Test func qualityBuildCanRetainTheOriginalRowEllipseForComparison() async throws {
    let pipeline = AutoRigPipeline(options: .init(qualityDepthStrategy: .rowEllipse))
    let archive = try await pipeline.makeQualityArchive(
        front: SyntheticCharacter.cgImage(), side: SyntheticCharacter.cgImage(),
        sideDirection: .right, sideFileName: "side.png"
    )
    let head = try #require(archive.front.rig.firstPart(ofKind: .head))
    #expect(head.mesh.columns == 12)
    #expect(head.mesh.rows == 12)
}

@Test func sameCharacterConfidenceIsHighForAnIdenticalImagePair() async throws {
    let pipeline = AutoRigPipeline()
    let assessment = try await pipeline.assessQualityPair(
        front: SyntheticCharacter.cgImage(),
        side: SyntheticCharacter.cgImage(),
        sideFileName: "identical.png"
    )
    #expect(assessment.sameCharacterConfidence > 0.8)
}

@Test func sameCharacterConfidenceDropsForARecoloredVariant() async throws {
    // Same silhouette (so head-width/coverage similarity stay ~1), but skin
    // and shirt colors swapped for a very different palette — isolates the
    // color histogram signal introduced by the P2 same-character heuristic.
    var recolored = SyntheticCharacter.bitmap()
    for y in 0..<recolored.height {
        for x in 0..<recolored.width {
            let pixel = recolored.rgba(x: x, y: y)
            guard pixel.w > 0.01 else { continue }
            if pixel.x > 0.9, pixel.z < 0.85 {
                // was skin (0.98, 0.86, 0.76) -> deep purple
                recolored.setRGBA(x: x, y: y, SIMD4(0.1, 0.05, 0.4, pixel.w))
            } else if pixel.z > 0.8 {
                // was shirt (0.55, 0.65, 0.9) -> bright green
                recolored.setRGBA(x: x, y: y, SIMD4(0.1, 0.8, 0.15, pixel.w))
            }
        }
    }

    let pipeline = AutoRigPipeline()
    let same = try await pipeline.assessQualityPair(
        front: SyntheticCharacter.cgImage(),
        side: SyntheticCharacter.cgImage(),
        sideFileName: "identical.png"
    )
    let recoloredAssessment = try await pipeline.assessQualityPair(
        front: SyntheticCharacter.cgImage(),
        side: recolored.cgImage()!,
        sideFileName: "recolored.png"
    )
    #expect(same.sameCharacterConfidence - recoloredAssessment.sameCharacterConfidence > 0.15)
}

@Test func qualityArchiveRoundTrips() async throws {
    let archive = try await AutoRigPipeline().makeQualityArchive(
        front: SyntheticCharacter.cgImage(),
        side: SyntheticCharacter.cgImage(),
        sideDirection: .right,
        sideFileName: "side.png"
    )
    let restored = try QualityAvatarArchive(data: archive.data())
    #expect(restored.formatVersion == QualityAvatarArchive.currentFormatVersion)
    #expect(restored.sideDirection == .right)
    #expect(restored.front.rig == archive.front.rig)
    #expect(restored.side.rig == archive.side.rig)
}

@Test func qualityArchivePersistsPresentationModeAndLegacyDefaultsTo2D() async throws {
    var archive = try await AutoRigPipeline().makeQualityArchive(
        front: SyntheticCharacter.cgImage(), side: SyntheticCharacter.cgImage(),
        sideDirection: .right, sideFileName: "side.png"
    )
    archive.preferredPresentationMode = .twoD
    let restored = try QualityAvatarArchive(data: archive.data())
    #expect(restored.preferredPresentationMode == .twoD)

    var object = try #require(PropertyListSerialization.propertyList(
        from: archive.data(), options: [], format: nil
    ) as? [String: Any])
    object.removeValue(forKey: "preferredPresentationMode")
    let legacyData = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    #expect(try QualityAvatarArchive(data: legacyData).preferredPresentationMode == .twoD)
}

// MARK: - Planner & layers

private func makePlan() async -> (PartPlan, Bitmap, FloatPlane) {
    let bitmap = SyntheticCharacter.bitmap()
    let context = AnalysisContext(originalImage: bitmap.cgImage()!, analysis: bitmap)
    let mask = (await AlphaSubjectMaskProvider().mask(for: context))!
    let layout = (await AnimeFaceEstimator().estimateLayout(context: context, subjectMask: mask))!
    let plan = PartPlanner.plan(
        layout: layout,
        subjectMask: mask,
        imageWidth: bitmap.width,
        imageHeight: bitmap.height
    )
    return (plan, bitmap, mask)
}

@Test func plannerCutIncludesHairAboveTheHeadBox() {
    // Hair above the box used to stay on the body and float as a strip
    // whenever the head tilted.
    var mask = FloatPlane(width: 100, height: 200, fill: 0)
    for y in 10..<200 { for x in 20..<80 { mask[x, y] = 1 } }
    let layout = FaceLayout(
        headRect: CGRect(x: 25, y: 30, width: 50, height: 60),
        eyeLeftRect: CGRect(x: 35, y: 55, width: 10, height: 6),
        eyeRightRect: CGRect(x: 55, y: 55, width: 10, height: 6),
        mouthRect: CGRect(x: 45, y: 75, width: 10, height: 4),
        confidence: 1
    )
    let plan = PartPlanner.plan(layout: layout, subjectMask: mask, imageWidth: 100, imageHeight: 200)
    for y in 0..<30 { for x in 0..<100 { mask[x, y] = 0 } }
    let bald = PartPlanner.plan(layout: layout, subjectMask: mask, imageWidth: 100, imageHeight: 200)
    #expect(abs(plan.headRect.minY - 10) <= 1)
    #expect(plan.headRect.maxY == bald.headRect.maxY)
    #expect(plan.collarHeight == bald.collarHeight)
}

@Test func plannerSurvivesLayoutEntirelyOutsideTheImage() {
    // Regression: `.intersection` of disjoint rects yields the null rect
    // (infinite coordinates); passing it downstream trapped in Int().
    let layout = FaceLayout(
        headRect: CGRect(x: -500, y: -500, width: 100, height: 100),
        eyeLeftRect: CGRect(x: -480, y: -470, width: 20, height: 10),
        eyeRightRect: CGRect(x: -440, y: -470, width: 20, height: 10),
        mouthRect: CGRect(x: -460, y: -430, width: 15, height: 8),
        confidence: 1
    )
    let plan = PartPlanner.plan(
        layout: layout,
        subjectMask: FloatPlane(width: 4, height: 4, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 260)
    for rect in [plan.subjectRect, plan.headRect, plan.eyeLeftRect, plan.eyeRightRect, plan.mouthRect] {
        #expect(!rect.isNull)
        #expect(rect.minX.isFinite && rect.minY.isFinite)
        #expect(bounds.contains(rect))
        #expect(rect.width > 0 && rect.height > 0)
    }
}

@Test func plannedRectsStayInBounds() async {
    let (plan, bitmap, _) = await makePlan()
    let bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
    for rect in [plan.subjectRect, plan.headRect, plan.eyeLeftRect, plan.eyeRightRect, plan.mouthRect] {
        #expect(bounds.contains(rect))
        #expect(rect.width > 0 && rect.height > 0)
    }
    #expect(plan.collarHeight > 0)
}

@Test func layerFactoryProducesConsistentLayers() async {
    let (plan, bitmap, mask) = await makePlan()
    let layers = LayerFactory.extract(source: bitmap, subjectMask: mask, plan: plan)

    // Sizes match the planned rects.
    #expect(layers.head.width == Int(plan.headRect.maxX.rounded(.up)) - Int(plan.headRect.minX))
    #expect(layers.body.width > 0 && layers.body.height > 0)
    #expect(layers.neckSeam.width == Int(plan.neckSeamRect.maxX.rounded(.up)) - Int(plan.neckSeamRect.minX))
    #expect(layers.neckSeam.height == Int(plan.neckSeamRect.maxY.rounded(.up)) - Int(plan.neckSeamRect.minY))

    // Head layer is transparent below the neck line.
    let neckLocalY = Int(plan.neckY) - Int(plan.headRect.minY)
    if neckLocalY < layers.head.height {
        for x in stride(from: 0, to: layers.head.width, by: 7) {
            #expect(layers.head.alpha(x: x, y: min(layers.head.height - 1, neckLocalY + 1)) < 0.05)
        }
    }

    // Body keeps collar fill inside the head zone just above the neck.
    let collarProbeY = Int(plan.neckY) - 2 - Int(plan.subjectRect.minY)
    let collarProbeX = Int(plan.headRect.midX) - Int(plan.subjectRect.minX)
    #expect(layers.body.alpha(x: collarProbeX, y: collarProbeY) > 0.2)

    // The real source seam covers the synthesized collar backing, while its
    // rectangular outer corners are feathered away.
    let seamProbeX = Int(plan.headRect.midX - plan.neckSeamRect.minX)
    let seamProbeY = Int(plan.neckY - plan.neckSeamRect.minY)
    #expect(layers.neckSeam.alpha(x: seamProbeX, y: seamProbeY) > 0.2)
    #expect(layers.neckSeam.alpha(x: 0, y: 0) < 0.05)
    let sourceSeam = bitmap.rgba(x: Int(plan.headRect.midX), y: Int(plan.neckY))
    let extractedSeam = layers.neckSeam.rgba(x: seamProbeX, y: seamProbeY)
    #expect(simd_reduce_max(simd_abs(sourceSeam - extractedSeam)) < 0.02)

    // Below the eyes the body is backed where the head was, so tilting the
    // head never shows a hole through the character...
    let faceProbeY = Int(plan.mouthRect.minY) + 1 - Int(plan.subjectRect.minY)
    #expect(layers.body.alpha(x: collarProbeX, y: faceProbeY) > 0.8)
    // ...while at the crown, which only background lies behind, the backing
    // is cleared so a moving head leaves no grey ghost of its outline.
    let crownProbeY = Int(plan.headRect.minY) + 2 - Int(plan.subjectRect.minY)
    if crownProbeY >= 0 {
        #expect(layers.body.alpha(x: collarProbeX, y: crownProbeY) < 0.05)
    }

    // Eye cutout corners are feathered to transparent.
    #expect(layers.eyeLeft.alpha(x: 0, y: 0) < 0.05)

    // Eye hole on the head layer was inpainted with skin, not left transparent.
    let eyeLocalX = Int(SyntheticCharacter.eyeLeftCenter.x) - Int(plan.headRect.minX)
    let eyeLocalY = Int(SyntheticCharacter.eyeLeftCenter.y) - Int(plan.headRect.minY)
    let inpainted = layers.head.rgba(x: eyeLocalX, y: eyeLocalY)
    #expect(inpainted.w > 0.5)
    // Skin-ish (red channel dominant), not the dark eye color.
    #expect(inpainted.x > inpainted.z)
}

@Test func headRegionProfileTurnsTheHumanRectangleIntoACurvedOwnershipMask() {
    let plan = PartPlan(
        imageWidth: 100,
        imageHeight: 120,
        subjectRect: CGRect(x: 0, y: 0, width: 100, height: 120),
        headRect: CGRect(x: 20, y: 10, width: 60, height: 60),
        eyeLeftRect: CGRect(x: 34, y: 38, width: 10, height: 6),
        eyeRightRect: CGRect(x: 56, y: 38, width: 10, height: 6),
        mouthRect: CGRect(x: 45, y: 55, width: 10, height: 4),
        collarHeight: 8
    )
    let profile = HeadRegionProfile(plan: plan)

    let centerBoundary = profile.lowerBoundaryY(at: plan.headRect.midX)
    let sideX = plan.headRect.minX + 3
    let sideBoundary = profile.lowerBoundaryY(at: sideX)
    #expect(centerBoundary > sideBoundary + 4)

    let probeY = sideBoundary + 3
    #expect(profile.ownershipWeight(x: plan.headRect.midX, y: probeY) > 0.8)
    #expect(profile.ownershipWeight(x: sideX, y: probeY) < 0.05)
}

@Test func layerFactoryUsesCurvedHeadOwnershipInsteadOfAStraightNeckCut() {
    var source = Bitmap(width: 100, height: 120)
    for y in 0..<source.height {
        for x in 0..<source.width {
            source.setRGBA(x: x, y: y, SIMD4(0.8, 0.6, 0.5, 1))
        }
    }
    let mask = FloatPlane(width: 100, height: 120, fill: 1)
    let plan = PartPlan(
        imageWidth: 100,
        imageHeight: 120,
        subjectRect: CGRect(x: 0, y: 0, width: 100, height: 120),
        headRect: CGRect(x: 20, y: 10, width: 60, height: 60),
        eyeLeftRect: CGRect(x: 34, y: 38, width: 10, height: 6),
        eyeRightRect: CGRect(x: 56, y: 38, width: 10, height: 6),
        mouthRect: CGRect(x: 45, y: 55, width: 10, height: 4),
        collarHeight: 8
    )
    let profile = HeadRegionProfile(plan: plan)
    let layers = LayerFactory.extract(source: source, subjectMask: mask, plan: plan)
    let sourceProbeY = Int(profile.lowerBoundaryY(at: plan.headRect.minX + 3) + 3)
    let localY = sourceProbeY - Int(plan.headRect.minY)
    let centerX = Int(plan.headRect.midX - plan.headRect.minX)
    let sideX = 3

    #expect(layers.head.alpha(x: centerX, y: localY) > 0.8)
    #expect(layers.head.alpha(x: sideX, y: localY) < 0.05)
    // The excluded side pixel remains owned by the fixed body rather than
    // becoming a transparent rectangular hole behind the moving head.
    #expect(layers.body.alpha(x: Int(plan.headRect.minX) + sideX, y: sourceProbeY) > 0.95)
}

@Test func tightHumanHeadSelectionExpandsOnlyTowardNearbyFacialAnatomy() {
    let mask = FloatPlane(width: 100, height: 120, fill: 1)
    let supplied = FaceLayout(
        headRect: CGRect(x: 28, y: 22, width: 44, height: 58),
        eyeLeftRect: CGRect(x: 35, y: 48, width: 9, height: 6),
        eyeRightRect: CGRect(x: 56, y: 48, width: 9, height: 6),
        mouthRect: CGRect(x: 46, y: 73, width: 8, height: 5),
        confidence: 1
    )
    let plan = PartPlanner.plan(
        layout: supplied,
        subjectMask: mask,
        imageWidth: 100,
        imageHeight: 120
    )

    #expect(plan.headRect.maxY > supplied.headRect.maxY)
    #expect(plan.headRect.maxY <= supplied.headRect.maxY + supplied.headRect.height * 0.14 + 0.01)
    #expect(plan.headRect.minX >= supplied.headRect.minX - supplied.headRect.width * 0.10 - 0.01)
    #expect(plan.headRect.maxX <= supplied.headRect.maxX + supplied.headRect.width * 0.10 + 0.01)
}

// MARK: - Rig document & archive

@Test func rigDocumentRoundTripsThroughJSON() async throws {
    let (plan, _, _) = await makePlan()
    let rig = BindingSynthesizer.makeRig(plan: plan)
    let data = try JSONEncoder().encode(rig)
    let decoded = try JSONDecoder().decode(AvatarRig.self, from: data)
    #expect(decoded == rig)
}

@Test func legacyRigWithoutValidatedPoseLimitsUsesTheHistoricalSafeRange() async throws {
    let (plan, _, _) = await makePlan()
    let rig = BindingSynthesizer.makeRig(plan: plan)
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(rig)) as? [String: Any]
    )
    object.removeValue(forKey: "validatedPoseLimits")
    let data = try JSONSerialization.data(withJSONObject: object)
    let restored = try JSONDecoder().decode(AvatarRig.self, from: data)

    #expect(restored.validatedPoseLimits == .legacyDefault)
}

@Test func autoRigBuildPersistsValidatedPoseLimits() async throws {
    let sweep = PoseSweepPlan(
        yawDegrees: [-10, 0, 10],
        pitchDegrees: [-3, 0, 3],
        rasterResolution: 64
    )
    let pipeline = AutoRigPipeline(options: .init(poseSweepPlan: sweep))
    let avatar = try await pipeline.makeAvatar(from: SyntheticCharacter.cgImage())

    #expect(avatar.rig.validatedPoseLimits.minimumYawDegrees >= -10)
    #expect(avatar.rig.validatedPoseLimits.maximumYawDegrees <= 10)
    #expect(avatar.rig.validatedPoseLimits.minimumPitchDegrees >= -3)
    #expect(avatar.rig.validatedPoseLimits.maximumPitchDegrees <= 3)
    // A clean synthetic rig must retain useful motion; a validator that merely
    // rejects every non-neutral sample would satisfy the bounds above.
    #expect(avatar.rig.validatedPoseLimits.minimumYawDegrees < 0)
    #expect(avatar.rig.validatedPoseLimits.maximumYawDegrees > 0)
    #expect(avatar.rig.validatedPoseLimits.minimumPitchDegrees < 0)
    #expect(avatar.rig.validatedPoseLimits.maximumPitchDegrees > 0)
}

@Test func synthesizedRigHasExpectedStructure() async {
    let (plan, _, _) = await makePlan()
    let rig = BindingSynthesizer.makeRig(plan: plan)

    #expect(rig.formatVersion == AvatarRig.currentFormatVersion)
    #expect(rig.parts.count == 6)
    #expect(rig.firstPart(ofKind: .head)?.parentID == "body")
    #expect(rig.part(withID: "neckSeam")?.parentID == "body")
    #expect(rig.firstPart(ofKind: .eyeLeft)?.parentID == "head")
    #expect(rig.firstPart(ofKind: .mouth)?.parentID == "head")
    #expect(!rig.physics.channels.isEmpty)
    let mouth = rig.firstPart(ofKind: .mouth)!
    #expect(mouth.deformations.contains {
        if case let .warpKeyform(
            parameterX: .mouthOpen,
            parameterY: .mouthForm,
            keys
        ) = $0 {
            return keys.count == 5
        }
        return false
    })

    // Pivots normalized, draw order sane (body behind head behind eyes).
    for part in rig.parts {
        #expect(part.pivot.x >= 0 && part.pivot.x <= 1)
        #expect(part.pivot.y >= 0 && part.pivot.y <= 1)
    }
    let order = rig.partsInDrawOrder.map(\.id)
    #expect(order.firstIndex(of: "body")! < order.firstIndex(of: "neckSeam")!)
    #expect(order.firstIndex(of: "neckSeam")! < order.firstIndex(of: "head")!)
    #expect(order.firstIndex(of: "body")! < order.firstIndex(of: "head")!)
    #expect(order.firstIndex(of: "head")! < order.firstIndex(of: "eyeLeft")!)

    // The seam's upper center follows pitch, but the real neck row and side
    // edges remain fixed so it bridges rather than creating another cut.
    let seam = rig.part(withID: "neckSeam")!
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])[seam.id]!
    let pitched = evaluator.evaluate(parameters: [.angleY: 6])[seam.id]!
    let topCenter = 8 // 17 columns, first row center
    #expect(pitched[topCenter].y < rest[topCenter].y - 1)
    let neckCenter = seam.mesh.vertices.indices.min {
        let left = abs(seam.mesh.vertices[$0].x - Float(seam.rect.midX))
            + abs(seam.mesh.vertices[$0].y - Float(plan.neckY))
        let right = abs(seam.mesh.vertices[$1].x - Float(seam.rect.midX))
            + abs(seam.mesh.vertices[$1].y - Float(plan.neckY))
        return left < right
    }!
    #expect(simd_distance(rest[neckCenter], pitched[neckCenter]) < 0.001)
    #expect(simd_distance(rest[0], pitched[0]) < 0.001)
}

@Test func layerFactorySynthesizesADarkMouthInteriorForOpenKeyforms() async {
    let (plan, bitmap, mask) = await makePlan()
    let layers = LayerFactory.extract(
        source: bitmap,
        subjectMask: mask,
        plan: plan
    )
    let lowerStart = layers.mouth.height / 2
    let darkOpaquePixels = (lowerStart..<layers.mouth.height).reduce(0) { count, y in
        count + (0..<layers.mouth.width).filter { x in
            layers.mouth.alpha(x: x, y: y) > 0.8
                && layers.mouth.luminance(x: x, y: y) < 0.15
        }.count
    }
    #expect(darkOpaquePixels > 2)
}

@Test func avatarArchiveRoundTrips() async throws {
    let avatar = try await AutoRigPipeline().makeAvatar(from: SyntheticCharacter.cgImage())
    let archive = try AvatarArchive(avatar: avatar)
    let data = try archive.data()
    let restored = try AvatarArchive(data: data).makeAvatar()

    #expect(restored.rig == avatar.rig)
    #expect(Set(restored.textures.keys) == Set(avatar.textures.keys))
    for (partID, texture) in restored.textures {
        #expect(texture.width == avatar.textures[partID]!.width)
        #expect(texture.height == avatar.textures[partID]!.height)
    }
}

@Test func archiveLoadRemovesTheObsoleteNeckForegroundBand() async throws {
    var avatar = try await AutoRigPipeline().makeAvatar(from: SyntheticCharacter.cgImage())
    var obsolete = avatar.rig.firstPart(ofKind: .body)!
    obsolete.id = "neckForeground"
    obsolete.kind = .accessory
    obsolete.zOrder = 15
    avatar.rig.parts.append(obsolete)
    avatar.textures[obsolete.id] = avatar.textures["body"]

    let restored = try AvatarArchive(data: AvatarArchive(avatar: avatar).data()).makeAvatar()
    #expect(restored.rig.part(withID: "neckForeground") == nil)
    #expect(restored.textures["neckForeground"] == nil)
    #expect(restored.rig.parts.count == avatar.rig.parts.count - 1)
}

@Test func archiveRoundTripPreservesPremultipliedPixels() async throws {
    // Regression: textures come back from the PNG archive with *straight*
    // alpha; the renderer must normalize them back to premultiplied or every
    // feathered edge glows white. This asserts the normalization (Bitmap via
    // a premultiplied CGContext) reproduces the original pixels.
    let avatar = try await AutoRigPipeline().makeAvatar(from: SyntheticCharacter.cgImage())
    let archive = try AvatarArchive(avatar: avatar)
    let restored = try AvatarArchive(data: archive.data()).makeAvatar()

    // The eye layer has feathered (partial-alpha) edges — the sensitive case.
    let original = Bitmap(image: avatar.textures["eyeLeft"]!)!
    let roundTripped = Bitmap(image: restored.textures["eyeLeft"]!)!
    #expect(original.width == roundTripped.width)
    #expect(original.height == roundTripped.height)

    var maxDelta: Float = 0
    var sawPartialAlpha = false
    for y in 0..<original.height {
        for x in 0..<original.width {
            let a = original.rgba(x: x, y: y)
            let b = roundTripped.rgba(x: x, y: y)
            maxDelta = max(maxDelta, simd_reduce_max(simd_abs(a - b)))
            if a.w > 0.05 && a.w < 0.95 { sawPartialAlpha = true }
        }
    }
    #expect(sawPartialAlpha) // the test only means something on soft edges
    #expect(maxDelta < 0.03)
}

@Test func sharpenedMaskCommitsSoftEdgesInsteadOfFringing() {
    var source = Bitmap(width: 16, height: 16)
    for y in 0..<16 {
        for x in 0..<16 {
            source.setRGBA(x: x, y: y, SIMD4(0.9, 0.2, 0.2, 1))
        }
    }
    // A mask that is 0.5 everywhere — like a Vision edge over background.
    let mask = FloatPlane(width: 4, height: 4, fill: 0.5)
    let plan = PartPlan(
        imageWidth: 16,
        imageHeight: 16,
        subjectRect: CGRect(x: 0, y: 0, width: 16, height: 16),
        headRect: CGRect(x: 2, y: 1, width: 12, height: 8),
        eyeLeftRect: CGRect(x: 4, y: 3, width: 3, height: 2),
        eyeRightRect: CGRect(x: 9, y: 3, width: 3, height: 2),
        mouthRect: CGRect(x: 6, y: 6, width: 4, height: 2),
        collarHeight: 2
    )

    let soft = LayerFactory.extract(source: source, subjectMask: mask, plan: plan, sharpenMaskEdges: false)
    let sharpened = LayerFactory.extract(source: source, subjectMask: mask, plan: plan, sharpenMaskEdges: true)

    // Probe a body pixel below the neck line (y >= 9).
    #expect(abs(soft.body.alpha(x: 8, y: 12) - 0.5) < 0.05)
    #expect(sharpened.body.alpha(x: 8, y: 12) < 0.02)
}

@Test func collarRepairDoesNotRetainStaticHairAndPreservesSoftAlpha() {
    var source = Bitmap(width: 16, height: 16)
    for y in 0..<16 {
        for x in 0..<16 {
            source.setRGBA(x: x, y: y, SIMD4(0.9, 0.2, 0.2, 1))
        }
    }
    var mask = FloatPlane(width: 16, height: 16, fill: 1)
    // x=3 is a strand that ends at the neck. The narrow side-underpaint band
    // now covers it with a low-frequency palette so head yaw does not uncover
    // a straight transparent slit.
    for y in 9..<16 { mask[3, y] = 0 }
    // x=6 exercises the interior backing near the center.
    for y in 9..<16 { mask[6, y] = 0 }
    // A broad soft-alpha patch around x=10 lets the low-frequency sample keep
    // the premultiplied alpha instead of averaging mostly opaque neighbors.
    for y in 9..<13 {
        for x in 8...12 {
            mask[x, y] = 0.5
            source.setRGBA(x: x, y: y, SIMD4(0.45, 0.10, 0.10, 0.5))
        }
    }
    let plan = PartPlan(
        imageWidth: 16,
        imageHeight: 16,
        subjectRect: CGRect(x: 0, y: 0, width: 16, height: 16),
        headRect: CGRect(x: 2, y: 1, width: 12, height: 8),
        eyeLeftRect: CGRect(x: 4, y: 3, width: 3, height: 2),
        eyeRightRect: CGRect(x: 9, y: 3, width: 3, height: 2),
        mouthRect: CGRect(x: 6, y: 6, width: 4, height: 2),
        collarHeight: 4
    )

    let layers = LayerFactory.extract(source: source, subjectMask: mask, plan: plan)
    #expect(layers.body.alpha(x: 3, y: 5) > 0.5)
    #expect(layers.body.alpha(x: 3, y: 8) > 0.5)
    #expect(layers.body.alpha(x: 6, y: 5) > 0.8)
    #expect(layers.body.alpha(x: 6, y: 8) > 0.8)
    #expect(layers.body.alpha(x: 10, y: 8) > 0.3)
    #expect(layers.body.alpha(x: 10, y: 8) < 0.7)
}

@Test func collarRepairRemovesHighFrequencyVerticalStripes() {
    var source = Bitmap(width: 64, height: 64)
    for y in 0..<64 {
        for x in 0..<64 {
            let bright: Float = x.isMultiple(of: 2) ? 0.95 : 0.08
            source.setRGBA(x: x, y: y, SIMD4(bright, bright, bright, 1))
        }
    }
    let mask = FloatPlane(width: 64, height: 64, fill: 1)
    let plan = PartPlan(
        imageWidth: 64,
        imageHeight: 64,
        subjectRect: CGRect(x: 0, y: 0, width: 64, height: 64),
        headRect: CGRect(x: 10, y: 4, width: 44, height: 38),
        eyeLeftRect: CGRect(x: 20, y: 20, width: 8, height: 5),
        eyeRightRect: CGRect(x: 36, y: 20, width: 8, height: 5),
        mouthRect: CGRect(x: 27, y: 32, width: 10, height: 4),
        collarHeight: 8
    )

    let layers = LayerFactory.extract(source: source, subjectMask: mask, plan: plan)
    var maximumAdjacentDelta: Float = 0
    for x in 25..<39 {
        maximumAdjacentDelta = max(
            maximumAdjacentDelta,
            abs(layers.body.luminance(x: x, y: 40) - layers.body.luminance(x: x - 1, y: 40))
        )
    }
    #expect(maximumAdjacentDelta < 0.05)
}

@Test func headTextureHasTransparentHorizontalSamplerGutters() async {
    let (plan, bitmap, mask) = await makePlan()
    let layers = LayerFactory.extract(source: bitmap, subjectMask: mask, plan: plan)
    for y in stride(from: 0, to: layers.head.height, by: max(1, layers.head.height / 9)) {
        #expect(layers.head.alpha(x: 0, y: y) < 0.01)
        #expect(layers.head.alpha(x: layers.head.width - 1, y: y) < 0.01)
    }
}

@Test func headTextureKeepsSoftNeckOverlapInsteadOfExposingTheBackingRepair() {
    var source = Bitmap(width: 16, height: 16)
    for y in 0..<source.height {
        for x in 0..<source.width {
            source.setRGBA(x: x, y: y, SIMD4(0.9, 0.2, 0.2, 1))
        }
    }
    let mask = FloatPlane(width: 16, height: 16, fill: 1)
    let plan = PartPlan(
        imageWidth: 16,
        imageHeight: 16,
        subjectRect: CGRect(x: 0, y: 0, width: 16, height: 16),
        headRect: CGRect(x: 2, y: 1, width: 12, height: 8),
        eyeLeftRect: CGRect(x: 4, y: 3, width: 3, height: 2),
        eyeRightRect: CGRect(x: 9, y: 3, width: 3, height: 2),
        mouthRect: CGRect(x: 6, y: 6, width: 4, height: 2),
        collarHeight: 4
    )

    let layers = LayerFactory.extract(source: source, subjectMask: mask, plan: plan)
    let bottomCenterAlpha = layers.head.alpha(
        x: layers.head.width / 2,
        y: layers.head.height - 1
    )
    // The final sampler row remains a small real-source overlap, but is mostly
    // transparent so clamp-to-edge cannot stretch it into a dark line.
    #expect(bottomCenterAlpha > 0.1)
    #expect(bottomCenterAlpha < 0.25)
}

@Test func mlMaskIsLimitedToHiddenBackingInsteadOfTheFaceBand() async throws {
    let (plan, bitmap, mask) = await makePlan()
    let request = try #require(LayerFactory.occlusionInpaintingRequest(
        source: bitmap,
        subjectMask: mask,
        plan: plan
    ))
    let requestMask = try #require(Bitmap(image: request.maskImage))
    let eyeX = Int(plan.eyeLeftRect.midX)
    let eyeY = Int(plan.eyeLeftRect.midY)
    let collarX = Int(plan.headRect.midX)
    let collarY = Int(plan.neckY) - 1
    #expect(requestMask.luminance(x: eyeX, y: eyeY) < 0.01)
    #expect(requestMask.luminance(x: collarX, y: collarY) > 0.99)
}

@Test func underpaintEnvelopeKeepsItsBoundaryBehindTheMaximumSupportedPose() async {
    let (plan, _, _) = await makePlan()
    let envelope = LayerFactory.underpaintEnvelope(for: plan)

    #expect(envelope.maximumHorizontalDisplacement > 0)
    #expect(envelope.maximumVerticalDisplacement > 0)
    #expect(envelope.horizontalOpaqueDepth > envelope.maximumHorizontalDisplacement + 3.9)
    #expect(envelope.verticalOpaqueDepth > envelope.maximumVerticalDisplacement + 3.9)
    #expect(envelope.horizontalExtent > envelope.horizontalOpaqueDepth)

    let sampleY = Int(plan.headRect.midY)
    let maximumRevealX = Int(
        plan.headRect.minX
            + CGFloat(envelope.maximumHorizontalDisplacement + envelope.safetyPixels * 0.5)
    )
    let hiddenBoundaryX = Int(
        plan.headRect.minX
            + CGFloat(envelope.horizontalExtent + 1)
    )
    #expect(LayerFactory.underpaintWeights(
        x: maximumRevealX,
        y: sampleY,
        plan: plan
    ).side > 0.999)
    #expect(LayerFactory.underpaintWeights(
        x: hiddenBoundaryX,
        y: sampleY,
        plan: plan
    ).side < 0.001)

    let pitchRevealY = Int(
        plan.neckY
            - CGFloat(envelope.maximumVerticalDisplacement + envelope.safetyPixels * 0.5)
    )
    #expect(LayerFactory.underpaintWeights(
        x: Int(plan.headRect.midX),
        y: pitchRevealY,
        plan: plan
    ).collar > 0.9)
}

@Test func underpaintEnvelopeContainsTheActualExtremeDepthRigDisplacement() async {
    let (plan, _, _) = await makePlan()
    var depth = DepthMap(width: plan.imageWidth, height: plan.imageHeight)
    for y in 0..<depth.height {
        for x in 0..<depth.width {
            depth[x, y] = 1
        }
    }
    let cap = BindingSynthesizer.recommendedHeadDepthCap(plan: plan)
    let rig = BindingSynthesizer.makeDepthRig(
        plan: plan,
        depthMap: depth,
        depthScalePixels: Float(plan.imageWidth),
        maximumHeadDepthPixels: cap
    )
    let evaluator = DeformationEvaluator3D(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])["head"]!
    let yaw = evaluator.evaluate(parameters: [
        .angleX: SupportedHeadPose.maximumYawDegrees,
    ])["head"]!
    let pitch = evaluator.evaluate(parameters: [
        .angleY: SupportedHeadPose.maximumPitchDegrees,
    ])["head"]!
    let maximumX = zip(rest, yaw).map { abs($1.x - $0.x) }.max() ?? 0
    let maximumY = zip(rest, pitch).map { abs($1.y - $0.y) }.max() ?? 0
    let envelope = LayerFactory.underpaintEnvelope(for: plan)

    #expect(maximumX <= envelope.maximumHorizontalDisplacement + 0.001)
    #expect(maximumY <= envelope.maximumVerticalDisplacement + 0.001)
}

@Test func mlMaskUsesTheSameMaximumPoseEnvelopeAsTheBodyBacking() async throws {
    let (plan, bitmap, _) = await makePlan()
    let fullSubject = FloatPlane(width: bitmap.width, height: bitmap.height, fill: 1)
    let request = try #require(LayerFactory.occlusionInpaintingRequest(
        source: bitmap,
        subjectMask: fullSubject,
        plan: plan
    ))
    let requestMask = try #require(Bitmap(image: request.maskImage))
    let envelope = LayerFactory.underpaintEnvelope(for: plan)
    let sampleY = Int(plan.headRect.midY)
    let coveredX = Int(
        plan.headRect.minX
            + CGFloat(envelope.maximumHorizontalDisplacement + envelope.safetyPixels * 0.5)
    )
    let hiddenBoundaryX = Int(
        plan.headRect.minX
            + CGFloat(envelope.horizontalExtent + 1)
    )

    #expect(requestMask.luminance(x: coveredX, y: sampleY) > 0.99)
    #expect(requestMask.luminance(x: hiddenBoundaryX, y: sampleY) < 0.01)
}

private actor InpaintingCallRecorder {
    private var calls = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}

private enum StubInpaintingError: Error {
    case unavailable
    case encoding
}

private struct SolidGreenInpainter: OcclusionInpaintingProviding {
    let recorder: InpaintingCallRecorder

    func inpaint(_ request: OcclusionInpaintingRequest) async throws -> CGImage {
        await recorder.record()
        var bitmap = Bitmap(width: request.sourceImage.width, height: request.sourceImage.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                bitmap.setRGBA(x: x, y: y, SIMD4(0.02, 0.95, 0.04, 1))
            }
        }
        guard let image = bitmap.cgImage() else { throw StubInpaintingError.encoding }
        return image
    }
}

private struct FailingInpainter: OcclusionInpaintingProviding {
    let recorder: InpaintingCallRecorder

    func inpaint(_ request: OcclusionInpaintingRequest) async throws -> CGImage {
        await recorder.record()
        throw StubInpaintingError.unavailable
    }
}

@Test func autoRigUsesInjectedInpaintingOnlyForBackingRepair() async throws {
    let recorder = InpaintingCallRecorder()
    let avatar = try await AutoRigPipeline(
        occlusionInpainter: SolidGreenInpainter(recorder: recorder)
    ).makeAvatar(from: SyntheticCharacter.cgImage())
    #expect(await recorder.count() == 1)

    let bodyTexture = try #require(avatar.textures["body"])
    let body = try #require(Bitmap(image: bodyTexture))
    var foundGeneratedBacking = false
    for y in 0..<body.height {
        for x in 0..<body.width {
            let color = body.rgba(x: x, y: y)
            if color.w > 0.1, color.y > color.x * 4, color.y > color.z * 4 {
                foundGeneratedBacking = true
                break
            }
        }
        if foundGeneratedBacking { break }
    }
    #expect(foundGeneratedBacking)
}

@Test func failedInpaintingFallsBackWithoutFailingTheAvatarBuild() async throws {
    let recorder = InpaintingCallRecorder()
    let avatar = try await AutoRigPipeline(
        occlusionInpainter: FailingInpainter(recorder: recorder)
    ).makeAvatar(from: SyntheticCharacter.cgImage())
    #expect(await recorder.count() == 1)
    #expect(avatar.textures["body"] != nil)
    #expect(avatar.textures["head"] != nil)
    #expect(avatar.textures["neckSeam"] != nil)
}

@Test func autoRigPipelineProducesCompleteAvatar() async throws {
    let avatar = try await AutoRigPipeline().makeAvatar(from: SyntheticCharacter.cgImage())
    #expect(avatar.rig.imageWidth == SyntheticCharacter.size.width)
    #expect(avatar.rig.imageHeight == SyntheticCharacter.size.height)
    #expect(avatar.rig.parts.count == 6)
    for part in avatar.rig.parts {
        #expect(avatar.textures[part.id] != nil, "missing texture for \(part.id)")
        #expect(part.mesh.vertexCount > 0)
    }
}

@Test func sideHairRootsFollowTheHeadWhileTheTipsStayWithTheBody() async throws {
    // The beta is applied to a finished rig when a pet loads.
    let built = try await AutoRigPipeline().makeAvatar(from: SyntheticCharacter.cgImage())
    #expect(built.rig.part(withID: SideHairRegion.partID) == nil)
    let layers = try built.textures.mapValues { try #require(Bitmap(image: $0)) }
    let following = try #require(FollowingHair.apply(rig: built.rig, layers: layers))
    #expect(following.layers[SideHairRegion.partID] != nil)
    #expect(FollowingHair.apply(rig: following.rig, layers: following.layers) == nil)
    let avatar = following
    let side = try #require(avatar.rig.part(withID: SideHairRegion.partID))
    let head = try #require(avatar.rig.firstPart(ofKind: .head))
    var tiltKeys: [WarpKeyformKey] = []
    for operation in side.deformations {
        if case let .warpKeyform(parameterX, parameterY, keys) = operation, parameterX == .angleX, parameterY == .angleZ {
            tiltKeys = keys
        }
    }
    let tilt = try #require(tiltKeys.first { $0.parameterXValue == 0 && $0.parameterYValue == 30 })
    let columns = side.mesh.columns + 1
    // The vertex beside the head's left edge on the top row moves with the tilt...
    let nearHead = (0..<columns).min {
        abs(side.mesh.vertices[$0].x - Float(head.rect.minX)) < abs(side.mesh.vertices[$1].x - Float(head.rect.minX))
    }!
    let root = tilt.vertexOffsets[nearHead]
    #expect((root * root).sum().squareRoot() > 1)
    // ...while the bottom row, at the shoulders, stays put.
    for index in (side.mesh.rows * columns)..<side.mesh.vertexCount {
        let tip = tilt.vertexOffsets[index]
        #expect((tip * tip).sum().squareRoot() < 0.01)
    }
}

@Test func scaledPoseLimitsWidenEveryDirectionAndNeverShrink() {
    let limits = ValidatedPoseLimits(
        minimumYawDegrees: -12, maximumYawDegrees: 20,
        minimumPitchDegrees: -3, maximumPitchDegrees: 6
    )
    let wide = limits.scaled(by: 1.5)
    #expect(wide == ValidatedPoseLimits(
        minimumYawDegrees: -18, maximumYawDegrees: 30,
        minimumPitchDegrees: -4.5, maximumPitchDegrees: 9
    ))
    #expect(limits.scaled(by: 0.5) == limits)
    #expect(limits.scaled(by: .nan) == limits)
}
