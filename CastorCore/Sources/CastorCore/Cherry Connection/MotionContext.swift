import Foundation

/// Caller-supplied context that lets `CherryConnection` fold in the small amount of
/// renderer/UI-side state (touch, speaking, listening) that used to live as ad-hoc sine-wave
/// overlays in `PetFloatingView.petParameters(at:touched:)`. Keeping this a plain, all-default
/// struct means every existing call site that does not pass a context (`ContentView`'s preview
/// usage via `parameters(from:at:)` / `parameters(from:trilobite:at:)`) keeps producing exactly
/// the same output as before this type existed.
public nonisolated struct MotionContext: Sendable {
    public var touched: Bool = false
    public var isSpeaking: Bool = false
    public var isListening: Bool = false
    /// Real playback energy (0...1) for the mouth flap while `isSpeaking` (phase E), sourced from
    /// `PetSpeechOutput.playbackEnergy`. `nil` means "no live energy signal available" (nothing is
    /// playing yet, or the active TTS path can't report one) — `CherryConnection` falls back to
    /// the legacy sine-wave mouth flap whenever this is `nil`, so passing it is purely additive
    /// and never required for existing behavior.
    public var speechEnergy: Double? = nil
    /// Optional, data-driven performance cue for panel evasion. The controller owns panel
    /// movement; this value only lets Cherry Connection add a small body/gaze performance.
    public var evasionCue: EvasionMotionCue? = nil

    /// The context matching the previous, context-free `CherryConnection` behavior. Used as the
    /// default for every overload that does not take an explicit context.
    public static let preview = MotionContext()

    public init(
        touched: Bool = false,
        isSpeaking: Bool = false,
        isListening: Bool = false,
        speechEnergy: Double? = nil,
        evasionCue: EvasionMotionCue? = nil
    ) {
        self.touched = touched
        self.isSpeaking = isSpeaking
        self.isListening = isListening
        self.speechEnergy = speechEnergy
        self.evasionCue = evasionCue
    }
}
