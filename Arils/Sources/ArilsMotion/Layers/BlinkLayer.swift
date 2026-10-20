import Foundation

import ArilsCore

/// Blink scheduler with a human blink profile (fast close, brief hold,
/// slower open) and human timing:
///
/// - spontaneous intervals are **log-normal** (median ≈ 2.8 s at rest, CV ≈
///   0.65), not uniform, so blinks cluster and pause like real ones;
/// - the rate follows the conversation (more while speaking, fewer while
///   concentrating, suppressed in a startle) and the personality;
/// - ~18 % of blinks are **partial**, ~12 % come as a **double blink**;
/// - other layers can **evoke** a blink: large gaze shifts, phrase ends,
///   the end of an utterance, a change of behavior.
///
/// Blinks are evaluated from their *scheduled* start time, not the frame that
/// noticed them, so the lid trajectory is the same at 30, 60, or 120 fps.
/// Owns the eye-openness base via `override`; other layers still `add`.
public final class BlinkLayer: MotionLayer {
    private var rng: SeededRandom
    private let personality: MotionPersonality
    private let cues: MotionCues
    private var nextBlinkAt: Double = .nan
    private var blinkStartedAt: Double = -.greatestFiniteMagnitude
    private var blinkDepth: Float = 1

    // Blink profile (seconds). Kept short: a squashed eye is a thin dark
    // strip, and the longer it lingers the more it reads as a shadow under
    // the eye than a blink (see `BlinkFade`, which also lightens it).
    private let closeDuration: Float = 0.06
    private let holdDuration: Float = 0.03
    private let openDuration: Float = 0.11
    /// No new blink this soon after the previous one started.
    private let refractory: Double = 0.45

    public convenience init(seed: UInt64, personality: MotionPersonality = .standard) {
        self.init(seed: seed, personality: personality, cues: MotionCues())
    }

    init(seed: UInt64, personality: MotionPersonality, cues: MotionCues) {
        self.rng = SeededRandom(seed: seed, stream: "blink")
        self.personality = personality.sanitized
        self.cues = cues
    }

    /// Spontaneous-rate multiplier per behavior (rest = 1). People blink
    /// markedly more while talking — here that increase comes from the evoked
    /// blinks at phrase ends and gaze shifts — and less while concentrating.
    static func rateMultiplier(for behavior: MotionBehavior) -> Float {
        switch behavior {
        case .idle: 1
        case .listening: 1.05
        case .thinking: 0.7
        case .speaking: 1.0
        case .surprised: 0.25
        }
    }

    /// Probability that a cue actually produces a blink.
    static func probability(for cue: BlinkCue) -> Float {
        switch cue {
        case .gazeShift(let amplitude):
            Interpolation.smoothstep(0.25, 0.9, amplitude) * 0.55
        case .phraseBoundary:
            0.25
        case .utteranceEnd:
            0.55
        case .behaviorChange:
            0.45
        case .forced:
            1
        }
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let time = context.time
        if nextBlinkAt.isNaN || time - nextBlinkAt > 1 {
            // First frame, or resuming after a pause: start a fresh schedule.
            nextBlinkAt = time + Double(rng.float(in: 0.6...2.0))
        }

        // Evoked blinks.
        for request in cues.blinkRequests {
            let forced = request.cue == .forced
            guard forced || request.time >= cues.blinkSuppressedUntil,
                  request.time - blinkStartedAt >= refractory else { continue }
            if rng.chance(Self.probability(for: request.cue)) {
                start(at: max(request.time, blinkStartedAt + refractory), behavior: context.inputs.effectiveBehavior)
            }
        }
        cues.blinkRequests.removeAll(keepingCapacity: true)

        // Spontaneous blinks.
        if time >= nextBlinkAt {
            if nextBlinkAt < cues.blinkSuppressedUntil {
                nextBlinkAt = cues.blinkSuppressedUntil + Double(rng.float(in: 0.05...0.4))
            } else {
                start(at: nextBlinkAt, behavior: context.inputs.effectiveBehavior)
            }
        }

        let elapsed = Float(time - blinkStartedAt)
        let closed: Float
        if elapsed < 0 {
            closed = 0
        } else if elapsed < closeDuration {
            closed = Interpolation.smoothstep(0, closeDuration, elapsed)
        } else if elapsed < closeDuration + holdDuration {
            closed = 1
        } else {
            let opening = elapsed - closeDuration - holdDuration
            closed = 1 - Interpolation.smoothstep(0, openDuration, opening)
        }

        let openness = 1 - closed * blinkDepth
        values.override(.eyeLeftOpen, openness)
        values.override(.eyeRightOpen, openness)
    }

    private func start(at time: Double, behavior: MotionBehavior) {
        blinkStartedAt = time
        blinkDepth = rng.chance(0.18) ? rng.float(in: 0.5...0.85) : 1
        if rng.chance(0.12) {
            // Double blink: the follow-up comes right after this one.
            nextBlinkAt = time + 0.34
        } else {
            let rate = max(0.1, personality.blinkRate * Self.rateMultiplier(for: behavior))
            let interval = rng.logNormal(median: 2.8 / rate, sigma: 0.6)
            nextBlinkAt = time + Double(Interpolation.clamp(interval, 0.5...14))
        }
    }
}
