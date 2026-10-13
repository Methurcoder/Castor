import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Small things a character does of its own accord — the generalization of
/// the sneeze: each action has anticipation → action → follow-through →
/// settle, a refractory period, and gating by conversation behavior and by
/// **boredom** (time since the user last engaged).
///
/// - **glance**: looks around the room for a moment;
/// - **weight shift**: a counter-lean, then re-settles its posture;
/// - **sigh**: deep inhale, slumping exhale with half-closed eyes;
/// - **yawn** (bored): head back, eyes squeezed, mouth wide, then a blink;
/// - **doze** (very bored): eyelids and head droop… then it jerks awake.
///
/// Engaging the character (pointer, stroke, conversation) interrupts an
/// action: most fade out quickly; a dozing character startles awake.
///
/// Arm gestures (stretching, touching the hair) are intentionally absent:
/// auto-rigged characters have only sway parameters for the arms, not joints.
public final class MicroActionLayer: MotionLayer {
    public enum Kind: String, CaseIterable, Sendable {
        case glance
        case weightShift
        case sigh
        case yawn
        case doze
    }

    struct Spec {
        /// Mean starts per minute at full eligibility (personality 1).
        var ratePerMinute: Float
        var refractory: Double
        /// Boredom (s) before the action becomes possible; eligibility ramps
        /// up to full over the following equal span.
        var minimumBoredom: Double
        var behaviors: Set<MotionBehavior>
    }

    static func spec(for kind: Kind) -> Spec {
        switch kind {
        case .glance:
            Spec(ratePerMinute: 1.6, refractory: 6, minimumBoredom: 3, behaviors: [.idle])
        case .weightShift:
            Spec(ratePerMinute: 2.2, refractory: 8, minimumBoredom: 0, behaviors: [.idle, .listening])
        case .sigh:
            Spec(ratePerMinute: 0.4, refractory: 40, minimumBoredom: 20, behaviors: [.idle, .thinking])
        case .yawn:
            Spec(ratePerMinute: 0.4, refractory: 60, minimumBoredom: 45, behaviors: [.idle])
        case .doze:
            Spec(ratePerMinute: 0.5, refractory: 90, minimumBoredom: 90, behaviors: [.idle])
        }
    }

    private struct Active {
        var kind: Kind
        var start: Double
        var duration: Double
        var direction: Float
        var amplitude: Float
        /// Doze only: when the character startles awake.
        var wakeAt: Double = .greatestFiniteMagnitude
        var droopAtWake: Float = 1
        /// When engagement interrupted a fading action.
        var cancelledAt: Double?
        /// One-shot side effect (wake impulse, post-yawn blink) already sent.
        var eventFired = false
    }

    private var rng: SeededRandom
    private let personality: MotionPersonality
    private let cues: MotionCues
    private var active: Active?
    private var nextCheck: Double = .nan
    private var lastStart: [Kind: Double] = [:]

    /// Every action started so far, in order (exposed for tests and evaluation).
    public private(set) var history: [(kind: Kind, start: Double)] = []

    public convenience init(seed: UInt64, personality: MotionPersonality = .standard) {
        self.init(seed: seed, personality: personality, cues: MotionCues())
    }

    init(seed: UInt64, personality: MotionPersonality, cues: MotionCues) {
        self.rng = SeededRandom(seed: seed, stream: "micro.actions")
        self.personality = personality.sanitized
        self.cues = cues
    }

    private var pendingRequest: Kind?

    /// Starts `kind` on the next update regardless of the schedule (demo/debug).
    public func request(_ kind: Kind) {
        pendingRequest = kind
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let time = context.time
        let behavior = context.inputs.effectiveBehavior
        if context.inputs.petting != nil || behavior != .idle {
            cues.lastEngagement = time
        }
        let boredom = time - cues.lastEngagement

        if var current = active, current.cancelledAt == nil, cues.lastEngagement > current.start + 0.05 {
            if current.kind == .doze {
                if time < current.wakeAt {
                    current.droopAtWake = dozeDroop(time - current.start)
                    current.wakeAt = time
                    current.duration = time - current.start + 0.9
                }
            } else {
                current.cancelledAt = time
            }
            active = current
        }

        if let current = active {
            let end = current.cancelledAt.map { $0 + 0.3 } ?? current.start + current.duration
            if time >= end { active = nil }
        }

        if active == nil, let kind = pendingRequest {
            pendingRequest = nil
            start(kind, at: time)
        } else if active == nil, !cues.transientBusy {
            if nextCheck.isNaN || time - nextCheck > 2 {
                // First frame or resuming after a pause: no catch-up burst.
                nextCheck = time + 1
            }
            if time >= nextCheck {
                nextCheck += 1
                chooseAction(at: time, behavior: behavior, boredom: boredom)
            }
        }

        if let current = active {
            apply(current, at: time, values: &values)
        }
    }

    // MARK: - Scheduling

    private func chooseAction(at time: Double, behavior: MotionBehavior, boredom: Double) {
        // Rare, boredom-gated actions are considered first.
        for kind in [Kind.doze, .yawn, .sigh, .weightShift, .glance] {
            let spec = Self.spec(for: kind)
            guard spec.behaviors.contains(behavior),
                  boredom >= spec.minimumBoredom,
                  time - (lastStart[kind] ?? -.greatestFiniteMagnitude) >= spec.refractory else { continue }
            // Boredom-gated actions ramp in over the span after their threshold;
            // a short quiet-time gate (the glance) applies fully at once.
            let eligibility: Float = spec.minimumBoredom >= 10
                ? Interpolation.smoothstep(Float(spec.minimumBoredom), Float(spec.minimumBoredom * 2), Float(boredom))
                : 1
            // One check per second: per-check probability = rate / 60.
            let probability = spec.ratePerMinute / 60 * personality.fidgetRate * max(0.15, eligibility)
            if rng.chance(probability) {
                start(kind, at: time)
                return
            }
        }
    }

