import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Geometry and coverage regressions measured for one evaluated rig pose.
///
/// Area values are fractions of the fixed-resolution coverage canvas (0...1),
/// which makes thresholds independent of the source artwork resolution.
public struct RigIntegrityMetrics: Codable, Equatable, Sendable {
    public var meshInversionCount: Int
    /// Vertices that cannot be projected by the renderer. This is a hard
    /// safety failure rather than a visual-quality score.
    public var nonFiniteVertexCount: Int
    public var holeArea: Float
    public var ghostArea: Float
    public var unknownExposure: Float

    public init(
        meshInversionCount: Int = 0,
        nonFiniteVertexCount: Int = 0,
        holeArea: Float = 0,
        ghostArea: Float = 0,
        unknownExposure: Float = 0
    ) {
        self.meshInversionCount = meshInversionCount
        self.nonFiniteVertexCount = nonFiniteVertexCount
        self.holeArea = holeArea
        self.ghostArea = ghostArea
        self.unknownExposure = unknownExposure
    }

    public var isFinite: Bool {
        holeArea.isFinite && ghostArea.isFinite && unknownExposure.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case meshInversionCount
        case nonFiniteVertexCount
        case holeArea
        case ghostArea
        case unknownExposure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meshInversionCount = try container.decode(Int.self, forKey: .meshInversionCount)
        nonFiniteVertexCount = try container.decodeIfPresent(
            Int.self,
            forKey: .nonFiniteVertexCount
        ) ?? 0
        holeArea = try container.decode(Float.self, forKey: .holeArea)
        ghostArea = try container.decode(Float.self, forKey: .ghostArea)
        unknownExposure = try container.decode(Float.self, forKey: .unknownExposure)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meshInversionCount, forKey: .meshInversionCount)
        try container.encode(nonFiniteVertexCount, forKey: .nonFiniteVertexCount)
        try container.encode(holeArea, forKey: .holeArea)
        try container.encode(ghostArea, forKey: .ghostArea)
        try container.encode(unknownExposure, forKey: .unknownExposure)
    }

    /// Measures a 2D evaluator result against the rig's rest geometry.
    ///
    /// `alphaCoverageByPartID` contains part-local alpha planes sampled using
    /// mesh UVs. Missing planes are treated as fully opaque, so geometry-only
    /// tests need no texture data. `unknownCoverageByPartID` marks pixels whose
    /// color was synthesized or is otherwise unsupported by the source image.
    public static func measure(
        rig: AvatarRig,
        evaluatedVertices: [String: [SIMD2<Float>]],
        referenceVertices: [String: [SIMD2<Float>]]? = nil,
        alphaCoverageByPartID: [String: FloatPlane] = [:],
        unknownCoverageByPartID: [String: FloatPlane] = [:],
        rasterResolution: Int = 256
    ) -> RigIntegrityMetrics {
        let reference = referenceVertices
            ?? Dictionary(uniqueKeysWithValues: rig.parts.map { ($0.id, $0.mesh.vertices) })
        return RigIntegrityAnalyzer.measure(
            rig: rig,
            evaluatedVertices: evaluatedVertices,
            referenceVertices: reference,
            alphaCoverageByPartID: alphaCoverageByPartID,
            unknownCoverageByPartID: unknownCoverageByPartID,
            rasterResolution: rasterResolution
        )
    }

    /// Measures a projected 3D evaluator result. Integrity is evaluated in the
    /// same image plane the renderer ultimately displays.
    public static func measure(
        rig: AvatarRig,
        evaluatedVertices: [String: [SIMD3<Float>]],
        referenceVertices: [String: [SIMD3<Float>]]? = nil,
        alphaCoverageByPartID: [String: FloatPlane] = [:],
        unknownCoverageByPartID: [String: FloatPlane] = [:],
        rasterResolution: Int = 256
    ) -> RigIntegrityMetrics {
        let projection = RenderProjectionContract(
            imageWidth: rig.imageWidth,
            imageHeight: rig.imageHeight
        )
        let reference3D = referenceVertices ?? Dictionary(uniqueKeysWithValues: rig.parts.map { part in
            let vertices = part.mesh.vertices.indices.map { index in
                let vertex = part.mesh.vertices[index]
                let depth = index < part.mesh.depths.count ? part.mesh.depths[index] : 0
                return SIMD3(vertex.x, vertex.y, depth)
            }
            return (part.id, vertices)
        })
        let projected = evaluatedVertices.mapValues { vertices in
            vertices.map { vertex in
                let value = projection.project(vertex)
                return SIMD2(value.x, value.y)
            }
        }
        let projectedReference = reference3D.mapValues { vertices in
            vertices.map { vertex in
                let value = projection.project(vertex)
                return SIMD2(value.x, value.y)
            }
        }
        var metrics = measure(
            rig: rig,
            evaluatedVertices: projected,
            referenceVertices: projectedReference,
            alphaCoverageByPartID: alphaCoverageByPartID,
            unknownCoverageByPartID: unknownCoverageByPartID,
            rasterResolution: rasterResolution
        )
        metrics.nonFiniteVertexCount = evaluatedVertices.values.reduce(0) { count, vertices in
            count + vertices.filter {
                !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite
            }.count
        }
        return metrics
    }
}

