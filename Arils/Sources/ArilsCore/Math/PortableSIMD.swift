import Foundation

// Apple's `simd` module adds free functions (`simd_length`, `simd_clamp` …)
// and matrix types on top of the standard library's SIMD vectors. Windows and
// Linux have the vectors but not the module, so the subset Arils uses is
// provided here with the same names and meaning. On Apple platforms these are
// compiled out and the real `simd` is used.
#if !canImport(simd)

@inlinable public func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint {
    (a * b).sum()
}

@inlinable public func simd_length_squared<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint {
    (v * v).sum()
}

@inlinable public func simd_length<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length_squared(v).squareRoot()
}

@inlinable public func simd_distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length(a - b)
}

@inlinable public func simd_distance_squared<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length_squared(a - b)
}

@inlinable public func simd_normalize<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint {
    let length = simd_length(v)
    return length > 0 ? v / length : v
}

@inlinable public func simd_clamp<V: SIMD>(_ v: V, _ low: V, _ high: V) -> V where V.Scalar: Comparable {
    v.clamped(lowerBound: low, upperBound: high)
}

@inlinable public func simd_clamp<T: Comparable>(_ v: T, _ low: T, _ high: T) -> T {
    min(max(v, low), high)
}

@inlinable public func simd_mix<V: SIMD>(_ a: V, _ b: V, _ t: V) -> V where V.Scalar: FloatingPoint {
    a + (b - a) * t
}

@inlinable public func simd_mix<T: FloatingPoint>(_ a: T, _ b: T, _ t: T) -> T {
    a + (b - a) * t
}

@inlinable public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

@inlinable public func simd_abs<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint {
    var result = v
    for i in v.indices { result[i] = abs(v[i]) }
    return result
}

/// Column-major 3×3 float matrix with the subset of `simd_float3x3` Arils
/// uses: column construction, identity, products with matrices and vectors.
public struct simd_float3x3: Equatable, Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    public init(columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        self.columns = columns
    }

    public init(diagonal: SIMD3<Float>) {
        columns = (SIMD3(diagonal.x, 0, 0), SIMD3(0, diagonal.y, 0), SIMD3(0, 0, diagonal.z))
    }

    public static func == (lhs: simd_float3x3, rhs: simd_float3x3) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 && lhs.columns.2 == rhs.columns.2
    }

    @inlinable public static func * (m: simd_float3x3, v: SIMD3<Float>) -> SIMD3<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z
    }

    @inlinable public static func * (a: simd_float3x3, b: simd_float3x3) -> simd_float3x3 {
        simd_float3x3(columns: (a * b.columns.0, a * b.columns.1, a * b.columns.2))
    }

    public var transpose: simd_float3x3 {
        let (a, b, c) = columns
        return simd_float3x3(columns: (SIMD3(a.x, b.x, c.x), SIMD3(a.y, b.y, c.y), SIMD3(a.z, b.z, c.z)))
    }
}

public let matrix_identity_float3x3 = simd_float3x3(diagonal: SIMD3(1, 1, 1))

#endif
