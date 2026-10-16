#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Hair hanging beside the head box, cut as its own layer. Its roots follow the
/// head and its lower part stays with the body, so a head tilt or turn no longer
/// splits the hair at the box edge.
///
/// Without a hair segmentation model, "hair" is what touches the head box from
/// outside: above the mouth any subject pixel connected to the box edge (side
/// hair, ribbons, hair ornaments), below it only pixels close to the crown's
/// hair colour, so shoulders and clothing stay on the body.
public struct SideHairRegion: Sendable {
    public static let partID = "hairSide"

    /// Image-space bounds of the layer, aligned to whole pixels.
    public var rect: CGRect
    /// rect-sized ownership in 0...1.
    public var ownership: FloatPlane

    private static func length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }

    static func reach(_ plan: PartPlan) -> CGFloat { plan.headRect.width * 0.4 }

    static func bottomY(_ plan: PartPlan) -> CGFloat { plan.neckY + plan.headRect.height * 0.5 }

    /// How much of the head's motion a point beside the head follows: all of it
    /// down to the mouth, fading to none at the shoulders and toward the
    /// region's outer edge.
    public static func followWeight(at point: SIMD2<Float>, plan: PartPlan) -> Float {
        let head = plan.headRect
        let reach = Float(reach(plan))
        let vertical = 1 - Interpolation.smoothstep(Float(plan.mouthRect.maxY), Float(bottomY(plan)), point.y)
        let outside = max(Float(head.minX) - point.x, point.x - Float(head.maxX), 0)
        let horizontal = 1 - Interpolation.smoothstep(reach * 0.6, reach, outside)
        return vertical * horizontal
    }

    public static func detect(source: Bitmap, plan: PartPlan, mask: (Int, Int) -> Float) -> SideHairRegion? {
        let head = plan.headRect
        let reach = reach(plan)
        let minX = max(0, Int((head.minX - reach).rounded(.down)))
        let maxX = min(source.width, Int((head.maxX + reach).rounded(.up)))
        let minY = max(0, Int(head.minY.rounded(.down)))
        let maxY = min(source.height, Int(bottomY(plan).rounded(.up)))
        let headMinX = Int(head.minX.rounded(.down))
        let headMaxX = Int(head.maxX.rounded(.up))
        guard maxX > minX, maxY > minY, headMinX > minX || headMaxX < maxX else { return nil }
        let width = maxX - minX
        let height = maxY - minY

        func color(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            let pixel = source.rgba(x: x, y: y)
            guard pixel.w > 0.5, mask(x, y) > 0.5 else { return nil }
            return SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
        }

        // The crown's hair colour, sampled over the middle of the head top.
        var samples: [SIMD3<Float>] = []
        let crownBottom = Int(head.minY + head.height * 0.25)
        for y in stride(from: minY, to: min(crownBottom, source.height), by: 2) {
            for x in stride(from: Int(head.minX + head.width * 0.2), to: Int(head.maxX - head.width * 0.2), by: 2) {
                if let sample = color(x, y) { samples.append(sample) }
            }
        }
        guard samples.count >= 8 else { return nil }
        let mean = samples.reduce(SIMD3<Float>.zero, +) / Float(samples.count)
        let spread = samples.map { length($0 - mean) }.sorted()
        let tolerance = min(0.35, max(0.1, spread[spread.count * 9 / 10] * 1.5))

        let mouthY = Int(plan.mouthRect.maxY)
        // The head's ownership feathers out over a few columns inside its box;
        // the side hair takes over exactly what the head leaves there.
        let headProfile = HeadRegionProfile(plan: plan)
        let seam = Int(headProfile.horizontalFeather.rounded(.up)) + 1
        func isCandidate(_ x: Int, _ y: Int) -> Bool {
            guard x < headMinX + seam || x >= headMaxX - seam, let value = color(x, y) else { return false }
            return y < mouthY || length(value - mean) <= tolerance
        }

        // Grow from the pixels touching the head box edges.
        var owned = [Bool](repeating: false, count: width * height)
        var queue: [(Int, Int)] = []
        let seedBottom = min(maxY, Int(plan.neckY))
        for y in minY..<seedBottom {
            for x in [headMinX, headMaxX - 1] where x >= minX && x < maxX && isCandidate(x, y) {
                owned[(y - minY) * width + (x - minX)] = true
                queue.append((x, y))
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let (x, y) = queue[cursor]
            cursor += 1
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= minX && nx < maxX && ny >= minY && ny < maxY {
                let index = (ny - minY) * width + (nx - minX)
                guard !owned[index], isCandidate(nx, ny) else { continue }
                owned[index] = true
                queue.append((nx, ny))
            }
        }
        guard queue.count > 16 else { return nil }

        // Soften the cut where the hair meets the rest of the subject (not the
        // background, where a soft edge would leave a faint outline behind),
        // then fade it out where the head's motion no longer reaches.
        var subject = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width { subject[y * width + x] = mask(minX + x, minY + y) > 0.5 }
        }
        var ownership = FloatPlane(width: width, height: height)
        let radius = 2
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                var count: Float = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let sx = x + dx, sy = y + dy
                        guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                        let index = sy * width + sx
                        guard owned[index] || subject[index] else { continue }
                        sum += owned[index] ? 1 : 0
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let imageX = minX + x
                let point = SIMD2(Float(imageX) + 0.5, Float(minY + y) + 0.5)
                let reachFade = Interpolation.smoothstep(0, 0.05, followWeight(at: point, plan: plan))
                let headShare = headProfile.ownershipWeight(x: CGFloat(imageX), y: CGFloat(minY + y))
                ownership[x, y] = sum / count * reachFade * (1 - headShare)
            }
        }
        return SideHairRegion(
            rect: CGRect(x: minX, y: minY, width: width, height: height),
            ownership: ownership
        )
    }

    /// A copy of `source` whose `region` is replaced by an opaque box blur of
    /// the subject alone (background pixels carry no weight).
    static func subjectBlur(_ source: Bitmap, region: CGRect, radius: Int, mask: (Int, Int) -> Float) -> Bitmap {
        var result = source
        let minX = max(0, Int(region.minX)), maxX = min(source.width, Int(region.maxX.rounded(.up)))
        let minY = max(0, Int(region.minY)), maxY = min(source.height, Int(region.maxY.rounded(.up)))
        guard maxX > minX, maxY > minY, radius > 0 else { return result }
        // Blur over a margin so the region's edge still sees its neighbours.
        let x0 = max(0, minX - radius), x1 = min(source.width, maxX + radius)
        let y0 = max(0, minY - radius), y1 = min(source.height, maxY + radius)
        let width = x1 - x0, height = y1 - y0
        var weighted = [SIMD4<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = source.rgba(x: x0 + x, y: y0 + y)
                let weight = min(max(mask(x0 + x, y0 + y), 0), 1) * (pixel.w > 0.02 ? 1 : 0)
                guard weight > 0 else { continue }
                weighted[y * width + x] = SIMD4(pixel.x / pixel.w, pixel.y / pixel.w, pixel.z / pixel.w, 1) * weight
            }
        }
        // Two separable running-sum box passes (close to a Gaussian, so fine
        // stripes do not survive as ripples); w carries the total weight.
        func boxPass(_ values: [SIMD4<Float>]) -> [SIMD4<Float>] {
            var horizontal = [SIMD4<Float>](repeating: .zero, count: width * height)
            for y in 0..<height {
                var sum = SIMD4<Float>.zero
                for x in 0..<min(radius, width) { sum += values[y * width + x] }
                for x in 0..<width {
                    if x + radius < width { sum += values[y * width + x + radius] }
                    if x - radius - 1 >= 0 { sum -= values[y * width + x - radius - 1] }
                    horizontal[y * width + x] = sum
                }
            }
            var vertical = [SIMD4<Float>](repeating: .zero, count: width * height)
            for x in 0..<width {
                var sum = SIMD4<Float>.zero
                for y in 0..<min(radius, height) { sum += horizontal[y * width + x] }
                for y in 0..<height {
                    if y + radius < height { sum += horizontal[(y + radius) * width + x] }
                    if y - radius - 1 >= 0 { sum -= horizontal[(y - radius - 1) * width + x] }
                    vertical[y * width + x] = sum
                }
            }
            return vertical
        }
        let blurred = boxPass(boxPass(weighted))
        for y in (minY - y0)..<(maxY - y0) {
            for x in (minX - x0)..<(maxX - x0) {
                let sum = blurred[y * width + x]
                result.setRGBA(
                    x: x0 + x, y: y0 + y,
                    sum.w > 0.001 ? SIMD4(sum.x / sum.w, sum.y / sum.w, sum.z / sum.w, 1) : .zero
                )
            }
        }
        return result
    }

    /// Low-frequency copy of the region left on the body, so moving hair
    /// reveals blurred hair rather than a sharp duplicate of itself.
    static func blurredBacking(_ body: Bitmap, region: CGRect, radius: Int) -> Bitmap {
        var result = body
        let minX = max(0, Int(region.minX)), maxX = min(body.width, Int(region.maxX))
        let minY = max(0, Int(region.minY)), maxY = min(body.height, Int(region.maxY))
        guard maxX > minX, maxY > minY, radius > 0 else { return result }
        let width = maxX - minX, height = maxY - minY
        var horizontal = [SIMD4<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD4<Float>.zero
                var count: Float = 0
                for dx in -radius...radius {
                    let sx = minX + x + dx
                    guard sx >= 0, sx < body.width else { continue }
                    sum += body.rgba(x: sx, y: minY + y)
                    count += 1
                }
                horizontal[y * width + x] = sum / count
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD4<Float>.zero
                var count: Float = 0
                for dy in -radius...radius {
                    let sy = y + dy
                    guard sy >= 0, sy < height else { continue }
                    sum += horizontal[sy * width + x]
                    count += 1
                }
                let blurred = sum / count
                let original = body.rgba(x: minX + x, y: minY + y)
                // Keep the original coverage: the blur only replaces colour.
                let alpha = original.w
                let colour = blurred.w > 0.001 ? blurred / blurred.w * alpha : original
                result.setRGBA(x: minX + x, y: minY + y, SIMD4(colour.x, colour.y, colour.z, alpha))
            }
        }
        return result
    }
}

