import Foundation

public struct ThreeViewBlendWeights: Equatable, Sendable {
    public var left: Float
    public var front: Float
    public var right: Float

    public init(left: Float, front: Float, right: Float) {
        self.left = left
        self.front = front
        self.right = right
    }
}

public enum ThreeViewBlend {
    public static func weights(for viewTurn: Float) -> ThreeViewBlendWeights {
        let turn = viewTurn.isFinite ? min(max(viewTurn, -1), 1) : 0
        let amount = abs(turn)
        return ThreeViewBlendWeights(
            left: turn < 0 ? amount : 0,
            front: 1 - amount,
            right: turn > 0 ? amount : 0
        )
    }
}
