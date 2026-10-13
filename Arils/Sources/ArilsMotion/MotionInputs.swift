import Foundation
#if canImport(simd)
import simd
#endif

/// One frame of mouth state derived from audio (see `LipSyncAnalyzer`).
public struct LipSyncFrame: Sendable, Equatable {
    /// Mouth openness 0...1.
    public var open: Float
    /// Vowel-ish shape: -1 round/dark ("お・う"), +1 wide/bright ("い・え").
    public var form: Float
    /// How much of the live attack/release envelope `LipSyncLayer` still
    /// applies (1 = full, for raw live audio). Precomputed timelines are
    /// already smoothed and closure-shaped, so they pass a small value and the
    /// mouth can shut within a stop consonant instead of drifting closed.
    public var smoothing: Float

    public init(open: Float, form: Float, smoothing: Float = 1) {
        self.open = open
        self.form = form
        self.smoothing = smoothing
    }
}

/// What the character is doing in the conversation. Hosts map their own
/// state machine onto this (Pomegranate: idle / listening / thinking /
/// speaking, plus a surprised reaction). The motion system turns it into
/// posture, gaze strategy, blink rate, and gestures — never into a pose
/// snap: every change goes through the hesitant transition in
/// `AttitudeLayer`.
public enum MotionBehavior: String, Sendable, CaseIterable, Codable {
    case idle
    case listening
    case thinking
    case speaking
    case surprised
}

/// A stroke over the character's head this frame.
public struct PettingInput: Sendable, Equatable {
    /// Stroke position normalized to the head area: x, y in -1...1
    /// (x positive = viewer's right, y positive = up).
    public var position: SIMD2<Float>
    /// Stroke velocity in the same normalized units per second.
    public var velocity: SIMD2<Float>

    public init(position: SIMD2<Float>, velocity: SIMD2<Float>) {
        self.position = position
        self.velocity = velocity
    }
}

/// One camera face-landmark sample supplied by the host.
///
/// Angles are degrees in the character coordinate system: yaw is positive
/// toward the viewer's right, pitch is positive up, and roll is positive
/// clockwise. Aspect ratios are landmark bounding-height / bounding-width;
/// keeping the raw ratios here lets hosts use Vision or another local tracker
/// without making ArilsMotion depend on either framework.
public struct FaceTrackingInput: Sendable, Equatable {
    public var yawDegrees: Float
    public var pitchDegrees: Float
    public var rollDegrees: Float
    public var leftEyeAspectRatio: Float
    public var rightEyeAspectRatio: Float
    public var mouthAspectRatio: Float
    /// Tracker confidence in 0...1.
    public var confidence: Float

    public init(
        yawDegrees: Float,
        pitchDegrees: Float,
        rollDegrees: Float,
        leftEyeAspectRatio: Float,
        rightEyeAspectRatio: Float,
        mouthAspectRatio: Float,
        confidence: Float = 1
    ) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.leftEyeAspectRatio = leftEyeAspectRatio
        self.rightEyeAspectRatio = rightEyeAspectRatio
        self.mouthAspectRatio = mouthAspectRatio
        self.confidence = confidence
    }
}

/// Everything the outside world tells the motion system, sampled per frame.
///
/// The engine never reaches out to AppKit, audio, or the host app — hosts fill
/// this struct and the motion system stays a pure, testable state machine.
public struct MotionInputs: Sendable, Equatable {
    /// Gaze target normalized around the character: x, y in -1...1
    /// (x positive = viewer's right, y positive = up). nil = nothing to watch.
    public var pointer: SIMD2<Float>?
    /// True while the character is producing speech. Used as a fallback mouth
    /// driver when no `lipSync` frame is available.
    public var isSpeaking: Bool
    /// Audio-derived mouth state; overrides the procedural fallback.
    public var lipSync: LipSyncFrame?
    /// Active head-pat stroke, if any.
    public var petting: PettingInput?
    /// Arousal 0...1; scales idle-motion amplitude and breathing rate.
    public var energy: Float
    /// Optional host-driven head pitch in degrees. When present, it replaces
    /// only the gaze layer's head-pitch contribution; idle drift and transient
    /// motions such as a sneeze remain additive.
    public var headPitch: Float?
    /// Optional host-supplied face pose and landmark ratios.
    public var faceTracking: FaceTrackingInput?
    /// Strength of the face-tracking bias. Zero disables it without dropping
    /// the latest sample; one applies the full conservative bias.
    public var faceTrackingBlend: Float
    /// Conversation behavior. `isSpeaking == true` implies `.speaking` for
    /// gestures even when the host leaves this at `.idle`.
    public var behavior: MotionBehavior
    /// 0...1 momentary unsureness (delay, false starts, overshoot on state
    /// changes). nil uses the personality's resting hesitation.
    public var hesitation: Float?
    /// 0...1 level of the *user's* voice while the character listens; drives
    /// backchannel nods at the user's pauses. nil = unknown (nods fall back
    /// to a gentle schedule).
    public var listenerVoiceLevel: Float?

    /// The behavior the motion system acts on: speech output always reads as
    /// speaking, except that a surprise reaction wins while it lasts.
    public var effectiveBehavior: MotionBehavior {
        if behavior == .surprised { return .surprised }
        return isSpeaking ? .speaking : behavior
    }

    public init(
        pointer: SIMD2<Float>? = nil,
        isSpeaking: Bool = false,
        lipSync: LipSyncFrame? = nil,
        petting: PettingInput? = nil,
        energy: Float = 0.5,
        headPitch: Float? = nil,
        faceTracking: FaceTrackingInput? = nil,
        faceTrackingBlend: Float = 0,
        behavior: MotionBehavior = .idle,
        hesitation: Float? = nil,
        listenerVoiceLevel: Float? = nil
    ) {
        self.pointer = pointer
        self.isSpeaking = isSpeaking
        self.lipSync = lipSync
        self.petting = petting
        self.energy = energy
        self.headPitch = headPitch
        self.faceTracking = faceTracking
        self.faceTrackingBlend = faceTrackingBlend
        self.behavior = behavior
        self.hesitation = hesitation
        self.listenerVoiceLevel = listenerVoiceLevel
    }
}
