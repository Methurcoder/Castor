import Foundation
#if canImport(simd)
import simd
#endif

/// Damped harmonic spring smoother (semi-implicit Euler with substepping).
///
/// Used to give every motion target inertia: layers compute *targets* and route
/// them through a spring so the character eases into poses, overshoots slightly
/// when underdamped, and never snaps. Frequency is in Hz; `dampingRatio` < 1
/// overshoots, 1 is critically damped, > 1 is sluggish.
public struct SpringDamper: Sendable {
    public var value: Float
    public var velocity: Float
    public var frequency: Float
    public var dampingRatio: Float

    /// Largest integration step; larger frame deltas are split into substeps
    /// so a dropped frame can't destabilize the spring.
    private static let maxStep: Float = 1.0 / 60.0

    public init(value: Float = 0, frequency: Float = 1.0, dampingRatio: Float = 1.0) {
        self.value = value
        self.velocity = 0
        self.frequency = frequency
        self.dampingRatio = dampingRatio
    }

    @discardableResult
    public mutating func step(toward target: Float, deltaTime: Float) -> Float {
        guard deltaTime > 0 else { return value }
        let omega = 2 * Float.pi * max(0.0001, frequency)
        var remaining = min(deltaTime, 1.0)
        while remaining > 0 {
            let dt = min(remaining, Self.maxStep)
            remaining -= dt
            let acceleration = -omega * omega * (value - target) - 2 * dampingRatio * omega * velocity
            velocity += acceleration * dt
            value += velocity * dt
        }
        return value
    }

    /// Instantly jumps to a value, clearing momentum.
    public mutating func snap(to newValue: Float) {
        value = newValue
        velocity = 0
    }
}

/// Two-dimensional variant of `SpringDamper` for point targets (e.g. gaze).
public struct SpringDamper2: Sendable {
    public var value: SIMD2<Float>
    public var velocity: SIMD2<Float>
    public var frequency: Float
    public var dampingRatio: Float

    private static let maxStep: Float = 1.0 / 60.0

    public init(value: SIMD2<Float> = .zero, frequency: Float = 1.0, dampingRatio: Float = 1.0) {
        self.value = value
        self.velocity = .zero
        self.frequency = frequency
        self.dampingRatio = dampingRatio
    }

    @discardableResult
    public mutating func step(toward target: SIMD2<Float>, deltaTime: Float) -> SIMD2<Float> {
        guard deltaTime > 0 else { return value }
        let omega = 2 * Float.pi * max(0.0001, frequency)
        var remaining = min(deltaTime, 1.0)
        while remaining > 0 {
            let dt = min(remaining, Self.maxStep)
            remaining -= dt
            let acceleration = -omega * omega * (value - target) - 2 * dampingRatio * omega * velocity
            velocity += acceleration * dt
            value += velocity * dt
        }
        return value
    }

    public mutating func snap(to newValue: SIMD2<Float>) {
        value = newValue
        velocity = .zero
    }
}
