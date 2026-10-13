import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Conversation posture with Pomegranate's "clumsy aliveness": every change
/// of `MotionInputs.behavior` is carried out *hesitantly* instead of snapped.
///
/// - **Reaction delay** before anything moves (longer when unsure; a startle
///   is reflexive and nearly immediate).
/// - **False start**: an unsure character sometimes moves part of the way,
///   stalls for a beat, then commits.
/// - **Flustered glance**: it may dart its eyes away right at the change.
/// - **Settle overshoot**: unsure characters are under-damped and wobble
///   into the new pose; confident ones glide.
///
/// Poses use only standard rig parameters (head/body angles, lids, mouth
/// form, shoulders), so they work on every auto-rigged character.
public final class AttitudeLayer: MotionLayer {
    struct Pose: Equatable {
        var angleX: Float = 0
        var angleY: Float = 0
        var angleZ: Float = 0
        var eyeOpen: Float = 0
        var mouthForm: Float = 0
        var mouthOpen: Float = 0
        var bodyY: Float = 0
        var bodyAngleZ: Float = 0
        var shoulderY: Float = 0

        static let neutral = Pose()

        var channels: [Float] {
            [angleX, angleY, angleZ, eyeOpen, mouthForm, mouthOpen, bodyY, bodyAngleZ, shoulderY]
        }

        init() {}

        init(channels: [Float]) {
            angleX = channels[0]; angleY = channels[1]; angleZ = channels[2]
            eyeOpen = channels[3]; mouthForm = channels[4]; mouthOpen = channels[5]
            bodyY = channels[6]; bodyAngleZ = channels[7]; shoulderY = channels[8]
        }

        func scaled(_ factor: Float) -> Pose {
            Pose(channels: channels.map { $0 * factor })
        }

        static func lerp(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
            Pose(channels: zip(a.channels, b.channels).map { $0 + ($1 - $0) * t })
        }
    }

    /// Target pose for a behavior at full expressiveness. `side` (±1) picks
    /// which way a thinking character looks and leans.
    static func pose(for behavior: MotionBehavior, side: Float) -> Pose {
        var pose = Pose()
        switch behavior {
        case .idle:
            break
        case .listening:
            // Attentive: slight forward dip, curious tilt, soft smile, eyes a touch wider.
            pose.angleY = -1.5
            pose.angleZ = 4
            pose.eyeOpen = 0.06
            pose.mouthForm = 0.18
            pose.bodyY = -0.02
        case .thinking:
            // Looks up and aside, tilts the other way, narrows the eyes, purses the mouth.
            pose.angleX = 4 * side
            pose.angleY = 3
            pose.angleZ = -5 * side
            pose.eyeOpen = -0.12
            pose.mouthForm = -0.25
            pose.bodyAngleZ = -1 * side
        case .speaking:
            pose.angleY = 1
            pose.eyeOpen = 0.04
            pose.mouthForm = 0.1
        case .surprised:
            // Head back, eyes wide, rounded mouth, shoulders up, a small hop.
            pose.angleY = 6
            pose.angleZ = -2
            pose.eyeOpen = 0.2
            pose.mouthOpen = 0.3
            pose.mouthForm = -0.35
            pose.bodyY = 0.08
            pose.shoulderY = 0.25
        }
        return pose
    }

    private static let channelIDs: [[ParameterID]] = [
        [.angleX], [.angleY], [.angleZ], [.eyeLeftOpen, .eyeRightOpen], [.mouthForm],
        [.mouthOpen], [.bodyY], [.bodyAngleZ], [.shoulderY],
    ]

    private var rng: SeededRandom
    private let personality: MotionPersonality
    private let cues: MotionCues
    private var springs: [SpringDamper]

    /// Behavior whose pose is the current target.
    public private(set) var appliedBehavior: MotionBehavior = .idle
    private var pendingBehavior: MotionBehavior?
    private var onsetAt: Double = 0
    private var startPose = Pose.neutral
    private var targetPose = Pose.neutral
    private var hitchUntil: Double = -.greatestFiniteMagnitude
    private var hitchFraction: Float = 0.4
    private var surpriseStartedAt: Double = -.greatestFiniteMagnitude

    public convenience init(seed: UInt64, personality: MotionPersonality = .standard) {
        self.init(seed: seed, personality: personality, cues: MotionCues())
    }

