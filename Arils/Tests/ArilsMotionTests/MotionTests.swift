import Foundation
import simd
import Testing

import ArilsCore
@testable import ArilsMotion

private func makeController(seed: UInt64 = 7) -> MotionController {
    MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(seed: seed)
    )
}

/// Runs a controller at 60 fps for `seconds`, collecting every frame.
private func run(
    _ controller: MotionController,
    seconds: Double,
    from start: Double = 0,
    inputs: (Double) -> MotionInputs = { _ in MotionInputs() }
) -> [[ParameterID: Float]] {
    var frames: [[ParameterID: Float]] = []
    var time = start
    while time < start + seconds {
        frames.append(controller.update(at: time, inputs: inputs(time)))
        time += 1.0 / 60.0
    }
    return frames
}

// MARK: - Controller

@Test func controllerIsDeterministicForSameSeed() {
    let framesA = run(makeController(seed: 99), seconds: 5)
    let framesB = run(makeController(seed: 99), seconds: 5)
    for (a, b) in zip(framesA, framesB) {
        for (id, value) in a {
            #expect(value == b[id])
        }
    }
}

@Test func differentSeedsProduceDifferentMotion() {
    let framesA = run(makeController(seed: 1), seconds: 2)
    let framesB = run(makeController(seed: 2), seconds: 2)
    var differing = 0
    for (a, b) in zip(framesA, framesB) where a[.angleX] != b[.angleX] {
        differing += 1
    }
    #expect(differing > 30)
}

@Test func allOutputsStayFiniteAndClamped() {
    let descriptorByID = Dictionary(
        StandardParameters.all.map { ($0.id, $0) },
        uniquingKeysWith: { a, _ in a }
    )
    let frames = run(makeController(), seconds: 10, inputs: { time in
        MotionInputs(
            pointer: SIMD2(Float(sin(time)), Float(cos(time * 0.7))),
            isSpeaking: time > 5,
            petting: time > 3 && time < 4
                ? PettingInput(position: SIMD2(0.2, 0.8), velocity: SIMD2(3, 0))
                : nil,
            energy: 0.8
        )
    })
    for frame in frames {
        for (id, value) in frame {
            #expect(value.isFinite)
            if let descriptor = descriptorByID[id] {
                #expect(value >= descriptor.minimum - 0.0001)
                #expect(value <= descriptor.maximum + 0.0001)
            }
        }
    }
}

// MARK: - Face tracking

@Test func faceTrackingCalibrationIsAdditiveAndConfidenceWeighted() {
    let input = FaceTrackingInput(
        yawDegrees: 20,
        pitchDegrees: -10,
        rollDegrees: 8,
        leftEyeAspectRatio: 0.08,
        rightEyeAspectRatio: 0.34,
        mouthAspectRatio: 0.62,
        confidence: 0.5
    )
    let bias = FaceTrackingLayer.bias(for: input, blend: 0.8)
    #expect(bias.yawDegrees > 4)
    #expect(bias.pitchDegrees < 0)
    #expect(bias.rollDegrees > 0)
    #expect(bias.leftEyeOpen < 0)
    #expect(bias.rightEyeOpen > 0)
    #expect(bias.mouthOpen > 0)
    #expect(FaceTrackingLayer.bias(for: input, blend: 0) == .zero)
}

