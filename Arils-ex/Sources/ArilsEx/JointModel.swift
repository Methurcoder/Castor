import Foundation
import simd

/// The three drawings used by Arils-ex. They are deliberately explicit: a
/// left drawing is never silently mirrored and used as a right drawing.
public enum ReferenceRole: String, Codable, CaseIterable, Sendable, Identifiable {
    case left
    case front
    case right

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .left: "左向き"
        case .front: "正面"
        case .right: "右向き"
        }
    }
}

/// Joints are normalized in top-left image coordinates (0...1 on each axis).
/// This keeps edits stable when a source image is resized.
public enum JointKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case head
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case pelvis
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .head: "頭"
        case .neck: "首"
        case .leftShoulder: "左肩"
        case .rightShoulder: "右肩"
        case .leftElbow: "左ひじ"
        case .rightElbow: "右ひじ"
        case .leftWrist: "左手首"
        case .rightWrist: "右手首"
        case .pelvis: "腰"
        case .leftKnee: "左ひざ"
        case .rightKnee: "右ひざ"
        case .leftAnkle: "左足首"
        case .rightAnkle: "右足首"
        }
    }
}

public enum JointObservationSource: String, Codable, Sendable {
    case vision
    case silhouetteTemplate
    case crossViewConsensus
    case user
}

/// Whether the source drawing actually contains pixels for a joint.
///
/// This is deliberately independent from `position`: an occluded joint can
/// still have a projected anatomical position for kinematics and cross-view
/// registration, but must never seed texture ownership in this view.
public enum JointVisibility: String, Codable, CaseIterable, Sendable {
    case visible
    case occluded
    case outOfFrame
    case unknown

    public var contributesTexture: Bool { self == .visible }

    public var displayName: String {
        switch self {
        case .visible: "見えている"
        case .occluded: "他パーツの後ろ"
        case .outOfFrame: "画面外"
        case .unknown: "不明"
        }
    }
}

public enum JointVisibilitySource: String, Codable, Sendable {
    /// Archives written before the visibility layer implicitly treated stored
    /// points as visible.
    case legacy
    case vision
    case topology
    case user
}

public struct JointObservation: Codable, Equatable, Sendable {
    public var position: SIMD2<Float>
    public var confidence: Float
    public var source: JointObservationSource
    public var visibility: JointVisibility
    public var visibilitySource: JointVisibilitySource

    public init(
        position: SIMD2<Float>,
        confidence: Float,
        source: JointObservationSource,
        visibility: JointVisibility = .visible,
        visibilitySource: JointVisibilitySource = .legacy
    ) {
        self.position = Self.clamp(position)
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.source = source
        self.visibility = visibility
        self.visibilitySource = visibilitySource
    }

    private enum CodingKeys: String, CodingKey {
        case position
        case confidence
        case source
        case visibility
        case visibilitySource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            position: try container.decode(SIMD2<Float>.self, forKey: .position),
            confidence: try container.decode(Float.self, forKey: .confidence),
            source: try container.decode(JointObservationSource.self, forKey: .source),
            // v0.1/v0.2 archives predate visibility and treated every stored
            // coordinate as visible. Preserve that behavior when decoding.
            visibility: try container.decodeIfPresent(
                JointVisibility.self,
                forKey: .visibility
            ) ?? .visible,
            visibilitySource: try container.decodeIfPresent(
                JointVisibilitySource.self,
                forKey: .visibilitySource
            ) ?? .legacy
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(position, forKey: .position)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(source, forKey: .source)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(visibilitySource, forKey: .visibilitySource)
    }

    private static func clamp(_ point: SIMD2<Float>) -> SIMD2<Float> {
        guard point.x.isFinite, point.y.isFinite else { return SIMD2(0.5, 0.5) }
        return simd_clamp(point, SIMD2(repeating: 0), SIMD2(repeating: 1))
    }
}

public struct ReferencePose: Codable, Equatable, Sendable, Identifiable {
    public var role: ReferenceRole
    public var fileName: String
    public var joints: [JointKind: JointObservation]

    public var id: ReferenceRole { role }

    public init(
        role: ReferenceRole,
        fileName: String,
        joints: [JointKind: JointObservation] = [:]
    ) {
        self.role = role
        self.fileName = fileName
        self.joints = joints
    }

    public subscript(_ joint: JointKind) -> JointObservation? {
        get { joints[joint] }
        set { joints[joint] = newValue }
    }

    public mutating func setUserPosition(_ position: SIMD2<Float>, for joint: JointKind) {
        joints[joint] = JointObservation(
            position: position,
            confidence: 1,
            source: .user,
            visibility: .visible,
            visibilitySource: .user
        )
    }

    /// Changes semantic visibility without discarding a useful projected
    /// position. Manual visibility is authoritative during topology fusion.
    public mutating func setUserVisibility(
        _ visibility: JointVisibility,
        for joint: JointKind
    ) {
        if var observation = joints[joint] {
            observation.visibility = visibility
            observation.visibilitySource = .user
            joints[joint] = observation
        } else {
            joints[joint] = JointObservation(
                position: SIMD2(0.5, 0.5),
                confidence: 0,
                source: .silhouetteTemplate,
                visibility: visibility,
                visibilitySource: .user
            )
        }
    }

    public var averageConfidence: Float {
        guard !joints.isEmpty else { return 0 }
        return joints.values.reduce(0) { $0 + $1.confidence } / Float(joints.count)
    }
}

public enum JointSkeleton {
    public static let bones: [(JointKind, JointKind)] = [
        (.head, .neck),
        (.neck, .leftShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.neck, .rightShoulder),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.neck, .pelvis),
        (.pelvis, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.pelvis, .rightKnee),
        (.rightKnee, .rightAnkle),
    ]
}
