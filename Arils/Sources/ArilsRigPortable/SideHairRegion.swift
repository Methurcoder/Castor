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
    /// to the body, measured from the finished rig and scaled per vertex by
    /// `SideHairRegion.followWeight`, so the player needs no new operation.
    static func sideHairPart(rig: AvatarRig, plan: PartPlan, rect: CGRect) -> AvatarPart? {
        guard let head = rig.firstPart(ofKind: .head),
              let body = rig.parts.first(where: { $0.id == head.parentID }),
              head.mesh.columns > 0, head.mesh.rows > 0,
              head.mesh.vertexCount == (head.mesh.columns + 1) * (head.mesh.rows + 1) else { return nil }
        let mesh = DeformableMesh.grid(rect: rect, columns: 16, rows: 12)
        let weights = mesh.vertices.map { SideHairRegion.followWeight(at: $0, plan: plan) }
        let evaluator = DeformationEvaluator3D(rig: rig)
        let descriptors = Dictionary(rig.parameters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let defaults = descriptors.mapValues(\.defaultValue)
        let headColumns = head.mesh.columns + 1
        let upperRows = Int(Float(head.mesh.rows) * 0.75)

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

            func edge(column: Int, y: Float) -> (rest: SIMD2<Float>, moved: SIMD2<Float>) {
                let rows = head.mesh.rows
                let top = head.mesh.vertices[column].y
                let bottom = head.mesh.vertices[rows * headColumns + column].y
                let t = min(max((y - top) / max(1, bottom - top), 0), 1) * Float(rows)
                let row = min(Int(t), rows - 1)
                let f = t - Float(row)
                let a = row * headColumns + column, b = (row + 1) * headColumns + column
                let rest = head.mesh.vertices[a] + (head.mesh.vertices[b] - head.mesh.vertices[a]) * f
                return (rest, local[a] + (local[b] - local[a]) * f)
            }

            return zip(mesh.vertices, weights).map { point, weight in
                guard weight > 0.001 else { return .zero }
                let column = point.x < Float(head.rect.midX) ? 0 : head.mesh.columns
                let (rest, moved) = edge(column: column, y: point.y)
                // The edge's own motion, carried outward with the head's
                // rotation and scale so the hair stays attached to the box.
                let follow = moved + headMotion.linear(point - rest) - point
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

        return AvatarPart(
            id: SideHairRegion.partID,
            kind: .hairBack,
            parentID: body.id,
            rect: rect,
            pivot: SIMD2(0.5, 0.5),
            zOrder: 8,
            mesh: mesh,
            deformations: [
                .warpKeyform(parameterX: .angleX, parameterY: .angleZ, keys: keys(.angleX, .angleZ)),
                .warpKeyform(parameterX: .angleY, parameterY: .touchSquash, keys: keys(.angleY, .touchSquash)),
            ]
        )
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
