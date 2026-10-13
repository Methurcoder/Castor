import CoreGraphics
import Foundation

import ArilsCore

/// Converts the rectangular head review box into a soft, curved ownership
/// mask. The box remains a human-provided search region; it is not treated as
/// the final cut between the moving head and the fixed body.
public struct HeadRegionProfile: PartOwnershipWeighting, Sendable, Equatable {
    public var headRect: CGRect
    public var faceAxisX: CGFloat
    public var faceHalfWidth: CGFloat
    public var sideRise: CGFloat
    public var lowerFeather: CGFloat
    public var horizontalFeather: CGFloat

    public init(plan: PartPlan) {
        let leftEye = CGPoint(x: plan.eyeLeftRect.midX, y: plan.eyeLeftRect.midY)
        let rightEye = CGPoint(x: plan.eyeRightRect.midX, y: plan.eyeRightRect.midY)
        let mouth = CGPoint(x: plan.mouthRect.midX, y: plan.mouthRect.midY)
        let eyeAxis = (leftEye.x + rightEye.x) / 2
        let eyeSeparation = abs(rightEye.x - leftEye.x)
        let headWidth = max(1, plan.headRect.width)
        let headHeight = max(1, plan.headRect.height)

        headRect = plan.headRect
        // The mouth gets a smaller vote: a stylized or off-axis mouth should
        // bend the mask gently, not drag the whole head cut sideways.
        faceAxisX = eyeAxis * 0.82 + mouth.x * 0.18
        faceHalfWidth = min(
            headWidth * 0.38,
            max(headWidth * 0.22, eyeSeparation * 0.92, plan.mouthRect.width * 1.8)
        )
        let eyeY = (leftEye.y + rightEye.y) / 2
        let eyeToMouth = max(1, mouth.y - eyeY)
        sideRise = min(headHeight * 0.15, max(headHeight * 0.08, eyeToMouth * 0.42))
        lowerFeather = min(10, max(2, headHeight * 0.035))
        horizontalFeather = min(8, max(2, headWidth * 0.025))
    }

    /// The bottom of the moving head at a source-space x coordinate. It stays
    /// lowest around the face/chin and rises toward the side hair/shoulders,
    /// avoiding a single horizontal ownership boundary across the whole crop.
    public func lowerBoundaryY(at x: CGFloat) -> CGFloat {
        let halfRect = max(1, headRect.width / 2)
        let transition = max(1, halfRect - faceHalfWidth)
        let distance = abs(x - faceAxisX)
        let t = Float(min(max((distance - faceHalfWidth) / transition, 0), 1))
        let curved = CGFloat(Interpolation.smoothstep(0, 1, t))
        return headRect.maxY - sideRise * curved
    }

    /// 1 means the source pixel moves with the head; 0 leaves it on the body.
    /// The caller still multiplies this by the subject mask, so background and
    /// transparent gaps never become part of the head merely because they are
    /// inside the review rectangle.
    public func ownershipWeight(x: CGFloat, y: CGFloat) -> Float {
        guard x >= headRect.minX, x < headRect.maxX,
              y >= headRect.minY, y < headRect.maxY else { return 0 }

        let lowerBoundary = lowerBoundaryY(at: x)
        // Reach zero slightly before the crop edge. The Metal sampler clamps
        // the last texel, so leaving that texel half opaque would recreate a
        // dark line even though the ownership boundary itself is curved.
        let transparentEdge = lowerBoundary - min(0.5, lowerFeather * 0.25)
        let lower = 1 - Interpolation.smoothstep(
            Float(transparentEdge - lowerFeather),
            Float(transparentEdge),
            Float(y)
        )
        let left = Interpolation.smoothstep(
            Float(headRect.minX),
            Float(headRect.minX + horizontalFeather),
            Float(x)
        )
        let right = 1 - Interpolation.smoothstep(
            Float(headRect.maxX - horizontalFeather),
            Float(headRect.maxX),
            Float(x)
        )
        return min(max(lower * left * right, 0), 1)
    }

    /// Narrow real-source bridge around the same curved boundary. Restricting
    /// the seam texture to this band prevents its rectangular crop from becoming
    /// visible when its upper vertices follow head pitch.
    public func seamWeight(x: CGFloat, y: CGFloat) -> Float {
        let boundary = lowerBoundaryY(at: x) - lowerFeather * 0.45
        let distance = abs(y - boundary)
        let band = 1 - Interpolation.smoothstep(
            Float(lowerFeather * 0.55),
            Float(lowerFeather * 2.8),
            Float(distance)
        )
        return min(max(band * ownershipHorizontalWeight(x: x), 0), 1)
    }

    private func ownershipHorizontalWeight(x: CGFloat) -> Float {
        guard x >= headRect.minX, x < headRect.maxX else { return 0 }
        let left = Interpolation.smoothstep(
            Float(headRect.minX),
            Float(headRect.minX + horizontalFeather),
            Float(x)
        )
        let right = 1 - Interpolation.smoothstep(
            Float(headRect.maxX - horizontalFeather),
            Float(headRect.maxX),
            Float(x)
        )
        return min(left, right)
    }
}
