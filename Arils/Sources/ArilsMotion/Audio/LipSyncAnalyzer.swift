#if canImport(Accelerate)
import Accelerate
#endif
import Foundation

import ArilsCore

/// Turns speech audio into `LipSyncFrame`s.
///
/// Two signals, both cheap enough for every frame:
/// - **openness** from the RMS level of the last ~20 ms, mapped from dB — the
///   classic volume drive, but perceptually scaled;
/// - **form** from the spectral tilt (energy above ~1.5 kHz vs below ~800 Hz).
///   Bright vowels (い/え, "ee") carry far more high-band energy than round
///   ones (お/う, "oh") — a crude but effective vowel-shape estimate that makes
///   the mouth articulate instead of just flapping with volume.
///
/// Push paths:
/// - `push(samples:sampleRate:)` — full analysis; safe to call from an audio
///   tap thread (internally locked).
/// - `push(level:)` — meter-only fallback (e.g. `AVAudioPlayer.averagePower`
///   already normalized 0...1); openness only, form stays neutral.
/// - `analyzeTimeline(...)` — offline analysis of a whole clip (e.g. a TTS WAV
///   before playback) into per-frame values for perfectly aligned sync.
public final class LipSyncAnalyzer: @unchecked Sendable {
    static let windowSize = 1024
    /// Frames older than this are considered stale and report nil (silence).
    private static let staleAfter: TimeInterval = 0.3

    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 4096)
    private var ringCount = 0
    private var writeIndex = 0
    private var sampleRate: Double = 48_000
    private var lastPushUptime: TimeInterval = -.greatestFiniteMagnitude
    private var externalLevel: Float?
    /// Speech-level follower (dBFS) for automatic gain: quiet voices still
    /// articulate instead of barely parting the lips.
    private var referencePeak: Float = -45
    private var lastFrameUptime: TimeInterval?

    #if canImport(Accelerate)
    private let dft: vDSP.DiscreteFourierTransform<Float>?
    #endif
    private let hannWindow: [Float]

    public init() {
        #if canImport(Accelerate)
        self.dft = try? vDSP.DiscreteFourierTransform(
            previous: nil,
            count: Self.windowSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        self.hannWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.windowSize,
            isHalfWindow: false
        )
        #else
        self.hannWindow = Self.portableHannWindow(count: Self.windowSize)
        #endif
    }

    /// vDSP's denormalized Hann window, 0.5 (1 − cos 2πn/N), for platforms
    /// without Accelerate.
    static func portableHannWindow(count: Int) -> [Float] {
        let n = Float(count)
        return (0..<count).map { 0.5 * (1 - cos(2 * .pi * Float($0) / n)) }
    }

    /// Power of one DFT bin of `windowed`, computed directly, for platforms
    /// without Accelerate. Only ~100 bins between 100 Hz and 5 kHz are used,
    /// so this is cheap enough without an FFT.
    static func portableBinPower(_ windowed: [Float], bin: Int) -> Float {
        var real: Float = 0
        var imaginary: Float = 0
        let step = -2 * Float.pi * Float(bin) / Float(windowed.count)
        for (n, value) in windowed.enumerated() {
            let angle = step * Float(n)
            real += value * cos(angle)
            imaginary += value * sin(angle)
        }
        return real * real + imaginary * imaginary
    }

    // MARK: - Push

    /// Feeds PCM samples (mono; interleave-averaged upstream if needed).
    public func push(samples: [Float], sampleRate: Double) {
        // An audio route can briefly report an unusable format while it is
        // being reconfigured. Ignore that buffer rather than storing a zero
        // or non-finite rate that would make spectral bin calculation trap.
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = sampleRate
        self.externalLevel = nil
        for sample in samples {
            ring[writeIndex] = sample
            writeIndex = (writeIndex + 1) % ring.count
        }
        ringCount = min(ring.count, ringCount + samples.count)
        lastPushUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Meter-only path: a pre-normalized 0...1 level (no spectral analysis).
    public func push(level: Float) {
        lock.lock()
        defer { lock.unlock() }
        externalLevel = Interpolation.clamp(level, 0...1)
        lastPushUptime = ProcessInfo.processInfo.systemUptime
    }

    /// nil while silent/stale — the motion layer treats that as "mouth closed".
    public func currentFrame() -> LipSyncFrame? {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - lastPushUptime
        guard age <= Self.staleAfter else { return nil }

        if let level = externalLevel {
            // Meter levels arrive as the host's linear map of -50...0 dB.
            let absolute = Interpolation.smoothstep(0.02, 0.75, level)
            return LipSyncFrame(open: adaptiveOpen(absolute: absolute, decibels: -50 + 50 * level, now: now), form: 0)
        }
        guard ringCount >= Self.windowSize / 2 else { return nil }

        // Copy out the newest window in chronological order.
        var window = [Float](repeating: 0, count: Self.windowSize)
        let available = min(ringCount, Self.windowSize)
        for offset in 0..<available {
            let sourceIndex = (writeIndex - available + offset + ring.count * 2) % ring.count
            window[Self.windowSize - available + offset] = ring[sourceIndex]
        }
        let frame = analyze(window: window, sampleRate: sampleRate)
        return LipSyncFrame(
            open: adaptiveOpen(absolute: frame.open, decibels: Self.recentDecibels(window), now: now),
            form: frame.form
        )
    }

    /// Automatic gain on top of the absolute dB map: openness relative to the
    /// recent speech peak, never lower than the absolute value. The peak
    /// follower rises instantly, sinks 1.5 dB/s, and never drops below −45 dBFS,
    /// so silence and noise floors are not amplified into mouth movement.
    private func adaptiveOpen(absolute: Float, decibels: Float, now: TimeInterval) -> Float {
        let dt = Float(min(0.5, max(0, now - (lastFrameUptime ?? now))))
        lastFrameUptime = now
        referencePeak = max(-45, max(decibels, referencePeak - 1.5 * dt))
        let relative = Interpolation.clamp((decibels - (referencePeak - 20)) / 17, 0...1)
        return max(absolute, relative)
    }

    /// RMS level of the newest quarter window in dBFS.
    static func recentDecibels(_ window: [Float]) -> Float {
        let recent = Array(window.suffix(windowSize / 4))
        var meanSquare: Float = 0
        #if canImport(Accelerate)
        vDSP_measqv(recent, 1, &meanSquare, vDSP_Length(recent.count))
        #else
        meanSquare = recent.reduce(0) { $0 + $1 * $1 } / Float(max(1, recent.count))
        #endif
        return 20 * log10(max(sqrt(meanSquare), 1e-6))
    }

    // MARK: - Analysis core (pure given its inputs; exposed for tests)

    public func analyze(window: [Float], sampleRate: Double) -> LipSyncFrame {
        precondition(window.count == Self.windowSize)

        // Openness from RMS over the newest quarter (~5 ms resolution beats
        // a full-window average for attack sharpness).
        let decibels = Self.recentDecibels(window)
        let open = Interpolation.clamp((decibels + 42) / 28, 0...1)

        // `analyze` is public, so callers can bypass `push`. A sample rate is
        // required only for spectral bands; retain the level-driven openness
        // and use neutral form when no valid frequency scale is available.
        guard sampleRate.isFinite, sampleRate > 0 else {
            return LipSyncFrame(open: open, form: 0)
        }

        // Spectral tilt from the full window.
        var form: Float = 0
        if open > 0.02 {
            let binWidth = sampleRate / Double(Self.windowSize)
            #if canImport(Accelerate)
            guard let dft else { return LipSyncFrame(open: open, form: 0) }
            var windowed = [Float](repeating: 0, count: Self.windowSize)
            vDSP.multiply(window, hannWindow, result: &windowed)
            let zeros = [Float](repeating: 0, count: Self.windowSize)
            let (outReal, outImaginary) = dft.transform(real: windowed, imaginary: zeros)
            func binPower(_ bin: Int) -> Float {
                outReal[bin] * outReal[bin] + outImaginary[bin] * outImaginary[bin]
            }
            #else
            let windowed = zip(window, hannWindow).map { $0 * $1 }
            func binPower(_ bin: Int) -> Float { Self.portableBinPower(windowed, bin: bin) }
            #endif

            func bandEnergy(_ low: Double, _ high: Double) -> Float {
                let first = max(1, Int(low / binWidth))
                let last = min(Self.windowSize / 2 - 1, Int(high / binWidth))
                guard last >= first else { return 0 }
                var energy: Float = 0
                for bin in first...last {
                    energy += binPower(bin)
                }
                return energy
            }

            let lowBand = bandEnergy(100, 800)
            let highBand = bandEnergy(1500, 5000)
            let total = lowBand + highBand
            if total > 1e-9 {
                form = Interpolation.clamp((highBand - lowBand) / total * 1.6, -1...1)
            }
        }
        return LipSyncFrame(open: open, form: form)
    }

    // MARK: - Offline

    /// Analyzes a whole clip into `frameRate` frames/second — ideal when the
    /// audio exists before playback (TTS output), giving sample-exact sync:
    /// index into the result with `Int(playbackTime * frameRate)`.
    public func analyzeTimeline(
        samples: [Float],
        sampleRate: Double,
        frameRate: Double = 60
    ) -> [LipSyncFrame] {
        guard !samples.isEmpty, sampleRate > 0, frameRate > 0 else { return [] }
        let frameCount = Int(ceil(Double(samples.count) / sampleRate * frameRate))
        var frames: [LipSyncFrame] = []
        frames.reserveCapacity(frameCount)
        for frameIndex in 0..<max(1, frameCount) {
            let end = min(samples.count, Int(Double(frameIndex + 1) / frameRate * sampleRate))
            var window = [Float](repeating: 0, count: Self.windowSize)
            let start = max(0, end - Self.windowSize)
            let chunk = samples[start..<end]
            window.replaceSubrange((Self.windowSize - chunk.count)..., with: chunk)
            frames.append(analyze(window: window, sampleRate: sampleRate))
        }
        return frames
    }
}
