import Arils
import CoreGraphics
import Foundation
import simd

public struct ReferenceViewArchive: Codable, Sendable, Identifiable {
    public var role: ReferenceRole
    public var fileName: String
    public var pose: ReferencePose
    public var avatar: AvatarArchive

    public var id: ReferenceRole { role }

    public init(
        role: ReferenceRole,
        fileName: String,
        pose: ReferencePose,
        avatar: AvatarArchive
    ) {
        self.role = role
        self.fileName = fileName
        self.pose = pose
        self.avatar = avatar
    }
}

public struct ReferenceViewRegistration: Codable, Equatable, Sendable {
    public var neck: SIMD2<Float>
    public var scaleRelativeToFront: Float

    public init(neck: SIMD2<Float>, scaleRelativeToFront: Float) {
        self.neck = neck
        self.scaleRelativeToFront = scaleRelativeToFront
    }
}

/// Alignment is driven by the user-reviewable neck and pelvis joints rather
/// than an opaque image registration step.
public struct ThreeViewRegistration: Codable, Equatable, Sendable {
    public var views: [ReferenceRole: ReferenceViewRegistration]

    public init(views: [ReferenceRole: ReferenceViewRegistration]) {
        self.views = views
    }

    public static func automatic(from references: [ReferenceViewArchive]) -> ThreeViewRegistration {
        guard let front = references.first(where: { $0.role == .front }) else {
            return ThreeViewRegistration(views: [:])
        }
        let frontTorso = torsoLength(front)
        var values: [ReferenceRole: ReferenceViewRegistration] = [:]
        for reference in references {
            let neck = reference.pose[.neck]?.position ?? SIMD2(0.5, 0.25)
            let scale: Float
            if reference.role == .front {
                scale = 1
            } else {
                scale = min(max(frontTorso / max(torsoLength(reference), 0.001), 0.45), 2.2)
            }
            values[reference.role] = ReferenceViewRegistration(
                neck: neck,
                scaleRelativeToFront: scale
            )
        }
        return ThreeViewRegistration(views: values)
    }

    private static func torsoLength(_ reference: ReferenceViewArchive) -> Float {
        let neck = reference.pose[.neck]?.position ?? SIMD2(0.5, 0.25)
        let pelvis = reference.pose[.pelvis]?.position ?? SIMD2(0.5, 0.58)
        let width = Float(max(1, reference.avatar.rig.imageWidth))
        let height = Float(max(1, reference.avatar.rig.imageHeight))
        return simd_distance(neck * SIMD2(width, height), pelvis * SIMD2(width, height))
    }
}

/// Persistent Arils-ex asset. Each source is independently auto-rigged by
/// Arils and accompanied by the editable skeleton used for alignment and
/// future articulated body deformation.
public struct ThreeViewRigArchive: Codable, Sendable {
    public static let currentFormatVersion = 4

    public var formatVersion: Int
    public var references: [ReferenceViewArchive]
    public var registration: ThreeViewRegistration
    public var consensus: ThreeViewConsensusResult
    /// Missing in v1 archives. New builds persist compiled arm masks, meshes,
    /// underpaint and LBS weights for each authored view.
    public var articulationByRole: [ReferenceRole: ArticulationRigArchive]?
    /// Missing in v1-v3 archives. New builds persist per-segment front
    /// symmetry and side-view anatomical correspondence so runtime arm
    /// visibility is independent from whole-image cross-fade.
    public var crossViewArticulation: CrossViewArticulationProfile?

    public init(
        references: [ReferenceViewArchive],
        registration: ThreeViewRegistration? = nil,
        consensus: ThreeViewConsensusResult,
        articulationByRole: [ReferenceRole: ArticulationRigArchive] = [:],
        crossViewArticulation: CrossViewArticulationProfile? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.references = references
        self.registration = registration ?? .automatic(from: references)
        self.consensus = consensus
        self.articulationByRole = articulationByRole
        self.crossViewArticulation = crossViewArticulation
    }

    public func reference(for role: ReferenceRole) -> ReferenceViewArchive? {
        references.first { $0.role == role }
    }

    public func articulation(for role: ReferenceRole) -> ArticulationRigArchive? {
        articulationByRole?[role]
    }

    public func data() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try PropertyListDecoder().decode(ThreeViewRigArchive.self, from: data)
    }
}

public struct ReferenceImageInput: @unchecked Sendable {
    public var role: ReferenceRole
    public var fileName: String
    public var image: CGImage
    public var reviewedPose: ReferencePose?
    public var ownershipCorrections: [ArticulationPartID: [OwnershipBrushStroke]]
    public var articulationLayerOrders: [ArticulationPartID: ArticulationLayerOrder]

    public init(
        role: ReferenceRole,
        fileName: String,
        image: CGImage,
        reviewedPose: ReferencePose? = nil,
        ownershipCorrections: [ArticulationPartID: [OwnershipBrushStroke]] = [:],
        articulationLayerOrders: [ArticulationPartID: ArticulationLayerOrder] = [:]
    ) {
        self.role = role
        self.fileName = fileName
        self.image = image
        self.reviewedPose = reviewedPose
        self.ownershipCorrections = ownershipCorrections
        self.articulationLayerOrders = articulationLayerOrders
    }
}