public extension BindingSynthesizer {
    /// The side hair part. Its keyforms replay the head's own motion relative
    /// to the body (see `headFollowKeyforms`), so the player needs no new
    /// operation.
    static func sideHairPart(rig: AvatarRig, plan: PartPlan, rect: CGRect) -> AvatarPart? {
        guard let body = rig.firstPart(ofKind: .head).flatMap({ head in rig.parts.first { $0.id == head.parentID } }) else { return nil }
        let mesh = DeformableMesh.grid(rect: rect, columns: 16, rows: 12)
        let weights = mesh.vertices.map { SideHairRegion.followWeight(at: $0, plan: plan) }
        guard let keyforms = headFollowKeyforms(rig: rig, mesh: mesh, weights: weights) else { return nil }
        return AvatarPart(
            id: SideHairRegion.partID,
            kind: .hairBack,
            parentID: body.id,
            rect: rect,
            pivot: SIMD2(0.5, 0.5),
            zOrder: 8,
            mesh: mesh,
            deformations: keyforms
        )
    }

    /// Warp keyforms that move a body-frame mesh with the head, scaled per
    /// vertex by `weights`, measured by evaluating the finished rig. A vertex
    /// follows the nearest point of the head: beside the head it also turns
    /// with it, so hair stays attached to the box edge; below the head it only
    /// shifts with the neck, so shoulders do not swing the opposite way.
    static func headFollowKeyforms(rig: AvatarRig, mesh: DeformableMesh, weights: [Float]) -> [DeformationOp]? {
        guard let head = rig.firstPart(ofKind: .head),
              let body = rig.parts.first(where: { $0.id == head.parentID }),
              head.mesh.columns > 0, head.mesh.rows > 0, weights.count == mesh.vertexCount,
              head.mesh.vertexCount == (head.mesh.columns + 1) * (head.mesh.rows + 1) else { return nil }
        let evaluator = DeformationEvaluator3D(rig: rig)
        let descriptors = Dictionary(rig.parameters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let defaults = descriptors.mapValues(\.defaultValue)
        let headColumns = head.mesh.columns + 1
        let upperRows = Int(Float(head.mesh.rows) * 0.75)
        let headRect = head.rect

        func offsets(_ overrides: [ParameterID: Float]) -> [SIMD2<Float>] {
            var parameters = defaults
            for (id, value) in overrides { parameters[id] = value }
            let evaluated = evaluator.evaluate(parameters: parameters)
            guard let headNow = evaluated[head.id], let bodyNow = evaluated[body.id],
                  headNow.count == head.mesh.vertexCount, bodyNow.count == body.mesh.vertexCount,
                  let bodyMotion = AffineFit(from: body.mesh.vertices, to: bodyNow.map { SIMD2($0.x, $0.y) }),
                  let toBody = bodyMotion.inverse else {
                return Array(repeating: .zero, count: mesh.vertexCount)
            }
            // The head's motion in the body's frame, which is where keyform
            // offsets apply.
            let local = headNow.map { toBody.apply(SIMD2($0.x, $0.y)) }
            let upper = (0..<(upperRows + 1) * headColumns)
            guard let headMotion = AffineFit(
                from: upper.map { head.mesh.vertices[$0] },
                to: upper.map { local[$0] }
            ) else { return Array(repeating: .zero, count: mesh.vertexCount) }

            /// Where the head grid point at `anchor` (inside the head rect) moved to.
            func moved(_ anchor: SIMD2<Float>) -> SIMD2<Float> {
                let u = min(max((anchor.x - Float(headRect.minX)) / Float(max(1, headRect.width)), 0), 1) * Float(head.mesh.columns)
                let v = min(max((anchor.y - Float(headRect.minY)) / Float(max(1, headRect.height)), 0), 1) * Float(head.mesh.rows)
                let column = min(Int(u), head.mesh.columns - 1), row = min(Int(v), head.mesh.rows - 1)
                let fu = u - Float(column), fv = v - Float(row)
                let a = row * headColumns + column
                func displaced(_ index: Int) -> SIMD2<Float> { local[index] - head.mesh.vertices[index] }
                let top = displaced(a) + (displaced(a + 1) - displaced(a)) * fu
                let bottom = displaced(a + headColumns) + (displaced(a + headColumns + 1) - displaced(a + headColumns)) * fu
                return anchor + top + (bottom - top) * fv
            }

            return zip(mesh.vertices, weights).map { point, weight in
                guard weight > 0.001 else { return .zero }
                let anchor = SIMD2(
                    min(max(point.x, Float(headRect.minX)), Float(headRect.maxX)),
                    min(max(point.y, Float(headRect.minY)), Float(headRect.maxY))
                )
                var follow = moved(anchor) - anchor
                if point.y <= Float(headRect.maxY) {
                    follow += headMotion.linear(point - anchor) - (point - anchor)
                }
                return follow * weight
            }
        }

        func values(_ id: ParameterID) -> [Float] {
            guard let descriptor = descriptors[id], descriptor.maximum > descriptor.minimum else { return [] }
            return (0...4).map { descriptor.minimum + (descriptor.maximum - descriptor.minimum) * Float($0) / 4 }
                + [descriptor.defaultValue]
        }
        func keys(_ x: ParameterID, _ y: ParameterID) -> [WarpKeyformKey] {
            let xs = Array(Set(values(x))).sorted(), ys = Array(Set(values(y))).sorted()
            return xs.flatMap { vx in
                ys.map { vy in
                    WarpKeyformKey(parameterXValue: vx, parameterYValue: vy, vertexOffsets: offsets([x: vx, y: vy]))
                }
            }
        }
        return [
            .warpKeyform(parameterX: .angleX, parameterY: .angleZ, keys: keys(.angleX, .angleZ)),
            .warpKeyform(parameterX: .angleY, parameterY: .touchSquash, keys: keys(.angleY, .touchSquash)),
        ]
    }
}

/// Least-squares 2D affine map, in plain floats so it builds without simd.
struct AffineFit {
    // [a b; c d] * p + t
    var a: Float, b: Float, c: Float, d: Float
    var t: SIMD2<Float>

