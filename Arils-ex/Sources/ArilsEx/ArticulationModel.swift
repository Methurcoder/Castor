import Arils
import CoreGraphics
import Foundation
import simd

public enum ArticulationPartID: String, Codable, CaseIterable, Sendable, Identifiable {
    case leftUpperArm
    case leftForearm
    case rightUpperArm
    case rightForearm

    public var id: String { rawValue }

    public var side: ArmSide {
        switch self {
        case .leftUpperArm, .leftForearm: .left
        case .rightUpperArm, .rightForearm: .right
        }
    }

    public var joints: (start: JointKind, end: JointKind) {
        switch self {
        case .leftUpperArm: (.leftShoulder, .leftElbow)
        case .leftForearm: (.leftElbow, .leftWrist)
        case .rightUpperArm: (.rightShoulder, .rightElbow)
        case .rightForearm: (.rightElbow, .rightWrist)
        }
    }

    public func hasVisibleTexture(in pose: ReferencePose) -> Bool {
        let endpoints = joints
        return pose[endpoints.start]?.visibility == .visible
            && pose[endpoints.end]?.visibility == .visible
    }
}

public enum ArticulationBoneID: String, Codable, CaseIterable, Sendable {
    case leftUpperArm
    case leftForearm
    case rightUpperArm
    case rightForearm

    public var joints: (start: JointKind, end: JointKind) {
        switch self {
        case .leftUpperArm: (.leftShoulder, .leftElbow)
        case .leftForearm: (.leftElbow, .leftWrist)
        case .rightUpperArm: (.rightShoulder, .rightElbow)
        case .rightForearm: (.rightElbow, .rightWrist)
        }
    }
}

public enum ArticulationLayerOrder: String, Codable, Sendable {
    case behindBody
    case inFrontOfBody

    public var zOrder: Int {
        switch self {
        case .behindBody: -5
        case .inFrontOfBody: 5
        }
    }
}

public enum OwnershipBrushMode: String, Codable, Sendable {
    case add
    case remove
}

/// Serializable user correction. Points and radius are normalized to the image
/// so the correction survives source resizing.
public struct OwnershipBrushStroke: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var points: [SIMD2<Float>]
    public var radius: Float
    public var mode: OwnershipBrushMode

    public init(
        id: UUID = UUID(),
        points: [SIMD2<Float>],
        radius: Float,
        mode: OwnershipBrushMode
    ) {
        self.id = id
        self.points = points.map {
            simd_clamp($0, SIMD2(repeating: 0), SIMD2(repeating: 1))
        }
        self.radius = min(max(radius, 0.002), 0.25)
        self.mode = mode
    }
}

public struct LBSVertexWeight: Codable, Equatable, Sendable {
    public var primaryBone: ArticulationBoneID
    public var secondaryBone: ArticulationBoneID
    public var secondaryWeight: Float

    public init(
        primaryBone: ArticulationBoneID,
        secondaryBone: ArticulationBoneID,
        secondaryWeight: Float
    ) {
        self.primaryBone = primaryBone
        self.secondaryBone = secondaryBone
        self.secondaryWeight = min(max(secondaryWeight, 0), 1)
    }
}

public struct ArticulatedPartArchive: Codable, Equatable, Sendable, Identifiable {
    public var id: ArticulationPartID
    public var rect: CGRect
    public var mesh: DeformableMesh
    public var weights: [LBSVertexWeight]
    public var texturePNG: Data
    public var layerOrder: ArticulationLayerOrder

    public init(
        id: ArticulationPartID,
        rect: CGRect,
        mesh: DeformableMesh,
        weights: [LBSVertexWeight],
        texturePNG: Data,
        layerOrder: ArticulationLayerOrder
    ) {
        self.id = id
        self.rect = rect
        self.mesh = mesh
        self.weights = weights
        self.texturePNG = texturePNG
        self.layerOrder = layerOrder
    }
}

public struct ArticulationRigArchive: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    public var imageWidth: Int
    public var imageHeight: Int
    public var restPose: ReferencePose
    public var baseTexturePNG: Data
    public var unknownUnderpaintMaskPNG: Data
    public var parts: [ArticulatedPartArchive]
    /// Parts intentionally absent because the authored view contains no source
    /// pixels for one or both endpoints. Optional for v1 archive compatibility.
    public var omittedParts: [ArticulationPartID: JointVisibility]?
    public var corrections: [ArticulationPartID: [OwnershipBrushStroke]]
    public var integrityMetrics: RigIntegrityMetrics
    /// New archives distinguish hard rejection from a visually questionable
    /// but render-safe result. Optional so v1/v2 archives continue to decode.
    public var integrityDisposition: RigValidationDisposition?
    /// Legacy combined result: true only when no review is required.
    public var integrityAccepted: Bool

    public init(
        imageWidth: Int,
        imageHeight: Int,
        restPose: ReferencePose,
        baseTexturePNG: Data,
        unknownUnderpaintMaskPNG: Data,
        parts: [ArticulatedPartArchive],
        omittedParts: [ArticulationPartID: JointVisibility] = [:],
        corrections: [ArticulationPartID: [OwnershipBrushStroke]],
        integrityMetrics: RigIntegrityMetrics,
        integrityDisposition: RigValidationDisposition? = nil,
        integrityAccepted: Bool
    ) {
        formatVersion = Self.currentFormatVersion
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.restPose = restPose
        self.baseTexturePNG = baseTexturePNG
        self.unknownUnderpaintMaskPNG = unknownUnderpaintMaskPNG
        self.parts = parts
        self.omittedParts = omittedParts
        self.corrections = corrections
        self.integrityMetrics = integrityMetrics
        self.integrityDisposition = integrityDisposition
            ?? (integrityAccepted ? .accepted : .rejected)
        self.integrityAccepted = integrityAccepted
    }
}

public struct ArticulationPoseParameters: Codable, Equatable, Sendable {
    /// Local rotations at shoulder/elbow joints, in degrees.
    public var jointRotations: [JointKind: Float]

    public init(jointRotations: [JointKind: Float] = [:]) {
        self.jointRotations = jointRotations
    }

    public subscript(_ joint: JointKind) -> Float {
        let value = jointRotations[joint] ?? 0
        return value.isFinite ? value : 0
    }
}
