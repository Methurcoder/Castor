#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

/// A triangulated 2D mesh whose rest vertices live in source-image pixel space.
///
/// The renderer draws these triangles with the part texture mapped by `uvs`;
/// deformation systems produce a displaced copy of `vertices` every frame.
/// Regular grids carry their `columns`/`rows` so warp fields can reason about
/// normalized positions cheaply, but nothing else assumes grid topology — a
/// future Live2D-style hand-authored mesh fits this same structure.
public struct DeformableMesh: Codable, Equatable, Sendable {
    /// Rest positions in source-image pixel coordinates (y grows downward).
    public var vertices: [SIMD2<Float>]
    /// Per-vertex rest depth in source-image pixel units. Legacy meshes omit
    /// this field and decode as a flat Z=0 surface.
    public var depths: [Float]
    /// Texture coordinates in [0, 1] within the part texture (v grows downward).
    public var uvs: [SIMD2<Float>]
    /// Triangle list indices into `vertices`/`uvs`.
    public var indices: [UInt32]
    /// Grid metadata (cell counts); 0 when the mesh is not a regular grid.
    public var columns: Int
    public var rows: Int

    public init(
        vertices: [SIMD2<Float>],
        depths: [Float]? = nil,
        uvs: [SIMD2<Float>],
        indices: [UInt32],
        columns: Int = 0,
        rows: Int = 0
    ) {
        self.vertices = vertices
        self.depths = depths ?? [Float](repeating: 0, count: vertices.count)
        precondition(self.depths.count == vertices.count)
        self.uvs = uvs
        self.indices = indices
        self.columns = columns
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case vertices, depths, uvs, indices, columns, rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vertices = try container.decode([SIMD2<Float>].self, forKey: .vertices)
        depths = try container.decodeIfPresent([Float].self, forKey: .depths)
            ?? [Float](repeating: 0, count: vertices.count)
        guard depths.count == vertices.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .depths,
                in: container,
                debugDescription: "Depth count must match vertex count"
            )
        }
        uvs = try container.decode([SIMD2<Float>].self, forKey: .uvs)
        indices = try container.decode([UInt32].self, forKey: .indices)
        columns = try container.decode(Int.self, forKey: .columns)
        rows = try container.decode(Int.self, forKey: .rows)
    }

    /// Builds a regular grid covering `rect` with `columns` x `rows` cells.
    public static func grid(rect: CGRect, columns: Int, rows: Int) -> DeformableMesh {
        let columns = max(1, columns)
        let rows = max(1, rows)
        var vertices: [SIMD2<Float>] = []
        var uvs: [SIMD2<Float>] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1))
        uvs.reserveCapacity((columns + 1) * (rows + 1))

        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                vertices.append(SIMD2(
                    Float(rect.minX) + u * Float(rect.width),
                    Float(rect.minY) + v * Float(rect.height)
                ))
                uvs.append(SIMD2(u, v))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        let stride = UInt32(columns + 1)
        for row in 0..<rows {
            for column in 0..<columns {
                let topLeft = UInt32(row) * stride + UInt32(column)
                let topRight = topLeft + 1
                let bottomLeft = topLeft + stride
                let bottomRight = bottomLeft + 1
                indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
            }
        }

        return DeformableMesh(
            vertices: vertices,
            uvs: uvs,
            indices: indices,
            columns: columns,
            rows: rows
        )
    }

    public var vertexCount: Int { vertices.count }
    public var triangleCount: Int { indices.count / 3 }
}
