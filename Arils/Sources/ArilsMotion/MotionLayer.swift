import Foundation

import ArilsCore

/// Per-frame context shared by all motion layers.
public struct MotionContext: Sendable {
    /// Absolute time in seconds (any monotonic origin).
    public let time: Double
    /// Clamped frame delta in seconds (0 on the very first frame).
    public let deltaTime: Float
    public let inputs: MotionInputs

    public init(time: Double, deltaTime: Float, inputs: MotionInputs) {
        self.time = time
        self.deltaTime = deltaTime
        self.inputs = inputs
    }
}

/// One source of motion (breathing, blink, gaze, ...). Layers run in a fixed
/// order each frame and write contributions into `ParameterValues`.
///
/// Layers may keep state (springs, schedulers) but must be deterministic:
/// all randomness comes from `SeededRandom` streams derived from the
/// controller's seed, so a given seed and update timeline always replays the
/// same motion. Layers are not thread-safe; the controller owns them on a
/// single isolation domain.
public protocol MotionLayer: AnyObject {
    func update(context: MotionContext, values: inout ParameterValues)
}