    init(a: Float, b: Float, c: Float, d: Float, t: SIMD2<Float>) {
        self.a = a; self.b = b; self.c = c; self.d = d
        self.t = t
    }

    init?(from source: [SIMD2<Float>], to target: [SIMD2<Float>]) {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let count = Float(source.count)
        let sourceMean = source.reduce(.zero, +) / count
        let targetMean = target.reduce(.zero, +) / count
        var sxx: Float = 0, sxy: Float = 0, syy: Float = 0
        var qxpx: Float = 0, qxpy: Float = 0, qypx: Float = 0, qypy: Float = 0
        for (p, q) in zip(source, target) {
            let ps = p - sourceMean, qs = q - targetMean
            sxx += ps.x * ps.x; sxy += ps.x * ps.y; syy += ps.y * ps.y
            qxpx += qs.x * ps.x; qxpy += qs.x * ps.y
            qypx += qs.y * ps.x; qypy += qs.y * ps.y
        }
        let determinant = sxx * syy - sxy * sxy
        guard abs(determinant) > 1e-6 else { return nil }
        // [qxpx qxpy; qypx qypy] * inverse([sxx sxy; sxy syy])
        let i11 = syy / determinant, i12 = -sxy / determinant, i22 = sxx / determinant
        a = qxpx * i11 + qxpy * i12
        b = qxpx * i12 + qxpy * i22
        c = qypx * i11 + qypy * i12
        d = qypx * i12 + qypy * i22
        t = .zero
        t = targetMean - linear(sourceMean)
    }

