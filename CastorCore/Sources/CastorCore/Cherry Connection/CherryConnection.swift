import Foundation

public struct CherryConnection {
    public func parameters(from snapshot: HesitateSnapshot, at date: Date) -> MotionParameters {
        parameters(from: snapshot, trilobite: .inactive, at: date)
    }

    /// Preview/debug entry point (used by `ContentView`'s `MotionParameterTimeline`). Does not
    /// apply the `MotionContext` overlay (D) — that overlay is exclusively the pet-renderer's
    /// ported touch/speaking/listening behavior and must stay opt-in so this preview path's
    /// output is unaffected by D's refactor.
    public func parameters(from snapshot: HesitateSnapshot, trilobite: TrilobiteInputSnapshot, at date: Date) -> MotionParameters {
        coreParameters(from: snapshot, trilobite: trilobite, at: date)
    }

    /// Context-aware entry point used by `PetFloatingView`. Applies the same base motion as the
    /// preview path, then folds in the `MotionContext` overlay (touched/speaking/listening) that
    /// used to live in `PetFloatingView.petParameters(at:touched:)`.
    public func parameters(
        from snapshot: HesitateSnapshot,
        trilobite: TrilobiteInputSnapshot,
        context: MotionContext,
        at date: Date
    ) -> MotionParameters {
        var parameters = coreParameters(from: snapshot, trilobite: trilobite, at: date, gazeContext: context)
        applyContextOverlay(
            &parameters,
            context: context,
            voiceIsListening: trilobite.isListening || context.isListening,
            time: date.timeIntervalSinceReferenceDate
        )
        // `isSpeaking` is the only place a renderer can learn "the character is actually
        // producing speech right now" rather than inferring it from mouthOpen's magnitude (which
        // ambient thinking/listening chatter can also reach).
        parameters.isSpeaking = context.isSpeaking
        return parameters
    }

    private func coreParameters(
        from snapshot: HesitateSnapshot,
        trilobite: TrilobiteInputSnapshot,
        at date: Date,
        gazeContext: MotionContext = .preview
    ) -> MotionParameters {
        let time = date.timeIntervalSinceReferenceDate
        let age = max(0, date.timeIntervalSince(snapshot.requestedAt))
        let lag = hesitantLag(age: age, awkwardness: snapshot.awkwardness)
        let currentState = effectiveState(coreState: snapshot.state, trilobite: trilobite)
        // The trilobite-driven override (surprised on close face, listening on mic activity) has
        // no `requestedAt` of its own, so its pose swaps stay instantaneous — that path is a
        // preview-only override and is intentionally out of scope for the cross-fade below.
        let previousEffectiveState = effectiveState(coreState: snapshot.previousState, trilobite: trilobite)
        let currentInputEnergy = max(snapshot.speechEnergy, trilobite.audioLevel)
        // `HesitateSnapshot` only carries the *current* state's speechEnergy, not the previous
        // state's — so the previous side of the mouth-open blend uses the same resting energy
        // `HesitateCore` would have assigned to that previous state, keeping the two sides of the
        // blend comparable instead of mixing one state's mouth shape with another state's energy.
        let previousInputEnergy = max(restingSpeechEnergy(for: snapshot.previousState), trilobite.audioLevel)
        let inputAwkwardness = min(1, snapshot.awkwardness + trilobite.audioLevel * 0.18)
        let blink = blinkAmount(time: time, awkwardness: snapshot.awkwardness, requestedAt: snapshot.requestedAt)
        let breathing = sin(time * 2.1) * (5 + inputAwkwardness * 3)
        let tinyMistake = sin(time * 11.0) * inputAwkwardness

        // Pose fields (headTilt, eyeOpen, eyeScale, browLift, mouthSlant, cheekWarmth) cross-fade
        // from the previous state's pose to the current state's pose using `lag` as the
        // interpolation progress. `lag` is the existing hesitant-delay curve (a short pause,
        // then an exponential ease-in) — reused here purely as a 0->1 progress value, not as a
        // multiplier that can freeze ambient motion.
        var parameters = blendedPoseParameters(
            from: previousEffectiveState,
            to: currentState,
            progress: lag
        )

        // Ambient motion (breathing, head bob, gaze, mouth chatter) is a pure function of
        // absolute time, so it must not be multiplied by `lag` — doing so froze it at zero right
        // after every state change. Instead it stays continuous across the transition; only the
        // *shape* of gaze/mouth (which switches per state) is blended across the same progress.
        parameters.bodyLift = breathing
        parameters.headBob = sin(time * 1.4 + 0.7) * 2.4 + tinyMistake
            + listeningNodBob(time: time, trilobite: trilobite, state: currentState)
        parameters.eyeOpen = max(0.05, parameters.eyeOpen - blink)

        let previousGaze = gaze(time: time, state: previousEffectiveState, trilobite: trilobite, context: gazeContext)
        let currentGaze = gaze(time: time, state: currentState, trilobite: trilobite, context: gazeContext)
        parameters.gazeX = lerp(previousGaze.x, currentGaze.x, lag)
        parameters.gazeY = lerp(previousGaze.y, currentGaze.y, lag)

        let previousMouthOpen = mouthOpen(time: time, energy: previousInputEnergy, state: previousEffectiveState)
        let currentMouthOpen = mouthOpen(time: time, energy: currentInputEnergy, state: currentState)
        parameters.mouthOpen = lerp(previousMouthOpen, currentMouthOpen, lag)

        parameters.cheekWarmth = min(1, parameters.cheekWarmth + inputAwkwardness * 0.18)

        return parameters
    }

