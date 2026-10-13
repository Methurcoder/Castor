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

/// Direction a `regionSway` op displaces vertices in.
public enum SwayAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// Weight profile of a `regionSway` op along the region's vertical extent.
public enum SwayProfile: String, Codable, Sendable {
    /// 0 at the region top, 1 at the bottom — hanging hair whose free tips end
    /// at a transparent edge (back hair reaching the silhouette boundary).
    case rampDown
    /// 1 at the region top, 0 at the bottom.
    case rampUp
    /// 0 at both edges with a smooth peak near 70% depth — for sway regions
    /// embedded inside an opaque surface (a fringe on the head layer), where
    /// both edges must stay glued to the surrounding pixels to avoid seams.
    case bell
}

public enum Rotation3DAxis: String, Codable, Sendable {
    case x
    case y
    case z
}

/// One point in a two-parameter warp grid. Offsets correspond one-to-one with
/// the owning part's mesh vertices and are expressed in source-image pixels.
public struct WarpKeyformKey: Codable, Equatable, Sendable {
    public var parameterXValue: Float
    public var parameterYValue: Float
    public var vertexOffsets: [SIMD2<Float>]

    public init(
        parameterXValue: Float,
        parameterYValue: Float,
        vertexOffsets: [SIMD2<Float>]
    ) {
        self.parameterXValue = parameterXValue
        self.parameterYValue = parameterYValue
        self.vertexOffsets = vertexOffsets
    }
}

/// One data-driven deformation rule: how a parameter moves this part's vertices.
///
/// Ops are *data*, not code — a rig document fully describes its own behavior,
/// so rigs can be persisted, hand-edited, or produced by a different rigging
/// algorithm without touching the evaluator. All ops act on the parameter's
/// deviation from its descriptor default (`value - defaultValue`), which is what
/// lets "eyes default open" and "mouth default closed" share the same math.
///
/// Coordinate conventions:
/// - Pivots and regions are normalized [0, 1] within the part's `rect`
///   (y grows downward, matching image space).
/// - Translation/scale gains are fractions of the part's width/height per unit
///   of deviation, so rigs behave identically at any image resolution.
///
/// Extension point: adding a case (e.g. a keyform-interpolating warp for
/// Live2D-grade deformation) only requires teaching `DeformationEvaluator`
/// about it; documents that don't use the new case remain readable by old code.
public enum DeformationOp: Codable, Equatable, Sendable {
    /// Rigid translation. Inherited by child parts. The automatic head
    /// `.angleY` binding is evaluated as a boundary-bounded warp for legacy
    /// Standard/2D rigs so their rectangular crop remains attached to the body.
    case translate(parameter: ParameterID, gainX: Float, gainY: Float)

    /// Rigid rotation around `pivot`. Inherited by child parts.
    case rotate(parameter: ParameterID, pivot: SIMD2<Float>, degreesPerUnit: Float)

    /// 3D rotation around a part-local pivot. Only v2 depth rigs emit
    /// this operation; legacy documents retain `perspectiveShift`. Pivot X/Y
    /// are normalized within the part rect. Pivot Z is an image-space depth
    /// offset from the character's central Z=0 plane (the mesh stores its
    /// visible front surface at positive Z). The evaluator fades the angle to
    /// zero toward the pivot row so the seam against non-rotating parts stays
    /// closed. Yaw and pitch use different taper bands because pitch must keep
    /// facial landmarks moving together (see `DeformationEvaluator3D`).
    case rotate3D(
        parameter: ParameterID,
        axis: Rotation3DAxis,
        pivot: SIMD3<Float>,
        degreesPerUnit: Float
    )

    /// Scale about `pivot`; factor = 1 + gain * deviation. Inherited by children.
    case scale(parameter: ParameterID, pivot: SIMD2<Float>, gainX: Float, gainY: Float)

    /// Fake 3D head turn: displaces vertices by a parabolic field that peaks at
    /// the part center and vanishes at the edges, so the silhouette stays put
    /// while interior features (face) shift — reads as depth, not as a sliding
    /// flat picture. `parameterX`/`parameterY` are yaw/pitch in degrees.
    /// Children inherit the displacement sampled at their pivot.
    case perspectiveShift(parameterX: ParameterID, parameterY: ParameterID, strength: Float)

    /// Localized sway: displaces vertices inside `region` along `axis`,
    /// weighted by `profile` vertically and faded at the region's horizontal
    /// edges. Not inherited by children (a swaying fringe must not drag eyes).
    case regionSway(
        parameter: ParameterID,
        region: CGRect,
        axis: SwayAxis,
        profile: SwayProfile,
        gain: Float
    )

    /// Live2D-style non-linear corrective geometry on a sparse two-dimensional
    /// parameter grid. Existing procedural operations may coexist with it.
    case warpKeyform(
        parameterX: ParameterID,
        parameterY: ParameterID,
        keys: [WarpKeyformKey]
    )

    /// Whether the op contributes to the affine transform children inherit.
    public var isAffine: Bool {
        switch self {
        case .translate, .rotate, .rotate3D, .scale:
            true
        case .perspectiveShift, .regionSway, .warpKeyform:
            false
        }
    }
}