    var inverse: AffineFit? {
        let determinant = a * d - b * c
        guard abs(determinant) > 1e-8 else { return nil }
        var result = AffineFit(a: d / determinant, b: -b / determinant, c: -c / determinant, d: a / determinant, t: .zero)
        result.t = -result.linear(t)
        return result
    }

    func linear(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(a * v.x + b * v.y, c * v.x + d * v.y) }

    func apply(_ point: SIMD2<Float>) -> SIMD2<Float> { linear(point) + t }
}

/// Approximate distance (chamfer 3-4) from each pixel of a rect to the nearest
/// background pixel, treating everything outside the rect as unknown.
struct BackgroundDistance {
    private let minX: Int, minY: Int, width: Int, height: Int
    private var values: [Float]

    init(rect: CGRect, mask: (Int, Int) -> Float) {
        minX = Int(rect.minX); minY = Int(rect.minY)
        width = max(0, Int(rect.maxX) - minX); height = max(0, Int(rect.maxY) - minY)
        let far = Float(width + height) * 3
        values = [Float](repeating: far, count: width * height)
        // Only open background reachable from the rect border counts: gaps
        // between strands are not something the moving hair uncovers.
        var queue: [Int] = []
        var clear = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width { clear[y * width + x] = mask(minX + x, minY + y) < 0.5 }
        }
        let gap = 3
        var rowOpen = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                rowOpen[y * width + x] = (max(0, x - gap)...min(width - 1, x + gap)).allSatisfy { clear[y * width + $0] }
            }
        }
        var isBackground = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard (max(0, y - gap)...min(height - 1, y + gap)).allSatisfy({ rowOpen[$0 * width + x] }) else { continue }
                isBackground[y * width + x] = true
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                    values[y * width + x] = 0
                    queue.append(y * width + x)
                }
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width, y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let next = ny * width + nx
                guard isBackground[next], values[next] != 0 else { continue }
                values[next] = 0
                queue.append(next)
            }
        }
        func relax(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ cost: Float) {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { return }
            let candidate = values[ny * width + nx] + cost
            if candidate < values[y * width + x] { values[y * width + x] = candidate }
        }
        for y in 0..<height {
            for x in 0..<width {
                relax(x, y, -1, 0, 3); relax(x, y, 0, -1, 3); relax(x, y, -1, -1, 4); relax(x, y, 1, -1, 4)
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                relax(x, y, 1, 0, 3); relax(x, y, 0, 1, 3); relax(x, y, 1, 1, 4); relax(x, y, -1, 1, 4)
            }
        }
        values = values.map { $0 / 3 }
    }

    subscript(x: Int, y: Int) -> Float {
        let lx = x - minX, ly = y - minY
        guard lx >= 0, lx < width, ly >= 0, ly < height else { return .infinity }
        return values[ly * width + lx]
    }
}

