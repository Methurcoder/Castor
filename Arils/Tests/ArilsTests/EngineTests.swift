import CoreGraphics
import Foundation
import simd
import Testing
import ArilsRender

@testable import Arils

/// Same synthetic character as the rig tests (duplicated: test targets can't
/// share sources without an extra utility target).
private func syntheticCharacterImage() -> CGImage {
    var bitmap = Bitmap(width: 200, height: 260)
    let skin = SIMD4<Float>(0.98, 0.86, 0.76, 1)
    let shirt = SIMD4<Float>(0.55, 0.65, 0.9, 1)
    let dark = SIMD4<Float>(0.15, 0.2, 0.45, 1)

    func fillEllipse(cx: Float, cy: Float, rx: Float, ry: Float, color: SIMD4<Float>) {
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let dx = (Float(x) - cx) / rx
                let dy = (Float(y) - cy) / ry
                if dx * dx + dy * dy <= 1 {
                    bitmap.setRGBA(x: x, y: y, color)
                }
            }
        }
    }
    func fillRect(_ rect: CGRect, color: SIMD4<Float>) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                bitmap.setRGBA(x: x, y: y, color)
            }
        }
    }

    fillRect(CGRect(x: 30, y: 140, width: 140, height: 110), color: shirt)
    fillRect(CGRect(x: 85, y: 120, width: 30, height: 25), color: skin)
    fillEllipse(cx: 100, cy: 70, rx: 55, ry: 55, color: skin)
    fillEllipse(cx: 75, cy: 85, rx: 12, ry: 8, color: dark)
    fillEllipse(cx: 125, cy: 85, rx: 12, ry: 8, color: dark)
    fillEllipse(cx: 100, cy: 115, rx: 10, ry: 4, color: SIMD4(0.6, 0.2, 0.2, 1))
    return bitmap.cgImage()!
}

@Test @MainActor func engineRigsAndAnimatesFromASingleImage() async throws {
    let engine = try await CharacterEngine.make(image: syntheticCharacterImage())

    let first = engine.parameters(at: 0)
    #expect(first[.eyeLeftOpen] != nil)
    #expect(first[.breath] != nil)

    // Advancing time produces motion.
    var time = 0.0
    var breaths: [Float] = []
    while time < 6 {
        breaths.append(engine.parameters(at: time)[.breath]!)
        time += 1.0 / 60.0
    }
    #expect(breaths.max()! - breaths.min()! > 0.3)
}

@Test @MainActor func speakingWithoutAudioStillMovesTheMouth() async throws {
    let engine = try await CharacterEngine.make(image: syntheticCharacterImage())
    engine.isSpeaking = true
    var opens: [Float] = []
    var time = 0.0
    while time < 4 {
        opens.append(engine.parameters(at: time)[.mouthOpen]!)
        time += 1.0 / 60.0
    }
    #expect(opens.max()! > 0.2)
}

@Test @MainActor func behaviorAndPersonalityReachTheMotionThroughTheFacade() async throws {
    let image = syntheticCharacterImage()
    let thinking = try await CharacterEngine.make(
        image: image,
        configuration: .init(sneezeInterval: .infinity, personality: .lively, microActionsEnabled: false)
    )
    thinking.behavior = .thinking
    var form: Float = 0
    var time = 0.0
    while time < 3 {
        form = thinking.parameters(at: time)[.mouthForm]!
        time += 1.0 / 60.0
    }
    #expect(form < -0.15)
}

