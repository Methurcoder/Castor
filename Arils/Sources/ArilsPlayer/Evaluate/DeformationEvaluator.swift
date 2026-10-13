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

/// Turns (rig, parameter values) into deformed vertex positions, once per frame.
///
/// This is a pure function of its inputs — no accumulated state — so identical
/// parameters always yield identical geometry regardless of frame rate, and the
/// whole deformation stack is unit-testable without a GPU.
///
/// Evaluation model:
/// 1. Each part's affine ops (translate/rotate/scale) compose into a local
///    matrix; the world matrix is `parentWorld * local`, so eyes ride the head
///    and the head rides the breathing body.
/// 2. Warp ops (`perspectiveShift`, `regionSway`) displace the part's own
///    vertices in part-local space *before* the affine transform. Children do
///    not re-apply the parent's warp field; instead they inherit the parent's
///    warp displacement sampled at their pivot, added post-transform. For the
///    small deformations this engine produces, that approximation keeps facial
///    features glued to the warping head at a fraction of the cost of true
///    nested warp evaluation.
public struct DeformationEvaluator: Sendable {
    private let rig: AvatarRig
    /// Part indices ordered so every parent precedes its children.
    private let evaluationOrder: [Int]
    private let parentIndexByPart: [Int?]
    private let defaultsByParameter: [ParameterID: Float]
    private let headPitchProfilesByPartID: [String: HeadPitchBoundaryProfile]

