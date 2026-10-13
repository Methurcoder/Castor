import Foundation

import ArilsCore

/// A recorded parameter timeline sampled at a fixed frame rate — the input to
/// `MotionMetrics`. Recording is the caller's job (run a `MotionController`
/// and append each frame), so the metrics stay pure and renderer-agnostic.
public struct MotionTrace: Sendable {
    public var frameRate: Double
    public var frames: [[ParameterID: Float]]

    public init(frameRate: Double, frames: [[ParameterID: Float]] = []) {
        self.frameRate = frameRate
        self.frames = frames
    }

    public var duration: Double {
        Double(frames.count) / max(1, frameRate)
    }

    public func series(_ id: ParameterID, default fallback: Float = 0) -> [Float] {
        frames.map { $0[id] ?? fallback }
    }
}

/// Pure measurements that turn a motion timeline into numbers comparable with
/// what is known about human behavior (blink rate, saccade rate, how periodic
/// the idle motion is, how well a mouth follows the voice...).
///
/// These exist so "does it look alive" can be tracked as a regression signal
/// instead of only by eye. None of them is a ground truth for "alive"; they are
/// guard rails that catch a change making the motion robotic, frozen,
/// over-busy, or out of sync.
public enum MotionMetrics {
    // MARK: - Blinks

    public struct Blink: Sendable, Equatable {
        /// Seconds from the start of the series to the start of the closing.
        public var start: Double
        /// Seconds from closing start until the lid is mostly reopened.
        public var duration: Double
        /// How far the lid closed relative to its open reference (0...1+).
        public var depth: Float
    }

    /// Finds lid-closing excursions in an eye-openness series.
    ///
    /// The open reference is the running maximum over the previous 0.4 s, so a
    /// narrowed resting lid (thinking, a content squint) still registers its
    /// blinks. An excursion counts when it closes by at least `minimumDepth`
    /// and reopens to 70 % of the way back within `maximumDuration`; longer
    /// closures (a yawn, a doze) are deliberate actions, not blinks.
    public static func blinks(
        openness: [Float],
        frameRate: Double,
        minimumDepth: Float = 0.25,
        maximumDuration: Double = 0.8
    ) -> [Blink] {
        guard frameRate > 0, openness.count > 2 else { return [] }
        let window = max(1, Int(0.4 * frameRate))
        var result: [Blink] = []
        var index = 0
        while index < openness.count {
            let lower = max(0, index - window)
            let reference = openness[lower...index].max() ?? openness[index]
            guard reference - openness[index] >= minimumDepth else {
                index += 1
                continue
            }
            // Walk back to where the lid left its open reference.
            var start = index
            while start > lower, openness[start - 1] < reference - 0.05 {
                start -= 1
            }
            var minimum = openness[index]
            var end = index
            while end < openness.count {
                minimum = min(minimum, openness[end])
                let reopenLevel = minimum + 0.7 * (reference - minimum)
                if openness[end] >= reopenLevel, openness[end] > minimum + 0.01 {
                    break
                }
                end += 1
            }
            let duration = Double(end - start) / frameRate
            if end < openness.count, duration <= maximumDuration {
                result.append(Blink(
                    start: Double(start) / frameRate,
                    duration: duration,
                    depth: (reference - minimum) / max(0.05, reference)
                ))
            }
            index = end + 1
        }
        return result
    }

    // MARK: - Saccades

    public struct Saccade: Sendable, Equatable {
        public var start: Double
        public var duration: Double
        public var amplitude: Float
        public var peakVelocity: Float
    }

    /// Detects rapid eye movements: contiguous runs where eye speed exceeds
    /// `velocityThreshold` (normalized eye units per second) whose net
    /// displacement is at least `minimumAmplitude`. Smooth pursuit and drift
    /// stay below the threshold.
    public static func saccades(
        eyeX: [Float],
        eyeY: [Float],
        frameRate: Double,
        velocityThreshold: Float = 2.2,
        minimumAmplitude: Float = 0.04
    ) -> [Saccade] {
        let count = min(eyeX.count, eyeY.count)
        guard frameRate > 0, count > 2 else { return [] }
        let fps = Float(frameRate)
        var result: [Saccade] = []
        var runStart: Int?
        var peak: Float = 0
        for index in 1..<count {
            let speed = hypot(eyeX[index] - eyeX[index - 1], eyeY[index] - eyeY[index - 1]) * fps
            if speed > velocityThreshold {
                if runStart == nil {
                    runStart = index - 1
                    peak = 0
                }
                peak = max(peak, speed)
            } else if let start = runStart {
                let amplitude = hypot(eyeX[index - 1] - eyeX[start], eyeY[index - 1] - eyeY[start])
                if amplitude >= minimumAmplitude {
                    result.append(Saccade(
                        start: Double(start) / frameRate,
                        duration: Double(index - 1 - start) / frameRate,
                        amplitude: amplitude,
                        peakVelocity: peak
                    ))
                }
                runStart = nil
            }
        }
        return result
    }

