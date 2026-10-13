import Arils
import CoreGraphics
import Foundation
import simd

/// Joint subsets supported by an articulation compiler. The initial scope is
/// deliberately bust-up: neck, both shoulders, elbows, and wrists (7 joints).
public enum JointScope: String, Codable, Sendable {
    case bustUp

    public var joints: Set<JointKind> {
        switch self {
        case .bustUp:
            [
                .neck,
                .leftShoulder,
                .rightShoulder,
                .leftElbow,
                .rightElbow,
                .leftWrist,
                .rightWrist,
            ]
        }
    }
}

public enum PoseAdmissionIssue: Codable, Equatable, Sendable {
    case jointNotVisible(JointKind)
    case jointPositionUnverified(JointKind)
    case jointVisibilityUnresolved(JointKind)
    case noCompleteVisibleArm
    case armIntersectsTorso(side: ArmSide)
    case subjectDoesNotReachBottom

    public var message: String {
        switch self {
        case let .jointNotVisible(joint):
            "\(joint.displayName)が十分に見えていません。"
        case let .jointPositionUnverified(joint):
            "\(joint.displayName)の位置を画像上で確認してください。"
        case let .jointVisibilityUnresolved(joint):
            "\(joint.displayName)の可視・遮蔽を確定できません。"
        case .noCompleteVisibleArm:
            "画像内に肩・ひじ・手首が揃って見える腕がありません。"
        case let .armIntersectsTorso(side):
            "\(side.displayName)腕が胴体と交差しています。"
        case .subjectDoesNotReachBottom:
            "バストアップの下端が画像下端まで接地していません。"
        }
    }
}

public enum ArmSide: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right

    public var displayName: String {
        switch self {
        case .left: "左"
        case .right: "右"
        }
    }
}

public struct PoseAdmissionResult: Codable, Equatable, Sendable {
    public var scope: JointScope
    public var issues: [PoseAdmissionIssue]

    public init(scope: JointScope, issues: [PoseAdmissionIssue]) {
        self.scope = scope
        self.issues = issues
    }

    public var isAdmitted: Bool { issues.isEmpty }
}

public enum PoseAdmission {
    public static func evaluate(
        pose: ReferencePose,
        image: CGImage,
        scope: JointScope = .bustUp,
        minimumJointConfidence: Float = 0.35
    ) -> PoseAdmissionResult {
        guard let bitmap = Bitmap(image: image) else {
            return PoseAdmissionResult(
                scope: scope,
                issues: scope.joints.map(PoseAdmissionIssue.jointNotVisible)
            )
        }
        let mask = bitmap.alphaPlane()
        let transparentFraction = Float(mask.values.count { $0 < 0.1 })
            / Float(max(1, mask.values.count))
        guard transparentFraction >= 0.02 else {
            // A fully opaque alpha plane is background opacity, not subject
            // evidence. Async builders must resolve a real subject mask and
            // call the `subjectMask:` overload.
            return PoseAdmissionResult(
                scope: scope,
                issues: scope.joints.sorted { $0.rawValue < $1.rawValue }.map(
                    PoseAdmissionIssue.jointVisibilityUnresolved
                )
            )
        }
        return evaluate(
            pose: pose,
            subjectMask: mask,
            scope: scope,
            minimumJointConfidence: minimumJointConfidence
        )
    }

    /// Admission using the actual extraction mask. The builder uses this path
    /// so opaque white-background artwork is not mistaken for foreground at
    /// every coordinate merely because its alpha channel is fully opaque.
    public static func evaluate(
        pose: ReferencePose,
        subjectMask: FloatPlane,
        scope: JointScope = .bustUp,
        minimumJointConfidence: Float = 0.35
    ) -> PoseAdmissionResult {
        var issues: [PoseAdmissionIssue] = []

        for joint in scope.joints.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let observation = pose[joint] else {
                issues.append(.jointNotVisible(joint))
                continue
            }
            switch observation.visibility {
            case .visible:
                guard calibratedPositionConfidence(observation) >= minimumJointConfidence else {
                    issues.append(.jointPositionUnverified(joint))
                    continue
                }
                guard isVisible(observation.position, in: subjectMask) else {
                    issues.append(.jointNotVisible(joint))
                    continue
                }
            case .unknown:
                issues.append(.jointVisibilityUnresolved(joint))
            case .occluded, .outOfFrame:
                // A side view may legitimately omit the far limb. Its
                // projected point is retained for kinematics but contributes
                // no texture. Front artwork remains strict.
                if pose.role == .front {
                    issues.append(.jointNotVisible(joint))
                }
            }
        }

        if pose.role != .front,
           ![ArmSide.left, .right].contains(where: { completeArmIsVisible($0, pose: pose) }) {
            issues.append(.noCompleteVisibleArm)
        }

