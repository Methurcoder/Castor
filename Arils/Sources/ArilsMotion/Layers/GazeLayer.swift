import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Human-like gaze. Deliberately imperfect, and modelled on how eyes really
/// move:
/// - **saccades** are ballistic jumps with a minimum-jerk velocity bell whose
///   duration grows with amplitude (the "main sequence"); large ones slightly
///   undershoot and are finished by a corrective drift;
/// - between saccades the eyes **pursue** slowly moving targets, **drift**,
///   and make tiny **microsaccades**, so a fixation is never frozen;
/// - the head follows the eyes at ~half gain through a much slower spring,
///   and the eyes **counter-rotate** as the head arrives (vestibulo-ocular
///   reflex), so the eyes lead and then recentre like a real gaze shift;
/// - the lids follow vertical gaze (lower when looking down);
/// - **interest** builds while the pointer moves and decays while it sits
///   still, and during attention the character occasionally **averts** its
///   gaze — more often for a shy personality;
/// - the conversation changes the strategy: a thinking character looks up
///   and aside, a listening or speaking one keeps the viewer near center, and
///   other layers can post brief **glances** (speech-start aversion, a
///   flustered dart, looking around out of boredom).
public final class GazeLayer: MotionLayer {
    private struct Saccade {
        var from: SIMD2<Float>
        var to: SIMD2<Float>
        var start: Double
        var duration: Double
    }

    /// Fraction of the head's gaze contribution the eyes give back.
    public static let vestibuloOcularGain: Float = 0.5
    /// Eye-in-head error that triggers a saccade instead of pursuit.
    static let saccadeThreshold: Float = 0.12

    private var rng: SeededRandom
    private let personality: MotionPersonality
    private let cues: MotionCues
    private let headTurnGain: Float
    private let driftX: ValueNoise1D
    private let driftY: ValueNoise1D

    private var headSpring: SpringDamper2
    /// Beyond the standard head range the torso joins in, later and slower
    /// than the head, the way a person turns to look far to the side.
    private var bodySpring = SpringDamper2(value: .zero, frequency: 0.35, dampingRatio: 1.0)
    private var pursuit = SpringDamper2(value: .zero, frequency: 4.0, dampingRatio: 1.0)
    private var saccade: Saccade?
    private var lastSaccadeEnd: Double = -.greatestFiniteMagnitude
    private var nextMicrosaccadeAt: Double = .nan
    private var lastDesired: SIMD2<Float>?

    private var interest: Float = 0
    private var lastPointer: SIMD2<Float>?
    private var pointerStillSince: Double?

    private var aversionUntil: Double = 0
    private var aversionOffset = SIMD2<Float>.zero
    private var nextAversionCheck: Double = 0

    private var idleFixation = SIMD2<Float>.zero
    private var idleFixationUntil: Double = -.greatestFiniteMagnitude
    private var thinkingFixation = SIMD2<Float>.zero
    private var thinkingFixationUntil: Double = -.greatestFiniteMagnitude
    private var glance: GlanceRequest? {
        didSet { if glance != oldValue { glanceStarted = false } }
    }
    private var glanceStarted = false
    /// Exact time of the latest known target jump (glance start/end).
    private var knownJumpTime: Double?

    public convenience init(seed: UInt64, personality: MotionPersonality = .standard) {
        self.init(seed: seed, personality: personality, cues: MotionCues())
    }

