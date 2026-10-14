#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

@frozen public nonisolated enum RigPartKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case head
    case leftEye
    case rightEye
    case mouth
    case body
    case hair

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .head:
            "head"
        case .leftEye:
            "leftEye"
        case .rightEye:
            "rightEye"
        case .mouth:
            "mouth"
        case .body:
            "body"
        case .hair:
            "hair"
        }
    }
}

@frozen public nonisolated enum RigPartShape: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case rectangle
    case ellipse

    public var id: String { rawValue }
}

public nonisolated struct RigPart: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var kind: RigPartKind
    public var normalizedRect: CGRect
    public var shape: RigPartShape
    public var anchorPoint: CGPoint
    public var zIndex: Double

    public init(
        id: UUID = UUID(),
        kind: RigPartKind,
        normalizedRect: CGRect,
        shape: RigPartShape,
        anchorPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        zIndex: Double
    ) {
        self.id = id
        self.kind = kind
        self.normalizedRect = normalizedRect
        self.shape = shape
        self.anchorPoint = anchorPoint
        self.zIndex = zIndex
    }
}
