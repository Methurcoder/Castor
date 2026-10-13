#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// One drawable, deformable layer of the avatar.
public struct AvatarPart: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PartKind
    /// Parts inherit the affine motion (and sampled warp displacement) of their
    /// parent — eyes and mouth ride on the head, the head rides on the body.
    public var parentID: String?
    /// Region of the source image this part's texture was cut from, in pixels.
    public var rect: CGRect
    /// Rotation/scale anchor, normalized [0, 1] within `rect`.
    public var pivot: SIMD2<Float>
    /// Draw order; lower values render first (further back).
    public var zOrder: Int
    public var opacity: Float
    /// Rest mesh in source-image pixel coordinates.
    public var mesh: DeformableMesh
    /// Parameter-driven deformation rules, applied in array order.
    public var deformations: [DeformationOp]

    public init(
        id: String,
        kind: PartKind,
        parentID: String? = nil,
        rect: CGRect,
        pivot: SIMD2<Float> = SIMD2(0.5, 0.5),
        zOrder: Int,
        opacity: Float = 1,
        mesh: DeformableMesh,
        deformations: [DeformationOp] = []
    ) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.rect = rect
        self.pivot = pivot
        self.zOrder = zOrder
        self.opacity = opacity
        self.mesh = mesh
        self.deformations = deformations
    }

    /// Pivot position in source-image pixel coordinates.
    public var pivotInImage: SIMD2<Float> {
        SIMD2(
            Float(rect.minX) + pivot.x * Float(rect.width),
            Float(rect.minY) + pivot.y * Float(rect.height)
        )
    }
}