    // MARK: - Signal statistics

    public static func mean(_ values: [Float]) -> Float {
        values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }

    public static func standardDeviation(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Float(values.count - 1)
        return variance.squareRoot()
    }

    /// Coefficient of variation (std / mean) — 0 means perfectly regular.
    public static func coefficientOfVariation(_ values: [Float]) -> Float {
        let average = mean(values)
        guard average > 0 else { return 0 }
        return standardDeviation(values) / average
    }

    /// Root-mean-square of the frame-to-frame change, in units per second.
    public static func meanSpeed(_ values: [Float], frameRate: Double) -> Float {
        guard values.count > 1 else { return 0 }
        var total: Float = 0
        for index in 1..<values.count {
            total += abs(values[index] - values[index - 1])
        }
        return total / Float(values.count - 1) * Float(frameRate)
    }

    /// Pearson correlation of two equally long series (0 when either is flat).
    public static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 2 else { return 0 }
        let meanA = mean(Array(a.prefix(count)))
        let meanB = mean(Array(b.prefix(count)))
        var covariance: Float = 0
        var varianceA: Float = 0
        var varianceB: Float = 0
        for index in 0..<count {
            let da = a[index] - meanA
            let db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 1e-12, varianceB > 1e-12 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    /// The shift (in frames) that best aligns `signal` with `reference`, and
    /// the correlation at that shift. A positive lag means `signal` trails
    /// `reference` (e.g. a mouth reacting after the audio).
    public static func bestLag(
        reference: [Float],
        signal: [Float],
        maximumLag: Int
    ) -> (lag: Int, correlation: Float) {
        var best = (lag: 0, correlation: -Float.greatestFiniteMagnitude)
        let count = min(reference.count, signal.count)
        for lag in -maximumLag...maximumLag {
            let referenceSlice: ArraySlice<Float>
            let signalSlice: ArraySlice<Float>
            if lag >= 0 {
                guard count - lag > 2 else { continue }
                referenceSlice = reference[0..<(count - lag)]
                signalSlice = signal[lag..<count]
            } else {
                guard count + lag > 2 else { continue }
                referenceSlice = reference[(-lag)..<count]
                signalSlice = signal[0..<(count + lag)]
            }
            let value = correlation(Array(referenceSlice), Array(signalSlice))
            if value > best.correlation {
                best = (lag, value)
            }
        }
        return best
    }

    /// How strongly the signal *comes back* to itself: the highest normalized
    /// autocorrelation found after the autocorrelation first drops below
    /// zero, within `maximumLag` seconds. Fixed sine loops score near 1 (the
    /// viewer eventually notices the repetition); organic drift scores low.
    /// Measuring only past the first zero crossing keeps slow-but-random
    /// motion from scoring as "periodic" just because it is smooth.
    public static func periodicity(
        _ values: [Float],
        frameRate: Double,
        maximumLag: Double = 20.0
    ) -> Float {
        let average = mean(values)
        let centered = values.map { $0 - average }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return 0 }
        let last = min(centered.count / 2, Int(maximumLag * frameRate))
        guard last > 1 else { return 0 }
        var best: Float = 0
        var crossedZero = false
        // Stride keeps this cheap on long traces; the autocorrelation of
        // these slow signals is smooth across a few frames.
        let step = max(1, Int(frameRate / 30))
        for lag in stride(from: 1, through: last, by: step) {
            var sum: Float = 0
            for index in 0..<(centered.count - lag) {
                sum += centered[index] * centered[index + lag]
            }
            // Normalize by overlap so long lags are not penalized.
            let normalized = sum / energy * Float(centered.count) / Float(centered.count - lag)
            if !crossedZero {
                crossedZero = normalized < 0
                continue
            }
            best = max(best, normalized)
        }
        return best
    }

    /// Counts open→close cycles with hysteresis: the value must rise above
    /// `high` after having fallen below `low`. Used for mouth articulation
    /// (syllable-like flaps) and nod counting.
    public static func cycles(_ values: [Float], low: Float, high: Float) -> Int {
        var armed = true
        var count = 0
        for value in values {
            if armed, value > high {
                count += 1
                armed = false
            } else if !armed, value < low {
                armed = true
            }
        }
        return count
    }

    /// Mean of `values` restricted to the frames where `mask` is true.
    public static func mean(_ values: [Float], where mask: [Bool]) -> Float {
        var total: Float = 0
        var count = 0
        for (value, include) in zip(values, mask) where include {
            total += value
            count += 1
        }
        return count == 0 ? 0 : total / Float(count)
    }
}