private enum RigIntegrityAnalyzer {
    private struct CoverageCanvas {
        var width: Int
        var height: Int
        var accumulated: [Float]
        var union: [Float]
        var visibleUnknown: [Float]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            accumulated = [Float](repeating: 0, count: width * height)
            union = [Float](repeating: 0, count: width * height)
            visibleUnknown = [Float](repeating: 0, count: width * height)
        }

        mutating func composite(partCoverage: [Float], partUnknown: [Float]) {
            guard partCoverage.count == accumulated.count,
                  partUnknown.count == accumulated.count else { return }
            for index in accumulated.indices {
                let alpha = min(max(partCoverage[index], 0), 1)
                let unknown = min(max(partUnknown[index], 0), alpha)
                accumulated[index] += alpha
                union[index] = alpha + union[index] * (1 - alpha)
                visibleUnknown[index] = unknown + visibleUnknown[index] * (1 - alpha)
            }
        }
    }

    static func measure(
        rig: AvatarRig,
        evaluatedVertices: [String: [SIMD2<Float>]],
        referenceVertices: [String: [SIMD2<Float>]],
        alphaCoverageByPartID: [String: FloatPlane],
        unknownCoverageByPartID: [String: FloatPlane],
        rasterResolution: Int
    ) -> RigIntegrityMetrics {
        let canvasSize = canvasDimensions(
            imageWidth: rig.imageWidth,
            imageHeight: rig.imageHeight,
            resolution: rasterResolution
        )
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return RigIntegrityMetrics()
        }

        let reference = rasterize(
            rig: rig,
            verticesByPartID: referenceVertices,
            alphaCoverageByPartID: alphaCoverageByPartID,
            unknownCoverageByPartID: [:],
            canvasSize: canvasSize
        )
        let evaluated = rasterize(
            rig: rig,
            verticesByPartID: evaluatedVertices,
            alphaCoverageByPartID: alphaCoverageByPartID,
            unknownCoverageByPartID: unknownCoverageByPartID,
            canvasSize: canvasSize
        )
        let pixelCount = Float(max(1, canvasSize.width * canvasSize.height))
        var holeArea: Float = 0
        var ghostArea: Float = 0
        var unknownExposure: Float = 0
        for index in reference.union.indices {
            holeArea += max(0, reference.union[index] - evaluated.union[index])
            ghostArea += max(0, evaluated.accumulated[index] - reference.accumulated[index])
            unknownExposure += evaluated.visibleUnknown[index]
        }

        return RigIntegrityMetrics(
            meshInversionCount: inversionCount(
                rig: rig,
                evaluatedVertices: evaluatedVertices,
                referenceVertices: referenceVertices
            ),
            holeArea: holeArea / pixelCount,
            ghostArea: ghostArea / pixelCount,
            unknownExposure: unknownExposure / pixelCount
        )
    }

    private static func inversionCount(
        rig: AvatarRig,
        evaluatedVertices: [String: [SIMD2<Float>]],
        referenceVertices: [String: [SIMD2<Float>]]
    ) -> Int {
        var result = 0
        for part in rig.parts {
            guard let evaluated = evaluatedVertices[part.id],
                  let reference = referenceVertices[part.id] else { continue }
            let indices = part.mesh.indices
            for offset in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
                let i0 = Int(indices[offset])
                let i1 = Int(indices[offset + 1])
                let i2 = Int(indices[offset + 2])
                guard i0 < evaluated.count, i1 < evaluated.count, i2 < evaluated.count,
                      i0 < reference.count, i1 < reference.count, i2 < reference.count else {
                    continue
                }
                let restArea = signedDoubleArea(reference[i0], reference[i1], reference[i2])
                let evaluatedArea = signedDoubleArea(evaluated[i0], evaluated[i1], evaluated[i2])
                let epsilon = max(1e-6, abs(restArea) * 1e-6)
                if abs(restArea) > epsilon, restArea * evaluatedArea < -epsilon * epsilon {
                    result += 1
                }
            }
        }
        return result
    }

    private static func rasterize(
        rig: AvatarRig,
        verticesByPartID: [String: [SIMD2<Float>]],
        alphaCoverageByPartID: [String: FloatPlane],
        unknownCoverageByPartID: [String: FloatPlane],
        canvasSize: (width: Int, height: Int)
    ) -> CoverageCanvas {
        var canvas = CoverageCanvas(width: canvasSize.width, height: canvasSize.height)
        let scale = SIMD2(
            Float(canvasSize.width) / Float(max(1, rig.imageWidth)),
            Float(canvasSize.height) / Float(max(1, rig.imageHeight))
        )

        for part in rig.partsInDrawOrder {
            guard let vertices = verticesByPartID[part.id] else { continue }
            var partCoverage = [Float](repeating: 0, count: canvasSize.width * canvasSize.height)
            var partUnknown = [Float](repeating: 0, count: canvasSize.width * canvasSize.height)
            let alphaPlane = alphaCoverageByPartID[part.id]
            let unknownPlane = unknownCoverageByPartID[part.id]
            let indices = part.mesh.indices

            for offset in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
                let i0 = Int(indices[offset])
                let i1 = Int(indices[offset + 1])
                let i2 = Int(indices[offset + 2])
                guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count,
                      i0 < part.mesh.uvs.count, i1 < part.mesh.uvs.count, i2 < part.mesh.uvs.count else {
                    continue
                }
                rasterizeTriangle(
                    points: (
                        vertices[i0] * scale,
                        vertices[i1] * scale,
                        vertices[i2] * scale
                    ),
                    uvs: (part.mesh.uvs[i0], part.mesh.uvs[i1], part.mesh.uvs[i2]),
                    opacity: part.opacity,
                    alphaPlane: alphaPlane,
                    unknownPlane: unknownPlane,
                    canvasSize: canvasSize,
                    partCoverage: &partCoverage,
                    partUnknown: &partUnknown
                )
            }
            canvas.composite(partCoverage: partCoverage, partUnknown: partUnknown)
        }
        return canvas
    }

    private static func rasterizeTriangle(
        points: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
        uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
        opacity: Float,
        alphaPlane: FloatPlane?,
        unknownPlane: FloatPlane?,
        canvasSize: (width: Int, height: Int),
        partCoverage: inout [Float],
        partUnknown: inout [Float]
    ) {
        let area = signedDoubleArea(points.0, points.1, points.2)
        guard abs(area) > 1e-7 else { return }
        let minX = max(0, Int(floor(min(points.0.x, min(points.1.x, points.2.x)))))
        let maxX = min(canvasSize.width - 1, Int(ceil(max(points.0.x, max(points.1.x, points.2.x)))))
        let minY = max(0, Int(floor(min(points.0.y, min(points.1.y, points.2.y)))))
        let maxY = min(canvasSize.height - 1, Int(ceil(max(points.0.y, max(points.1.y, points.2.y)))))
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let point = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = signedDoubleArea(points.1, points.2, point) / area
                let w1 = signedDoubleArea(points.2, points.0, point) / area
                let w2 = 1 - w0 - w1
                let epsilon: Float = -1e-5
                guard w0 >= epsilon, w1 >= epsilon, w2 >= epsilon else { continue }

                let uv = uvs.0 * w0 + uvs.1 * w1 + uvs.2 * w2
                let textureAlpha = alphaPlane?.sample(u: uv.x, v: uv.y) ?? 1
                let alpha = min(max(textureAlpha * opacity, 0), 1)
                guard alpha > 0 else { continue }
                let index = y * canvasSize.width + x
                partCoverage[index] = max(partCoverage[index], alpha)
                if let unknownPlane {
                    let unknown = min(max(unknownPlane.sample(u: uv.x, v: uv.y), 0), 1)
                    partUnknown[index] = max(partUnknown[index], alpha * unknown)
                }
            }
        }
    }

    private static func canvasDimensions(
        imageWidth: Int,
        imageHeight: Int,
        resolution: Int
    ) -> (width: Int, height: Int) {
        guard imageWidth > 0, imageHeight > 0, resolution > 0 else { return (0, 0) }
        if imageWidth >= imageHeight {
            return (
                resolution,
                max(1, Int((Float(imageHeight) / Float(imageWidth) * Float(resolution)).rounded()))
            )
        }
        return (
            max(1, Int((Float(imageWidth) / Float(imageHeight) * Float(resolution)).rounded())),
            resolution
        )
    }

    @inline(__always)
    private static func signedDoubleArea(
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>
    ) -> Float {
        let ab = b - a
        let ac = c - a
        return ab.x * ac.y - ab.y * ac.x
    }
}
