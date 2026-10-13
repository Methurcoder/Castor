import Foundation

/// Small pure-math helpers shared across the engine.
public enum Interpolation {
    /// Linear interpolation from `a` to `b` by `t` (unclamped).
    @inlinable
    public static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    /// Clamps `value` into `range`.
    @inlinable
    public static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Hermite smoothstep: 0 at `edge0`, 1 at `edge1`, smooth in between.
    @inlinable
    public static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = clamp((x - edge0) / (edge1 - edge0), 0...1)
        return t * t * (3 - 2 * t)
    }

    /// Remaps `value` from `from` into `to`, clamping to the destination range.
    @inlinable
    public static func remap(
        _ value: Float,
        from: ClosedRange<Float>,
        to: ClosedRange<Float>
    ) -> Float {
        guard from.upperBound > from.lowerBound else { return to.lowerBound }
        let t = clamp((value - from.lowerBound) / (from.upperBound - from.lowerBound), 0...1)
        return to.lowerBound + (to.upperBound - to.lowerBound) * t
    }
}
