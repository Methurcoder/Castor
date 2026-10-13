import Foundation

public struct MotionParameters {
    public var state: MotionState
    public var bodyLift: Double
    public var headTilt: Double
    public var headBob: Double
    public var eyeOpen: Double
    public var eyeScale: Double
    public var gazeX: Double
    public var gazeY: Double
    public var mouthOpen: Double
    public var mouthSlant: Double
    public var browLift: Double
    public var cheekWarmth: Double
    /// True only when the caller has confirmed the character is actually producing speech (from
    /// `MotionContext.isSpeaking`, folded in by `CherryConnection`'s context-aware entry point).
    /// This is deliberately *not* derived from `mouthOpen`'s magnitude: ambient mouth chatter
    /// (thinking/listening resting energy) can exceed the same thresholds a real talk animation
    /// would use, so renderers must not infer "is speaking" from mouthOpen alone. Defaults to
    /// `false` for every call site
    /// that does not know about speech (previews, context-free overloads).
    public var isSpeaking: Bool = false

    public static let neutral = MotionParameters(
        state: .idle,
        bodyLift: 0,
        headTilt: 0,
        headBob: 0,
        eyeOpen: 1,
        eyeScale: 1,
        gazeX: 0,
        gazeY: 0,
        mouthOpen: 0.08,
        mouthSlant: 0,
        browLift: 0,
        cheekWarmth: 0.25,
        isSpeaking: false
    )

    public init(
        state: MotionState,
        bodyLift: Double,
        headTilt: Double,
        headBob: Double,
        eyeOpen: Double,
        eyeScale: Double,
        gazeX: Double,
        gazeY: Double,
        mouthOpen: Double,
        mouthSlant: Double,
        browLift: Double,
        cheekWarmth: Double,
        isSpeaking: Bool = false
    ) {
        self.state = state
        self.bodyLift = bodyLift
        self.headTilt = headTilt
        self.headBob = headBob
        self.eyeOpen = eyeOpen
        self.eyeScale = eyeScale
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.mouthOpen = mouthOpen
        self.mouthSlant = mouthSlant
        self.browLift = browLift
        self.cheekWarmth = cheekWarmth
        self.isSpeaking = isSpeaking
    }
}