    private func start(_ kind: Kind, at time: Double) {
        lastStart[kind] = time
        history.append((kind, time))
        var action = Active(
            kind: kind,
            start: time,
            duration: 0,
            direction: rng.chance(0.5) ? 1 : -1,
            amplitude: 1
        )
        switch kind {
        case .glance:
            action.duration = Double(rng.float(in: 0.7...1.4))
            cues.glanceRequests.append(GlanceRequest(
                start: time,
                duration: action.duration,
                target: SIMD2(action.direction * rng.float(in: 0.5...0.85), rng.float(in: -0.2...0.35)),
                residualAttention: 0.05
            ))
        case .weightShift:
            action.duration = Double(rng.float(in: 4...9))
            action.amplitude = rng.float(in: 0.8...1.6) * personality.idleAmplitude
        case .sigh:
            action.duration = 2.4
        case .yawn:
            action.duration = 3.1
        case .doze:
            action.wakeAt = time + Double(rng.float(in: 4.5...7))
            action.duration = action.wakeAt - time + 0.9
        }
        active = action
    }

    // MARK: - Profiles

    /// 0...1 droop of a dozing character `elapsed` seconds in.
    private func dozeDroop(_ elapsed: Double) -> Float {
        Interpolation.smoothstep(0, 4.5, Float(elapsed))
    }

    private func apply(_ action: Active, at time: Double, values: inout ParameterValues) {
        let elapsed = time - action.start
        let fade: Float = action.cancelledAt.map { 1 - Interpolation.smoothstep(0, 0.3, Float(time - $0)) } ?? 1
        let d = action.direction
        let a = action.amplitude * fade

        switch action.kind {
        case .glance:
            break // carried out by the gaze layer

        case .weightShift:
            // Counter-lean first (anticipation), then the new posture, then back.
            let anticipation = Shape.bump(elapsed, duration: 0.35)
            let settle = Shape.plateau(elapsed - 0.25, attack: 0.6, hold: max(0, action.duration - 1.6), release: 0.7)
            values.add(.bodyAngleX, (-0.35 * anticipation + 1.6 * settle) * d * a)
            values.add(.bodyAngleZ, 0.6 * settle * d * a)
            values.add(.angleZ, -0.8 * settle * d * a) // head stays level-ish
            values.add(.bodyY, -0.03 * settle * a)

        case .sigh:
            let inhale = Shape.plateau(elapsed, attack: 0.9, hold: 0.1, release: 1.3)
            let exhale = Shape.plateau(elapsed - 0.9, attack: 0.5, hold: 0.4, release: 0.6)
            values.add(.breath, 0.55 * inhale * a)
            values.add(.shoulderY, (0.2 * inhale - 0.18 * exhale) * a)
            values.add(.angleY, (1.5 * inhale - 3 * exhale) * a)
            values.add(.eyeLeftOpen, -0.3 * exhale * a)
            values.add(.eyeRightOpen, -0.3 * exhale * a)
            values.add(.mouthOpen, 0.08 * exhale * a)

        case .yawn:
            let wide = Shape.plateau(elapsed, attack: 1.2, hold: 0.7, release: 1.0)
            values.add(.mouthOpen, 0.85 * wide * a)
            values.add(.mouthForm, -0.3 * wide * a)
            values.add(.eyeLeftOpen, -0.9 * wide * a)
            values.add(.eyeRightOpen, -0.9 * wide * a)
            values.add(.angleY, 7 * wide * a)
            values.add(.breath, 0.6 * wide * a)
            values.add(.shoulderY, 0.2 * wide * a)
            values.add(.bodyY, 0.04 * wide * a)
            if !action.eventFired, elapsed >= 2.9 {
                // Eyes water a little after a yawn: blink it away.
                active?.eventFired = true
                cues.requestBlink(at: action.start + 2.9, .forced)
            }

        case .doze:
            let droop: Float
            var jolt: Float = 0
            if time < action.wakeAt {
                droop = dozeDroop(elapsed)
            } else {
                let sinceWake = time - action.wakeAt
                droop = action.droopAtWake * (1 - Interpolation.smoothstep(0, 0.25, Float(sinceWake)))
                jolt = Shape.bump(sinceWake, duration: 0.6)
                if !action.eventFired {
                    active?.eventFired = true
                    cues.hairImpulse += 1.0
                    cues.requestBlink(at: action.wakeAt + 0.3, .forced)
                }
            }
            values.add(.eyeLeftOpen, -0.75 * droop + 0.15 * jolt)
            values.add(.eyeRightOpen, -0.75 * droop + 0.15 * jolt)
            values.add(.angleY, -9 * Interpolation.smoothstep(0.2, 1, droop) + 4 * jolt)
            values.add(.angleZ, 4 * d * Interpolation.smoothstep(0.3, 1, droop))
            values.add(.bodyY, -0.04 * droop + 0.05 * jolt)
        }
    }
}
