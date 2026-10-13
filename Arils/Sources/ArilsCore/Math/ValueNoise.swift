import Foundation

/// 1D value noise with fractal (fBm) stacking.
///
/// This is the backbone of "human-looking" idle motion: unlike a sine wave it
/// never repeats exactly, drifts at multiple time scales, and is still a pure
/// function of time — the same `(seed, t)` always yields the same value, so
/// motion is deterministic and frame-rate independent.
public struct ValueNoise1D: Sendable {
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    /// Smooth noise in [-1, 1] at coordinate `t` (roughly one feature per unit).
    public func value(at t: Float) -> Float {
        let floorT = t.rounded(.down)
        let i = Int64(floorT)
        let f = t - floorT
        let a = lattice(i)
        let b = lattice(i &+ 1)
        // Quintic fade for C2 continuity (no visible velocity kinks).
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        return a + (b - a) * u
    }

    /// Fractal sum of `octaves` noise layers in [-1, 1].
    public func fbm(at t: Float, octaves: Int, lacunarity: Float = 2.0, gain: Float = 0.5) -> Float {
        var amplitude: Float = 1
        var frequency: Float = 1
        var sum: Float = 0
        var norm: Float = 0
        for octave in 0..<max(1, octaves) {
            let shifted = ValueNoise1D(seed: seed &+ UInt64(octave) &* 0x9E37)
            sum += shifted.value(at: t * frequency) * amplitude
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        }
        return norm > 0 ? sum / norm : 0
    }

    private func lattice(_ index: Int64) -> Float {
        BitMix.unitFloat(seed ^ UInt64(bitPattern: index)) * 2 - 1
    }
}