extension SideHairRegion {
    /// The hairSide layer cut from `source`. `body`, whose first pixel is the
    /// image pixel `bodyOrigin`, keeps exactly what the layer does not cover
    /// at rest, so translucent hair or a veil does not double up; under opaque
    /// hair that remainder is empty and a blurred copy fills in for when the
    /// hair moves away.
    func cut(source: Bitmap, body: inout Bitmap, bodyOrigin: (x: Int, y: Int), plan: PartPlan) -> Bitmap {
        var layer = source.cropped(to: rect)
        let originX = Int(rect.minX), originY = Int(rect.minY)
        for y in 0..<layer.height {
            for x in 0..<layer.width {
                let share = ownership[x, y]
                if share <= 0.001 {
                    layer.setRGBA(x: x, y: y, .zero)
                } else if share < 1 {
                    layer.scaleAlpha(x: x, y: y, by: share)
                }
            }
        }
        let blurred = Self.blurredBacking(
            body,
            region: rect.offsetBy(dx: -CGFloat(bodyOrigin.x), dy: -CGFloat(bodyOrigin.y)),
            radius: max(3, Int(plan.headRect.width * 0.03))
        )
        for y in 0..<layer.height {
            for x in 0..<layer.width {
                let bodyX = originX + x - bodyOrigin.x, bodyY = originY + y - bodyOrigin.y
                guard ownership[x, y] > 0.001, bodyX >= 0, bodyX < body.width, bodyY >= 0, bodyY < body.height else { continue }
                let original = body.rgba(x: bodyX, y: bodyY)
                let front = layer.rgba(x: x, y: y)
                let remainder = (original - front) / max(0.02, 1 - front.w)
                let opaque = Interpolation.smoothstep(0.9, 0.98, front.w)
                let backing = remainder + (blurred.rgba(x: bodyX, y: bodyY) - remainder) * opaque
                body.setRGBA(x: bodyX, y: bodyY, simd_clamp(backing, SIMD4(repeating: 0), SIMD4(repeating: 1)))
            }
        }
        return layer
    }