@Test func faceTrackingLayerBiasesAuthoredMotionWithoutTakingItOver() {
    let tracked = makeController(seed: 42)
    let baseline = makeController(seed: 42)
    let sample = FaceTrackingInput(
        yawDegrees: 18,
        pitchDegrees: 10,
        rollDegrees: -8,
        leftEyeAspectRatio: 0.08,
        rightEyeAspectRatio: 0.08,
        mouthAspectRatio: 0.65,
        confidence: 1
    )
    var trackedFrame: [ParameterID: Float] = [:]
    var baselineFrame: [ParameterID: Float] = [:]
    var time = 0.0
    while time < 1 {
        trackedFrame = tracked.update(
            at: time,
            inputs: MotionInputs(
                isSpeaking: true,
                lipSync: LipSyncFrame(open: 0.2, form: 0),
                faceTracking: sample,
                faceTrackingBlend: 0.7
            )
        )
        baselineFrame = baseline.update(
            at: time,
            inputs: MotionInputs(
                isSpeaking: true,
                lipSync: LipSyncFrame(open: 0.2, form: 0)
            )
        )
        time += 1.0 / 60.0
    }

    #expect(trackedFrame[.angleX]! > baselineFrame[.angleX]!)
    #expect(trackedFrame[.angleY]! > baselineFrame[.angleY]!)
    #expect(trackedFrame[.angleZ]! < baselineFrame[.angleZ]!)
    #expect(trackedFrame[.eyeLeftOpen]! < baselineFrame[.eyeLeftOpen]!)
    // LipSync still owns the 0.2 base; tracking only adds a bounded opening.
    #expect(trackedFrame[.mouthOpen]! > baselineFrame[.mouthOpen]!)
    #expect(trackedFrame[.mouthOpen]! < 0.75)
}

// MARK: - Breathing & idle

@Test func breathingCyclesOverTime() {
    let frames = run(makeController(), seconds: 12)
    let breaths = frames.compactMap { $0[.breath] }
    #expect(breaths.max()! > 0.5)
    #expect(breaths.min()! < 0.25)
    // Multiple cycles: value crosses 0.4 several times.
    var crossings = 0
    for pair in zip(breaths, breaths.dropFirst())
    where (pair.0 < 0.4) != (pair.1 < 0.4) {
        crossings += 1
    }
    #expect(crossings >= 4)
}

@Test func idleMotionNeverFreezes() {
    let frames = run(makeController(), seconds: 8)
    let angles = frames.compactMap { $0[.angleZ] }
    let spread = angles.max()! - angles.min()!
    #expect(spread > 0.3) // visibly alive
    #expect(spread < 20)  // but not flailing
}

// MARK: - Blink

@Test func characterBlinksButEyesStayMostlyOpen() {
    let frames = run(makeController(), seconds: 30)
    let openness = frames.compactMap { $0[.eyeLeftOpen] }
    let closedFrames = openness.filter { $0 < 0.3 }.count
    #expect(closedFrames >= 4) // several blinks happened
    let average = openness.reduce(0, +) / Float(openness.count)
    #expect(average > 0.75) // mostly open
}

// MARK: - Gaze

@Test func gazeFollowsPointerWithLag() {
    let controller = makeController()
    // Settle without a pointer, then jump a moving pointer to the right.
    _ = run(controller, seconds: 2)
    var eyeXAtJump: Float = 0
    var frames: [[ParameterID: Float]] = []
    var time = 2.0
    var first = true
    while time < 6.0 {
        // Keep the pointer moving slightly so interest stays high.
        let wiggle = Float(sin(time * 5)) * 0.05
        let frame = controller.update(
            at: time,
            inputs: MotionInputs(pointer: SIMD2(0.8 + wiggle, 0.1))
        )
        if first {
            eyeXAtJump = frame[.eyeBallX] ?? 0
            first = false
        }
        frames.append(frame)
        time += 1.0 / 60.0
    }
    // Immediately after the jump the eyes had not reached the target...
    #expect(eyeXAtJump < 0.4)
    // ...but they get there (and mostly stay, aversion aside). With the
    // vestibulo-ocular counter-roll the eyes lead, then recentre as the head
    // turns, so check the whole settled window rather than one late second.
    let laterX = frames.dropFirst(30).compactMap { $0[.eyeBallX] }
    #expect(laterX.max()! > 0.45)
    #expect(frames.dropFirst(30).compactMap { $0[.angleX] }.max()! > 3)
}

