import Foundation

/// Deterministic 64-bit bit-mix hash (SplitMix64 finalizer).
///
/// Used wherever the engine needs a value that is random-looking but perfectly
/// reproducible for a given input — e.g. hashing a time window index into a blink
/// position, or deriving independent RNG streams per motion layer from one seed.
public enum BitMix {
    /// SplitMix64 finalizer: avalanches all input bits into the output.
    @inlinable
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Maps a hash to [0, 1).
    @inlinable
    public static func unitFloat(_ value: UInt64) -> Float {
        Float(mix(value) >> 40) * (1.0 / Float(1 << 24))
    }

    /// Stable 64-bit hash of a string (FNV-1a), for deriving per-name RNG streams.
    public static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Seeded `RandomNumberGenerator` (SplitMix64 stream) for reproducible motion.
///
/// Every stochastic element in the engine draws from one of these instead of
/// `SystemRandomNumberGenerator`, so the same seed and the same update timeline
/// always produce the same animation — which keeps behavior testable.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    /// Derives an independent stream for a named subsystem from a master seed.
    public init(seed: UInt64, stream: String) {
        self.state = BitMix.mix(seed ^ BitMix.hash(stream))
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        return BitMix.mix(state)
    }

    /// Uniform value in [0, 1).
    public mutating func unitFloat() -> Float {
        Float(next() >> 40) * (1.0 / Float(1 << 24))
    }

    /// Uniform value in `range`.
    public mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * unitFloat()
    }

    /// Returns `true` with the given probability (0...1).
    public mutating func chance(_ probability: Float) -> Bool {
        unitFloat() < probability
    }
}
