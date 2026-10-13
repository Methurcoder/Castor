import Foundation

import ArilsCore

/// Mouth track computed from a whole speech clip *before* it plays — the
/// accurate lip-sync path for TTS, where the audio exists ahead of time.
///
/// Compared with live analysis it can:
/// - use **centred** windows (no causal analysis lag);
/// - **normalize** to the clip's own speech level, so a quiet voice
///   articulates as clearly as a loud one;
/// - find **stop closures** (the short silences of p/t/k/b/っ) and shut the
///   mouth there, instead of letting the release envelope drift through;
/// - run slightly **ahead** of the audio: lips and jaw move before the sound
///   they shape, and viewers accept a mouth that leads far more readily than
///   one that lags.
///
/// Index it by the player's clock (`frame(at:)`), so stalls and seeks stay
/// aligned automatically.
public struct LipSyncTimeline: Sendable, Equatable {
    public var frameRate: Double
    public var frames: [LipSyncFrame]

    /// Default mouth lead over the audio, in seconds.
    public static let defaultLead: Double = 0.06
    /// Envelope share `LipSyncLayer` still applies to these frames.
    public static let frameSmoothing: Float = 0.35

    public init(frameRate: Double, frames: [LipSyncFrame]) {
        self.frameRate = frameRate
        self.frames = frames
    }

    public var duration: Double {
        frameRate > 0 ? Double(frames.count) / frameRate : 0
    }

    /// The mouth for audio playback position `playbackTime` (seconds), read
    /// `lead` seconds ahead. Closed before the start; nil once past the end.
    public func frame(at playbackTime: Double, lead: Double = LipSyncTimeline.defaultLead) -> LipSyncFrame? {
        guard frameRate > 0, playbackTime.isFinite, !frames.isEmpty else { return nil }
        let position = (playbackTime + lead) * frameRate
        if position < 0 {
            return LipSyncFrame(open: 0, form: 0, smoothing: Self.frameSmoothing)
        }
        let lower = Int(position.rounded(.down))
        guard lower < frames.count else {
            return playbackTime < duration
                ? LipSyncFrame(open: 0, form: 0, smoothing: Self.frameSmoothing)
                : nil
        }
        let upper = min(frames.count - 1, lower + 1)
        let t = Float(position - Double(lower))
        let a = frames[lower]
        let b = frames[upper]
        return LipSyncFrame(
            open: a.open + (b.open - a.open) * t,
            form: a.form + (b.form - a.form) * t,
            smoothing: Self.frameSmoothing
        )
    }

    /// Analyzes a mono clip into a timeline.
    public static func analyze(samples: [Float], sampleRate: Double, frameRate: Double = 60) -> LipSyncTimeline {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0, frameRate > 0 else {
            return LipSyncTimeline(frameRate: max(1, frameRate), frames: [])
        }
        let frameCount = Int(ceil(Double(samples.count) / sampleRate * frameRate))
        let half = max(1, Int(0.01 * sampleRate))
        let analyzer = LipSyncAnalyzer()

        var decibels = [Float](repeating: -120, count: frameCount)
        var forms = [Float](repeating: 0, count: frameCount)
        let windowSize = LipSyncAnalyzer.windowSize
        for index in 0..<frameCount {
            let center = Int(Double(index) / frameRate * sampleRate)
            let lower = max(0, center - half)
            let upper = min(samples.count, center + half)
            if upper > lower {
                var sum: Float = 0
                for sample in samples[lower..<upper] { sum += sample * sample }
                decibels[index] = 20 * log10(max((sum / Float(upper - lower)).squareRoot(), 1e-6))
            }
            // Vowel shape from a window centred on the frame.
            var window = [Float](repeating: 0, count: windowSize)
            let start = center - windowSize / 2
            for offset in 0..<windowSize {
                let source = start + offset
                if source >= 0, source < samples.count { window[offset] = samples[source] }
            }
            forms[index] = analyzer.analyze(window: window, sampleRate: sampleRate).form
        }

        let voiced = decibels.filter { $0 > -60 }.sorted()
        guard !voiced.isEmpty else {
            return LipSyncTimeline(
                frameRate: frameRate,
                frames: Array(repeating: LipSyncFrame(open: 0, form: 0, smoothing: frameSmoothing), count: frameCount)
            )
        }
        let peak = voiced[min(voiced.count - 1, Int(Double(voiced.count) * 0.95))]
        let floor = peak - 28

        var open = decibels.map { Interpolation.clamp(($0 - floor) / 24, 0...1) }
        // Light zero-phase smoothing (no lag, unlike a live envelope).
        if open.count > 2 {
            let raw = open
            for index in 1..<(raw.count - 1) {
                open[index] = 0.25 * raw[index - 1] + 0.5 * raw[index] + 0.25 * raw[index + 1]
            }
        }

        // Stop closures: short near-silent runs *inside* speech shut the mouth,
        // starting one frame early so the lips are closed when the burst comes.
        let quiet = decibels.map { $0 < peak - 30 }
        var index = 0
        while index < frameCount {
            guard quiet[index] else { index += 1; continue }
            var end = index
            while end < frameCount, quiet[end] { end += 1 }
            let length = end - index
            let insideSpeech = index > 0 && end < frameCount
            if insideSpeech, length >= 2 {
                for closed in max(0, index - 1)..<end { open[closed] = 0 }
            }
            index = end
        }

        let frames = zip(open, forms).map { LipSyncFrame(open: $0, form: $0 > 0.02 ? $1 : 0, smoothing: frameSmoothing) }
        return LipSyncTimeline(frameRate: frameRate, frames: frames)
    }
}