    init(seed: UInt64, personality: MotionPersonality, cues: MotionCues) {
        self.rng = SeededRandom(seed: seed, stream: "attitude")
        self.personality = personality.sanitized
        self.cues = cues
        self.springs = Array(
            repeating: SpringDamper(value: 0, frequency: 1.3, dampingRatio: 1),
            count: Pose.neutral.channels.count
        )
    }

    /// Seconds between a behavior request and the first visible movement.
    static func reactionDelay(for behavior: MotionBehavior, hesitation: Float, responsiveness: Float) -> Double {
        let base: Float
        switch behavior {
        case .surprised:
            base = 0.03 + 0.08 * hesitation
        case .speaking:
            // Speech timing is set by the audio; only a short beat of lag.
            base = 0.04 + 0.16 * hesitation
        default:
            base = 0.06 + 0.40 * hesitation
        }
        return Double(base / responsiveness.squareRoot())
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let time = context.time
        let hesitation = Interpolation.clamp(context.inputs.hesitation ?? personality.hesitation, 0...1)
        let requested = context.inputs.effectiveBehavior

        if requested != (pendingBehavior ?? appliedBehavior) {
            if requested == appliedBehavior {
                // Changed its mind before moving: just cancel the pending change.
                pendingBehavior = nil
            } else {
                pendingBehavior = requested
                onsetAt = time + Self.reactionDelay(
                    for: requested,
                    hesitation: hesitation,
                    responsiveness: personality.responsiveness
                )
            }
        }

        if let pending = pendingBehavior, time >= onsetAt {
            commit(pending, at: onsetAt, hesitation: hesitation)
        }

        var target = targetPose
        if time < hitchUntil {
            target = Pose.lerp(startPose, targetPose, hitchFraction)
        }
        if appliedBehavior == .surprised {
            // A startle peaks, then relaxes into mild alertness while it lasts.
            let elapsed = Float(time - surpriseStartedAt)
            let relax = Interpolation.smoothstep(0.6, 2.5, elapsed)
            target = target.scaled(1 - 0.45 * relax)
        }

        let dt = context.deltaTime
        for (index, value) in target.channels.enumerated() {
            let output = springs[index].step(toward: value, deltaTime: dt)
            for id in Self.channelIDs[index] {
                values.add(id, output)
            }
        }
    }

    private func commit(_ behavior: MotionBehavior, at time: Double, hesitation: Float) {
        let previous = appliedBehavior
        appliedBehavior = behavior
        pendingBehavior = nil
        startPose = Pose(channels: springs.map(\.value))

        var side = cues.thinkingSide
        if behavior == .thinking {
            side = rng.chance(0.5) ? 1 : -1
            cues.thinkingSide = side
        }
        targetPose = Self.pose(for: behavior, side: side).scaled(personality.expressiveness)

        let isStartle = behavior == .surprised
        let frequency = (isStartle ? 3.0 : 1.3) * personality.responsiveness
        let damping = isStartle ? 0.42 : max(0.4, 1 - 0.7 * hesitation)
        for index in springs.indices {
            springs[index].frequency = frequency
            springs[index].dampingRatio = damping
        }

        hitchUntil = -.greatestFiniteMagnitude
        if isStartle {
            surpriseStartedAt = time
            // The jolt: head snaps back and the body hops before the springs settle.
            springs[1].velocity += 45 * personality.expressiveness
            springs[6].velocity += 0.9 * personality.expressiveness
            cues.hairImpulse += 0.9
            cues.blinkSuppressedUntil = time + 0.9
        } else {
            if rng.chance(hesitation * 0.8) {
                // False start: part of the way, a stall, then the rest.
                hitchFraction = rng.float(in: 0.25...0.5)
                hitchUntil = time + Double(0.12 + 0.25 * hesitation)
            }
            if rng.chance(hesitation * 0.7) {
                // Flustered dart of the eyes at the moment of change.
                let glanceSide: Float = rng.chance(0.5) ? 1 : -1
                cues.glanceRequests.append(GlanceRequest(
                    start: time,
                    duration: Double(0.22 + 0.3 * hesitation),
                    target: SIMD2(glanceSide * rng.float(in: 0.45...0.75), rng.float(in: -0.35...0.1)),
                    residualAttention: 0
                ))
            }
        }

        if previous == .surprised {
            cues.requestBlink(at: time, .forced)
        } else if !isStartle {
            cues.requestBlink(at: time, .behaviorChange)
        }
    }
}
