import Foundation

public struct ThicknessProfile: Codable, Equatable, Sendable {
    /// Normalized thickness for each source-mask row.
    public var rows: [Float]

    public init(rows: [Float]) { self.rows = rows }

    public func sample(v: Float) -> Float {
        guard !rows.isEmpty else { return 0 }
        let y = min(max(v, 0), 1) * Float(rows.count - 1)
        let y0 = Int(floor(y)), y1 = min(y0 + 1, rows.count - 1)
        return rows[y0] + (rows[y1] - rows[y0]) * (y - Float(y0))
    }

    public static func fromSideMask(_ mask: FloatPlane) -> ThicknessProfile {
        guard mask.width > 0, mask.height > 0 else { return ThicknessProfile(rows: []) }
        var result = [Float](repeating: 0, count: mask.height)
        for y in 0..<mask.height {
            var first: Int?
            var last: Int?
            for x in 0..<mask.width where mask[x, y] >= 0.5 {
                first = first ?? x
                last = x
            }
            if let first, let last {
                result[y] = Float(last - first + 1) / Float(mask.width)
            }
        }
        return ThicknessProfile(rows: result)
    }

    /// Re-samples a side-image profile into front-image vertical coordinates
    /// using the same neck registration and scale used by Quality rendering.
    public func alignedToFront(
        rowCount: Int,
        frontImageHeight: Int,
        sideImageHeight: Int,
        registration: QualityViewRegistration
    ) -> ThicknessProfile {
        guard rowCount > 0, frontImageHeight > 0, sideImageHeight > 0 else {
            return ThicknessProfile(rows: [])
        }
        let relativeScale = Float(frontImageHeight)
            / (Float(sideImageHeight) * max(registration.sideScale, 0.0001))
        let aligned = (0..<rowCount).map { row -> Float in
            let frontV = Float(row) / Float(max(1, rowCount - 1))
            let sideV = registration.sideNeck.y
                + (frontV - registration.frontNeck.y) * relativeScale
            return sample(v: sideV)
        }
        return ThicknessProfile(rows: aligned)
    }
}

public protocol DepthEstimating: Sendable {
    func estimate(frontMask: FloatPlane, sideThickness: ThicknessProfile?) -> DepthMap
}

/// Deterministic Stage-A baseline. The side view constrains thickness per row;
/// the front silhouette's distance from its boundary distributes that depth.
public struct SilhouetteDepthEstimator: DepthEstimating {
    public var defaultThickness: Float

    public init(defaultThickness: Float = 0.28) {
        self.defaultThickness = max(0, defaultThickness)
    }

    public func estimate(frontMask: FloatPlane, sideThickness: ThicknessProfile?) -> DepthMap {
        var result = DepthMap(width: frontMask.width, height: frontMask.height)
        guard frontMask.width > 0, frontMask.height > 0 else { return result }

        // Per-row inflation is intentionally conservative. It guarantees zero
        // depth at each silhouette edge and a monotonic rise toward its center,
        // while disconnected components remain independent.
        for y in 0..<frontMask.height {
            var runs: [ClosedRange<Int>] = []
            var start: Int?
            for x in 0...frontMask.width {
                let inside = x < frontMask.width && frontMask[x, y] >= 0.5
                if inside, start == nil { start = x }
                if !inside, let runStart = start {
                    runs.append(runStart...max(runStart, x - 1))
                    start = nil
                }
            }
            let v = Float(y) / Float(max(1, frontMask.height - 1))
            let thickness = max(0, sideThickness?.sample(v: v) ?? defaultThickness)
            for run in runs {
                let radius = Float(max(1, run.count - 1)) * 0.5
                let center = Float(run.lowerBound + run.upperBound) * 0.5
                for x in run {
                    let normalized = max(0, 1 - abs(Float(x) - center) / radius)
                    // Elliptic cross-section; half-thickness is the visible
                    // front surface's positive depth.
                    result[x, y] = 0.5 * thickness * sqrt(max(0, 1 - pow(1 - normalized, 2)))
                }
            }
        }
        return result
    }
}
