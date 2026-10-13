import Foundation
import simd
import Testing

import ArilsCore
@testable import ArilsMotion

private func controller(
    seed: UInt64 = 7,
    personality: MotionPersonality = .standard,
    microActions: Bool = false
) -> MotionController {
    MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(
            seed: seed,
            sneezeInterval: .infinity,
            personality: personality,
            microActionsEnabled: microActions
        )
    )
}

private func record(
    _ controller: MotionController,
    seconds: Double,
    from start: Double = 0,
    frameRate: Double = 60,
    inputs: (Double) -> MotionInputs = { _ in MotionInputs() }
) -> MotionTrace {
    var trace = MotionTrace(frameRate: frameRate)
    let count = Int((seconds * frameRate).rounded())
    for index in 0..<count {
        let time = start + Double(index) / frameRate
        trace.frames.append(controller.update(at: time, inputs: inputs(time)))
    }
    return trace
}

private func eyes(_ trace: MotionTrace) -> [Float] {
    zip(trace.series(.eyeLeftOpen, default: 1), trace.series(.eyeRightOpen, default: 1)).map { ($0 + $1) / 2 }
}

/// Difference of one channel between a run that switches behavior at
/// `switchAt` and an identical run that never does (same seed), which
/// cancels the shared ambient motion.
private func behaviorResponse(
    _ id: ParameterID,
    to behavior: MotionBehavior,
    hesitation: Float? = nil,
    personality: MotionPersonality = .standard,
    seconds: Double = 6,
    switchAt: Double = 2
) -> [Float] {
    let switched = record(controller(personality: personality), seconds: seconds) { time in
        MotionInputs(behavior: time < switchAt ? .idle : behavior, hesitation: hesitation)
    }
    let baseline = record(controller(personality: personality), seconds: seconds) { _ in
        MotionInputs(hesitation: hesitation)
    }
    return Array(zip(switched.series(id), baseline.series(id)).map { $0 - $1 }.dropFirst(Int(switchAt * 60)))
}

// MARK: - Attitude (1)

@Test func thinkingPostureAppearsAfterAHesitantDelay() {
    let response = behaviorResponse(.mouthForm, to: .thinking, hesitation: 1)
    // Reaction delay at full hesitation is ~0.46 s: nothing moves at first...
    #expect(response.prefix(20).allSatisfy { abs($0) < 0.01 })
    // ...then the pursed thinking mouth settles in.
    #expect(MotionMetrics.mean(Array(response.suffix(60))) < -0.15)
}

@Test func hesitationSlowsAndWobblesTheTransition() {
    func halfwayFrame(_ response: [Float]) -> Int {
        let final = MotionMetrics.mean(Array(response.suffix(60)))
        return response.firstIndex { abs($0) >= abs(final) * 0.5 } ?? response.count
    }
    func overshoot(_ response: [Float]) -> Float {
        let final = MotionMetrics.mean(Array(response.suffix(60)))
        let peak = response.map { $0 * (final < 0 ? -1 : 1) }.max() ?? 0
        return peak / abs(final) - 1
    }
    let confident = behaviorResponse(.mouthForm, to: .thinking, hesitation: 0)
    let unsure = behaviorResponse(.mouthForm, to: .thinking, hesitation: 1)
    #expect(halfwayFrame(unsure) > halfwayFrame(confident) + 12) // ≥ 200 ms later
    #expect(overshoot(confident) < 0.02)
    #expect(overshoot(unsure) > 0.08)
}

@Test func surpriseIsAFastStartleWithWideEyesAndHeldBlinks() {
    let headBack = behaviorResponse(.angleY, to: .surprised, seconds: 4)
    // Reflexive: the head is already well back within 150 ms.
    #expect(headBack.prefix(9).max()! > 2)
    let trace = record(controller(), seconds: 4) { time in
        MotionInputs(behavior: time < 2 ? .idle : .surprised)
    }
    let startle = Array(eyes(trace)[(2 * 60 + 12)..<(2 * 60 + 54)]) // 0.2–0.9 s after
    #expect(startle.min()! > 1.05) // wide open, no blink while startled
    let hair = trace.series(.hairFrontSway)
    #expect(hair[(2 * 60)...].map(abs).max()! > 0.05)
}

