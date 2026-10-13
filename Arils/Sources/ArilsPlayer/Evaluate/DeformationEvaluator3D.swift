import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Stage-A 3D evaluator. Existing 2D deformation remains authoritative, then
/// v2-only 3D rotations are composed through the parent chain, fading to zero
/// toward the rotation's pivot row so the neck seam against the non-rotating
/// body stays closed at any angle. Keeping the legacy evaluator intact is what
/// preserves old archive appearance.
public struct DeformationEvaluator3D: Sendable {
    private let rig: AvatarRig
    private let legacy: DeformationEvaluator
    private let defaults: [ParameterID: Float]
    private let partsByID: [String: AvatarPart]
    private let pitchReferenceDepthByHeadID: [String: Float]
    private let pitchTaperFractionByHeadID: [String: Float]
    private let pitchBoundaryProfileByHeadID: [String: HeadPitchBoundaryProfile]

    public init(rig: AvatarRig) {
        self.rig = rig
        self.legacy = DeformationEvaluator(rig: rig)
        self.defaults = Dictionary(rig.parameters.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { first, _ in first })
        self.partsByID = Dictionary(rig.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var pitchDepths: [String: Float] = [:]
        var pitchTapers: [String: Float] = [:]
        var pitchBoundaryProfiles: [String: HeadPitchBoundaryProfile] = [:]
        for head in rig.parts where head.kind == .head {
            pitchBoundaryProfiles[head.id] = HeadPitchBoundaryProfile(head: head, parts: rig.parts)
            let headWidth = Float(head.rect.width)
            let validDepths = head.mesh.depths
                .filter { $0.isFinite && $0 > 0 }
                .sorted()
            if headWidth.isFinite, headWidth > 0, !validDepths.isEmpty {
                let median = validDepths[validDepths.count / 2]
                pitchDepths[head.id] = min(headWidth * 0.35, max(headWidth * 0.18, median))
            }

            let headHeight = Float(head.rect.height)
            let pitchPivot = head.deformations.compactMap { operation -> SIMD3<Float>? in
                guard case let .rotate3D(_, axis: .x, pivot, _) = operation else { return nil }
                return pivot
            }.first
            if headHeight.isFinite, headHeight > 0,
               let pitchPivot,
               let mouth = rig.parts.first(where: { $0.kind == .mouth && $0.parentID == head.id }) {
                let pivotRestY = Float(head.rect.minY) + pitchPivot.y * headHeight
                let taperStartY = Float(mouth.rect.maxY) + headHeight * 0.04
                let fraction = (pivotRestY - taperStartY) / headHeight
                if fraction.isFinite {
                    pitchTapers[head.id] = min(0.24, max(0.08, fraction))
                }
            }
        }
        self.pitchReferenceDepthByHeadID = pitchDepths
        self.pitchTaperFractionByHeadID = pitchTapers
        self.pitchBoundaryProfileByHeadID = pitchBoundaryProfiles
    }

    /// Fraction of the rotating part's height over which a `rotate3D` fades
    /// in above its pivot row. The row itself does not move at all, so the
    /// head/body seam at the neck stays closed; content one band above turns
    /// with the full angle.
    ///
    /// The band deliberately spans the whole lower half. A short band packs
    /// the entire parallax displacement gradient into the visible neck, which
    /// reads as the neck rubber-stretching during a turn. Spread over half
    /// the head, the chin stays nearly rigid (~15% weight), the mouth moves
    /// at ~60%, and full parallax is reached at eye level — the same
    /// bottom-fading grade the v1 `perspectiveShift` bulge used.
    private static let yawPivotRowTaperFraction: Float = 0.5

    /// Fallback for hand-authored rigs without a mouth child. Production rigs
    /// derive this band from the actual mouth-to-neck distance so the eyes,
    /// nose, and mouth receive one coherent pitch angle on different face
    /// proportions.
    private static let pitchPivotRowTaperFraction: Float = 0.22

    /// Global strength of the displacement a `rotate3D` produces (a lerp from
    /// the rest position toward the fully rotated one).
    ///
    /// The silhouette-inflated depth is a balloon: the whole face plate sits
    /// at a nearly constant, skull-half-thickness Z, so a raw rotation
    /// translates the entire face by ~40% of the head width at 20°. Against a
    /// silhouette that cannot move, every pixel of that shows up as stretch.
    /// Real 2.5D looks believable when interior parallax stays subtle —
    /// half strength lands near the proven v1 `perspectiveShift` magnitude
    /// while keeping depth ordering and the perspective cue.
    public func evaluate(parameters: [ParameterID: Float]) -> [String: [SIMD3<Float>]] {
        let planar = legacy.evaluate(parameters: parameters)
        var result: [String: [SIMD3<Float>]] = [:]
        for part in rig.parts {
            guard let xy = planar[part.id], xy.count == part.mesh.vertexCount else { continue }
            var vertices = zip(xy, part.mesh.depths).map { SIMD3($0.0.x, $0.0.y, $0.1) }
            for owner in ancestry(of: part) {
                for operation in owner.deformations {
                    guard case let .rotate3D(parameter, axis, pivot, degreesPerUnit) = operation else { continue }
                    let fallback = defaults[parameter] ?? 0
                    guard fallback.isFinite,
                          let value = parameters[parameter],
                          value.isFinite else { continue }
                    let deviation = value - fallback
                    guard deviation.isFinite else { continue }
                    guard deviation != 0 else { continue }
                    let localPivot = transformedPivot(
                        owner: owner,
                        normalizedPivot: pivot,
                        planar: planar
                    )
                    let radians = deviation * degreesPerUnit * .pi / 180
                    // Weights come from rest-space heights so the head mesh
                    // and its riding children (eyes, mouth) sample the same
                    // ramp and stay registered with each other.
                    let pivotRestY = Float(owner.rect.minY) + pivot.y * Float(owner.rect.height)
                    let taperFraction = switch axis {
                    case .x: pitchTaperFractionByHeadID[owner.id] ?? Self.pitchPivotRowTaperFraction
                    case .y, .z: Self.yawPivotRowTaperFraction
                    }
                    let band = taperFraction * Float(max(1, owner.rect.height))
                    vertices = vertices.indices.map { index in
                        let vertex = vertices[index]
                        var weight = Interpolation.smoothstep(
                            0, band, pivotRestY - part.mesh.vertices[index].y
                        )
                        if axis == .x,
                           owner.kind == .head,
                           let profile = pitchBoundaryProfileByHeadID[owner.id] {
                            weight *= profile.outerBoundaryWeight(at: part.mesh.vertices[index])
                        }
                        guard weight > 0 else { return vertex }
                        let rotation = Self.rotation(axis: axis, radians: radians * weight)
                        // A side silhouette includes hair and clothing width,
                        // not just skull depth. During pitch, rotating each
                        // vertex's raw Z makes face-center pixels travel much
                        // farther than the zero-depth crown outline and reads
                        // as vertical compression. Use one bounded facial
                        // plate depth for the pitch displacement, while
                        // preserving the vertex's original Z and all raw-depth
                        // behavior for yaw.
                        let rotationVertex: SIMD3<Float>
                        if axis == .x,
                           owner.kind == .head,
                           let pitchDepth = pitchReferenceDepthByHeadID[owner.id] {
                            rotationVertex = SIMD3(vertex.x, vertex.y, pitchDepth)
                        } else {
                            rotationVertex = vertex
                        }
                        let rotated = localPivot + rotation * (rotationVertex - localPivot)
                        let strength = HeadPoseRendering.rotationParallaxStrength
                        var deformed = vertex + (rotated - rotationVertex) * strength
                        if axis == .y, owner.kind == .head {
                            // The evaluator blends toward a rotation rather
                            // than applying it at full strength, so a flat
                            // point's final horizontal scale is
                            //
                            //   f = 1 - strength * (1 - cos(angle)).
                            //
                            // Restore only that Z=0 foreshortening component.
                            // Scaling the complete post-rotation X offset by
                            // 1/f would also amplify the intended Z-driven
                            // parallax. This algebraically equivalent form
                            // leaves `strength * sin(angle) * depth` intact.
                            let cosine = cos(radians * weight)
                            let effectiveScale = 1 - strength * (1 - cosine)
                            let planarOffset = rotationVertex.x - localPivot.x
                            deformed.x += planarOffset * (1 - effectiveScale)
                        }
                        return deformed
                    }
                }
            }
            result[part.id] = vertices
        }
        bindFacialFeatureCards(toHeadSurfacesIn: &result, planar: planar)
        return result
    }

    /// Eye and mouth textures are shallow decals on the visible head surface,
    /// not independent pieces of face geometry. Rotating their separately
    /// sampled depths used to let a four-by-four feature mesh disagree with the
    /// denser head mesh. At combined yaw/pitch, depth interpolation could then
    /// open a triangular strip through an eye.
    ///
    /// Rebind v2 feature cards to the already-evaluated head grid. Their local
    /// 2D animation (blink, pupil motion, lip motion) is preserved as the
    /// difference from the planar head surface, while the base XYZ comes from
    /// exactly the same surface that renders the surrounding face. Legacy flat
    /// rigs have no head `rotate3D` operation and retain their old behavior.
    private func bindFacialFeatureCards(
        toHeadSurfacesIn result: inout [String: [SIMD3<Float>]],
        planar: [String: [SIMD2<Float>]]
    ) {
        for feature in rig.parts where Self.isFacialFeature(feature) {
            guard let headID = feature.parentID,
                  let head = partsByID[headID],
                  head.kind == .head,
                  head.deformations.contains(where: Self.is3DRotation),
                  let head3D = result[head.id],
                  let head2D = planar[head.id],
                  let feature2D = planar[feature.id],
                  feature2D.count == feature.mesh.vertexCount,
                  Self.isSampleableGrid(head.mesh, valueCount: head3D.count),
                  head2D.count == head3D.count else { continue }

            result[feature.id] = feature.mesh.vertices.indices.map { index in
                let restPoint = feature.mesh.vertices[index]
                let surface3D = Self.sampleGrid(
                    mesh: head.mesh,
                    rect: head.rect,
                    values: head3D,
                    at: restPoint
                )
                let surface2D = Self.sampleGrid(
                    mesh: head.mesh,
                    rect: head.rect,
                    values: head2D,
                    at: restPoint
                )
                let localAnimation = feature2D[index] - surface2D
                return surface3D + SIMD3(localAnimation.x, localAnimation.y, 0)
            }
        }
    }

    private static func isFacialFeature(_ part: AvatarPart) -> Bool {
        switch part.kind {
        case .eyeLeft, .eyeRight, .mouth:
            true
        case .body, .head, .hairBack, .hairFront, .accessory:
            false
        }
    }

    private static func is3DRotation(_ operation: DeformationOp) -> Bool {
        if case .rotate3D = operation { return true }
        return false
    }

    private static func isSampleableGrid(_ mesh: DeformableMesh, valueCount: Int) -> Bool {
        mesh.columns > 0
            && mesh.rows > 0
            && valueCount == (mesh.columns + 1) * (mesh.rows + 1)
    }

    private static func sampleGrid<Value: SIMD>(
        mesh: DeformableMesh,
        rect: CGRect,
        values: [Value],
        at point: SIMD2<Float>
    ) -> Value where Value.Scalar == Float {
        let width = Float(max(1, rect.width))
        let height = Float(max(1, rect.height))
        let minX = Float(rect.minX)
        let minY = Float(rect.minY)
        let gridX = min(max((point.x - minX) / width, 0), 1) * Float(mesh.columns)
        let gridY = min(max((point.y - minY) / height, 0), 1) * Float(mesh.rows)
        let column0 = min(mesh.columns - 1, Int(gridX.rounded(.down)))
        let row0 = min(mesh.rows - 1, Int(gridY.rounded(.down)))
        let column1 = min(mesh.columns, column0 + 1)
        let row1 = min(mesh.rows, row0 + 1)
        let tx = gridX - Float(column0)
        let ty = gridY - Float(row0)
        let stride = mesh.columns + 1
        let topLeft = values[row0 * stride + column0]
        let topRight = values[row0 * stride + column1]
        let bottomLeft = values[row1 * stride + column0]
        let bottomRight = values[row1 * stride + column1]
        let top = topLeft + (topRight - topLeft) * tx
        let bottom = bottomLeft + (bottomRight - bottomLeft) * tx
        return top + (bottom - top) * ty
    }

    private func transformedPivot(
        owner: AvatarPart,
        normalizedPivot: SIMD3<Float>,
        planar: [String: [SIMD2<Float>]]
    ) -> SIMD3<Float> {
        let restPoint = SIMD2(
            Float(owner.rect.minX) + normalizedPivot.x * Float(owner.rect.width),
            Float(owner.rect.minY) + normalizedPivot.y * Float(owner.rect.height)
        )
        guard let evaluated = planar[owner.id], !owner.mesh.vertices.isEmpty else {
            return SIMD3(restPoint.x, restPoint.y, normalizedPivot.z)
        }
        let index = owner.mesh.vertices.indices.min { left, right in
            simd_distance_squared(owner.mesh.vertices[left], restPoint)
                < simd_distance_squared(owner.mesh.vertices[right], restPoint)
        } ?? 0
        guard index < evaluated.count, index < owner.mesh.depths.count else {
            return SIMD3(restPoint.x, restPoint.y, normalizedPivot.z)
        }
        // X/Y follow the owner's already-evaluated planar motion so the neck
        // axis rides with the body. Z is different: mesh depths describe the
        // visible front surface, while rotate3D pivots are authored relative
        // to the character's central Z=0 plane. Adding the nearest surface
        // depth here moves the rotation axis in front of the volume and turns
        // yaw/pitch into a large translation of the whole head silhouette.
        return SIMD3(evaluated[index].x, evaluated[index].y, normalizedPivot.z)
    }

    private func ancestry(of part: AvatarPart) -> [AvatarPart] {
        var chain = [part]
        var cursor = part
        var visited = Set([part.id])
        while let parentID = cursor.parentID,
              let parent = partsByID[parentID],
              visited.insert(parent.id).inserted {
            chain.append(parent)
            cursor = parent
        }
        return chain.reversed()
    }

    private static func rotation(axis: Rotation3DAxis, radians: Float) -> simd_float3x3 {
        let c = cos(radians), s = sin(radians)
        switch axis {
        case .x:
            return simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, c, s), SIMD3(0, -s, c)))
        case .y:
            return simd_float3x3(columns: (SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c)))
        case .z:
            return simd_float3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
        }
    }
}