    init(seed: UInt64, personality: MotionPersonality, cues: MotionCues, headTurnGain: Float = 1) {
        self.rng = SeededRandom(seed: seed, stream: "gaze")
        self.personality = personality.sanitized
        self.cues = cues
        self.headTurnGain = headTurnGain.isFinite ? max(0, headTurnGain) : 1
        self.driftX = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("gaze.drift.x")))
        self.driftY = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("gaze.drift.y")))
        self.headSpring = SpringDamper2(
            value: .zero,
            frequency: 0.7 * self.personality.responsiveness,
            dampingRatio: 1.05
        )
    }

    /// Saccade duration in seconds for an amplitude in normalized eye units
    /// (≈ 25 ms + 85 ms per unit; a full-range jump takes ~110 ms).
    static func saccadeDuration(amplitude: Float) -> Double {
        Double(0.025 + 0.085 * amplitude)
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let time = context.time
        let dt = context.deltaTime
        let behavior = context.inputs.effectiveBehavior

        updateInterest(pointer: context.inputs.pointer, time: time, deltaTime: dt)
        let attending = context.inputs.pointer != nil && interest > 0.12

        // --- Glances posted by other layers -----------------------------
        if let latest = cues.glanceRequests.last {
            glance = latest
        }
        cues.glanceRequests.removeAll(keepingCapacity: true)
        if cues.endGlanceRequested {
            if glance != nil { knownJumpTime = time }
            glance = nil
            cues.endGlanceRequested = false
        }
        if let active = glance {
            // The exact moments a glance begins and ends are known; saccades
            // they cause start there rather than on the frame that noticed.
            if time >= active.start, !glanceStarted {
                glanceStarted = true
                knownJumpTime = active.start
            }
            if time >= active.start + active.duration {
                glance = nil
                knownJumpTime = active.start + active.duration
            }
        }

        // --- Target selection -------------------------------------------
        var target = baseTarget(
            behavior: behavior,
            pointer: attending ? context.inputs.pointer : nil,
            time: time
        )
        if let active = glance, time >= active.start {
            target = simd_clamp(active.target + target * active.residualAttention, SIMD2(-1, -1), SIMD2(1, 1))
        }

        // --- Head follows at partial gain, much more slowly -------------
        let head = headSpring.step(toward: target * 0.55, deltaTime: dt)

        // --- Eyes: saccades, pursuit, fixational motion -------------------
        let desired = simd_clamp(target - Self.vestibuloOcularGain * head, SIMD2(-1, -1), SIMD2(1, 1))
        let eyes = moveEyes(toward: desired, time: time, deltaTime: dt)

        let drift = SIMD2(
            driftX.value(at: Float(time) * 0.9),
            driftY.value(at: Float(time) * 0.9 + 31)
        ) * 0.006
        let output = simd_clamp(eyes + drift, SIMD2(-1, -1), SIMD2(1, 1))

        values.override(.eyeBallX, output.x)
        values.override(.eyeBallY, output.y)
        values.add(.angleX, head.x * 14 * headTurnGain)
        // A host-driven Quality pitch replaces this one gaze contribution,
        // not the complete angleY channel: idle drift and sneeze motion are
        // composed later by MotionController and must remain visible.
        if context.inputs.headPitch == nil {
            values.add(.angleY, head.y * 9 * headTurnGain)
        }
        // A touch of roll makes horizontal head turns look curious, not robotic.
        values.add(.angleZ, head.x * 2.2 * headTurnGain)
        let extraTurn = headTurnGain - 1
        if extraTurn > 0 {
            let body = bodySpring.step(toward: head, deltaTime: dt)
            values.add(.bodyAngleX, body.x * 10 * extraTurn)
            values.add(.bodyAngleZ, body.x * 4 * extraTurn)
        }
        // Lids ride the eyes: lower when looking down, a hair higher looking up.
        let lid = output.y < 0 ? 0.3 * output.y : 0.05 * output.y
        values.add(.eyeLeftOpen, lid)
        values.add(.eyeRightOpen, lid)
    }

    // MARK: - Interest

    private func updateInterest(pointer: SIMD2<Float>?, time: Double, deltaTime dt: Float) {
        if let pointer {
            if lastPointer == nil {
                // A pointer *appearing* is an attention event by itself, even
                // if it never moves again afterwards.
                interest = max(interest, 0.7)
                cues.lastEngagement = time
            }
            // Speed, not per-frame distance, so attention builds the same at
            // any frame rate.
            let speed = dt > 0 ? simd_distance(pointer, lastPointer ?? pointer) / dt : 0
            if speed > 0.9 {
                pointerStillSince = nil
                interest = min(1, interest + dt * (6 + speed * 2))
                cues.lastEngagement = time
            } else if dt > 0 {
                if pointerStillSince == nil { pointerStillSince = time }
                // A parked cursor gets boring after a few seconds.
                let stillFor = time - (pointerStillSince ?? time)
                interest -= dt * (stillFor > 4 ? 0.18 : 0.03)
            }
            lastPointer = pointer
        } else {
            interest -= dt * 0.8
            lastPointer = nil
        }
        interest = Interpolation.clamp(interest, 0...1)
    }

    // MARK: - Targets

    private func baseTarget(behavior: MotionBehavior, pointer: SIMD2<Float>?, time: Double) -> SIMD2<Float> {
        if behavior == .thinking {
            // Looking up and aside while searching memory, re-fixating within
            // that quadrant now and then. The side matches the head lean.
            if time >= thinkingFixationUntil {
                thinkingFixation = SIMD2(
                    cues.thinkingSide * rng.float(in: 0.35...0.7),
                    rng.float(in: 0.2...0.55)
                )
                thinkingFixationUntil = time + Double(rng.float(in: 0.7...2.0))
            }
            return thinkingFixation + (pointer ?? .zero) * 0.1
        }

        if let pointer {
            if time < aversionUntil {
                // Looking away: mostly the aversion offset, a hint of the target.
                return simd_clamp(pointer * 0.15 + aversionOffset, SIMD2(-1, -1), SIMD2(1, 1))
            }
            if time >= nextAversionCheck {
                nextAversionCheck = time + Double(rng.float(in: 2.6...6.5))
                let probability = 0.15 + 0.6 * personality.shyness
                if rng.chance(probability) {
                    aversionUntil = time + Double(rng.float(in: 0.6...1.6) * (0.7 + 0.8 * personality.shyness))
                    aversionOffset = SIMD2(
                        rng.float(in: 0.35...0.75) * (rng.chance(0.5) ? 1 : -1),
                        rng.float(in: -0.1...0.45)
                    )
                }
            }
            // Slight undershoot; eyes rarely pin a target dead center.
            return simd_clamp(pointer, SIMD2(-1, -1), SIMD2(1, 1)) * 0.88
        }

        if time >= idleFixationUntil {
            idleFixation = SIMD2(rng.float(in: -0.35...0.35), rng.float(in: -0.15...0.25))
            idleFixationUntil = time + Double(rng.float(in: 1.2...3.4))
        }
        if behavior == .listening || behavior == .speaking {
            // Engaged with someone in front: stay near the viewer.
            return idleFixation * 0.3 + SIMD2(0, 0.04)
        }
        return idleFixation
    }

    // MARK: - Eye movement

    private func moveEyes(toward desired: SIMD2<Float>, time: Double, deltaTime dt: Float) -> SIMD2<Float> {
        defer {
            lastDesired = desired
            knownJumpTime = nil
        }
        if let active = saccade {
            if let position = position(of: active, at: time) {
                return position
            }
            saccade = nil
            pursuit.snap(to: active.to)
            lastSaccadeEnd = active.start + active.duration
        }

        let error = simd_distance(desired, pursuit.value)
        if error > Self.saccadeThreshold, time - lastSaccadeEnd > 0.12 {
            // Onset time: a target that *jumped* this frame is seen now; one
            // that drifted across the threshold is back-dated to the crossing,
            // so the saccade lands at the same moment at any frame rate.
            var onset = time
            if let known = knownJumpTime, known <= time, time - known < Double(max(dt, 1e-4)) + 1e-6 {
                onset = known
            }
            let previousError = lastDesired.map { simd_distance($0, pursuit.value) } ?? error
            let jump = lastDesired.map { simd_distance($0, desired) } ?? .greatestFiniteMagnitude
            if jump < Self.saccadeThreshold, previousError < Self.saccadeThreshold, error > previousError, dt > 0 {
                let fraction = (error - Self.saccadeThreshold) / (error - previousError)
                onset = time - Double(dt * Interpolation.clamp(fraction, 0...1))
            }
            onset = max(onset, lastSaccadeEnd + 0.12)
            let from = pursuit.value
            // Large saccades land a little short; pursuit finishes the job.
            let gain: Float = error > 0.35 ? 0.92 : 1
            let next = Saccade(
                from: from,
                to: from + (desired - from) * gain,
                start: onset,
                duration: Self.saccadeDuration(amplitude: error)
            )
            saccade = next
            cues.requestBlink(at: onset, .gazeShift(amplitude: error))
            return position(of: next, at: time) ?? next.to
        }

        if nextMicrosaccadeAt.isNaN || time - nextMicrosaccadeAt > 1 {
            // First frame, or resuming after a pause: schedule from now
            // instead of replaying every missed microsaccade.
            nextMicrosaccadeAt = time + Double(rng.float(in: 0.5...1.6))
        }
        if time >= nextMicrosaccadeAt {
            let scheduled = nextMicrosaccadeAt
            nextMicrosaccadeAt = scheduled + Double(rng.float(in: 0.5...1.6))
            // Decided from scheduled times only, so every frame rate draws the
            // same random sequence.
            if scheduled - lastSaccadeEnd > 0.3 {
                let angle = rng.float(in: 0...(2 * .pi))
                let size = rng.float(in: 0.015...0.04)
                let from = pursuit.value
                let next = Saccade(
                    from: from,
                    to: from + SIMD2(cos(angle), sin(angle)) * size,
                    start: scheduled,
                    duration: 0.02
                )
                saccade = next
                return position(of: next, at: time) ?? next.to
            }
        }
        return pursuit.step(toward: desired, deltaTime: dt)
    }

    /// Eye position along a saccade, or nil once it has landed.
    private func position(of saccade: Saccade, at time: Double) -> SIMD2<Float>? {
        let progress = Float((time - saccade.start) / saccade.duration)
        guard progress < 1 else { return nil }
        return saccade.from + (saccade.to - saccade.from) * Shape.minimumJerk(progress)
    }
}