@Test func returningFromSurpriseBlinks() {
    let trace = record(controller(), seconds: 5) { time in
        MotionInputs(behavior: time >= 1 && time < 2.5 ? .surprised : .idle)
    }
    let after = MotionMetrics.blinks(openness: eyes(trace), frameRate: 60).filter { $0.start > 2.5 && $0.start < 3.2 }
    #expect(!after.isEmpty)
}

@Test func speakingImpliesSpeakingPostureEvenWithIdleBehavior() {
    #expect(MotionInputs(isSpeaking: true).effectiveBehavior == .speaking)
    #expect(MotionInputs(isSpeaking: true, behavior: .surprised).effectiveBehavior == .surprised)
    let motion = controller()
    _ = record(motion, seconds: 2) { _ in MotionInputs(isSpeaking: true) }
    #expect(motion.appliedBehavior == .speaking)
}

// MARK: - Personality (6)

@Test func personalitySanitizesCorruptValues() {
    let corrupt = MotionPersonality(
        hesitation: .nan, responsiveness: 100, idleAmplitude: -3, blinkRate: .infinity,
        fidgetRate: 9, shyness: 2, expressiveness: .nan
    ).sanitized
    #expect(corrupt.hesitation == 0.35)
    #expect(corrupt.responsiveness == 1.8)
    #expect(corrupt.idleAmplitude == 0)
    #expect(corrupt.blinkRate == 1)
    #expect(corrupt.fidgetRate == 2.5)
    #expect(corrupt.shyness == 1)
    #expect(corrupt.expressiveness == 1)
}

@Test func personalitiesChangeHowTheCharacterMoves() {
    func halfway(_ personality: MotionPersonality) -> Int {
        let response = behaviorResponse(.mouthForm, to: .thinking, personality: personality)
        let final = MotionMetrics.mean(Array(response.suffix(60)))
        return response.firstIndex { abs($0) >= abs(final) * 0.5 } ?? response.count
    }
    #expect(halfway(.lively) < halfway(.standard))
    #expect(halfway(.clumsy) > halfway(.standard))

    func averted(_ personality: MotionPersonality) -> Float {
        var shares: [Float] = []
        for seed in UInt64(1)...4 {
            let trace = record(controller(seed: seed, personality: personality), seconds: 60) { time in
                MotionInputs(pointer: SIMD2(0.3 + Float(sin(time * 5)) * 0.25, 0.1))
            }
            let away = trace.series(.eyeBallX).enumerated().filter { index, eye in
                abs(eye - Float(0.3 + sin(Double(index) / 60 * 5) * 0.25) * 0.88 * 0.725) > 0.3
            }.count
            shares.append(Float(away) / Float(trace.frames.count))
        }
        return MotionMetrics.mean(shares)
    }
    #expect(averted(.shy) > averted(.lively) * 2)
}

// MARK: - Blink & gaze coupling (3)

@Test func blinkTimingIsIrregularWithPartialBlinks() {
    let trace = record(controller(seed: 3), seconds: 300)
    let blinks = MotionMetrics.blinks(openness: eyes(trace), frameRate: 60)
    let perMinute = Float(blinks.count) / 5
    #expect(perMinute > 12 && perMinute < 28)
    let intervals = zip(blinks.dropFirst(), blinks).map { Float($0.start - $1.start) }
    #expect(MotionMetrics.coefficientOfVariation(intervals) > 0.5)
    #expect(blinks.contains { $0.depth < 0.9 })
}

@Test func concentrationLowersAndTalkRaisesBlinkRate() {
    func rate(_ inputs: MotionInputs) -> Int {
        var total = 0
        for seed in UInt64(1)...4 {
            let trace = record(controller(seed: seed), seconds: 120) { _ in inputs }
            total += MotionMetrics.blinks(openness: eyes(trace), frameRate: 60).count
        }
        return total
    }
    #expect(rate(MotionInputs(behavior: .thinking)) < rate(MotionInputs(behavior: .idle)))
    #expect(rate(MotionInputs(isSpeaking: true)) > rate(MotionInputs(behavior: .thinking)))
}

