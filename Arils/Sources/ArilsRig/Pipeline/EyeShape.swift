import CoreGraphics
import Foundation

/// A soft, eye-shaped outline for the eye unit (lid line, lashes, iris),
/// built from the six eyelid landmarks of the anime landmark model.
///
/// Eye layers used to be the padded eye *rectangle* with feathered sides, so
/// every gaze or blink moved a rectangle of skin and hair along with the eye.
/// The landmarks sit on the visible eye opening (three on the upper lid,
/// three on the lower), which is reliable and smaller than the eye unit; the
/// outline grows from them by margins proportional to the eye's width —
/// most above (lashes), least below — and is smoothed into a closed curve.
///
/// Two regions come out of it, and their order matters: the cut-out alpha
/// fades across a band centred on the outline, and the hole the head layer
/// repaints lies strictly inside the fully opaque part, so at rest the eye
/// layer covers the repaint and the original pixels show everywhere else.
public struct EyeShape: Sendable, Equatable {
    /// Closed outline in source pixels.
    public var outline: [CGPoint]
    /// Width of the alpha transition across the outline, in pixels.
    public var feather: CGFloat

    // Margins as fractions of the landmark eye width.
    static let topMargin: CGFloat = 0.24
    static let sideMargin: CGFloat = 0.18
    static let bottomMargin: CGFloat = 0.12
    static let featherFraction: CGFloat = 0.08

    /// `landmarks`: upper lid (3) then lower lid (3), any left-right order.
    /// Nil when there are not six finite points or they span no width.
    public init?(landmarks: [CGPoint]) {
        guard landmarks.count == 6, landmarks.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let upper = landmarks[0..<3].sorted { $0.x < $1.x }
        let lower = landmarks[3..<6].sorted { $0.x < $1.x }
        let minX = landmarks.map(\.x).min()!
        let maxX = landmarks.map(\.x).max()!
        let width = maxX - minX
        guard width > 2 else { return nil }

        let top = Self.topMargin * width
        let side = Self.sideMargin * width
        let bottom = Self.bottomMargin * width
        let leftCorner = CGPoint(x: (upper[0].x + lower[0].x) / 2 - side, y: (upper[0].y + lower[0].y) / 2)
        let rightCorner = CGPoint(x: (upper[2].x + lower[2].x) / 2 + side, y: (upper[2].y + lower[2].y) / 2)
        let controls = [
            leftCorner,
            CGPoint(x: upper[0].x - side * 0.4, y: upper[0].y - top * 0.7),
            CGPoint(x: upper[1].x, y: upper[1].y - top),
            CGPoint(x: upper[2].x + side * 0.4, y: upper[2].y - top * 0.7),
            rightCorner,
            CGPoint(x: lower[2].x + side * 0.3, y: lower[2].y + bottom * 0.7),
            CGPoint(x: lower[1].x, y: lower[1].y + bottom),
            CGPoint(x: lower[0].x - side * 0.3, y: lower[0].y + bottom * 0.7),
        ]
        self.outline = Self.closedCatmullRom(controls, samplesPerSegment: 10)
        self.feather = max(1.5, Self.featherFraction * width)
    }

    public init(outline: [CGPoint], feather: CGFloat) {
        self.outline = outline
        self.feather = feather
    }

    public var bounds: CGRect {
        var rect = CGRect.null
        for point in outline { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }

    /// Alpha of the cut-out at a source pixel centre: 1 well inside, 0.5 on
    /// the outline, 0 one half-feather outside.
    public func coverage(x: CGFloat, y: CGFloat) -> Float {
        let d = signedDistance(x: x, y: y)
        let t = Float(min(max((d + feather / 2) / feather, 0), 1))
        return t * t * (3 - 2 * t)
    }

    /// Whether the head layer should repaint this pixel: only where the eye
    /// layer is fully opaque.
    public func holeContains(x: CGFloat, y: CGFloat) -> Bool {
        signedDistance(x: x, y: y) >= feather / 2
    }

    /// Distance to the outline, positive inside.
    func signedDistance(x: CGFloat, y: CGFloat) -> CGFloat {
        var nearest = CGFloat.greatestFiniteMagnitude
        var inside = false
        var j = outline.count - 1
        for i in 0..<outline.count {
            let a = outline[j]
            let b = outline[i]
            if (b.y > y) != (a.y > y), x < (a.x - b.x) * (y - b.y) / (a.y - b.y) + b.x {
                inside.toggle()
            }
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            var t: CGFloat = 0
            if lengthSquared > 0 {
                t = min(max(((x - a.x) * ab.x + (y - a.y) * ab.y) / lengthSquared, 0), 1)
            }
            let dx = x - (a.x + ab.x * t)
            let dy = y - (a.y + ab.y * t)
            nearest = min(nearest, dx * dx + dy * dy)
            j = i
        }
        let distance = nearest.squareRoot()
        return inside ? distance : -distance
    }

    /// Uniform Catmull-Rom spline through `points`, closed.
    static func closedCatmullRom(_ points: [CGPoint], samplesPerSegment: Int) -> [CGPoint] {
        let count = points.count
        var result: [CGPoint] = []
        result.reserveCapacity(count * samplesPerSegment)
        for i in 0..<count {
            let p0 = points[(i - 1 + count) % count]
            let p1 = points[i]
            let p2 = points[(i + 1) % count]
            let p3 = points[(i + 2) % count]
            for step in 0..<samplesPerSegment {
                let t = CGFloat(step) / CGFloat(samplesPerSegment)
                let t2 = t * t
                let t3 = t2 * t
                func blend(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                result.append(CGPoint(
                    x: blend(p0.x, p1.x, p2.x, p3.x),
                    y: blend(p0.y, p1.y, p2.y, p3.y)
                ))
            }
        }
        return result
    }

    /// The shape for a planned eye rect, or nil when the landmarks do not
    /// describe that rect any more (a person moved it in review, or the
    /// layout came from an estimator without landmarks).
    static func shape(landmarks: [CGPoint], within rect: CGRect) -> EyeShape? {
        guard let shape = EyeShape(landmarks: landmarks) else { return nil }
        let slack = rect.insetBy(dx: -2, dy: -2)
        guard shape.outline.allSatisfy({ slack.contains($0) }) else { return nil }
        return shape
    }
}