    private func effectiveState(coreState: MotionState, trilobite: TrilobiteInputSnapshot) -> MotionState {
        if trilobite.faceIsClose {
            return .surprised
        }

        if trilobite.isListening {
            return .listening
        }

        return coreState
    }

    private func blendedPoseParameters(from previousState: MotionState, to state: MotionState, progress: Double) -> MotionParameters {
        var parameters = baseParameters(for: state)
        guard previousState != state else {
            return parameters
        }

        let previous = baseParameters(for: previousState)
        parameters.headTilt = lerp(previous.headTilt, parameters.headTilt, progress)
        parameters.eyeOpen = lerp(previous.eyeOpen, parameters.eyeOpen, progress)
        parameters.eyeScale = lerp(previous.eyeScale, parameters.eyeScale, progress)
        parameters.browLift = lerp(previous.browLift, parameters.browLift, progress)
        parameters.mouthSlant = lerp(previous.mouthSlant, parameters.mouthSlant, progress)
        parameters.cheekWarmth = lerp(previous.cheekWarmth, parameters.cheekWarmth, progress)
        return parameters
    }

    private func baseParameters(for state: MotionState) -> MotionParameters {
        switch state {
        case .idle:
            var parameters = MotionParameters.neutral
            parameters.state = .idle
            parameters.headTilt = -2
            parameters.eyeScale = 1
            parameters.browLift = 0
            parameters.mouthSlant = 0.04
            return parameters
        case .thinking:
            var parameters = MotionParameters.neutral
            parameters.state = .thinking
            parameters.headTilt = 8
            parameters.eyeScale = 0.88
            parameters.browLift = -4
            parameters.mouthSlant = -0.12
            parameters.cheekWarmth = 0.42
            return parameters
        case .listening:
            var parameters = MotionParameters.neutral
            parameters.state = .listening
            parameters.headTilt = 3
            parameters.eyeOpen = 1.05
            parameters.eyeScale = 1.04
            parameters.browLift = 3
            parameters.mouthSlant = 0.08
            parameters.cheekWarmth = 0.52
            return parameters
        case .surprised:
            var parameters = MotionParameters.neutral
            parameters.state = .surprised
            parameters.headTilt = -7
            parameters.eyeOpen = 1.2
            parameters.eyeScale = 1.18
            parameters.browLift = 10
            parameters.mouthSlant = 0.16
            parameters.cheekWarmth = 0.62
            return parameters
        }
    }

    /// Mirrors `HesitateCore.speechEnergy(for:)` — the resting speech energy a state settles at
    /// when nothing dynamic (mic level, live TTS energy) is overriding it. Used only to give the
    /// previous-state side of the mouth-open blend an energy value from the same state, instead
    /// of borrowing the new state's (possibly very different) live energy.
    private func restingSpeechEnergy(for state: MotionState) -> Double {
        switch state {
        case .idle:
            0.10
        case .thinking:
            0.34
        case .listening:
            0.72
        case .surprised:
            0.68
        }
    }

    private func hesitantLag(age: TimeInterval, awkwardness: Double) -> Double {
        let delay = 0.10 + awkwardness * 0.36
        let delayedAge = max(0, age - delay)
        return 1 - exp(-delayedAge * 3.8)
    }