@Test func largeGazeShiftsEvokeBlinks() {
    var evoked = 0
    var shifts = 0
    for seed in UInt64(1)...6 {
        let trace = record(controller(seed: seed), seconds: 40) { time in
            // Pointer hops between far corners every 2 s, with a tremor.
            let side: Float = Int(time / 2) % 2 == 0 ? -0.85 : 0.85
            return MotionInputs(pointer: SIMD2(side + Float(sin(time * 9)) * 0.01, 0.2))
        }
        let saccades = MotionMetrics.saccades(eyeX: trace.series(.eyeBallX), eyeY: trace.series(.eyeBallY), frameRate: 60)
            .filter { $0.amplitude > 0.6 }
        let blinks = MotionMetrics.blinks(openness: eyes(trace), frameRate: 60)
        shifts += saccades.count
        evoked += saccades.filter { saccade in blinks.contains { abs($0.start - saccade.start) < 0.2 } }.count
    }
    let ratio = Float(evoked) / Float(max(1, shifts))
    #expect(ratio > 0.2 && ratio < 0.7)
}

@Test func saccadeDurationFollowsTheMainSequence() {
    #expect(GazeLayer.saccadeDuration(amplitude: 0.2) < GazeLayer.saccadeDuration(amplitude: 1.0))
    #expect(GazeLayer.saccadeDuration(amplitude: 1.0) <= 0.12)

    let trace = record(controller(), seconds: 4) { time in
        MotionInputs(pointer: time < 2 ? SIMD2(-0.8, 0) : SIMD2(0.8, 0))
    }
    let jump = MotionMetrics.saccades(eyeX: trace.series(.eyeBallX), eyeY: trace.series(.eyeBallY), frameRate: 60)
        .filter { $0.start > 1.9 && $0.amplitude > 0.5 }
    #expect(!jump.isEmpty)
    #expect(jump.allSatisfy { $0.duration <= 0.12 })
}

@Test func eyesLeadThenRecentreAsTheHeadArrives() {
    let trace = record(controller(), seconds: 5) { time in
        MotionInputs(pointer: time < 1 ? nil : SIMD2(0.8 + Float(sin(time * 7)) * 0.02, 0))
    }
    let eyeX = Array(trace.series(.eyeBallX)[(60 + 6)...(60 + 30)])
    let lateEye = MotionMetrics.mean(Array(trace.series(.eyeBallX)[(3 * 60)..<(4 * 60)]))
    let lateHead = MotionMetrics.mean(Array(trace.series(.angleX)[(3 * 60)..<(4 * 60)]))
    #expect(eyeX.max()! > lateEye + 0.05) // the eyes got there first
    #expect(lateHead > 4) // the head followed
}

@Test func lidsFollowDownwardGaze() {
    let down = record(controller(), seconds: 6) { time in
        MotionInputs(pointer: SIMD2(0, -0.9 + Float(sin(time * 7)) * 0.02))
    }
    let up = record(controller(), seconds: 6) { time in
        MotionInputs(pointer: SIMD2(0, 0.6 + Float(sin(time * 7)) * 0.02))
    }
    // Median avoids blinks.
    func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
    #expect(median(Array(eyes(down).suffix(180))) < median(Array(eyes(up).suffix(180))) - 0.1)
}

@Test func motionIsTheSameAtAnyFrameRate() {
    func run(_ fps: Double) -> MotionTrace {
        record(controller(seed: 9, microActions: true), seconds: 10, frameRate: fps) { time in
            var inputs = MotionInputs(pointer: time >= 3 ? SIMD2(0.6, Float(sin(time)) * 0.3) : nil)
            inputs.isSpeaking = time >= 6
            inputs.behavior = time >= 1.5 && time < 3 ? .thinking : .idle
            return inputs
        }
    }
    let low = run(30), mid = run(60), high = run(120)
    var differences: [Float] = []
    for descriptor in StandardParameters.all {
        let range = descriptor.maximum - descriptor.minimum
        for index in 0..<low.frames.count {
            let a = low.frames[index][descriptor.id] ?? 0
            let b = mid.frames[index * 2][descriptor.id] ?? 0
            let c = high.frames[index * 4][descriptor.id] ?? 0
            differences.append(max(abs(a - b), abs(b - c)) / range)
        }
    }
    differences.sort()
    #expect(differences[Int(Double(differences.count) * 0.99)] < 0.03)
}