@Test func gazeSaccadeResponseIsStableAcrossFrameRates() {
    func eyePosition(fps: Int, after seconds: Double) -> Float {
        let gaze = GazeLayer(seed: 7)
        var values = ParameterValues(descriptors: StandardParameters.all)
        let frameCount = Int((seconds * Double(fps)).rounded())
        for frame in 0...frameCount {
            values.clear()
            gaze.update(
                context: MotionContext(
                    time: Double(frame) / Double(fps),
                    deltaTime: frame == 0 ? 0 : 1 / Float(fps),
                    inputs: MotionInputs(pointer: SIMD2(0.8, 0.1))
                ),
                values: &values
            )
        }
        return values.resolved()[.eyeBallX] ?? 0
    }

    let at60Hz = eyePosition(fps: 60, after: 0.1)
    let at120Hz = eyePosition(fps: 120, after: 0.1)
    let at240Hz = eyePosition(fps: 240, after: 0.1)
    #expect(abs(at60Hz - at120Hz) < 0.06)
    #expect(abs(at60Hz - at240Hz) < 0.06)
}

@Test func gazeReturnsTowardRestWhenPointerLeaves() {
    let controller = makeController()
    _ = run(controller, seconds: 3, inputs: { time in
        MotionInputs(pointer: SIMD2(0.9, 0.2 + Float(sin(time * 3)) * 0.1))
    })
    let frames = run(controller, seconds: 6, from: 3)
    let finalX = frames.suffix(30).compactMap { $0[.eyeBallX] }
    // Idle wander keeps |x| well below the pointer's 0.9.
    #expect(abs(finalX.last!) < 0.45)
}

@Test func parkedPointerLosesAttention() {
    let controller = makeController()
    // Move to earn interest, then park the pointer for a long while.
    _ = run(controller, seconds: 1.5, inputs: { time in
        MotionInputs(pointer: SIMD2(Float(sin(time * 4)) * 0.8, 0))
    })
    let frames = run(controller, seconds: 25, from: 1.5, inputs: { _ in
        MotionInputs(pointer: SIMD2(0.85, 0))
    })
    // At some point the gaze wanders visibly away from the parked target.
    let wandered = frames.contains { abs(($0[.eyeBallX] ?? 1) - 0.85 * 0.88) > 0.3 }
    #expect(wandered)
}

// MARK: - Lip sync

@Test func mouthOpensWithAudioAndClosesAfter() {
    let controller = makeController()
    let speaking = run(controller, seconds: 1, inputs: { _ in
        MotionInputs(isSpeaking: true, lipSync: LipSyncFrame(open: 0.8, form: 0.3))
    })
    #expect(speaking.suffix(10).compactMap { $0[.mouthOpen] }.max()! > 0.6)

    let silent = run(controller, seconds: 1, from: 1)
    #expect(silent.suffix(10).compactMap { $0[.mouthOpen] }.max()! < 0.05)
}

@Test func proceduralSpeechMovesMouthWithoutAudio() {
    let frames = run(makeController(), seconds: 4, inputs: { _ in
        MotionInputs(isSpeaking: true)
    })
    let opens = frames.compactMap { $0[.mouthOpen] }
    #expect(opens.max()! > 0.2)
    #expect(opens.min()! < 0.1) // articulated, not a frozen open mouth
}

@Test func mouthStaysShutWhenIdle() {
    let frames = run(makeController(), seconds: 3)
    #expect(frames.compactMap { $0[.mouthOpen] }.max()! < 0.05)
}

// MARK: - Petting

