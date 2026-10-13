import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Conversational body language around speech — the motion a talking or
/// listening person makes besides the mouth.
///
/// While **speaking** (driven by the lip-sync level, so it follows real audio):
/// - an **inhale** and slight head lift as the utterance starts, often with a
///   brief **look away** (speakers avert their gaze when starting a turn);
/// - at **phrase boundaries** (pauses inside the utterance) a small nod, a
///   chance of a blink, and a catch-breath;
/// - **beat** head dips on stressed syllables (onsets of loud segments);
/// - livelier head yaw/roll than at rest;
/// - at the **end** the gaze returns to the listener, often with a settling nod.
///
/// While **listening**: backchannel nods ("うん") at the user's pauses when
/// their voice level is known, or on a gentle schedule otherwise.
///
/// Gestures are time-profiled from their scheduled start, so they look the
/// same at any frame rate.
public final class SpeechGestureLayer: MotionLayer {
    private enum Kind {
        case nod
        case beat
        case inhale
    }

    private struct Gesture {
        var start: Double
        var kind: Kind
        var amplitude: Float
        var direction: Float
    }

    private var rng: SeededRandom
    private let personality: MotionPersonality
    private let cues: MotionCues
    private let yawNoise: ValueNoise1D
    private let rollNoise: ValueNoise1D
    private let pitchNoise: ValueNoise1D
    private var speakingGate = AttackReleaseEnvelope(value: 0, attack: 0.3, release: 0.8)
    private var gestures: [Gesture] = []

    private var wasSpeaking = false
    private var lastBoundary: Double = -.greatestFiniteMagnitude
    private var quietSince: Double?
    private var boundaryFired = false
    private var beatArmed = true
    private var lastBeat: Double = -.greatestFiniteMagnitude

    private var listenerVoicedSince: Double?
    private var listenerQuietSince: Double?
    private var lastNod: Double = -.greatestFiniteMagnitude
    private var nextSpontaneousNod: Double = .nan

    /// Number of nods started so far (exposed for tests and the eval harness).
    public private(set) var nodCount = 0

    public convenience init(seed: UInt64, personality: MotionPersonality = .standard) {
        self.init(seed: seed, personality: personality, cues: MotionCues())
    }

