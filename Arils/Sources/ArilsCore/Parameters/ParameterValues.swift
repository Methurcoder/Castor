import Foundation

/// A mutable bag of parameter values validated against a descriptor registry.
///
/// Motion layers assemble a frame from two kinds of contributions:
/// - `add` stacks deltas on top of the base (breathing, sway, physics all add);
/// - `override` replaces the *base* value where exactly one system owns the
///   parameter (blink owns eye openness, lip sync owns the mouth).
///
/// Resolution is `clamp((override ?? default) + additions)`: additions still
/// apply on top of an overridden base, so e.g. a petting layer can squint the
/// eyes (`add eyeLeftOpen -0.35`) without fighting the blink layer's override.
/// Between overrides of the same parameter, the last writer wins.
public struct ParameterValues: Sendable {
    public private(set) var descriptors: [ParameterID: ParameterDescriptor]
    private var additions: [ParameterID: Float] = [:]
    private var overrides: [ParameterID: Float] = [:]

    public init(descriptors: [ParameterDescriptor]) {
        self.descriptors = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Adds `delta` on top of whatever the parameter already accumulated.
    public mutating func add(_ id: ParameterID, _ delta: Float) {
        guard delta.isFinite else { return }
        let accumulated = (additions[id] ?? 0) + delta
        guard accumulated.isFinite else { return }
        additions[id] = accumulated
    }

    /// Replaces the parameter's base value (default stays untouched for others).
    public mutating func override(_ id: ParameterID, _ value: Float) {
        guard value.isFinite else { return }
        overrides[id] = value
    }

    /// Removes all contributions, keeping the registry.
    public mutating func clear() {
        additions.removeAll(keepingCapacity: true)
        overrides.removeAll(keepingCapacity: true)
    }

    /// Final clamped values for every registered parameter.
    public func resolved() -> [ParameterID: Float] {
        var result: [ParameterID: Float] = [:]
        result.reserveCapacity(descriptors.count)
        for (id, descriptor) in descriptors {
            let base = overrides[id] ?? descriptor.defaultValue
            let combined = base + (additions[id] ?? 0)
            result[id] = descriptor.clamp(combined.isFinite ? combined : descriptor.defaultValue)
        }
        // Parameters written without a descriptor pass through unclamped so
        // custom rigs can extend the vocabulary; they simply lose validation.
        for (id, value) in overrides where descriptors[id] == nil {
            let combined = value + (additions[id] ?? 0)
            result[id] = combined.isFinite ? combined : value
        }
        for (id, delta) in additions where descriptors[id] == nil && overrides[id] == nil {
            result[id] = delta
        }
        return result
    }
}
