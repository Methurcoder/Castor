#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Geometry of the planned cut, in original-image pixels. Everything the layer
/// extraction and binding synthesis need, with rects validated and padded.
public struct PartPlan: Sendable, Equatable {
    public var imageWidth: Int
    public var imageHeight: Int
    /// Bounding box of the subject mask.
    public var subjectRect: CGRect
    /// Human/estimator supplied search region for the head. The final head/body
    /// ownership is the curved `HeadRegionProfile`, not this rectangle itself.
    public var headRect: CGRect
    public var eyeLeftRect: CGRect
    public var eyeRightRect: CGRect
    public var mouthRect: CGRect
    /// Height of the band above the neck line that the body layer keeps as
    /// low-frequency collar fill, so small head motions never reveal a hole.
    public var collarHeight: CGFloat
    /// Eyelid landmarks carried over from the face layout (empty if none).
    public var eyeLeftLandmarks: [CGPoint] = []
    public var eyeRightLandmarks: [CGPoint] = []

    public var neckY: CGFloat { headRect.maxY }

    /// Original-image band that bridges the moving head and fixed body. Keeping
    /// this visible source patch separate from synthesized underpaint prevents a
    /// rectangular repair color from showing through long hair at the neck cut.
    public var neckSeamRect: CGRect {
        let halfHeight = max(12, min(40, headRect.height * 0.11))
        return CGRect(
            x: headRect.minX,
            y: neckY - halfHeight,
            width: headRect.width,
            height: halfHeight * 2
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }
}

public enum PartPlanner {
    /// Builds the plan from an estimated face layout and the subject mask
    /// (analysis resolution; sampled normalized).
    public static func plan(
        layout: FaceLayout,
        subjectMask: FloatPlane,
        imageWidth: Int,
        imageHeight: Int
    ) -> PartPlan {
        let imageRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)

        // Subject bounding box from the analysis mask, scaled up.
        var minU: Float = 1, minV: Float = 1, maxU: Float = 0, maxV: Float = 0
        var found = false
        for y in 0..<subjectMask.height {
            for x in 0..<subjectMask.width where subjectMask[x, y] > 0.5 {
                let u = Float(x) / Float(max(1, subjectMask.width - 1))
                let v = Float(y) / Float(max(1, subjectMask.height - 1))
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, v); maxV = max(maxV, v)
                found = true
            }
        }
        let subjectRect: CGRect
        if found {
            subjectRect = CGRect(
                x: CGFloat(minU) * CGFloat(imageWidth),
                y: CGFloat(minV) * CGFloat(imageHeight),
                width: CGFloat(maxU - minU) * CGFloat(imageWidth),
                height: CGFloat(maxV - minV) * CGFloat(imageHeight)
            ).intersection(imageRect)
        } else {
            subjectRect = imageRect
        }

        // Head: clamp into the image, keep a sane minimum size. `.intersection`
        // of disjoint rects yields the null rect (infinite coordinates), which
        // would trap in later Int() conversions — every clamp below must fall
        // back to a template rect instead of passing null through.
        var headRect = layout.headRect.intersection(imageRect)
        if headRect.isNull || headRect.width < 8 || headRect.height < 8 {
            headRect = CGRect(
                x: subjectRect.minX + subjectRect.width * 0.2,
                y: subjectRect.minY,
                width: subjectRect.width * 0.6,
                height: subjectRect.height * 0.45
            )
        }

        // A reviewer draws rectangles, and may leave the chin or hairline just
        // outside the box. Treat the box as an ROI: extend only toward nearby
        // anatomy implied by the confirmed eyes/mouth. Extra pixels are safe
        // because LayerFactory later intersects the curved ownership profile
        // with the real subject mask.
        let eyeY = (layout.eyeLeftRect.midY + layout.eyeRightRect.midY) / 2
        let eyeAxisX = (layout.eyeLeftRect.midX + layout.eyeRightRect.midX) / 2
        let eyeSeparation = abs(layout.eyeRightRect.midX - layout.eyeLeftRect.midX)
        let eyeToMouth = max(2, layout.mouthRect.midY - eyeY)
        let maximumXExtension = headRect.width * 0.10
        let maximumYExtension = headRect.height * 0.14
        let desiredHalfWidth = max(eyeSeparation * 1.05, layout.mouthRect.width * 2.0)
        let desiredTop = eyeY - max(eyeToMouth * 1.65, eyeSeparation * 0.62)
        let desiredBottom = layout.mouthRect.maxY + max(eyeToMouth * 0.68, headRect.height * 0.06)
        let expanded = CGRect(
            x: min(headRect.minX, max(headRect.minX - maximumXExtension, eyeAxisX - desiredHalfWidth)),
            y: min(headRect.minY, max(headRect.minY - maximumYExtension, desiredTop)),
            width: 0,
            height: 0
        )
        let expandedMaxX = max(
            headRect.maxX,
            min(headRect.maxX + maximumXExtension, eyeAxisX + desiredHalfWidth)
        )
        let expandedMaxY = max(
            headRect.maxY,
            min(headRect.maxY + maximumYExtension, desiredBottom)
        )
        headRect = CGRect(
            x: expanded.minX,
            y: expanded.minY,
            width: expandedMaxX - expanded.minX,
            height: expandedMaxY - expanded.minY
        ).intersection(imageRect)

        // Features must stay inside the head cut so they inherit its motion
        // without poking past the layer edge.
        let featureBounds = headRect.insetBy(dx: headRect.width * 0.02, dy: headRect.height * 0.02)

        func padded(
            _ rect: CGRect,
            x: CGFloat,
            y: CGFloat,
            fallback: CGRect
        ) -> CGRect {
            let clamped = rect
                .insetBy(dx: -rect.width * x, dy: -rect.height * y)
                .intersection(featureBounds)
            if clamped.isNull || clamped.width < 2 || clamped.height < 2 {
                return fallback.intersection(imageRect)
            }
            return clamped
        }

        func templateEye(offset: CGFloat) -> CGRect {
            CGRect(
                x: headRect.midX + offset * headRect.width - headRect.width * 0.11,
                y: headRect.minY + headRect.height * 0.52,
                width: headRect.width * 0.22,
                height: headRect.height * 0.13
            )
        }
        let templateMouth = CGRect(
            x: headRect.midX - headRect.width * 0.10,
            y: headRect.minY + headRect.height * 0.80,
            width: headRect.width * 0.20,
            height: headRect.height * 0.09
        )

        let eyeLeft = padded(layout.eyeLeftRect, x: 0.18, y: 0.22, fallback: templateEye(offset: -0.19))
        let eyeRight = padded(layout.eyeRightRect, x: 0.18, y: 0.22, fallback: templateEye(offset: 0.19))
        let mouth = padded(layout.mouthRect, x: 0.3, y: 0.35, fallback: templateMouth)

        return PartPlan(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            subjectRect: subjectRect,
            headRect: headRect,
            eyeLeftRect: eyeLeft,
            eyeRightRect: eyeRight,
            mouthRect: mouth,
            collarHeight: headRect.height * 0.14,
            eyeLeftLandmarks: layout.eyeLeftLandmarks,
            eyeRightLandmarks: layout.eyeRightLandmarks
        )
    }
}
