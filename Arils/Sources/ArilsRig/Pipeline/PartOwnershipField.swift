import CoreGraphics
import Foundation
import simd

import ArilsCore

/// A soft per-pixel ownership policy shared by specialized head cuts and
/// arbitrary articulated parts.
public protocol PartOwnershipWeighting: Sendable {
    func ownershipWeight(x: CGFloat, y: CGFloat) -> Float
}

/// Curved capsule ownership around a quadratic bone centerline.
///
/// The field is expressed in source-image pixels. Radius may taper from the
/// first joint to the second; `feather` defines the ambiguous correction band.
/// Multiplying by the subject mask prevents the capsule from claiming
/// transparent/background pixels.
public struct PartOwnershipField: PartOwnershipWeighting, Codable, Equatable, Sendable {
    public var start: SIMD2<Float>
    public var control: SIMD2<Float>
    public var end: SIMD2<Float>
    public var startRadius: Float
    public var endRadius: Float
    public var feather: Float

    public init(
        start: SIMD2<Float>,
        control: SIMD2<Float>? = nil,
        end: SIMD2<Float>,
        startRadius: Float,
        endRadius: Float,
        feather: Float
    ) {
        self.start = start
        self.control = control ?? (start + end) * 0.5
        self.end = end
        self.startRadius = max(0.5, startRadius)
        self.endRadius = max(0.5, endRadius)
        self.feather = max(0.5, feather)
    }

    public func ownershipWeight(x: CGFloat, y: CGFloat) -> Float {
        let point = SIMD2(Float(x), Float(y))
        let closest = closestPoint(to: point)
        let radius = startRadius + (endRadius - startRadius) * closest.t
        return 1 - Interpolation.smoothstep(
            max(0, radius - feather),
            radius + feather,
            closest.distance
        )
    }

    public func rasterized(
        subjectMask: FloatPlane,
        imageWidth: Int,
        imageHeight: Int
    ) -> PartOwnershipRaster {
        var weights = FloatPlane(width: subjectMask.width, height: subjectMask.height)
        var ambiguity = FloatPlane(width: subjectMask.width, height: subjectMask.height)
        guard subjectMask.width > 0, subjectMask.height > 0 else {
            return PartOwnershipRaster(weights: weights, ambiguity: ambiguity)
        }
        for y in 0..<subjectMask.height {
            let sourceY = subjectMask.height > 1
                ? Float(y) / Float(subjectMask.height - 1) * Float(imageHeight)
                : 0
            for x in 0..<subjectMask.width {
                let sourceX = subjectMask.width > 1
                    ? Float(x) / Float(subjectMask.width - 1) * Float(imageWidth)
                    : 0
                let ownership = ownershipWeight(
                    x: CGFloat(sourceX),
                    y: CGFloat(sourceY)
                ) * subjectMask[x, y]
                weights[x, y] = ownership
                if ownership > 0.05, ownership < 0.95 {
                    ambiguity[x, y] = 1 - abs(ownership - 0.5) * 2
                }
            }
        }
        return PartOwnershipRaster(weights: weights, ambiguity: ambiguity)
    }

    private func closestPoint(to point: SIMD2<Float>) -> (distance: Float, t: Float) {
        let segmentCount = 24
        var bestDistance = Float.greatestFiniteMagnitude
        var bestT: Float = 0
        var previous = start
        var previousT: Float = 0
        for segment in 1...segmentCount {
            let t = Float(segment) / Float(segmentCount)
            let current = pointOnCurve(t)
            let edge = current - previous
            let lengthSquared = simd_length_squared(edge)
            let local = lengthSquared > 1e-8
                ? min(max(simd_dot(point - previous, edge) / lengthSquared, 0), 1)
                : 0
            let projected = previous + edge * local
            let distance = simd_distance(point, projected)
            if distance < bestDistance {
                bestDistance = distance
                bestT = previousT + (t - previousT) * local
            }
            previous = current
            previousT = t
        }
        return (bestDistance, bestT)
    }

    private func pointOnCurve(_ t: Float) -> SIMD2<Float> {
        let oneMinusT = 1 - t
        return start * (oneMinusT * oneMinusT)
            + control * (2 * oneMinusT * t)
            + end * (t * t)
    }
}

public struct PartOwnershipRaster: Sendable {
    public var weights: FloatPlane
    public var ambiguity: FloatPlane

    public init(weights: FloatPlane, ambiguity: FloatPlane) {
        self.weights = weights
        self.ambiguity = ambiguity
    }
}