@Test @MainActor func speechTimelineDrivesTheMouthByThePlaybackClock() async throws {
    let engine = try await CharacterEngine.make(image: syntheticCharacterImage())
    let frames = (0..<120).map { LipSyncFrame(open: $0 < 60 ? 0.9 : 0, form: 0) }
    var playback: Double? = 0
    engine.isSpeaking = true
    engine.playSpeechTimeline(LipSyncTimeline(frameRate: 60, frames: frames)) { playback }
    var open: Float = 0
    var time = 0.0
    while time < 0.5 {
        playback = time
        open = engine.parameters(at: time)[.mouthOpen]!
        time += 1.0 / 60.0
    }
    #expect(open > 0.6)
    while time < 1.6 {
        playback = time
        open = engine.parameters(at: time)[.mouthOpen]!
        time += 1.0 / 60.0
    }
    #expect(open < 0.1)
    // A stopped clock or a finished clip keeps the mouth closed while
    // isSpeaking is still set, instead of falling back to the procedural flap.
    for clock in [{ nil }, { 5.0 }] as [@MainActor () -> Double?] {
        engine.playSpeechTimeline(LipSyncTimeline(frameRate: 60, frames: frames), clock: clock)
        var opens: [Float] = []
        let end = time + 2
        while time < end {
            opens.append(engine.parameters(at: time)[.mouthOpen]!)
            time += 1.0 / 60.0
        }
        #expect(opens.suffix(60).max()! < 0.05)
    }
}

@Test @MainActor func archiveRoundTripsThroughTheEngine() async throws {
    let original = try await CharacterEngine.make(image: syntheticCharacterImage())
    let data = try original.archiveData()
    let restored = try CharacterEngine(archiveData: data)
    #expect(restored.avatar.rig == original.avatar.rig)
    #expect(restored.parameters(at: 0)[.eyeLeftOpen] != nil)
}

@Test @MainActor func speechTimelineAnalysisWorksThroughTheFacade() async throws {
    let engine = try await CharacterEngine.make(image: syntheticCharacterImage())
    let sampleRate = 24_000.0
    let samples = (0..<24_000).map { index in
        0.4 * Float(sin(2.0 * .pi * 300 * Double(index) / sampleRate))
    }
    let frames = engine.analyzeSpeechTimeline(samples: samples, sampleRate: sampleRate)
    #expect(frames.count == 60)
    #expect(frames[30].open > 0.5)
}

// MARK: - Automatic view turning

private func settle(_ model: inout QualityTurnModel, gazeX: Float?, direction: QualitySideDirection, seconds: Float = 4) -> Float {
    var result: Float = 0
    var elapsed: Float = 0
    while elapsed < seconds {
        result = model.step(gazeX: gazeX, sideDirection: direction, deltaTime: 1.0 / 30.0)
        elapsed += 1.0 / 30.0
    }
    return result
}

private func settlePitch(_ model: inout QualityTurnModel, gazeY: Float?, seconds: Float = 4) -> Float {
    var result: Float = 0
    var elapsed: Float = 0
    while elapsed < seconds {
        result = model.stepPitch(gazeY: gazeY, deltaTime: 1.0 / 30.0)
        elapsed += 1.0 / 30.0
    }
    return result
}

@Test func turnModelTurnsTowardTheSupportedSide() {
    var model = QualityTurnModel()
    let turn = settle(&model, gazeX: 0.9, direction: .right)
    #expect(turn > 0.9)
}

@Test func turnModelCapsTheUnsupportedSideAtTheDepthOnlyRange() {
    var model = QualityTurnModel()
    let turn = settle(&model, gazeX: -0.9, direction: .right)
    #expect(turn < -0.30 && turn > -0.40)
}

@Test func turnModelDeadZoneIgnoresSmallGazeWander() {
    var model = QualityTurnModel()
    let turn = settle(&model, gazeX: 0.2, direction: .right)
    #expect(abs(turn) < 0.02)
}

@Test func turnModelEasesBackWhenTheTargetDisappears() {
    var model = QualityTurnModel()
    _ = settle(&model, gazeX: 0.9, direction: .right)
    let turn = settle(&model, gazeX: nil, direction: .right)
    #expect(abs(turn) < 0.02)
}

@Test func turnModelUsesNegativeValuesForLeftFacingArt() {
    var model = QualityTurnModel()
    let turn = settle(&model, gazeX: -0.9, direction: .left)
    #expect(turn < -0.9)
}

@Test func turnModelTracksVerticalGazeInBothDirections() {
    var upModel = QualityTurnModel()
    var downModel = QualityTurnModel()
    #expect(settlePitch(&upModel, gazeY: 0.9) > 0.9)
    #expect(settlePitch(&downModel, gazeY: -0.9) < -0.9)
}