        if completeArmIsVisible(.left, pose: pose),
           armsIntersectTorso(pose: pose, side: .left) {
            issues.append(.armIntersectsTorso(side: .left))
        }
        if completeArmIsVisible(.right, pose: pose),
           armsIntersectTorso(pose: pose, side: .right) {
            issues.append(.armIntersectsTorso(side: .right))
        }
        if !subjectReachesBottom(subjectMask) {
            issues.append(.subjectDoesNotReachBottom)
        }
        return PoseAdmissionResult(scope: scope, issues: issues)
    }

    private static func completeArmIsVisible(
        _ side: ArmSide,
        pose: ReferencePose
    ) -> Bool {
        OcclusionTopology.armJoints(side).allSatisfy {
            pose[$0]?.visibility == .visible
        }
    }

    private static func calibratedPositionConfidence(
        _ observation: JointObservation
    ) -> Float {
        switch observation.source {
        case .user, .vision:
            observation.confidence
        case .crossViewConsensus:
            // Other views improve a projected prior, but cannot localize the
            // joint against pixels in this drawing. Keep it just below the
            // automatic-admission threshold until the point is reviewed.
            min(observation.confidence, 0.34)
        case .silhouetteTemplate:
            min(observation.confidence, 0.22)
        }
    }

    private static func isVisible(_ point: SIMD2<Float>, in mask: FloatPlane) -> Bool {
        guard mask.width > 0, mask.height > 0 else { return false }
        let x = min(mask.width - 1, max(0, Int(point.x * Float(mask.width - 1))))
        let y = min(mask.height - 1, max(0, Int(point.y * Float(mask.height - 1))))
        let radius = max(1, min(6, max(mask.width, mask.height) / 256))
        for sampleY in max(0, y - radius)...min(mask.height - 1, y + radius) {
            for sampleX in max(0, x - radius)...min(mask.width - 1, x + radius)
            where mask[sampleX, sampleY] > 0.08 {
                return true
            }
        }
        return false
    }

    private static func subjectReachesBottom(_ mask: FloatPlane) -> Bool {
        guard mask.width > 0, mask.height > 0 else { return false }
        let startY = max(0, Int(Float(mask.height) * 0.96))
        for y in startY..<mask.height {
            for x in 0..<mask.width where mask[x, y] > 0.08 {
                return true
            }
        }
        return false
    }

    private static func armsIntersectTorso(pose: ReferencePose, side: ArmSide) -> Bool {
        guard let leftShoulder = pose[.leftShoulder]?.position,
              let rightShoulder = pose[.rightShoulder]?.position,
              let neck = pose[.neck]?.position else { return false }
        let shoulderMinX = min(leftShoulder.x, rightShoulder.x)
        let shoulderMaxX = max(leftShoulder.x, rightShoulder.x)
        let shoulderSpan = max(0.02, shoulderMaxX - shoulderMinX)
        let torsoMinX = shoulderMinX + shoulderSpan * 0.12
        let torsoMaxX = shoulderMaxX - shoulderSpan * 0.12
        let torsoTopY = max(leftShoulder.y, rightShoulder.y) + 0.025
        let centerX = (leftShoulder.x + rightShoulder.x + neck.x) / 3
        let torsoAxisStart = SIMD2<Float>(centerX, torsoTopY)
        let torsoAxisEnd = SIMD2<Float>(centerX, 1)

        let shoulderKind: JointKind = side == .left ? .leftShoulder : .rightShoulder
        let elbowKind: JointKind = side == .left ? .leftElbow : .rightElbow
        let wristKind: JointKind = side == .left ? .leftWrist : .rightWrist
        guard let shoulder = pose[shoulderKind]?.position,
              let elbow = pose[elbowKind]?.position,
              let wrist = pose[wristKind]?.position else { return false }

        let innerPoint = [elbow, wrist].contains { point in
            point.y > torsoTopY && point.x > torsoMinX && point.x < torsoMaxX
        }
        if innerPoint { return true }
        return segmentsIntersect(shoulder, elbow, torsoAxisStart, torsoAxisEnd)
            || segmentsIntersect(elbow, wrist, torsoAxisStart, torsoAxisEnd)
    }

    private static func segmentsIntersect(
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>,
        _ d: SIMD2<Float>
    ) -> Bool {
        func orientation(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
            let pq = q - p
            let pr = r - p
            return pq.x * pr.y - pq.y * pr.x
        }
        let abC = orientation(a, b, c)
        let abD = orientation(a, b, d)
        let cdA = orientation(c, d, a)
        let cdB = orientation(c, d, b)
        let epsilon: Float = 1e-5
        return abC * abD < -epsilon && cdA * cdB < -epsilon
    }
}