    init(seed: UInt64, personality: MotionPersonality, cues: MotionCues) {
        self.rng = SeededRandom(seed: seed, stream: "speech.gesture")
        self.personality = personality.sanitized
        self.cues = cues
        self.yawNoise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("speech.yaw")))
        self.rollNoise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("speech.roll")))
        self.pitchNoise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("speech.pitch")))
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let time = context.time
        let speaking = context.inputs.isSpeaking
        let level = cues.speechLevel
        let expressiveness = personality.expressiveness

        if speaking, !wasSpeaking {
            utteranceStarted(at: time)
        } else if !speaking, wasSpeaking {
            utteranceEnded(at: time)
        }
        wasSpeaking = speaking

        if speaking {
            cues.lastEngagement = time
            trackPhrases(level: level, time: time)
            trackBeats(level: level, time: time)
        } else if context.inputs.effectiveBehavior == .listening {
            trackListening(level: context.inputs.listenerVoiceLevel, time: time)
        } else {
            listenerVoicedSince = nil
            listenerQuietSince = nil
        }

        // Talkers move their heads more than people at rest.
        let gate = speakingGate.step(toward: speaking ? 1 : 0, deltaTime: context.deltaTime)
        if gate > 0.001 {
            let t = Float(time)
            values.add(.angleX, yawNoise.fbm(at: t * 0.7, octaves: 2) * 3.0 * expressiveness * gate)
            values.add(.angleZ, rollNoise.fbm(at: t * 0.6 + 11, octaves: 2) * 1.6 * expressiveness * gate)
            values.add(.angleY, pitchNoise.fbm(at: t * 0.5 + 23, octaves: 2) * 0.8 * expressiveness * gate)
        }

        gestures.removeAll { time - $0.start > 1.5 }
        for gesture in gestures {
            apply(gesture, elapsed: time - gesture.start, values: &values)
        }
    }

    // MARK: - Speaking

    private func utteranceStarted(at time: Double) {
        lastBoundary = time
        quietSince = nil
        boundaryFired = false
        gestures.append(Gesture(start: time, kind: .inhale, amplitude: 0.35, direction: 0))
        if rng.chance(0.35 + 0.4 * personality.shyness) {
            let side: Float = rng.chance(0.5) ? 1 : -1
            cues.glanceRequests.append(GlanceRequest(
                start: time + 0.05,
                duration: Double(rng.float(in: 0.5...1.3) * (0.8 + 0.5 * personality.shyness)),
                target: SIMD2(side * rng.float(in: 0.4...0.7), rng.float(in: -0.25...0.3)),
                residualAttention: 0.15
            ))
        }
    }

    private func utteranceEnded(at time: Double) {
        cues.endGlanceRequested = true
        cues.requestBlink(at: time + 0.05, .utteranceEnd)
        if rng.chance(0.45) {
            nod(at: time + 0.05, amplitude: rng.float(in: 1.2...2.2))
        }
    }

    private func trackPhrases(level: Float, time: Double) {
        guard level < 0.08 else {
            quietSince = nil
            boundaryFired = false
            return
        }
        let since = quietSince ?? time
        quietSince = since
        let boundaryTime = since + 0.16
        guard !boundaryFired, time >= boundaryTime, since - lastBoundary >= 0.8 else { return }
        boundaryFired = true
        lastBoundary = boundaryTime
        if rng.chance(0.1 + 0.55 * min(1, personality.expressiveness)) {
            nod(at: boundaryTime, amplitude: rng.float(in: 1.5...3.2))
        }
        cues.requestBlink(at: boundaryTime, .phraseBoundary)
        gestures.append(Gesture(start: boundaryTime, kind: .inhale, amplitude: 0.2, direction: 0))
    }

    private func trackBeats(level: Float, time: Double) {
        if level < 0.25 {
            beatArmed = true
        } else if beatArmed, level > 0.45, time - lastBeat > 0.3 {
            beatArmed = false
            lastBeat = time
            if rng.chance(0.35) {
                gestures.append(Gesture(
                    start: time,
                    kind: .beat,
                    amplitude: rng.float(in: 0.6...1.2),
                    direction: rng.chance(0.5) ? 1 : -1
                ))
            }
        }
    }

    // MARK: - Listening

    private func trackListening(level: Float?, time: Double) {
        guard let level, level.isFinite else {
            if nextSpontaneousNod.isNaN {
                nextSpontaneousNod = time + Double(rng.float(in: 1.5...3.0))
            }
            if time >= nextSpontaneousNod {
                nextSpontaneousNod = time + Double(rng.float(in: 3.0...6.5))
                if time - lastNod > 1.8, rng.chance(0.55) {
                    nod(at: time, amplitude: rng.float(in: 2.0...3.5))
                }
            }
            return
        }

        if level > 0.18 {
            listenerVoicedSince = listenerVoicedSince ?? time
            listenerQuietSince = nil
            cues.lastEngagement = time
            return
        }
        guard let voicedSince = listenerVoicedSince else { return }
        let quietStart = listenerQuietSince ?? time
        listenerQuietSince = quietStart
        guard time - quietStart >= 0.25 else { return }
        // The user paused after saying something: acknowledge it.
        listenerVoicedSince = nil
        let nodTime = quietStart + 0.25
        if quietStart - voicedSince >= 0.7, nodTime - lastNod > 1.8, rng.chance(0.75) {
            nod(at: nodTime, amplitude: rng.float(in: 2.0...3.5))
            if rng.chance(0.3) {
                // "うんうん": a quick second nod.
                nod(at: nodTime + 0.38, amplitude: rng.float(in: 1.4...2.4))
            }
        }
    }

    // MARK: - Gesture profiles

    private func nod(at time: Double, amplitude: Float) {
        lastNod = time
        nodCount += 1
        gestures.append(Gesture(start: time, kind: .nod, amplitude: amplitude, direction: 0))
    }

    private func apply(_ gesture: Gesture, elapsed: Double, values: inout ParameterValues) {
        let scale = gesture.amplitude * personality.expressiveness
        switch gesture.kind {
        case .nod:
            // Head dips down, then a small rebound past rest.
            let dip = Shape.bump(elapsed, duration: 0.3)
            let rebound = Shape.bump(elapsed - 0.3, duration: 0.22)
            values.add(.angleY, -scale * dip + 0.3 * scale * rebound)
        case .beat:
            let pulse = Shape.bump(elapsed, duration: 0.22)
            values.add(.angleY, -scale * pulse)
            values.add(.angleX, 0.4 * scale * gesture.direction * pulse)
        case .inhale:
            let breath = Shape.plateau(elapsed, attack: 0.25, hold: 0.05, release: 0.5)
            values.add(.breath, gesture.amplitude * breath)
            values.add(.shoulderY, 0.12 * gesture.amplitude * breath)
            values.add(.angleY, 1.2 * scale * breath)
        }
    }
}