// MARK: - Speech gestures (2)

/// Mouth-level pattern of speech: 0.9 s phrases separated by 0.35 s pauses,
/// with syllable-rate modulation inside phrases.
private func speechFrame(at time: Double) -> LipSyncFrame {
    let cycle = time.truncatingRemainder(dividingBy: 1.25)
    guard cycle < 0.9 else { return LipSyncFrame(open: 0, form: 0) }
    return LipSyncFrame(open: Float(0.35 + 0.35 * abs(sin(time * 2 * .pi * 3.5))), form: 0)
}

@Test func speakingStartsWithAnInhaleAndNodsAtPhraseBoundaries() {
    let motion = controller()
    _ = record(motion, seconds: 1)
    let speaking = record(motion, seconds: 8, from: 1) { time in
        MotionInputs(isSpeaking: true, lipSync: speechFrame(at: time - 1), behavior: .speaking)
    }
    #expect(speaking.series(.breath).prefix(30).max()! > 0.3)
    // Several phrase boundaries → several nods.
    #expect(motion.nodCount >= 2)
}

@Test func speakersMoveTheirHeadsMoreThanIdlePeople() {
    func headSpeed(_ trace: MotionTrace) -> Float {
        MotionMetrics.meanSpeed(trace.series(.angleX), frameRate: 60)
            + MotionMetrics.meanSpeed(trace.series(.angleY), frameRate: 60)
    }
    let idle = record(controller(), seconds: 10)
    let speaking = record(controller(), seconds: 10) { time in
        MotionInputs(isSpeaking: true, lipSync: speechFrame(at: time), behavior: .speaking)
    }
    #expect(headSpeed(speaking) > headSpeed(idle) * 1.5)
}

@Test func endOfUtteranceReturnsTheGazeToTheListener() {
    let motion = controller(seed: 2)
    let trace = record(motion, seconds: 6) { time in
        let speaking = time >= 1 && time < 3
        return MotionInputs(isSpeaking: speaking, lipSync: speaking ? speechFrame(at: time) : nil, behavior: .listening)
    }
    // Two seconds after speaking ends, a listening character looks near center.
    let settled = trace.series(.eyeBallX).suffix(60).map(abs)
    #expect(settled.max()! < 0.3)
}

@Test func listenersNodAtTheUsersPauses() {
    let motion = controller()
    var nodTimes: [Double] = []
    var last = 0
    // User talks 2 s, pauses 1 s.
    _ = record(motion, seconds: 30) { time in
        if motion.nodCount > last { nodTimes.append(time); last = motion.nodCount }
        let talking = time.truncatingRemainder(dividingBy: 3) < 2
        return MotionInputs(behavior: .listening, listenerVoiceLevel: talking ? 0.5 : 0.02)
    }
    #expect(nodTimes.count >= 4)
    // Nods land in the pauses, not over the user's speech.
    let inPause = nodTimes.filter { $0.truncatingRemainder(dividingBy: 3) >= 2 }
    #expect(Float(inPause.count) / Float(nodTimes.count) > 0.8)
}

// MARK: - Lip sync (4)

private func syllables(sampleRate: Double, seconds: Double, amplitude: Float, gap: (Double, Double)? = nil) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { index in
        let t = Double(index) / sampleRate
        if let gap, t >= gap.0, t < gap.1 { return 0 }
        let envelope = Float(0.5 + 0.5 * sin(t * 2 * .pi * 4))
        return amplitude * envelope * Float(sin(t * 2 * .pi * 220))
    }
}

@Test func timelineShutsTheMouthInAStopClosure() {
    let samples = syllables(sampleRate: 24_000, seconds: 1.2, amplitude: 0.4, gap: (0.6, 0.66))
    let timeline = LipSyncTimeline.analyze(samples: samples, sampleRate: 24_000)
    let closure = timeline.frames[37..<39].map(\.open)
    #expect(closure.allSatisfy { $0 == 0 })
    #expect(timeline.frames[20..<34].map(\.open).max()! > 0.6)
}