    /// Clears backing that only background lies behind. Near the outline of
    /// the upper head, what the moving head (`headMoves`) and side hair
    /// uncover is the background, not more hair; a backing there reads as a
    /// grey ghost of the old outline, so it fades out within the distance they
    /// can move. From the eyes down the neck, hair and shoulders behind the
    /// face stay backed; behind side hair, background reaches to the mouth.
    static func clearBacking(body: inout Bitmap, bodyOrigin: (x: Int, y: Int), plan: PartPlan,
                             mask: (Int, Int) -> Float, headMoves: Bool, side: SideHairRegion?) {
        let width = plan.imageWidth, height = plan.imageHeight
        let headProfile = HeadRegionProfile(plan: plan)
        let envelope = HeadDisocclusionEnvelope.supported(plan: plan)
        let eyeY = Float(plan.eyeLeftRect.midY + plan.eyeRightRect.midY) / 2
        let ghostRect = plan.headRect
            .insetBy(dx: -reach(plan), dy: 0)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !ghostRect.isNull, !ghostRect.isEmpty else { return }
        let distanceRect = ghostRect.insetBy(dx: 0, dy: -plan.headRect.height * 0.2)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let backgroundDistance = BackgroundDistance(rect: distanceRect, mask: mask)
        let pivot = SIMD2(Float(plan.headRect.midX), Float(plan.neckY))
        let baseReach = max(envelope.horizontalOpaqueDepth, envelope.verticalOpaqueDepth)
        let minX = Int(ghostRect.minX), maxX = Int(ghostRect.maxX)
        let minY = Int(ghostRect.minY), maxY = min(Int(ghostRect.maxY), Int(plan.neckY))
        guard maxY > minY else { return }
        for sourceY in minY..<maxY {
            let headFade = headMoves ? 1 - Interpolation.smoothstep(eyeY, Float(plan.mouthRect.minY), Float(sourceY)) : 0
            let sideFade = side == nil ? 0 : 1 - Interpolation.smoothstep(Float(plan.mouthRect.maxY), Float(plan.neckY), Float(sourceY))
            guard headFade > 0 || sideFade > 0 else { continue }
            for sourceX in minX..<maxX {
                let x = sourceX - bodyOrigin.x, y = sourceY - bodyOrigin.y
                guard x >= 0, x < body.width, y >= 0, y < body.height, body.alpha(x: x, y: y) > 0 else { continue }
                let point = SIMD2(Float(sourceX) + 0.5, Float(sourceY) + 0.5)
                let headShare = headProfile.ownershipWeight(x: CGFloat(sourceX), y: CGFloat(sourceY))
                var sideShare: Float = 0
                var sideFollow: Float = 0
                if let side, side.rect.contains(CGPoint(x: sourceX, y: sourceY)) {
                    sideShare = side.ownership[sourceX - Int(side.rect.minX), sourceY - Int(side.rect.minY)]
                    sideFollow = sideShare * followWeight(at: point, plan: plan)
                }
                guard (headMoves && headShare > 0.001) || sideFollow > 0.001 else { continue }
                let offset = point - pivot
                let motion = baseReach + (offset * offset).sum().squareRoot() * 0.26
                func exposure(_ follow: Float, _ distance: Float) -> Float {
                    guard follow > 0.001 else { return 0 }
                    let travel = follow * motion
                    return 1 - Interpolation.smoothstep(travel * 0.7, travel, distance)
                }
                let distance = backgroundDistance[sourceX, sourceY]
                let exposed = max(
                    headMoves && headShare > 0.001 ? headFade * exposure(1, distance) : 0,
                    sideFade * exposure(sideFollow, distance)
                )
                // At rest the moving layers must still cover what is cleared.
                let uncovered = max(0, 1 - headShare - sideShare)
                let keep = max(uncovered, 1 - exposed)
                if keep < 0.999 { body.scaleAlpha(x: x, y: y, by: keep) }
            }
        }
    }
}

