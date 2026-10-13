import Arils
import Foundation

public enum ThreeViewRigBuildError: Error, Equatable, LocalizedError {
    case missingReference(ReferenceRole)
    case duplicateReference(ReferenceRole)
    case poseNotAdmitted(role: ReferenceRole, issues: [PoseAdmissionIssue])
    case articulationCompilationFailed(role: ReferenceRole, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .missingReference(role):
            "\(role.displayName)画像が必要です。"
        case let .duplicateReference(role):
            "\(role.displayName)画像が重複しています。"
        case let .poseNotAdmitted(role, issues):
            "\(role.displayName)画像はバストアップ関節リグの対象外です: "
                + issues.map(\.message).joined(separator: " ")
        case let .articulationCompilationFailed(role, reason):
            "\(role.displayName)画像の関節パーツ生成に失敗しました: \(reason)"
        }
    }
}

/// One-call builder for the mostly-automatic path:
/// image -> joint proposal/review -> normal Arils rig -> three-view archive.
public struct ThreeViewRigBuilder: Sendable {
    public var pipeline: any RiggingPipeline
    public var jointProposalEngine: JointProposalEngine
    public var jointScope: JointScope
    public var articulationCompiler: ArticulationCompiler

    public init(
        pipeline: any RiggingPipeline = AutoRigPipeline(),
        jointProposalEngine: JointProposalEngine = JointProposalEngine(),
        jointScope: JointScope = .bustUp,
        articulationCompiler: ArticulationCompiler = ArticulationCompiler()
    ) {
        self.pipeline = pipeline
        self.jointProposalEngine = jointProposalEngine
        self.jointScope = jointScope
        self.articulationCompiler = articulationCompiler
    }

    public func proposeJoints(for inputs: [ReferenceImageInput]) async throws -> [ReferencePose] {
        try Self.validate(inputs)
        let poses = await proposedPoses(for: Self.ordered(inputs))
        return ThreeViewJointConsensus.reconcile(poses).poses
    }

    public func build(from inputs: [ReferenceImageInput]) async throws -> ThreeViewRigArchive {
        try Self.validate(inputs)
        let orderedInputs = Self.ordered(inputs)
        let proposed = await proposedPoses(for: orderedInputs)
        let consensus = ThreeViewJointConsensus.reconcile(proposed)
        let poses = Dictionary(uniqueKeysWithValues: consensus.poses.map { ($0.role, $0) })
        var subjectMasks: [ReferenceRole: FloatPlane] = [:]
        for input in orderedInputs {
            let pose = poses[input.role]
                ?? ReferencePose(role: input.role, fileName: input.fileName)
            let subjectMask: FloatPlane
            do {
                subjectMask = try await articulationCompiler.subjectMask(for: input.image)
                subjectMasks[input.role] = subjectMask
            } catch {
                throw ThreeViewRigBuildError.articulationCompilationFailed(
                    role: input.role,
                    reason: error.localizedDescription
                )
            }
            let admission = PoseAdmission.evaluate(
                pose: pose,
                subjectMask: subjectMask,
                scope: jointScope
            )
            guard admission.isAdmitted else {
                throw ThreeViewRigBuildError.poseNotAdmitted(
                    role: input.role,
                    issues: admission.issues
                )
            }
        }

        var references: [ReferenceViewArchive] = []
        var articulationByRole: [ReferenceRole: ArticulationRigArchive] = [:]
        for input in orderedInputs {
            let pose = poses[input.role]
                ?? ReferencePose(role: input.role, fileName: input.fileName)
            do {
                articulationByRole[input.role] = try await articulationCompiler.compile(
                    image: input.image,
                    pose: pose,
                    subjectMask: subjectMasks[input.role],
                    corrections: input.ownershipCorrections,
                    layerOrders: input.articulationLayerOrders
                )
            } catch {
                throw ThreeViewRigBuildError.articulationCompilationFailed(
                    role: input.role,
                    reason: error.localizedDescription
                )
            }
            let avatar = try await pipeline.makeAvatar(from: input.image)
            references.append(ReferenceViewArchive(
                role: input.role,
                fileName: input.fileName,
                pose: pose,
                avatar: try AvatarArchive(avatar: avatar)
            ))
        }
        return ThreeViewRigArchive(
            references: references,
            consensus: consensus,
            articulationByRole: articulationByRole,
            crossViewArticulation: CrossViewArticulationAnalyzer.analyze(
                articulationByRole: articulationByRole
            )
        )
    }

    private func proposedPoses(for inputs: [ReferenceImageInput]) async -> [ReferencePose] {
        var poses: [ReferencePose] = []
        for input in inputs {
            if var reviewed = input.reviewedPose {
                reviewed.role = input.role
                reviewed.fileName = input.fileName
                poses.append(reviewed)
            } else {
                poses.append(await jointProposalEngine.propose(
                    for: input.image,
                    role: input.role,
                    fileName: input.fileName
                ))
            }
        }
        return poses
    }

    private static func validate(_ inputs: [ReferenceImageInput]) throws {
        for role in ReferenceRole.allCases {
            let count = inputs.lazy.filter { $0.role == role }.count
            if count == 0 { throw ThreeViewRigBuildError.missingReference(role) }
            if count > 1 { throw ThreeViewRigBuildError.duplicateReference(role) }
        }
    }

    private static func ordered(_ inputs: [ReferenceImageInput]) -> [ReferenceImageInput] {
        ReferenceRole.allCases.compactMap { role in inputs.first { $0.role == role } }
    }
}