    private func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return start + (end - start) * clamped
    }

    // MARK: - Motion context overlay (D)

    /// Folds in the small set of caller-side overlays that `PetFloatingView.petParameters` used
    /// to apply on top of `CherryConnection`'s output: the touched happy-bounce/head/gaze wiggle,
    /// the wider-eyed touched/listening look, and the speaking mouth override. Ported verbatim
    /// (same waveforms/constants) from the pre-D `petParameters(at:touched:)` — this method must
    /// not change the visual result for any existing call site, only relocate where it runs.
    ///
    /// Gaze itself is *not* ported here — the old per-call drift (`sin(t*0.55)*4.2`, etc.) is
    /// superseded by the saccade gaze model in `gaze(time:state:trilobite:context:)` (C).
    private func applyContextOverlay(_ parameters: inout MotionParameters, context: MotionContext, voiceIsListening: Bool, time: Double) {
        let touched = context.touched
        let happyBounce = touched ? abs(sin(time * 7.4)) * -5.0 : 0

        parameters.bodyLift += sin(time * 1.45) * 2.6 + happyBounce
        parameters.headTilt += touched ? sin(time * 4.1) * 4.2 : sin(time * 0.72) * 2.8
        parameters.headBob += sin(time * (touched ? 4.8 : 1.85)) * (touched ? 3.2 : 1.8)
        // Touched/listening reads as a slightly wider-eyed, alert look. This is expressed purely
        // through eyeScale so Cherry Connection's blink (applied to eyeOpen above) is never
        // suppressed — the pet can still blink while touched or listening.
        parameters.eyeScale = max(parameters.eyeScale, touched || voiceIsListening ? 1.08 : 1)

        if context.isSpeaking {
            if let speechEnergy = context.speechEnergy {
                // Phase E: real playback energy drives the mouth directly via the pure
                // energy->mouthOpen mapping, instead of the old fixed sine flap. `max` still
                // guards against ambient mouth shapes exceeding this (e.g. surprised's base 0.45),
                // matching the old override's behavior of only ever opening the mouth further.
                parameters.mouthOpen = max(parameters.mouthOpen, SpeechEnergyMouthMapping.mouthOpen(forEnergy: speechEnergy))
            } else {
                // Fallback: no live energy signal available yet (e.g. before the first audio
                // byte arrives, or an unsupported playback path) — keep the legacy sine-wave flap
                // so the mouth still moves plausibly instead of sitting still.
                parameters.mouthOpen = max(parameters.mouthOpen, 0.18 + abs(sin(time * 8.4)) * 0.48)
            }
        } else if touched {
            parameters.mouthOpen = max(parameters.mouthOpen, 0.22 + max(0, sin(time * 8.0)) * 0.10)
        }

        parameters.mouthSlant += touched ? 0.28 : sin(time * 0.5) * 0.18
        parameters.browLift += touched ? 4.0 : 0.12
        parameters.cheekWarmth = max(parameters.cheekWarmth, touched ? 0.72 : 0.3)

        if let cue = context.evasionCue {
            applyEvasionCue(cue, to: &parameters)
        }
    }

    private func applyEvasionCue(_ cue: EvasionMotionCue, to parameters: inout MotionParameters) {
        let age = max(0, cue.elapsed)
        switch cue.bodyCue {
        case .startledHop:
            let envelope = exp(-age * 2.8)
            parameters.bodyLift -= abs(sin(age * 10.5)) * 8.0 * envelope
            parameters.headBob -= abs(sin(age * 9.2)) * 3.5 * envelope
            parameters.eyeScale = max(parameters.eyeScale, 1.10)
            parameters.browLift += 3.0 * envelope
        case .bow:
            let bowProgress = min(1, age / 0.7)
            parameters.headBob += sin(bowProgress * .pi) * 5.0
            parameters.headTilt *= 0.72
        case .none:
            break
        case .displeased:
            parameters.browLift -= 3.2
            parameters.mouthSlant -= 0.24
            parameters.headTilt += 2.2
        case .stabilized:
            parameters.bodyLift *= 0.24
            parameters.headBob *= 0.30
            parameters.headTilt *= 0.42
        }

        if let gazeTarget = cue.gazeTarget {
            parameters.gazeX = lerp(parameters.gazeX, Double(gazeTarget.x), 0.78)
            parameters.gazeY = lerp(parameters.gazeY, Double(gazeTarget.y), 0.78)
        }
    }

    // MARK: - Blinking

    /// Single source of truth for blinking. Stays a pure function of `time`/`awkwardness`/
    /// `requestedAt` (never wall-clock randomness) so the same inputs always reproduce the same
    /// blink, which keeps it unit-testable and keeps every renderer (Cherry Connection ambient
    /// motion, PetFloatingView) in sync without competing blink cycles.
    ///
    /// The timeline is divided into windows of `averageInterval(awkwardness:)` seconds. Each
    /// window's index is fed through a small deterministic bit-mix hash to derive: the blink's
    /// jittered position inside the window, whether it is a rare double-blink, and (for the
    /// window immediately after a state transition) whether attention-switch blink is nudged to
    /// trigger near the end of the hesitant delay.
    private func blinkAmount(time: TimeInterval, awkwardness: Double, requestedAt: Date) -> Double {
        let interval = averageBlinkInterval(awkwardness: awkwardness)
        let windowIndex = Int(floor(time / interval))
        let windowStart = Double(windowIndex) * interval

        var amount = blinkContribution(
            time: time,
            windowStart: windowStart,
            windowIndex: windowIndex,
            interval: interval
        )

        // A blink is also possible from the *previous* window bleeding into this one (its gaussian
        // tail) or the *next* window's blink starting early — check neighbors so windows don't
        // create a hard seam.
        amount = max(amount, blinkContribution(
            time: time,
            windowStart: windowStart - interval,
            windowIndex: windowIndex - 1,
            interval: interval
        ))
        amount = max(amount, blinkContribution(
            time: time,
            windowStart: windowStart + interval,
            windowIndex: windowIndex + 1,
            interval: interval
        ))

        amount = max(amount, transitionBlinkContribution(time: time, requestedAt: requestedAt))

        return min(0.95, amount)
    }

    private func averageBlinkInterval(awkwardness: Double) -> Double {
        3.2 - awkwardness * 0.8
    }

    /// One window can contain up to two blinks (a rare double-blink): the primary blink plus,
    /// with low probability, a quick second one shortly after.
    private func blinkContribution(time: TimeInterval, windowStart: Double, windowIndex: Int, interval: Double) -> Double {
        let hash = Self.mix(UInt64(bitPattern: Int64(windowIndex)))
        let jitter = Self.unitInterval(hash, salt: 1) * (interval * 0.6)
        let blinkTime = windowStart + interval * 0.15 + jitter

        var amount = gaussianBlink(time: time, center: blinkTime, width: 0.055)

        let isDoubleBlink = Self.unitInterval(hash, salt: 2) < 0.18
        if isDoubleBlink {
            let secondBlinkTime = blinkTime + 0.16 + Self.unitInterval(hash, salt: 3) * 0.08
            amount = max(amount, gaussianBlink(time: time, center: secondBlinkTime, width: 0.05) * 0.85)
        }

        return amount
    }

    /// People tend to blink when attention or gaze shifts — nudge one extra blink shortly after
    /// the hesitant delay finishes settling into a new state, deterministically keyed off
    /// `requestedAt` so it stays a pure function of the snapshot rather than wall-clock state.
    private func transitionBlinkContribution(time: TimeInterval, requestedAt: Date) -> Double {
        let requestedTime = requestedAt.timeIntervalSinceReferenceDate
        let hash = Self.mix(UInt64(bitPattern: Int64(requestedTime.rounded())))
        guard Self.unitInterval(hash, salt: 4) < 0.85 else {
            return 0
        }

        let delay = 0.10 + 0.36 // matches the widest hesitant-lag settle window
        let blinkTime = requestedTime + delay + Self.unitInterval(hash, salt: 5) * 0.5
        return gaussianBlink(time: time, center: blinkTime, width: 0.06)
    }

    private func gaussianBlink(time: TimeInterval, center: Double, width: Double) -> Double {
        exp(-pow((time - center) / width, 2))
    }

    /// Deterministic 64-bit bit-mix hash (splitmix64 finalizer). Same input always produces the
    /// same output, with no dependency on wall-clock randomness or external state.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Derives a value in [0, 1) from a hash, salted so multiple independent draws (jitter,
    /// double-blink chance, etc.) can be taken from the same window hash without correlating.
    private static func unitInterval(_ hash: UInt64, salt: UInt64) -> Double {
        let salted = mix(hash ^ (salt &* 0x2545F4914F6CDD1D))
        return Double(salted % 1_000_000) / 1_000_000
    }

    // MARK: - Saccadic gaze (C)

    /// A single fixation point in the gaze plane.
    private struct GazePoint {
        var x: Double
        var y: Double
    }

    /// Deterministic saccade-and-fixation gaze model: same shape as blinking (B) — the timeline is
    /// divided into fixed-length windows, each window's index is bit-mix hashed to derive a target
    /// fixation point, and the eye "saccades" (a fast 0.12-0.2s smooth step) from the previous
    /// window's fixation point to the current window's, then holds nearly still (small jitter)
    /// until the next saccade. This is a pure O(1) function of `time` — no running/cumulative
    /// state — evaluated for the current window plus its immediate neighbor, mirroring the
    /// blink implementation's neighbor-window seam handling.
    ///
    /// `trilobite.faceDetected` bypasses this model entirely and returns the tracked face gaze
    /// directly, same as before.
    private func gaze(time: TimeInterval, state: MotionState, trilobite: TrilobiteInputSnapshot, context: MotionContext) -> GazePoint {
        if trilobite.faceDetected {
            return GazePoint(x: trilobite.gazeX, y: trilobite.gazeY)
        }

        let profile = gazeProfile(state: state, trilobite: trilobite, context: context)
        let windowIndex = Int(floor(time / profile.windowLength))
        return fixation(time: time, windowIndex: windowIndex, profile: profile)
    }

    /// Range/timing parameters for a state's gaze distribution. `xRange`/`yRange` are the
    /// half-widths (in the same units as `gazeX`/`gazeY`) around `xCenter`/`yCenter` from which
    /// fixation points are drawn; `windowLength` controls how long each fixation is held before
    /// the next saccade; `jitterAmplitude` is the small in-fixation jitter (never a full saccade).
    private struct GazeProfile {
        var xCenter: Double
        var yCenter: Double
        var xRange: Double
        var yRange: Double
        var windowLength: Double
        var jitterAmplitude: Double
        /// Duration of the smooth-step saccade transition between two fixation points.
        var saccadeDuration: Double
    }

    private func gazeProfile(state: MotionState, trilobite: TrilobiteInputSnapshot, context: MotionContext) -> GazeProfile {
        if context.touched {
            var profile = baseGazeProfile(state: state, trilobite: trilobite)
            profile.yCenter = -2
            profile.windowLength = 0.8
            return profile
        }

        return baseGazeProfile(state: state, trilobite: trilobite)
    }

    private func baseGazeProfile(state: MotionState, trilobite: TrilobiteInputSnapshot) -> GazeProfile {
        switch state {
        case .idle:
            return GazeProfile(xCenter: 0, yCenter: 0, xRange: 8, yRange: 3, windowLength: 2.0, jitterAmplitude: 0.5, saccadeDuration: 0.16)
        case .thinking:
            return GazeProfile(xCenter: -10, yCenter: 5, xRange: 4, yRange: 2.5, windowLength: 2.5, jitterAmplitude: 0.4, saccadeDuration: 0.18)
        case .listening:
            let widen = trilobite.audioLevel * 2
            return GazeProfile(xCenter: 0, yCenter: 0, xRange: 4 + widen, yRange: 2 + widen * 0.5, windowLength: 1.0, jitterAmplitude: 0.4, saccadeDuration: 0.14)
        case .surprised:
            return GazeProfile(xCenter: 0, yCenter: 0, xRange: 2, yRange: 2, windowLength: 0.5, jitterAmplitude: 0.6, saccadeDuration: 0.12)
        }
    }

    /// Derives the fixation point for `windowIndex` from the deterministic hash, then blends
    /// smoothly from the *previous* window's fixation point over `saccadeDuration` seconds at the
    /// start of the window (the saccade), holding the current window's fixation (plus small
    /// jitter) for the remainder (the fixation). Evaluating the immediate neighbor window and
    /// taking whichever is "in control" of `time` avoids a hard seam exactly like the blink
    /// window's neighbor check.
    private func fixation(time: TimeInterval, windowIndex: Int, profile: GazeProfile) -> GazePoint {
        let windowStart = Double(windowIndex) * profile.windowLength
        let localTime = time - windowStart

        let target = fixationPoint(windowIndex: windowIndex, profile: profile)

        if localTime < profile.saccadeDuration {
            // Still saccading in from the previous window's fixation point.
            let previousTarget = fixationPoint(windowIndex: windowIndex - 1, profile: profile)
            let progress = smoothStep(localTime / profile.saccadeDuration)
            let jitter = fixationJitter(time: time, windowIndex: windowIndex, profile: profile)
            return GazePoint(
                x: lerp(previousTarget.x, target.x, progress) + jitter.x * progress,
                y: lerp(previousTarget.y, target.y, progress) + jitter.y * progress
            )
        }

        let jitter = fixationJitter(time: time, windowIndex: windowIndex, profile: profile)
        return GazePoint(x: target.x + jitter.x, y: target.y + jitter.y)
    }

    /// The fixation point a given window settles on, derived purely from the window index via the
    /// shared bit-mix hash (same construction as the blink jitter/double-blink draws).
    private func fixationPoint(windowIndex: Int, profile: GazeProfile) -> GazePoint {
        let hash = Self.mix(UInt64(bitPattern: Int64(windowIndex)) ^ 0xA5A5_5A5A_1234_5678)
        let unitX = Self.unitInterval(hash, salt: 11) * 2 - 1
        let unitY = Self.unitInterval(hash, salt: 12) * 2 - 1
        return GazePoint(
            x: profile.xCenter + unitX * profile.xRange,
            y: profile.yCenter + unitY * profile.yRange
        )
    }

    /// Small continuous jitter during a fixation, derived from the same window hash so it stays
    /// deterministic; low amplitude keeps fixations reading as "nearly still".
    private func fixationJitter(time: TimeInterval, windowIndex: Int, profile: GazeProfile) -> GazePoint {
        let hash = Self.mix(UInt64(bitPattern: Int64(windowIndex)) ^ 0xA5A5_5A5A_1234_5678)
        let phaseX = Self.unitInterval(hash, salt: 13) * 2 * Double.pi
        let phaseY = Self.unitInterval(hash, salt: 14) * 2 * Double.pi
        let freqX = 1.6 + Self.unitInterval(hash, salt: 15) * 0.8
        let freqY = 1.3 + Self.unitInterval(hash, salt: 16) * 0.8
        return GazePoint(
            x: sin(time * freqX + phaseX) * profile.jitterAmplitude,
            y: sin(time * freqY + phaseY) * profile.jitterAmplitude
        )
    }

    /// Smooth (ease-in/ease-out) interpolation curve for saccades, clamped to [0, 1].
    private func smoothStep(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Ambient (non-speaking) mouth shape per state. `listening` deliberately carries no chatter
    /// term: the pet is listening, not talking, so its mouth should stay quiet/closed rather than
    /// flapping along with the *user's* mic level (the old behavior read as "the pet is talking
    /// while you talk", which was confusing, and is replaced by a small listening nod instead —
    /// see `listeningNodBob(time:trilobite:state:)`).
    private func mouthOpen(time: TimeInterval, energy: Double, state: MotionState) -> Double {
        switch state {
        case .idle:
            let chatter = abs(sin(time * 9.2) * cos(time * 4.7))
            return min(1, 0.05 + chatter * energy)
        case .thinking:
            let chatter = abs(sin(time * 9.2) * cos(time * 4.7))
            return min(1, 0.10 + chatter * energy)
        case .listening:
            return 0.12
        case .surprised:
            let chatter = abs(sin(time * 9.2) * cos(time * 4.7))
            return min(1, 0.45 + chatter * energy)
        }
    }

    /// Small "listening nod" head-bob amplification: while listening, headBob gets a gentle extra
    /// wobble that scales with `trilobite.audioLevel` (the input mic level), capped at a modest
    /// amplitude so it reads as an attentive nod rather than a full head-bob replacement. Returns
    /// 0 outside the listening state so it never affects other states' headBob.
    private func listeningNodBob(time: TimeInterval, trilobite: TrilobiteInputSnapshot, state: MotionState) -> Double {
        guard state == .listening else {
            return 0
        }
        let level = max(0, min(1, trilobite.audioLevel))
        // Capped at 2.0 (per the spec's "up to ~2" headBob addition), using a slower nod-like
        // frequency than the idle head-bob's own wobble so the two don't just look like a single
        // faster bob.
        return sin(time * 3.1) * level * 2.0
    }

    public init() {}
}