@Test func timelineNormalizesQuietSpeech() {
    let loud = LipSyncTimeline.analyze(samples: syllables(sampleRate: 24_000, seconds: 1, amplitude: 0.4), sampleRate: 24_000)
    let quiet = LipSyncTimeline.analyze(samples: syllables(sampleRate: 24_000, seconds: 1, amplitude: 0.04), sampleRate: 24_000)
    let loudMean = MotionMetrics.mean(loud.frames.map(\.open))
    let quietMean = MotionMetrics.mean(quiet.frames.map(\.open))
    #expect(abs(loudMean - quietMean) < 0.05)
}

@Test func timelineLeadsTheAudioAndEndsCleanly() {
    let frames = (0..<60).map { LipSyncFrame(open: $0 >= 30 ? 1 : 0, form: 0) }
    let timeline = LipSyncTimeline(frameRate: 60, frames: frames)
    // With the default lead the mouth is already opening before t = 0.5 s.
    #expect(timeline.frame(at: 0.46)!.open > 0.5)
    #expect(timeline.frame(at: 0.46, lead: 0)!.open == 0)
    #expect(timeline.frame(at: -1)!.open == 0)
    #expect(timeline.frame(at: 2) == nil)
    #expect(timeline.frame(at: 0.2)!.smoothing < 1)
}