@Test func turnModelPitchHasADeadZoneAndReturnsToCenter() {
    var model = QualityTurnModel()
    #expect(abs(settlePitch(&model, gazeY: 0.1)) < 0.02)
    _ = settlePitch(&model, gazeY: 0.9)
    #expect(abs(settlePitch(&model, gazeY: nil)) < 0.02)
}

@Test func turnModelManualPoseCanSeedAutomaticResumeWithoutSnappingBack() {
    var model = QualityTurnModel()
    _ = settlePitch(&model, gazeY: 0.9)
    model.snap(turn: 0, pitch: -1)
    let firstAutomaticFrame = model.stepPitch(gazeY: nil, deltaTime: 1.0 / 30.0)
    #expect(firstAutomaticFrame < -0.9)
}

@Test func turnModelRejectsNonFiniteGazeWithoutPoisoningItsSpring() {
    var model = QualityTurnModel()
    #expect(model.stepPitch(gazeY: .nan, deltaTime: 1.0 / 30.0).isFinite)
    #expect(settlePitch(&model, gazeY: 0.9) > 0.9)
}

@Test @MainActor func currentGazeTargetReflectsExternalTarget() async throws {
    let engine = try await CharacterEngine.make(image: syntheticCharacterImage())
    #expect(engine.currentGazeTarget == nil)
    engine.externalGazeTarget = SIMD2(0.4, -0.1)
    #expect(engine.currentGazeTarget == SIMD2(0.4, -0.1))
    engine.externalGazeTarget = SIMD2(.nan, 0)
    #expect(engine.currentGazeTarget == nil)
    engine.faceTrackingBlend = 2
    #expect(engine.faceTrackingBlend == 1)
    engine.faceTrackingBlend = .nan
    #expect(engine.faceTrackingBlend == 0)
    engine.viewAngleYOverride = .nan
    #expect(engine.parameters(at: 0)[.angleY]?.isFinite == true)
}

@Test func gazeMappingReachesEveryImageEdgeFromAnOffCenterHead() {
    let imageSize = SIMD2<Float>(200, 500)
    let headCenter = SIMD2<Float>(100, 75)
    #expect(CharacterEngine.normalizedGazeTarget(
        imagePoint: SIMD2(100, 0), headCenter: headCenter, imageSize: imageSize
    ).y == 1)
    #expect(CharacterEngine.normalizedGazeTarget(
        imagePoint: SIMD2(100, 500), headCenter: headCenter, imageSize: imageSize
    ).y == -1)
    #expect(CharacterEngine.normalizedGazeTarget(
        imagePoint: SIMD2(0, 75), headCenter: headCenter, imageSize: imageSize
    ).x == -1)
    #expect(CharacterEngine.normalizedGazeTarget(
        imagePoint: SIMD2(200, 75), headCenter: headCenter, imageSize: imageSize
    ).x == 1)
}

// MARK: - Quality registration layout

@Test func aspectFitRectLettersBoxesAWideImageInATallBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
    let fit = QualityRegistrationLayout.aspectFitRect(imageSize: CGSize(width: 400, height: 100), in: bounds)
    // scale = min(100/400, 200/100) = 0.25 -> 100x25, vertically centered.
    #expect(abs(fit.width - 100) < 0.01)
    #expect(abs(fit.height - 25) < 0.01)
    #expect(abs(fit.origin.x - 0) < 0.01)
    #expect(abs(fit.origin.y - 87.5) < 0.01)
}

@Test func aspectFitRectLettersBoxesATallImageInAWideBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
    let fit = QualityRegistrationLayout.aspectFitRect(imageSize: CGSize(width: 100, height: 400), in: bounds)
    // scale = min(200/100, 100/400) = 0.25 -> 25x100, horizontally centered.
    #expect(abs(fit.width - 25) < 0.01)
    #expect(abs(fit.height - 100) < 0.01)
    #expect(abs(fit.origin.x - 87.5) < 0.01)
    #expect(abs(fit.origin.y - 0) < 0.01)
}