@Test func pettingSquashesTiltsAndRecovers() {
    let controller = makeController()
    _ = run(controller, seconds: 1)
    let petted = run(controller, seconds: 1.5, from: 1, inputs: { _ in
        MotionInputs(petting: PettingInput(position: SIMD2(0.6, 0.8), velocity: SIMD2(2.5, 0)))
    })
    let squash = petted.suffix(20).compactMap { $0[.touchSquash] }
    #expect(squash.max()! > 0.2)
    // Leans toward the stroke side (positive x → positive tilt).
    let tilt = petted.suffix(20).compactMap { $0[.angleZ] }
    #expect(tilt.reduce(0, +) / Float(tilt.count) > 1)
    // Sinks a little.
    let sink = petted.suffix(20).compactMap { $0[.bodyY] }
    #expect(sink.reduce(0, +) / Float(sink.count) < -0.02)

    let released = run(controller, seconds: 4, from: 2.5)
    #expect(abs(released.suffix(5).compactMap { $0[.touchSquash] }.last!) < 0.1)
}

@Test func nonFinitePettingInputDoesNotPoisonLaterMotion() {
    let controller = makeController()
    _ = run(controller, seconds: 1, inputs: { _ in
        MotionInputs(petting: PettingInput(
            position: SIMD2(0.4, 0.8),
            velocity: SIMD2(2, 0)
        ))
    })
    let invalid = controller.update(
        at: 1,
        inputs: MotionInputs(petting: PettingInput(
            position: SIMD2(.nan, 0.8),
            velocity: SIMD2(.infinity, 0)
        ))
    )
    let recovered = run(controller, seconds: 2, from: 1 + 1.0 / 60.0)

    #expect(invalid.values.allSatisfy { $0.isFinite })
    #expect(recovered.allSatisfy { frame in frame.values.allSatisfy { $0.isFinite } })
    #expect(abs(recovered.last?[.touchSquash] ?? 1) < 0.1)
}

@Test func pettingStirsHairPhysics() {
    let controller = makeController()
    _ = run(controller, seconds: 1)
    let petted = run(controller, seconds: 2, from: 1, inputs: { time in
        // A vigorous back-and-forth stroke.
        MotionInputs(petting: PettingInput(
            position: SIMD2(Float(sin(time * 6)) * 0.7, 0.8),
            velocity: SIMD2(Float(cos(time * 6)) * 4, 0)
        ))
    })
    let sway = petted.compactMap { $0[.hairFrontSway] }
    #expect(sway.map(abs).max()! > 0.05)
}

@Test func hairRecoversQuicklyAfterSustainedPetting() {
    // Regression: per-frame velocity kicks used to integrate into huge
    // oscillator velocities, pinning the hair at ±1 long after release.
    let controller = makeController()
    _ = run(controller, seconds: 3, inputs: { time in
        MotionInputs(petting: PettingInput(
            position: SIMD2(Float(sin(time * 6)) * 0.7, 0.8),
            velocity: SIMD2(Float(cos(time * 6)) * 4, 0)
        ))
    })
    let released = run(controller, seconds: 2.5, from: 3)
    let tail = released.suffix(30).compactMap { $0[.hairFrontSway] }
    #expect(tail.map(abs).max()! < 0.35)
}

// MARK: - Sneeze

@Test func manualSneezeRunsTheFullProfile() {
    let controller = MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(seed: 7, sneezeInterval: .infinity)
    )
    _ = run(controller, seconds: 1)
    controller.requestSneeze()
    let frames = run(controller, seconds: 2.6, from: 1)

    // Inhale: the head tips back at some point.
    #expect(frames.contains { ($0[.angleY] ?? 0) > 3 })
    // Burst: head whips forward with the mouth open and the eyes shut.
    #expect(frames.contains {
        ($0[.angleY] ?? 0) < -6 && ($0[.mouthOpen] ?? 0) > 0.5 && ($0[.eyeLeftOpen] ?? 1) < 0.15
    })
    // The burst kicks the hair physics.
    #expect(frames.compactMap { $0[.hairFrontSway] }.map(abs).max()! > 0.05)
    // Fully recovered by the end.
    #expect(abs(frames.last![.angleY] ?? 0) < 6)
    #expect((frames.last![.mouthOpen] ?? 1) < 0.15)
}

