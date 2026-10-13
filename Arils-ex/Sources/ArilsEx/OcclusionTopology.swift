import Foundation

/// A semantic layer between 2D landmark proposal and pixel ownership.
/// Positions answer "where is the joint projected?"; visibility answers
/// "does this authored view contain pixels that may be cut for it?".
public struct OcclusionTopologyResult: Codable, Equatable, Sendable {
    public var poses: [ReferencePose]
    public var decisions: [OcclusionTopologyDecision]

    public init(
        poses: [ReferencePose],
        decisions: [OcclusionTopologyDecision]
    ) {
        self.poses = poses
        self.decisions = decisions
    }

    public func pose(for role: ReferenceRole) -> ReferencePose? {
        poses.first { $0.role == role }
    }
}

public struct OcclusionTopologyDecision: Codable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable {
        case asymmetricVisionEvidence
        case userSpecified
    }

    public var role: ReferenceRole
    public var side: ArmSide
    public var visibility: JointVisibility
    public var basis: Basis

    public init(
        role: ReferenceRole,
        side: ArmSide,
        visibility: JointVisibility,
        basis: Basis
    ) {
        self.role = role
        self.side = side
        self.visibility = visibility
        self.basis = basis
    }
}

public struct VisibilityAuditMetrics: Codable, Equatable, Sendable {
    /// What the pre-visibility pipeline did: every coordinate became a texture
    /// seed, including silhouette templates and cross-view predictions.
    public var legacyTextureSeedCount: Int
    public var visibleTextureSeedCount: Int
    public var occludedJointCount: Int
    public var unresolvedJointCount: Int

    public init(
        pose: ReferencePose,
        joints: Set<JointKind> = Set(JointKind.allCases)
    ) {
        let observations = joints.compactMap { pose[$0] }
        legacyTextureSeedCount = observations.count
        visibleTextureSeedCount = observations.count { $0.visibility == .visible }
        occludedJointCount = observations.count {
            $0.visibility == .occluded || $0.visibility == .outOfFrame
        }
        unresolvedJointCount = observations.count { $0.visibility == .unknown }
    }

    public var preventedTextureSeedCount: Int {
        max(0, legacyTextureSeedCount - visibleTextureSeedCount)
    }
}

public enum OcclusionTopology {
    /// Classifies a fully hidden arm only when a side drawing has asymmetric
    /// landmark evidence: one distal arm chain is observed while the other is
    /// only a template/prediction. Ambiguous cases remain `.unknown` and are
    /// rejected by admission instead of being hallucinated as texture.
    public static func resolve(_ input: [ReferencePose]) -> OcclusionTopologyResult {
        var output: [ReferencePose] = []
        var decisions: [OcclusionTopologyDecision] = []

        for var pose in input {
            normalizeManualVisibility(in: &pose, decisions: &decisions)
            guard pose.role != .front else {
                output.append(pose)
                continue
            }

            let left = evidence(for: .left, in: pose)
            let right = evidence(for: .right, in: pose)
            if left.isStrong, right.isWeak {
                markAutomaticallyOccluded(.right, in: &pose)
                decisions.append(OcclusionTopologyDecision(
                    role: pose.role,
                    side: .right,
                    visibility: .occluded,
                    basis: .asymmetricVisionEvidence
                ))
            } else if right.isStrong, left.isWeak {
                markAutomaticallyOccluded(.left, in: &pose)
                decisions.append(OcclusionTopologyDecision(
                    role: pose.role,
                    side: .left,
                    visibility: .occluded,
                    basis: .asymmetricVisionEvidence
                ))
            }
            output.append(pose)
        }
        return OcclusionTopologyResult(poses: output, decisions: decisions)
    }

    private struct ArmEvidence {
        var observedDistalCount: Int
        var strongConfidenceCount: Int
        var hasManualVisible: Bool
        var hasManualHidden: Bool

        var isStrong: Bool {
            hasManualVisible || observedDistalCount >= 2 || strongConfidenceCount >= 2
        }

        var isWeak: Bool {
            !hasManualVisible && !hasManualHidden && observedDistalCount == 0
        }
    }

    private static func evidence(
        for side: ArmSide,
        in pose: ReferencePose
    ) -> ArmEvidence {
        let joints = armJoints(side)
        let distal = Set(joints.dropFirst())
        var result = ArmEvidence(
            observedDistalCount: 0,
            strongConfidenceCount: 0,
            hasManualVisible: false,
            hasManualHidden: false
        )
        for joint in joints {
            guard let observation = pose[joint] else { continue }
            if observation.visibilitySource == .user {
                result.hasManualVisible = result.hasManualVisible
                    || observation.visibility == .visible
                result.hasManualHidden = result.hasManualHidden
                    || observation.visibility == .occluded
                    || observation.visibility == .outOfFrame
            }
            let isDirectEvidence = observation.source == .vision
                || observation.source == .user
            if isDirectEvidence,
               observation.visibility == .visible,
               observation.confidence >= 0.18,
               distal.contains(joint) {
                result.observedDistalCount += 1
            }
            if isDirectEvidence,
               observation.visibility == .visible,
               observation.confidence >= 0.35 {
                result.strongConfidenceCount += 1
            }
        }
        return result
    }

    private static func normalizeManualVisibility(
        in pose: inout ReferencePose,
        decisions: inout [OcclusionTopologyDecision]
    ) {
        for side in [ArmSide.left, .right] {
            let observations = armJoints(side).compactMap { pose[$0] }
            let userHidden = observations.contains {
                $0.visibilitySource == .user
                    && ($0.visibility == .occluded || $0.visibility == .outOfFrame)
            }
            guard userHidden else { continue }
            for joint in armJoints(side) {
                guard var observation = pose[joint], observation.visibilitySource != .user else {
                    continue
                }
                if observation.visibility == .unknown {
                    observation.visibility = .occluded
                    observation.visibilitySource = .topology
                    pose[joint] = observation
                }
            }
            decisions.append(OcclusionTopologyDecision(
                role: pose.role,
                side: side,
                visibility: .occluded,
                basis: .userSpecified
            ))
        }
    }

    private static func markAutomaticallyOccluded(
        _ side: ArmSide,
        in pose: inout ReferencePose
    ) {
        for joint in armJoints(side) {
            guard var observation = pose[joint], observation.visibilitySource != .user else {
                continue
            }
            // Never erase direct contradictory evidence. The topology layer
            // only resolves template/predicted uncertainty.
            guard observation.source == .silhouetteTemplate
                    || observation.source == .crossViewConsensus
                    || observation.visibility == .unknown else {
                continue
            }
            observation.visibility = .occluded
            observation.visibilitySource = .topology
            pose[joint] = observation
        }
    }

    public static func armJoints(_ side: ArmSide) -> [JointKind] {
        switch side {
        case .left: [.leftShoulder, .leftElbow, .leftWrist]
        case .right: [.rightShoulder, .rightElbow, .rightWrist]
        }
    }
}