private func expectNeckAligned(
    bounds: CGRect,
    frontImageSize: CGSize,
    sideImageSize: CGSize,
    registration: QualityViewRegistration,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let frontFit = QualityRegistrationLayout.aspectFitRect(imageSize: frontImageSize, in: bounds)
    let sideFrame = QualityRegistrationLayout.sideFrame(
        bounds: bounds,
        frontImageSize: frontImageSize,
        sideImageSize: sideImageSize,
        registration: registration
    )
    let frontNeck = CGPoint(
        x: frontFit.origin.x + CGFloat(registration.frontNeck.x) * frontFit.width,
        y: frontFit.origin.y + CGFloat(registration.frontNeck.y) * frontFit.height
    )
    let sideNeck = CGPoint(
        x: sideFrame.origin.x + CGFloat(registration.sideNeck.x) * sideFrame.width,
        y: sideFrame.origin.y + CGFloat(registration.sideNeck.y) * sideFrame.height
    )
    #expect(abs(frontNeck.x - sideNeck.x) < 0.01, sourceLocation: sourceLocation)
    #expect(abs(frontNeck.y - sideNeck.y) < 0.01, sourceLocation: sourceLocation)
    // The side frame keeps the side image's own aspect ratio, so the side
    // view's internal aspect-fit fills it exactly (no inner letterboxing).
    if sideImageSize.width > 0, sideImageSize.height > 0 {
        let frameAspect = sideFrame.width / sideFrame.height
        let imageAspect = sideImageSize.width / sideImageSize.height
        #expect(abs(frameAspect - imageAspect) < 0.01, sourceLocation: sourceLocation)
    }
}

@Test func sideFrameAlignsNeckPointsAcrossSquareBoundsWithMismatchedAspects() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    let registration = QualityViewRegistration(
        frontNeck: SIMD2(0.5, 0.55),
        sideNeck: SIMD2(0.4, 0.6),
        sideScale: 0.9
    )
    expectNeckAligned(
        bounds: bounds,
        frontImageSize: CGSize(width: 200, height: 260),
        sideImageSize: CGSize(width: 150, height: 300),
        registration: registration
    )
}

@Test func sideFrameAlignsNeckPointsWhenBoundsAreWiderThanBothImages() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
    let registration = QualityViewRegistration(
        frontNeck: SIMD2(0.5, 0.4),
        sideNeck: SIMD2(0.45, 0.5),
        sideScale: 1.3
    )
    expectNeckAligned(
        bounds: bounds,
        frontImageSize: CGSize(width: 200, height: 260),
        sideImageSize: CGSize(width: 180, height: 260),
        registration: registration
    )
}

@Test func sideFrameAlignsNeckPointsWhenBoundsAreTallerThanBothImages() {
    let bounds = CGRect(x: 0, y: 0, width: 250, height: 900)
    let registration = QualityViewRegistration(
        frontNeck: SIMD2(0.5, 0.5),
        sideNeck: SIMD2(0.5, 0.5),
        sideScale: 1
    )
    expectNeckAligned(
        bounds: bounds,
        frontImageSize: CGSize(width: 200, height: 260),
        sideImageSize: CGSize(width: 100, height: 260),
        registration: registration
    )
}

