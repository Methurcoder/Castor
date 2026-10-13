import Foundation

/// Asymmetric exponential follower: rises with the `attack` time constant and
/// falls with the `release` time constant (both in seconds to ~63%).
///
/// The classic tool for audio-driven values — a mouth should snap open with the
/// voice but drift closed a beat later, which a symmetric filter can't do.
public struct AttackReleaseEnvelope: Sendable {
    public var value: Float
    public var attack: Float
    public var release: Float

    public init(value: Float = 0, attack: Float = 0.04, release: Float = 0.12) {
        self.value = value
        self.attack = attack
        self.release = release
    }

    @discardableResult
    public mutating func step(toward target: Float, deltaTime: Float) -> Float {
        guard deltaTime > 0 else { return value }
        let tau = target > value ? attack : release
        guard tau > 0 else {
            value = target
            return value
        }
        let coefficient = 1 - exp(-deltaTime / tau)
        value += (target - value) * coefficient
        return value
    }
}
