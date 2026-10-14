import Foundation

public nonisolated enum MotionState: String, CaseIterable, Identifiable, Sendable {
    case idle
    case thinking
    case listening
    case surprised

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .idle:
            "idle"
        case .thinking:
            "thinking"
        case .listening:
            "listening"
        case .surprised:
            "surprised"
        }
    }
}
