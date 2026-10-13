import Foundation
import simd

public enum ThreeViewJointWarning: Codable, Equatable, Sendable {
    case missingReference(ReferenceRole)
    case lowConfidence(role: ReferenceRole, joint: JointKind, confidence: Float)
    case occluded(role: ReferenceRole, joint: JointKind)
    case unresolvedVisibility(role: ReferenceRole, joint: JointKind)
    case implausibleBone(role: ReferenceRole, from: JointKind, to: JointKind)

    public var message: String {
        switch self {
        case let .missingReference(role):
            "\(role.displayName)画像がありません。"
        case let .lowConfidence(role, joint, confidence):
            "\(role.displayName)の\(joint.displayName)は要確認です（信頼度 \(Int(confidence * 100))%）。"
        case let .occluded(role, joint):
            "\(role.displayName)の\(joint.displayName)はこの画像では遮蔽されています。"
        case let .unresolvedVisibility(role, joint):
            "\(role.displayName)の\(joint.displayName)が画像に実際に見えるか確認してください。"
        case let .implausibleBone(role, from, to):
            "\(role.displayName)の\(from.displayName)〜\(to.displayName)の位置関係を確認してください。"
        }
    }
}

public struct ThreeViewConsensusResult: Codable, Equatable, Sendable {
    public var poses: [ReferencePose]
    public var confidence: Float
    public var warnings: [ThreeViewJointWarning]

    public init(poses: [ReferencePose], confidence: Float, warnings: [ThreeViewJointWarning]) {
        self.poses = poses
        self.confidence = confidence
        self.warnings = warnings
    }
}

/// Cross-view completion is intentionally conservative. It never overwrites a
/// user point; it only fills absent points and reports weak or impossible
/// geometry for confirmation.
public enum ThreeViewJointConsensus {
    public static func reconcile(_ input: [ReferencePose]) -> ThreeViewConsensusResult {
        // Visibility is resolved before coordinates are fused. Otherwise a
        // hidden limb filled from another view is silently reclassified as
        // visible and becomes a false texture seed.
        let topology = OcclusionTopology.resolve(input)
        var byRole = Dictionary(uniqueKeysWithValues: topology.poses.map { ($0.role, $0) })
        var warnings: [ThreeViewJointWarning] = []

        for role in ReferenceRole.allCases where byRole[role] == nil {
            warnings.append(.missingReference(role))
        }

        for role in ReferenceRole.allCases {
            guard var pose = byRole[role] else { continue }
            for joint in JointKind.allCases {
                let existing = pose[joint]
                let canRefinePosition = existing == nil
                    || (existing?.source != .user
                        && existing?.visibility != .visible
                        && (existing?.source == .silhouetteTemplate
                            || existing?.source == .crossViewConsensus))
                guard canRefinePosition else { continue }
                let candidates: [JointObservation] = ReferenceRole.allCases.compactMap { candidateRole -> JointObservation? in
                    guard candidateRole != role,
                          let candidate = byRole[candidateRole]?[joint],
                          candidate.visibility == .visible else { return nil }
                    return candidate
                }
                guard !candidates.isEmpty else { continue }
                let xs = candidates.map(\.position.x).sorted()
                let ys = candidates.map(\.position.y).sorted()
                let confidence = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
                pose[joint] = JointObservation(
                    position: SIMD2(Self.median(xs), Self.median(ys)),
                    confidence: min(confidence * 0.65, 0.55),
                    source: .crossViewConsensus,
                    // Cross-view evidence can improve projected geometry but
                    // cannot prove pixels exist in the target drawing.
                    visibility: existing?.visibility ?? .unknown,
                    visibilitySource: existing?.visibilitySource ?? .topology
                )
            }
            byRole[role] = pose
        }

        for role in ReferenceRole.allCases {
            guard let pose = byRole[role] else { continue }
            for joint in JointKind.allCases {
                guard let observation = pose[joint] else { continue }
                switch observation.visibility {
                case .occluded, .outOfFrame:
                    warnings.append(.occluded(role: role, joint: joint))
                case .unknown:
                    warnings.append(.unresolvedVisibility(role: role, joint: joint))
                case .visible where observation.confidence < 0.35:
                    warnings.append(.lowConfidence(
                        role: role,
                        joint: joint,
                        confidence: observation.confidence
                    ))
                case .visible:
                    break
                }
            }
            for (from, to) in JointSkeleton.bones {
                guard let a = pose[from]?.position, let b = pose[to]?.position else { continue }
                let length = simd_distance(a, b)
                if !length.isFinite || length < 0.008 || length > 0.48 {
                    warnings.append(.implausibleBone(role: role, from: from, to: to))
                }
            }
        }

        let poses = ReferenceRole.allCases.compactMap { byRole[$0] }
        let observations = poses.flatMap { pose in
            pose.joints.values.filter { $0.visibility == .visible }
        }
        let confidence = observations.isEmpty
            ? 0
            : observations.map(\.confidence).reduce(0, +) / Float(observations.count)
        return ThreeViewConsensusResult(
            poses: poses,
            confidence: confidence,
            warnings: warnings
        )
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0.5 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) * 0.5
        }
        return values[middle]
    }
}