/// "More natural face motion" (beta): hair beside the head, the neck and the
/// shoulders beside it follow the head. It is
/// applied to a finished rig when a pet loads, so existing pets get it without
/// being made again and the setting can be switched at any time.
public enum FollowingHair {
    /// The rig and layers with the hairSide part added, or nil when the rig
    /// has no standard head/body pair or no side hair was found.
    public static func apply(rig: AvatarRig, layers: [String: Bitmap]) -> (rig: AvatarRig, layers: [String: Bitmap])? {
        guard rig.part(withID: SideHairRegion.partID) == nil,
              let head = rig.firstPart(ofKind: .head), let body = rig.parts.first(where: { $0.id == head.parentID }),
              let headLayer = layers[head.id], var bodyLayer = layers[body.id],
              let eyeLeft = rig.firstPart(ofKind: .eyeLeft), let eyeRight = rig.firstPart(ofKind: .eyeRight),
              let mouth = rig.firstPart(ofKind: .mouth),
              // Already applied: the body follows the head through keyforms.
              !body.deformations.contains(where: { if case .warpKeyform = $0 { true } else { false } }) else { return nil }
        let plan = PartPlan(
            imageWidth: rig.imageWidth, imageHeight: rig.imageHeight,
            subjectRect: body.rect, headRect: head.rect,
            eyeLeftRect: eyeLeft.rect, eyeRightRect: eyeRight.rect, mouthRect: mouth.rect,
            collarHeight: head.rect.height * 0.14
        )
        // The picture at rest, from the body with the head over it.
        let bodyOrigin = (x: max(0, Int(body.rect.minX)), y: max(0, Int(body.rect.minY)))
        let headOrigin = (x: max(0, Int(head.rect.minX)), y: max(0, Int(head.rect.minY)))
        var picture = Bitmap(width: rig.imageWidth, height: rig.imageHeight)
        for y in 0..<bodyLayer.height where bodyOrigin.y + y < picture.height {
            for x in 0..<bodyLayer.width where bodyOrigin.x + x < picture.width {
                picture.setRGBA(x: bodyOrigin.x + x, y: bodyOrigin.y + y, bodyLayer.rgba(x: x, y: y))
            }
        }
        for y in 0..<headLayer.height where headOrigin.y + y < picture.height {
            for x in 0..<headLayer.width where headOrigin.x + x < picture.width {
                let front = headLayer.rgba(x: x, y: y)
                let back = picture.rgba(x: headOrigin.x + x, y: headOrigin.y + y)
                picture.setRGBA(x: headOrigin.x + x, y: headOrigin.y + y, front + back * (1 - front.w))
            }
        }
        let mask: (Int, Int) -> Float = { x, y in
            x >= 0 && y >= 0 && x < picture.width && y < picture.height ? picture.alpha(x: x, y: y) : 0
        }
        var result = rig
        var resultLayers = layers
        var changed = false
        if let region = SideHairRegion.detect(source: picture, plan: plan, mask: mask),
           let part = BindingSynthesizer.sideHairPart(rig: rig, plan: plan, rect: region.rect) {
            let sideLayer = region.cut(source: picture, body: &bodyLayer, bodyOrigin: bodyOrigin, plan: plan)
            SideHairRegion.clearBacking(body: &bodyLayer, bodyOrigin: bodyOrigin, plan: plan, mask: mask, headMoves: false, side: region)
            result.parts.append(part)
            resultLayers[body.id] = bodyLayer
            resultLayers[part.id] = sideLayer
            changed = true
        }
        // The neck and the shoulders beside it follow the head with the same
        // fading weight, so the body moves with it instead of the head sliding
        // over a still neck. The body's grid is made finer there to bend
        // smoothly (flat rigs only; a depth rig keeps its sampled depths).
        for id in [body.id, "neckSeam"] {
            guard let index = result.parts.firstIndex(where: { $0.id == id }) else { continue }
            var part = result.parts[index]
            if id == body.id, part.mesh.depths.allSatisfy({ $0 == 0 }) {
                part.mesh = .grid(rect: part.rect, columns: 24, rows: 48)
            }
            let weights = part.mesh.vertices.map { SideHairRegion.followWeight(at: $0, plan: plan) }
            guard weights.contains(where: { $0 > 0.001 }),
                  let keyforms = BindingSynthesizer.headFollowKeyforms(rig: rig, mesh: part.mesh, weights: weights) else { continue }
            part.deformations += keyforms
            result.parts[index] = part
            changed = true
        }
        return changed ? (result, resultLayers) : nil
    }
}