@Test func liveAnalyzerGainKeepsQuietVoicesArticulating() {
    let quiet = LipSyncAnalyzer()
    let loud = LipSyncAnalyzer()
    // Quiet voice: −20 dB relative to the loud one.
    for chunk in 0..<10 {
        let loudSamples = (0..<1024).map { 0.3 * Float(sin(Double(chunk * 1024 + $0) * 2 * .pi * 220 / 24_000)) }
        loud.push(samples: loudSamples, sampleRate: 24_000)
        quiet.push(samples: loudSamples.map { $0 * 0.1 }, sampleRate: 24_000)
        _ = loud.currentFrame()
        _ = quiet.currentFrame()
    }
    let loudOpen = loud.currentFrame()!.open
    let quietOpen = quiet.currentFrame()!.open
    #expect(quietOpen > 0.5)
    #expect(quietOpen > loudOpen * 0.6)
    // Absolute analysis (no gain) of the same quiet window stays small.
    let window = (0..<1024).map { 0.03 * Float(sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    #expect(quiet.analyze(window: window, sampleRate: 24_000).open < quietOpen)
}

@Test func precomputedFramesCloseFasterThanLiveOnes() {
    func mouthAfterRelease(smoothing: Float) -> Float {
        let motion = controller()
        _ = record(motion, seconds: 0.5) { _ in
            MotionInputs(isSpeaking: true, lipSync: LipSyncFrame(open: 0.8, form: 0, smoothing: smoothing))
        }
        let closing = record(motion, seconds: 0.05, from: 0.5) { _ in
            MotionInputs(isSpeaking: true, lipSync: LipSyncFrame(open: 0, form: 0, smoothing: smoothing))
        }
        return closing.series(.mouthOpen).last!
    }
    #expect(mouthAfterRelease(smoothing: LipSyncTimeline.frameSmoothing) < mouthAfterRelease(smoothing: 1) * 0.5)
}

// MARK: - Micro-actions (5)

@Test func boredCharactersYawnAndDozeButEngagedOnesDoNot() {
    let unattended = controller(seed: 4, microActions: true)
    _ = record(unattended, seconds: 600)
    let kinds = Set(unattended.microActionHistory.map(\.kind))
    #expect(kinds.contains(.glance))
    #expect(kinds.contains(.weightShift))
    #expect(kinds.contains(.yawn) || kinds.contains(.doze))

    let engaged = controller(seed: 4, microActions: true)
    _ = record(engaged, seconds: 600) { time in
        MotionInputs(pointer: SIMD2(Float(sin(time * 3)) * 0.5, 0))
    }
    let engagedKinds = engaged.microActionHistory.map(\.kind)
    #expect(!engagedKinds.contains(.yawn) && !engagedKinds.contains(.doze) && !engagedKinds.contains(.glance))
}

@Test func yawnOpensTheMouthAndClosesTheEyes() {
    let motion = controller(microActions: true)
    _ = record(motion, seconds: 1)
    motion.requestMicroAction(.yawn)
    let trace = record(motion, seconds: 3.5, from: 1)
    #expect(trace.series(.mouthOpen).max()! > 0.6)
    #expect(eyes(trace).min()! < 0.2)
    #expect(motion.microActionHistory.last?.kind == .yawn)
}

@Test func dozingCharacterStartlesAwakeWhenEngaged() {
    let motion = controller(microActions: true)
    _ = record(motion, seconds: 1)
    motion.requestMicroAction(.doze)
    let drooping = record(motion, seconds: 3.5, from: 1)
    #expect(eyes(drooping).suffix(10).max()! < 0.75)
    // The user moves the pointer: eyes open again within a second.
    let woken = record(motion, seconds: 1.5, from: 4.5) { time in
        MotionInputs(pointer: SIMD2(Float(sin(time * 4)) * 0.6, 0))
    }
    #expect(eyes(woken).suffix(20).max()! > 0.9)
}

@Test func disabledMicroActionsNeverStart() {
    let motion = controller(seed: 4, microActions: false)
    _ = record(motion, seconds: 300)
    #expect(motion.microActionHistory.isEmpty)
}

// MARK: - Clock origin and pauses

@Test func motionDoesNotDependOnTheClockOrigin() {
    // The renderer passes seconds since boot, not seconds since launch.
    let origin = 100_000.0
    let late = record(controller(microActions: true), seconds: 30, from: origin)
    let early = record(controller(microActions: true), seconds: 30)
    // Fixational microsaccades keep their rate whatever the clock origin.
    func microsaccades(_ trace: MotionTrace) -> Int {
        MotionMetrics.saccades(
            eyeX: trace.series(.eyeBallX), eyeY: trace.series(.eyeBallY), frameRate: 60,
            velocityThreshold: 0.5, minimumAmplitude: 0.01
        ).count
    }
    let lateCount = microsaccades(late)
    let earlyCount = microsaccades(early)
    #expect(abs(lateCount - earlyCount) <= max(3, earlyCount / 4))

    let fresh = controller(microActions: true)
    _ = record(fresh, seconds: 30, from: origin)
    #expect(!fresh.microActionHistory.contains { $0.kind == .doze || $0.kind == .yawn || $0.kind == .sigh })
}

@Test func resumingAfterAPauseDoesNotReplayMissedEvents() {
    let motion = controller(microActions: true)
    _ = record(motion, seconds: 5)
    // The window was hidden for ten minutes.
    let resumed = record(motion, seconds: 5, from: 605)
    let blinks = MotionMetrics.blinks(openness: eyes(resumed), frameRate: 60)
    #expect(blinks.count <= 4)
    let saccades = MotionMetrics.saccades(eyeX: resumed.series(.eyeBallX), eyeY: resumed.series(.eyeBallY), frameRate: 60, minimumAmplitude: 0.01)
    #expect(saccades.count < 20)
}

// MARK: - Metrics (7)

@Test func periodicityTellsLoopsFromDrift() {
    let loop = (0..<3600).map { Float(sin(Double($0) / 60 * 2.1)) }
    #expect(MotionMetrics.periodicity(loop, frameRate: 60) > 0.9)
    let drift = record(controller(), seconds: 60).series(.angleZ)
    #expect(MotionMetrics.periodicity(drift, frameRate: 60) < 0.5)
}

@Test func metricDetectorsFindSyntheticEvents() {
    var openness = [Float](repeating: 1, count: 300)
    for index in 100..<112 { openness[index] = 0.1 } // full blink
    for index in 200..<210 { openness[index] = 0.5 } // partial blink
    let blinks = MotionMetrics.blinks(openness: openness, frameRate: 60)
    #expect(blinks.count == 2)
    #expect(blinks[1].depth < 0.8)

    var eyeX = [Float](repeating: 0, count: 120)
    for index in 60..<120 { eyeX[index] = 0.6 }
    let saccades = MotionMetrics.saccades(eyeX: eyeX, eyeY: [Float](repeating: 0, count: 120), frameRate: 60)
    #expect(saccades.count == 1)

    let reference = (0..<200).map { Float(sin(Double($0) * 0.2)) }
    let lagged = [Float](repeating: 0, count: 5) + reference.dropLast(5)
    #expect(MotionMetrics.bestLag(reference: reference, signal: lagged, maximumLag: 10).lag == 5)
}