@Test func hostDrivenPitchPreservesTheSneezeProfile() {
    let controller = MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(seed: 7, sneezeInterval: .infinity)
    )
    let inputs: (Double) -> MotionInputs = { _ in MotionInputs(headPitch: 8) }
    _ = run(controller, seconds: 1, inputs: inputs)
    controller.requestSneeze()
    let frames = run(controller, seconds: 2.6, from: 1, inputs: inputs)

    #expect(frames.contains { ($0[.angleY] ?? 0) > 10 })
    #expect(frames.contains {
        ($0[.angleY] ?? 0) < 1 && ($0[.mouthOpen] ?? 0) > 0.5 && ($0[.eyeLeftOpen] ?? 1) < 0.15
    })
}

@Test func spontaneousSneezesFollowTheConfiguredInterval() {
    let controller = MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(seed: 11, sneezeInterval: 15)
    )
    let frames = run(controller, seconds: 60)
    let burstFrames = frames.filter {
        ($0[.angleY] ?? 0) < -6 && ($0[.mouthOpen] ?? 0) > 0.5
    }
    #expect(!burstFrames.isEmpty)
}

@Test func infiniteIntervalDisablesSpontaneousSneezes() {
    let controller = MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(seed: 11, sneezeInterval: .infinity)
    )
    let frames = run(controller, seconds: 60)
    let burstFrames = frames.filter {
        ($0[.angleY] ?? 0) < -6 && ($0[.mouthOpen] ?? 0) > 0.5
    }
    #expect(burstFrames.isEmpty)
}

// MARK: - Sway physics

@Test func swaySettlesAfterExcitation() {
    let sway = SwaySimulator(
        channels: [SwayChannelSettings(
            output: .hairFrontSway, frequency: 1.7, dampingRatio: 0.25, headDrive: 1, breeze: 0
        )],
        seed: 5
    )
    var values = ParameterValues(descriptors: StandardParameters.all)
    var time = 0.0
    var peak: Float = 0
    // Excite for half a second...
    while time < 0.5 {
        values.clear()
        sway.update(
            context: MotionContext(time: time, deltaTime: 1 / 60, inputs: MotionInputs()),
            headAngularVelocity: 60,
            impulse: 0,
            values: &values
        )
        peak = max(peak, abs(values.resolved()[.hairFrontSway]!))
        time += 1.0 / 60.0
    }
    #expect(peak > 0.05)
    // ...then let it ring down.
    var final: Float = 1
    while time < 6 {
        values.clear()
        sway.update(
            context: MotionContext(time: time, deltaTime: 1 / 60, inputs: MotionInputs()),
            headAngularVelocity: 0,
            impulse: 0,
            values: &values
        )
        final = abs(values.resolved()[.hairFrontSway]!)
        time += 1.0 / 60.0
    }
    #expect(final < 0.02)
}

// MARK: - Lip sync analyzer

private func sineWave(frequency: Double, amplitude: Float, count: Int, sampleRate: Double) -> [Float] {
    (0..<count).map { index in
        amplitude * Float(sin(2.0 * .pi * frequency * Double(index) / sampleRate))
    }
}

@Test func silenceProducesClosedMouth() {
    let analyzer = LipSyncAnalyzer()
    let frame = analyzer.analyze(window: [Float](repeating: 0, count: 1024), sampleRate: 48_000)
    #expect(frame.open < 0.02)
}

@Test func loudLowToneOpensMouthWithRoundForm() {
    let analyzer = LipSyncAnalyzer()
    let window = sineWave(frequency: 250, amplitude: 0.4, count: 1024, sampleRate: 48_000)
    let frame = analyzer.analyze(window: window, sampleRate: 48_000)
    #expect(frame.open > 0.5)
    #expect(frame.form < -0.3) // low-frequency energy → round vowel
}

