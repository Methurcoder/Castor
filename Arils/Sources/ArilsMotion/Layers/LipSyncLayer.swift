import Foundation

import ArilsCore

/// Drives the mouth from audio when a `LipSyncFrame` is supplied, or from a
/// procedural syllable pattern while `isSpeaking` without audio. Openness runs
/// through an attack/release envelope (mouths snap open, drift shut); form
/// through a spring so vowel shapes morph instead of popping. Precomputed
/// frames (`LipSyncTimeline`) carry a small `smoothing` so the envelope does
/// not blur their closures a second time.
public final class LipSyncLayer: MotionLayer {
    private static let attack: Float = 0.035
    private static let release: Float = 0.11

    private var openEnvelope = AttackReleaseEnvelope(value: 0, attack: LipSyncLayer.attack, release: LipSyncLayer.release)
    private var formSpring = SpringDamper(value: 0, frequency: 4.0, dampingRatio: 1.0)
    private let syllableNoise: ValueNoise1D
    private let cues: MotionCues

    public convenience init(seed: UInt64) {
        self.init(seed: seed, cues: MotionCues())
    }

    init(seed: UInt64, cues: MotionCues) {
        self.syllableNoise = ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("lipsync")))
        self.cues = cues
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let dt = context.deltaTime
        let targetOpen: Float
        let targetForm: Float

        if let frame = context.inputs.lipSync {
            targetOpen = Interpolation.clamp(frame.open, 0...1)
            targetForm = Interpolation.clamp(frame.form, -1...1)
        } else if context.inputs.isSpeaking {
            // Procedural fallback: noise bursts at syllable rate (~5-8 Hz)
            // gated so pauses between "words" appear naturally.
            let t = Float(context.time)
            let burst = syllableNoise.fbm(at: t * 6.2, octaves: 2)
            let gate = Interpolation.smoothstep(-0.15, 0.25, syllableNoise.value(at: t * 0.9 + 40))
            targetOpen = Interpolation.clamp((0.12 + 0.62 * abs(burst)) * gate, 0...1)
            targetForm = syllableNoise.value(at: t * 2.1 + 80) * 0.5
        } else {
            targetOpen = 0
            targetForm = 0
        }

        let smoothing = Interpolation.clamp(context.inputs.lipSync?.smoothing ?? 1, 0.05...1)
        openEnvelope.attack = Self.attack * smoothing
        openEnvelope.release = Self.release * smoothing
        let open = openEnvelope.step(toward: targetOpen, deltaTime: dt)
        let form = formSpring.step(toward: targetForm, deltaTime: dt)
        // Phrasing and stress are read from the unsmoothed target: the
        // release tail would otherwise swallow short pauses.
        cues.speechLevel = targetOpen

        values.override(.mouthOpen, open)
        values.override(.mouthForm, form)
    }
}
