import CoreGraphics
import Foundation

enum RigPartKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case head
    case leftEye
    case rightEye
    case mouth
    case body
    case hair

    var id: String { rawValue }

    var label: String {
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

enum RigPartShape: String, CaseIterable, Codable, Hashable, Identifiable {
    case rectangle
    case ellipse

    var id: String { rawValue }
}

struct RigPart: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var kind: RigPartKind
    var normalizedRect: CGRect
    var shape: RigPartShape
    var anchorPoint: CGPoint
    var zIndex: Double

    init(
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
