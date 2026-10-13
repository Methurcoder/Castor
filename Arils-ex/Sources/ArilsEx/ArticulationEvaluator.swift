import Arils
import Foundation
import simd

/// Pure two-bone linear-blend-skinning evaluator for compiled arm parts.
public struct ArticulationEvaluator: Sendable {
    public var rig: ArticulationRigArchive

    public init(rig: ArticulationRigArchive) {
        self.rig = rig
    }

    public func evaluate(
        parameters: ArticulationPoseParameters
    ) -> [ArticulationPartID: [SIMD2<Float>]] {
        let transforms = boneTransforms(parameters: parameters)
        return Dictionary(uniqueKeysWithValues: rig.parts.map { part in
            let vertices = part.mesh.vertices.indices.map { index -> SIMD2<Float> in
                guard index < part.weights.count else { return part.mesh.vertices[index] }
                let weight = part.weights[index]
                let primary = apply(
                    transforms[weight.primaryBone] ?? matrix_identity_float3x3,
                    to: part.mesh.vertices[index]
                )
                let secondary = apply(
                    transforms[weight.secondaryBone] ?? matrix_identity_float3x3,
                    to: part.mesh.vertices[index]
                )
                return primary + (secondary - primary) * weight.secondaryWeight
            }
            return (part.id, vertices)
        })
    }

    private func boneTransforms(
        parameters: ArticulationPoseParameters
    ) -> [ArticulationBoneID: simd_float3x3] {
        var result: [ArticulationBoneID: simd_float3x3] = [:]
        for side in [ArmSide.left, .right] {
            let shoulderKind: JointKind = side == .left ? .leftShoulder : .rightShoulder
            let elbowKind: JointKind = side == .left ? .leftElbow : .rightElbow
            let upperBone: ArticulationBoneID = side == .left ? .leftUpperArm : .rightUpperArm
            let forearmBone: ArticulationBoneID = side == .left ? .leftForearm : .rightForearm
            guard let shoulder = imagePoint(shoulderKind),
                  let elbow = imagePoint(elbowKind) else { continue }

            let shoulderRotation = Self.about(
                shoulder,
                radians: parameters[shoulderKind] * .pi / 180
            )
            let movedElbow = Self.apply(shoulderRotation, to: elbow)
            let elbowRotation = Self.about(
                movedElbow,
                radians: parameters[elbowKind] * .pi / 180
            )
            result[upperBone] = shoulderRotation
            result[forearmBone] = elbowRotation * shoulderRotation
        }
        return result
    }

    private func imagePoint(_ joint: JointKind) -> SIMD2<Float>? {
        rig.restPose[joint].map {
            $0.position * SIMD2(Float(rig.imageWidth), Float(rig.imageHeight))
        }
    }

    private static func about(_ pivot: SIMD2<Float>, radians: Float) -> simd_float3x3 {
        let c = cos(radians)
        let s = sin(radians)
        let rotation = simd_float3x3(columns: (
            SIMD3(c, s, 0),
            SIMD3(-s, c, 0),
            SIMD3(0, 0, 1)
        ))
        return translation(pivot) * rotation * translation(-pivot)
    }

    private static func translation(_ value: SIMD2<Float>) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(1, 0, 0),
            SIMD3(0, 1, 0),
            SIMD3(value.x, value.y, 1)
        ))
    }

    private static func apply(
        _ matrix: simd_float3x3,
        to point: SIMD2<Float>
    ) -> SIMD2<Float> {
        let transformed = matrix * SIMD3(point.x, point.y, 1)
        return SIMD2(transformed.x, transformed.y)
    }

    private func apply(
        _ matrix: simd_float3x3,
        to point: SIMD2<Float>
    ) -> SIMD2<Float> {
        Self.apply(matrix, to: point)
    }
}