@Test func sideFrameShiftsTowardTheDirectionThatEqualizesNeckHeightWhenNormalizedYDiffers() {
    // Regression for the Y-flip bug: with a container that is Y-down
    // (`isFlipped == true`), a *larger* normalized-Y side neck must pull the
    // side frame's origin *up* (smaller Y) so the two necks still meet,
    // never down.
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    let frontImageSize = CGSize(width: 200, height: 260)
    let sideImageSize = CGSize(width: 200, height: 260)

    let lowSideNeck = QualityViewRegistration(frontNeck: SIMD2(0.5, 0.5), sideNeck: SIMD2(0.5, 0.3), sideScale: 1)
    let highSideNeck = QualityViewRegistration(frontNeck: SIMD2(0.5, 0.5), sideNeck: SIMD2(0.5, 0.7), sideScale: 1)

    let lowFrame = QualityRegistrationLayout.sideFrame(
        bounds: bounds, frontImageSize: frontImageSize, sideImageSize: sideImageSize, registration: lowSideNeck
    )
    let highFrame = QualityRegistrationLayout.sideFrame(
        bounds: bounds, frontImageSize: frontImageSize, sideImageSize: sideImageSize, registration: highSideNeck
    )

    // A neck further down inside the side image (larger normalized Y) must
    // pull the frame's origin further up so that point still lands on the
    // shared (front) neck height.
    #expect(highFrame.origin.y < lowFrame.origin.y)

    expectNeckAligned(bounds: bounds, frontImageSize: frontImageSize, sideImageSize: sideImageSize, registration: lowSideNeck)
    expectNeckAligned(bounds: bounds, frontImageSize: frontImageSize, sideImageSize: sideImageSize, registration: highSideNeck)
}

@Test @MainActor func qualityEngineKeepsTheSideDirectionalAndStandardEngineSeparate() async throws {
    let archive = try await AutoRigPipeline().makeQualityArchive(
        front: syntheticCharacterImage(),
        side: syntheticCharacterImage(),
        sideDirection: .right,
        sideFileName: "side.png"
    )
    let quality = try QualityCharacterEngine(archive: archive)
    let limits = archive.front.rig.validatedPoseLimits
    #expect(quality.front.viewAngleXOverride == 0)
    #expect(quality.front.viewAngleYOverride == 0)
    #expect(quality.side.viewAngleXOverride == 0)
    #expect(quality.side.viewAngleYOverride == 0)
    quality.viewTurn = -1
    #expect(quality.sideBlend == 0) // no silent mirroring on the unsupported side
    quality.viewTurn = 1
    #expect(quality.sideBlend == 1)
    #expect(quality.front.viewAngleXOverride == limits.maximumYawDegrees)
    quality.viewTurn = 0
    quality.viewPitch = 1
    #expect(quality.front.viewAngleYOverride == limits.maximumPitchDegrees)
    #expect(quality.side.viewAngleYOverride == 0)
    quality.viewTurn = 0.6
    #expect(
        abs(
            (quality.front.viewAngleYOverride ?? -1)
                - limits.maximumPitchDegrees * (1 - quality.sideBlend)
        ) < 0.001
    )
    quality.viewTurn = 1
    #expect(quality.front.viewAngleYOverride == 0)
    quality.viewTurn = -0.35
    #expect(quality.sideBlend == 0)
    #expect(quality.front.viewAngleXOverride == limits.minimumYawDegrees)
    quality.hybrid3DEnabled = false
    quality.viewTurn = 0.5
    #expect(abs(quality.sideBlend - 0.5) < 0.001)
    #expect(quality.front.viewAngleXOverride == 0)
    #expect(quality.front.viewAngleYOverride == nil)
    #expect(quality.side.viewAngleXOverride == 0)
    #expect(quality.side.viewAngleYOverride == nil)
    #expect(quality.front.avatar.rig == archive.front.rig)
}

@Test @MainActor func qualityContainerPausesOnlyFullyHiddenMetalViews() async throws {
    let archive = try await AutoRigPipeline().makeQualityArchive(
        front: syntheticCharacterImage(), side: syntheticCharacterImage(),
        sideDirection: .right, sideFileName: "side.png"
    )
    let quality = try QualityCharacterEngine(archive: archive)
    quality.automaticTurn = false
    let container = quality.makeView()
    let views = container.subviews.compactMap { $0 as? AvatarMetalView }
    #expect(views.count == 2)
    guard views.count == 2 else { return }
    #expect(views[0].isRenderingEnabled)
    #expect(!views[1].isRenderingEnabled)
    #expect(quality.renderActivitySnapshot().activeRendererCount <= 1)

    quality.viewTurn = 0.6
    #expect(views[0].isRenderingEnabled)
    #expect(views[1].isRenderingEnabled)

    quality.viewTurn = 1
    #expect(!views[0].isRenderingEnabled)
    #expect(views[1].isRenderingEnabled)
}

