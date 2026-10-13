import Foundation

import ArilsCore

/// Orchestrates all motion layers into one parameter frame per update call.
///
/// Fixed layer order: breathing → idle sway → attitude → lip sync → speech
/// gestures → blink → gaze → face-tracking bias → petting → sneeze →
/// micro-actions → hair physics. All state lives in the layers; the controller
/// wires shared signals. Layers talk to each other through one `MotionCues`
/// bus (gaze shifts evoke blinks, speech phrasing drives nods and glances,
/// a startle kicks the hair), and the controller differentiates the resolved
/// head angle to drive the sway physics.
///
/// Deterministic: a given `seed` plus a given sequence of `(time, inputs)`
/// always produces the same output, which is what the regression tests rely on.
/// Not thread-safe; call from a single isolation domain (typically MainActor).
public final class MotionController {
    public struct Configuration: Sendable {
        public var seed: UInt64
        public var swayChannels: [SwayChannelSettings]
        /// Mean seconds between spontaneous sneezes; `.infinity` disables them
        /// (the manual `requestSneeze()` trigger keeps working either way).
        public var sneezeInterval: Double
        /// Motion temperament shared by every layer.
        public var personality: MotionPersonality
        /// Spontaneous micro-actions (glances, weight shifts, sighs, yawns,
        /// dozing). Off keeps the character to ambient motion only.
        public var microActionsEnabled: Bool
        /// Multiplies how far the head turns and tilts while following the
        /// gaze (1 = the standard range). Larger values reveal more of what
        /// a single image cannot show, so hosts offer them as an opt-in.
        public var headTurnGain: Float

        public init(
            seed: UInt64 = 0x0A71_15EE_D5EE_D001,
            swayChannels: [SwayChannelSettings] = SwayChannelSettings.standard,
            sneezeInterval: Double = 240,
            personality: MotionPersonality = .standard,
            microActionsEnabled: Bool = true,
            headTurnGain: Float = 1
        ) {
            self.seed = seed
            self.swayChannels = swayChannels
            self.sneezeInterval = sneezeInterval
            self.personality = personality
            self.microActionsEnabled = microActionsEnabled
            self.headTurnGain = headTurnGain
        }
    }

    private let cues = MotionCues()
    private let breathing: BreathingLayer
    private let idleSway: IdleSwayLayer
    private let attitude: AttitudeLayer
    private let lipSync: LipSyncLayer
    private let speechGesture: SpeechGestureLayer
    private let blink: BlinkLayer
    private let gaze: GazeLayer
    private let faceTracking: FaceTrackingLayer
    private let petting: PettingLayer
    private let sneeze: SneezeLayer
    private let microActions: MicroActionLayer?
    private let sway: SwaySimulator

    private var values: ParameterValues
    private var lastTime: Double?
    private var lastHeadAngle: Float?
    /// `energy` arrives as a step (e.g. 0.5 → 0.72 when a conversation
    /// starts); easing it keeps breathing tempo and drift amplitude from jumping.
    private var energyEnvelope = AttackReleaseEnvelope(value: 0.5, attack: 0.6, release: 1.5)
    private var energyInitialized = false

    /// Frame deltas are clamped here so a background pause can't catapult
    /// springs and schedulers when updates resume.
    private static let maxDeltaTime: Float = 1.0 / 15.0