@Test func brightToneYieldsWideForm() {
    let analyzer = LipSyncAnalyzer()
    let window = sineWave(frequency: 3000, amplitude: 0.4, count: 1024, sampleRate: 48_000)
    let frame = analyzer.analyze(window: window, sampleRate: 48_000)
    #expect(frame.open > 0.5)
    #expect(frame.form > 0.3) // high-frequency energy → wide vowel
}

@Test func pushedSamplesProduceCurrentFrame() {
    let analyzer = LipSyncAnalyzer()
    analyzer.push(
        samples: sineWave(frequency: 440, amplitude: 0.3, count: 2048, sampleRate: 44_100),
        sampleRate: 44_100
    )
    let frame = analyzer.currentFrame()
    #expect(frame != nil)
    #expect(frame!.open > 0.3)
}

@Test func invalidSampleRatesAreSafeForLiveAndDirectAnalysis() {
    let analyzer = LipSyncAnalyzer()
    let loudWindow = [Float](repeating: 0.4, count: 1024)

    // Direct callers still receive level-driven openness, but no spectral
    // shape when there is no valid frequency scale.
    let direct = analyzer.analyze(window: loudWindow, sampleRate: 0)
    #expect(direct.open > 0.5)
    #expect(direct.form == 0)

    // The live path ignores a malformed audio-format buffer, instead of
    // retaining a zero rate that would later reach spectral bin calculation.
    analyzer.push(samples: loudWindow, sampleRate: 0)
    #expect(analyzer.currentFrame() == nil)
}

@Test func timelineAnalysisCoversWholeClip() {
    let analyzer = LipSyncAnalyzer()
    let sampleRate = 24_000.0
    var samples = sineWave(frequency: 300, amplitude: 0.4, count: 12_000, sampleRate: sampleRate)
    samples.append(contentsOf: [Float](repeating: 0, count: 12_000))
    let frames = analyzer.analyzeTimeline(samples: samples, sampleRate: sampleRate, frameRate: 60)
    #expect(frames.count == 60) // 1 second of audio
    #expect(frames[15].open > 0.5)  // during the tone
    #expect(frames[55].open < 0.05) // during the silence
}

@Test func timelineAnalysisIncludesPartialFinalFrame() {
    let analyzer = LipSyncAnalyzer()
    let sampleRate = 24_000.0
    let samples = sineWave(frequency: 300, amplitude: 0.4, count: 24_001, sampleRate: sampleRate)
    let frames = analyzer.analyzeTimeline(samples: samples, sampleRate: sampleRate, frameRate: 60)
    #expect(frames.count == 61)
    #expect(frames.last!.open > 0.5)
}

@Test func headTurnGainWidensTheHeadAndBringsTheBodyAlong() {
    func settle(gain: Float) -> [ParameterID: Float] {
        let gaze = GazeLayer(seed: 7, personality: .standard, cues: MotionCues(), headTurnGain: gain)
        var values = ParameterValues(descriptors: StandardParameters.all)
        for frame in 0...(60 * 4) {
            values.clear()
            gaze.update(
                context: MotionContext(
                    time: Double(frame) / 60,
                    deltaTime: frame == 0 ? 0 : 1 / 60,
                    inputs: MotionInputs(pointer: SIMD2(0.9, 0.4))
                ),
                values: &values
            )
        }
        return values.resolved()
    }

    let standard = settle(gain: 1)
    let wide = settle(gain: 2)
    // Same gaze, same seed: the head simply turns and tilts twice as far.
    #expect(abs(wide[.angleX]! - 2 * standard[.angleX]!) < 0.01)
    #expect(abs(wide[.angleY]! - 2 * standard[.angleY]!) < 0.01)
    // The torso stays out of gaze at the standard range and follows the
    // same side when the range is widened.
    #expect(standard[.bodyAngleX] ?? 0 == 0)
    #expect(wide[.bodyAngleX]! > 1)
    #expect(wide[.bodyAngleZ]! > 0)
}