@Test @MainActor func qualityEngineAppliesPersisted2DModeDuringInitialization() async throws {
    var archive = try await AutoRigPipeline().makeQualityArchive(
        front: syntheticCharacterImage(), side: syntheticCharacterImage(),
        sideDirection: .right, sideFileName: "side.png"
    )
    archive.preferredPresentationMode = .twoD
    let quality = try QualityCharacterEngine(archive: archive)
    #expect(quality.hybrid3DEnabled == false)
    #expect(quality.front.viewAngleXOverride == 0)
    #expect(quality.front.viewAngleYOverride == nil)
    #expect(quality.side.viewAngleYOverride == nil)
}

@Test @MainActor func qualityEngineSanitizesNonFinitePublicInputs() async throws {
    let archive = try await AutoRigPipeline().makeQualityArchive(
        front: syntheticCharacterImage(), side: syntheticCharacterImage(),
        sideDirection: .right, sideFileName: "side.png"
    )
    let quality = try QualityCharacterEngine(archive: archive)
    quality.automaticTurn = false
    quality.viewTurn = .nan
    quality.viewPitch = .nan
    quality.externalGazeTarget = SIMD2(.nan, 0)
    #expect(quality.viewTurn == 0)
    #expect(quality.viewPitch == 0)
    #expect(quality.externalGazeTarget == nil)
}

@Test @MainActor func legacyQuality2DLeavesPerspectiveYawUnforced() async throws {
    var archive = try await AutoRigPipeline().makeQualityArchive(
        front: syntheticCharacterImage(), side: syntheticCharacterImage(),
        sideDirection: .right, sideFileName: "legacy-side.png"
    )
    archive.front.rig.formatVersion = 1
    // Model a real legacy front rig: no rotate3D, perspectiveShift retained.
    if let index = archive.front.rig.parts.firstIndex(where: { $0.kind == .head }) {
        archive.front.rig.parts[index].deformations.removeAll {
            if case .rotate3D = $0 { return true }
            return false
        }
        archive.front.rig.parts[index].deformations.append(
            .perspectiveShift(parameterX: .angleX, parameterY: .angleY, strength: 0.06)
        )
    }
    let quality = try QualityCharacterEngine(archive: archive)
    quality.hybrid3DEnabled = false
    quality.viewTurn = 0.5
    #expect(quality.front.viewAngleXOverride == nil)
}

@Test func qualityHybridKeepsSmallTurnsOnTheDepthRigBeforeCrossfading() {
    #expect(QualityHybridTurnModel.profileBlend(viewTurn: 0.3, sideDirection: .right) == 0)
    let middle = QualityHybridTurnModel.profileBlend(viewTurn: 0.6, sideDirection: .right)
    #expect(middle > 0 && middle < 1)
    #expect(QualityHybridTurnModel.profileBlend(viewTurn: 0.9, sideDirection: .right) == 1)
    #expect(QualityHybridTurnModel.profileBlend(viewTurn: -0.9, sideDirection: .right) == 0)
}

@Test func qualityHybridStartsCrossfadeAtThePersistedYawLimit() {
    let limits = ValidatedPoseLimits(
        minimumYawDegrees: -20,
        maximumYawDegrees: 10,
        minimumPitchDegrees: -6,
        maximumPitchDegrees: 6
    )
    #expect(
        QualityHybridTurnModel.profileBlend(
            viewTurn: 0.17,
            sideDirection: .right,
            validatedPoseLimits: limits
        ) == 0
    )
    #expect(
        QualityHybridTurnModel.profileBlend(
            viewTurn: 0.2,
            sideDirection: .right,
            validatedPoseLimits: limits
        ) > 0
    )
}

@Test @MainActor func metalRendererCompilesDepthAndFeatherPipelines() async throws {
    let avatar = try await AutoRigPipeline().makeAvatar(from: syntheticCharacterImage())
    _ = try AvatarMetalView(avatar: avatar)
}