    public init(descriptors: [ParameterDescriptor], configuration: Configuration = Configuration()) {
        let seed = configuration.seed
        let personality = configuration.personality.sanitized
        self.breathing = BreathingLayer(seed: seed)
        self.idleSway = IdleSwayLayer(seed: seed, personality: personality)
        self.attitude = AttitudeLayer(seed: seed, personality: personality, cues: cues)
        self.lipSync = LipSyncLayer(seed: seed, cues: cues)
        self.speechGesture = SpeechGestureLayer(seed: seed, personality: personality, cues: cues)
        self.blink = BlinkLayer(seed: seed, personality: personality, cues: cues)
        self.gaze = GazeLayer(
            seed: seed,
            personality: personality,
            cues: cues,
            headTurnGain: configuration.headTurnGain
        )
        self.faceTracking = FaceTrackingLayer()
        self.petting = PettingLayer()
        self.sneeze = SneezeLayer(seed: seed, averageInterval: configuration.sneezeInterval)
        self.microActions = configuration.microActionsEnabled
            ? MicroActionLayer(seed: seed, personality: personality, cues: cues)
            : nil
        self.sway = SwaySimulator(channels: configuration.swayChannels, seed: seed)
        self.values = ParameterValues(descriptors: descriptors)
    }

    /// Forces a sneeze to start on the next update.
    public func requestSneeze() {
        sneeze.requestSneeze()
    }

    /// Forces a micro-action to start on the next update (ignored when
    /// micro-actions are disabled).
    public func requestMicroAction(_ kind: MicroActionLayer.Kind) {
        microActions?.request(kind)
    }

    /// Micro-actions started so far (empty when disabled).
    public var microActionHistory: [(kind: MicroActionLayer.Kind, start: Double)] {
        microActions?.history ?? []
    }

    /// Nods made so far (speech phrasing and listening backchannel).
    public var nodCount: Int {
        speechGesture.nodCount
    }

    /// The behavior whose posture is currently being held or approached.
    public var appliedBehavior: MotionBehavior {
        attitude.appliedBehavior
    }

    /// Computes the parameter frame for `time`. Call once per rendered frame
    /// with monotonically nondecreasing times.
    public func update(at time: Double, inputs rawInputs: MotionInputs = MotionInputs()) -> [ParameterID: Float] {
        let rawDelta = Float(time - (lastTime ?? time))
        let deltaTime = Interpolation.clamp(rawDelta, 0...Self.maxDeltaTime)
        if lastTime == nil {
            // Hosts pass any monotonic clock (the renderer uses seconds since
            // boot), so "bored since" starts at the first frame, not at 0.
            cues.lastEngagement = time
        }
        lastTime = time

        var inputs = rawInputs
        let requestedEnergy = rawInputs.energy.isFinite ? Interpolation.clamp(rawInputs.energy, 0...1) : 0.5
        if !energyInitialized {
            energyEnvelope.value = requestedEnergy
            energyInitialized = true
        }
        inputs.energy = energyEnvelope.step(toward: requestedEnergy, deltaTime: deltaTime)

        let context = MotionContext(time: time, deltaTime: deltaTime, inputs: inputs)
        values.clear()
        cues.transientBusy = sneeze.isActive(at: time)

        breathing.update(context: context, values: &values)
        idleSway.update(context: context, values: &values)
        attitude.update(context: context, values: &values)
        lipSync.update(context: context, values: &values)
        speechGesture.update(context: context, values: &values)
        blink.update(context: context, values: &values)
        gaze.update(context: context, values: &values)
        faceTracking.update(context: context, values: &values)
        petting.update(context: context, values: &values)
        sneeze.update(context: context, values: &values)
        microActions?.update(context: context, values: &values)

        if let headPitch = context.inputs.headPitch, headPitch.isFinite {
            values.add(.angleY, headPitch)
        }

        // Hair physics is driven by how fast the head is actually moving
        // (post-blend), differentiated across frames.
        let interim = values.resolved()
        let headAngle = (interim[.angleZ] ?? 0) + 0.5 * (interim[.angleX] ?? 0)
        let headVelocity: Float
        if deltaTime > 0, let last = lastHeadAngle {
            headVelocity = (headAngle - last) / deltaTime
        } else {
            headVelocity = 0
        }
        lastHeadAngle = headAngle

        sway.update(
            context: context,
            headAngularVelocity: headVelocity,
            impulse: petting.consumeHairImpulse() + sneeze.consumeHairImpulse() + cues.consumeHairImpulse(),
            values: &values
        )
        return values.resolved()
    }
}