    public init(rig: AvatarRig) {
        self.rig = rig
        self.defaultsByParameter = Dictionary(
            rig.parameters.map { ($0.id, $0.defaultValue) },
            uniquingKeysWith: { first, _ in first }
        )
        self.headPitchProfilesByPartID = Dictionary(
            uniqueKeysWithValues: rig.parts.compactMap { part in
                guard part.kind == .head else { return nil }
                return (part.id, HeadPitchBoundaryProfile(head: part, parts: rig.parts))
            }
        )

        let indexByID = Dictionary(
            rig.parts.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        self.parentIndexByPart = rig.parts.map { part in
            part.parentID.flatMap { indexByID[$0] }
        }

        // Topological order over the parent graph; cycles or missing parents
        // degrade gracefully by appending the remainder in declaration order.
        var order: [Int] = []
        var placed = Set<Int>()
        var progressed = true
        while progressed && placed.count < rig.parts.count {
            progressed = false
            for index in rig.parts.indices where !placed.contains(index) {
                let parent = parentIndexByPart[index]
                if parent == nil || placed.contains(parent!) || parent == index {
                    order.append(index)
                    placed.insert(index)
                    progressed = true
                }
            }
        }
        for index in rig.parts.indices where !placed.contains(index) {
            order.append(index)
        }
        self.evaluationOrder = order
    }

    /// Deformed vertices for every part, keyed by part ID, in image pixel space.
    public func evaluate(parameters: [ParameterID: Float]) -> [String: [SIMD2<Float>]] {
        var worldMatrices = [simd_float3x3](repeating: matrix_identity_float3x3, count: rig.parts.count)
        var inheritedDisplacements = [SIMD2<Float>](repeating: .zero, count: rig.parts.count)
        var result: [String: [SIMD2<Float>]] = [:]
        result.reserveCapacity(rig.parts.count)

        for index in evaluationOrder {
            let part = rig.parts[index]
            let local = affineMatrix(for: part, parameters: parameters)

            let world: simd_float3x3
            let inherited: SIMD2<Float>
            if let parentIndex = parentIndexByPart[index], parentIndex != index {
                let parentPart = rig.parts[parentIndex]
                world = worldMatrices[parentIndex] * local
                inherited = inheritedDisplacements[parentIndex]
                    + warpDisplacement(
                        of: parentPart,
                        at: part.pivotInImage,
                        parameters: parameters,
                        forInheritance: true
                    )
            } else {
                world = local
                inherited = .zero
            }
            worldMatrices[index] = world
            inheritedDisplacements[index] = inherited

            var vertices = [SIMD2<Float>]()
            vertices.reserveCapacity(part.mesh.vertexCount)
            for (vertexIndex, rest) in part.mesh.vertices.enumerated() {
                let warped = rest
                    + warpDisplacement(of: part, at: rest, parameters: parameters)
                    + keyformDisplacement(
                        of: part,
                        vertexIndex: vertexIndex,
                        parameters: parameters
                    )
                vertices.append(apply(world, warped) + inherited)
            }
            result[part.id] = vertices
        }
        return result
    }

    /// Deviation of a parameter from its rig default (0 for unknown parameters).
    private func deviation(_ id: ParameterID, _ parameters: [ParameterID: Float]) -> Float {
        let fallback = defaultsByParameter[id] ?? 0
        guard fallback.isFinite,
              let value = parameters[id],
              value.isFinite else { return 0 }
        let result = value - fallback
        return result.isFinite ? result : 0
    }

    private func parameterValue(_ id: ParameterID, _ parameters: [ParameterID: Float]) -> Float {
        let fallback = defaultsByParameter[id] ?? 0
        guard fallback.isFinite else { return 0 }
        guard let value = parameters[id], value.isFinite else { return fallback }
        return value
    }

    // MARK: - Affine ops

    private func affineMatrix(for part: AvatarPart, parameters: [ParameterID: Float]) -> simd_float3x3 {
        var matrix = matrix_identity_float3x3
        let width = Float(part.rect.width)
        let height = Float(part.rect.height)

        for op in part.deformations {
            switch op {
            case let .translate(parameter, gainX, gainY):
                // Automatic legacy rigs used a rigid angleY translation for a
                // readable nod. Treat that one binding as a bounded warp so
                // saved Standard/2D avatars keep their central motion without
                // sliding the rectangular head crop across fixed hair/body.
                if isBoundedHeadPitchTranslation(
                    part: part,
                    parameter: parameter,
                    gainX: gainX,
                    gainY: gainY
                ) {
                    continue
                }
                let dev = deviation(parameter, parameters)
                guard dev != 0 else { continue }
                matrix = translation(SIMD2(gainX * width * dev, gainY * height * dev)) * matrix

            case let .rotate(parameter, pivot, degreesPerUnit):
                let dev = deviation(parameter, parameters)
                guard dev != 0 else { continue }
                let radians = degreesPerUnit * dev * .pi / 180
                let pivotImage = pivotInImage(pivot, part: part)
                matrix = aboutPivot(pivotImage, rotation(radians)) * matrix

            case let .scale(parameter, pivot, gainX, gainY):
                let dev = deviation(parameter, parameters)
                guard dev != 0 else { continue }
                let pivotImage = pivotInImage(pivot, part: part)
                matrix = aboutPivot(pivotImage, scale(SIMD2(1 + gainX * dev, 1 + gainY * dev))) * matrix

            case .rotate3D, .perspectiveShift, .regionSway, .warpKeyform:
                continue
            }
        }
        return matrix
    }

    // MARK: - Warp ops

    /// Total warp displacement of this part's field at an image-space point.
    /// With `forInheritance`, `regionSway` ops are skipped: localized sway
    /// (a fringe) must not drag child parts (the eyes) along.
    private func warpDisplacement(
        of part: AvatarPart,
        at point: SIMD2<Float>,
        parameters: [ParameterID: Float],
        forInheritance: Bool = false
    ) -> SIMD2<Float> {
        let width = Float(part.rect.width)
        let height = Float(part.rect.height)
        guard width > 0, height > 0 else { return .zero }
        let u = (point.x - Float(part.rect.minX)) / width
        let v = (point.y - Float(part.rect.minY)) / height

        var displacement = SIMD2<Float>.zero
        for op in part.deformations {
            switch op {
            case let .translate(parameter, gainX, gainY):
                guard isBoundedHeadPitchTranslation(
                    part: part,
                    parameter: parameter,
                    gainX: gainX,
                    gainY: gainY
                ),
                let profile = headPitchProfilesByPartID[part.id]
                else { continue }
                let dev = deviation(parameter, parameters)
                guard dev != 0 else { continue }
                let pivotY = Float(part.rect.minY) + part.pivot.y * height
                let weight = profile.legacyWeight(at: point, pivotY: pivotY)
                displacement.y += gainY * height * dev * weight

            case let .perspectiveShift(parameterX, parameterY, strength):
                let turnX = Interpolation.clamp(deviation(parameterX, parameters) / 30, -1...1)
                let turnY = Interpolation.clamp(deviation(parameterY, parameters) / 30, -1...1)
                guard turnX != 0 || turnY != 0 else { continue }
                let cx = 2 * u - 1
                let cy = 2 * v - 1
                let bulgeX = max(0, 1 - cx * cx)
                let bulgeY = max(0, 1 - cy * cy)
                // Interior features shift with the turn; the silhouette (rect
                // edges) stays fixed, which is what sells the depth illusion.
                displacement.x += turnX * strength * width * bulgeX * (0.55 + 0.45 * bulgeY)
                // Positive angleY looks up; image y grows downward.
                displacement.y += -turnY * strength * height * bulgeY * (0.55 + 0.45 * bulgeX)

            case let .regionSway(parameter, region, axis, profile, gain):
                guard !forInheritance else { continue }
                let dev = deviation(parameter, parameters)
                guard dev != 0 else { continue }
                let rWidth = Float(region.width)
                let rHeight = Float(region.height)
                guard rWidth > 0, rHeight > 0 else { continue }
                let ru = (u - Float(region.minX)) / rWidth
                let rv = (v - Float(region.minY)) / rHeight
                guard ru >= 0, ru <= 1, rv >= 0, rv <= 1 else { continue }

                let verticalWeight: Float
                switch profile {
                case .rampDown:
                    verticalWeight = Interpolation.smoothstep(0, 1, rv)
                case .rampUp:
                    verticalWeight = Interpolation.smoothstep(0, 1, 1 - rv)
                case .bell:
                    verticalWeight = sin(.pi * Interpolation.clamp(rv, 0...1))
                }
                let horizontalFade = Interpolation.smoothstep(0, 0.2, ru)
                    * Interpolation.smoothstep(0, 0.2, 1 - ru)
                let weight = verticalWeight * horizontalFade

                switch axis {
                case .horizontal:
                    displacement.x += gain * dev * width * weight
                case .vertical:
                    displacement.y += gain * dev * height * weight
                }

            case .warpKeyform:
                continue

            case .rotate, .rotate3D, .scale:
                continue
            }
        }
        return displacement
    }

    private func keyformDisplacement(
        of part: AvatarPart,
        vertexIndex: Int,
        parameters: [ParameterID: Float]
    ) -> SIMD2<Float> {
        var displacement = SIMD2<Float>.zero
        for operation in part.deformations {
            guard case let .warpKeyform(parameterX, parameterY, keys) = operation,
                  !keys.isEmpty else { continue }
            let x = parameterValue(parameterX, parameters)
            let y = parameterValue(parameterY, parameters)
            displacement += Self.keyformOffset(
                keys: keys,
                x: x,
                y: y,
                vertexIndex: vertexIndex
            )
        }
        return displacement
    }

    private static func keyformOffset(
        keys: [WarpKeyformKey],
        x: Float,
        y: Float,
        vertexIndex: Int
    ) -> SIMD2<Float> {
        let valid = keys.filter { vertexIndex < $0.vertexOffsets.count }
        guard !valid.isEmpty else { return .zero }
        if let exact = valid.min(by: {
            squaredDistance($0, x: x, y: y) < squaredDistance($1, x: x, y: y)
        }), squaredDistance(exact, x: x, y: y) < 1e-10 {
            return exact.vertexOffsets[vertexIndex]
        }

        let xs = Array(Set(valid.map(\.parameterXValue))).sorted()
        let ys = Array(Set(valid.map(\.parameterYValue))).sorted()
        func hasKey(_ keyX: Float, _ keyY: Float) -> Bool {
            valid.contains {
                abs($0.parameterXValue - keyX) < 1e-6
                    && abs($0.parameterYValue - keyY) < 1e-6
            }
        }
        var completeCells: [(Float, Float, Float, Float)] = []
        for candidateX0 in xs where candidateX0 <= x {
            for candidateX1 in xs where candidateX1 >= x {
                for candidateY0 in ys where candidateY0 <= y {
                    for candidateY1 in ys where candidateY1 >= y {
                        if hasKey(candidateX0, candidateY0),
                           hasKey(candidateX1, candidateY0),
                           hasKey(candidateX0, candidateY1),
                           hasKey(candidateX1, candidateY1) {
                            completeCells.append((
                                candidateX0,
                                candidateX1,
                                candidateY0,
                                candidateY1
                            ))
                        }
                    }
                }
            }
        }
        let cell = completeCells.min { lhs, rhs in
            let lhsArea = max(1e-6, lhs.1 - lhs.0) * max(1e-6, lhs.3 - lhs.2)
            let rhsArea = max(1e-6, rhs.1 - rhs.0) * max(1e-6, rhs.3 - rhs.2)
            return lhsArea < rhsArea
        }
        let x0 = cell?.0 ?? xs.last(where: { $0 <= x }) ?? xs.first!
        let x1 = cell?.1 ?? xs.first(where: { $0 >= x }) ?? xs.last!
        let y0 = cell?.2 ?? ys.last(where: { $0 <= y }) ?? ys.first!
        let y1 = cell?.3 ?? ys.first(where: { $0 >= y }) ?? ys.last!
        let tx = x1 == x0 ? 0 : min(max((x - x0) / (x1 - x0), 0), 1)
        let ty = y1 == y0 ? 0 : min(max((y - y0) / (y1 - y0), 0), 1)

        func offset(at keyX: Float, _ keyY: Float) -> SIMD2<Float> {
            if let key = valid.first(where: {
                abs($0.parameterXValue - keyX) < 1e-6
                    && abs($0.parameterYValue - keyY) < 1e-6
            }) {
                return key.vertexOffsets[vertexIndex]
            }
            let nearest = valid.min {
                let left = ($0.parameterXValue - keyX) * ($0.parameterXValue - keyX)
                    + ($0.parameterYValue - keyY) * ($0.parameterYValue - keyY)
                let right = ($1.parameterXValue - keyX) * ($1.parameterXValue - keyX)
                    + ($1.parameterYValue - keyY) * ($1.parameterYValue - keyY)
                return left < right
            }!
            return nearest.vertexOffsets[vertexIndex]
        }

        let top = offset(at: x0, y0)
            + (offset(at: x1, y0) - offset(at: x0, y0)) * tx
        let bottom = offset(at: x0, y1)
            + (offset(at: x1, y1) - offset(at: x0, y1)) * tx
        return top + (bottom - top) * ty
    }

    private static func squaredDistance(
        _ key: WarpKeyformKey,
        x: Float,
        y: Float
    ) -> Float {
        let dx = key.parameterXValue - x
        let dy = key.parameterYValue - y
        return dx * dx + dy * dy
    }

    private func isBoundedHeadPitchTranslation(
        part: AvatarPart,
        parameter: ParameterID,
        gainX: Float,
        gainY: Float
    ) -> Bool {
        part.kind == .head
            && parameter == .angleY
            && abs(gainX) < 0.000_001
            && gainY != 0
            && headPitchProfilesByPartID[part.id] != nil
    }

    // MARK: - Matrix helpers

    private func pivotInImage(_ pivot: SIMD2<Float>, part: AvatarPart) -> SIMD2<Float> {
        SIMD2(
            Float(part.rect.minX) + pivot.x * Float(part.rect.width),
            Float(part.rect.minY) + pivot.y * Float(part.rect.height)
        )
    }

    private func translation(_ t: SIMD2<Float>) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(1, 0, 0),
            SIMD3(0, 1, 0),
            SIMD3(t.x, t.y, 1)
        ))
    }

    private func rotation(_ radians: Float) -> simd_float3x3 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float3x3(columns: (
            SIMD3(c, s, 0),
            SIMD3(-s, c, 0),
            SIMD3(0, 0, 1)
        ))
    }

    private func scale(_ factors: SIMD2<Float>) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(factors.x, 0, 0),
            SIMD3(0, factors.y, 0),
            SIMD3(0, 0, 1)
        ))
    }

    /// Conjugates `transform` so it acts about `pivot` instead of the origin.
    private func aboutPivot(_ pivot: SIMD2<Float>, _ transform: simd_float3x3) -> simd_float3x3 {
        translation(pivot) * transform * translation(-pivot)
    }

    private func apply(_ matrix: simd_float3x3, _ point: SIMD2<Float>) -> SIMD2<Float> {
        let transformed = matrix * SIMD3(point.x, point.y, 1)
        return SIMD2(transformed.x, transformed.y)
    }
}
