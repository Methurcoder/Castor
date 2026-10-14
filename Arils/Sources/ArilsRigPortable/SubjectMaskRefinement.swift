import Foundation
#if canImport(simd)
import simd
#endif

/// Fuses an estimated (Vision) subject mask with the image's own colors to
/// recover the true silhouette at the boundary.
///
/// Vision's foreground mask is a smooth, low-resolution blob: it decides
/// *where* the character is very reliably, but wraps flowing hair in a
/// rounded envelope that includes the background between strands. Cut with
/// that blob, the background between the strands stays opaque and the hair
/// grows a pale, ghostly halo (most visible on light hair over a light
/// background, placed on a dark desktop).
///
/// The refinement keeps Vision as the region prior and only lets the
/// background back in through a **band** just inside the blob's edge: a
/// flood starts from the background outside the blob and may only enter band
/// pixels whose color matches the background color it started from. Two
/// properties make it safe where a full-image flood is not:
///
/// - **bounded depth** — the flood can never travel deeper than the band, so
///   a background-colored garment or face can at worst lose a thin rim, never
///   be hollowed out (the failure that got a coverage-based arbiter
///   reverted; see `Arils/ROADMAP_POSE.md`, マスク品質);
/// - **local reference** — each flooded pixel is compared with the color of
///   the background pixel the flood came from, so gradients and scenic
///   backgrounds work, not just flat studio colors.
///
/// The result is accepted only if it removes a bounded share of the blob
/// and its boundary lies on image edges at least as well as Vision's did
/// (a correct silhouette follows the drawing's lines; a leak crosses flat
/// paint). Otherwise the original mask is returned unchanged.
public enum SubjectMaskBoundaryRefinement {
    public struct Options: Sendable, Equatable {
        /// Band depth as a fraction of the image diagonal.
        public var bandFraction: Float = 0.03
        /// Upper bound on the color distance (straight RGB, 0...1 per
        /// channel, Euclidean) within which a band pixel counts as the
        /// background it was reached from. The working tolerance is derived
        /// from how much the background itself varies near the subject; when
        /// that would exceed this bound the background is too busy to key
        /// and the refinement declines (Vision's mask is kept).
        public var colorTolerance: Float = 0.075
        /// Multiplier from the background's median neighbor difference to
        /// the adaptive key.
        public var noiseScale: Float = 4
        /// Lowest tolerance the adaptive key may use.
        public var minimumColorTolerance: Float = 0.025
        /// The flood never enters a pixel whose local color change reaches
        /// this — a drawn line is the subject's boundary, never background.
        public var edgeBarrier: Float = 0.05
        /// A removed region is kept only if at least this share of its
        /// boundary with the remaining subject lies on a visible edge.
        public var minimumRegionEdgeSupport: Float = 0.6
        /// Enclosed pockets (background seen through a closed loop of hair)
        /// are removed only when their color matches the background within
        /// this share of the working tolerance, they are flat inside, and
        /// drawn lines surround at least `pocketEdgeSupport` of them.
        /// Zero disables pocket removal.
        public var pocketColorShare: Float = 0.6
        public var pocketEdgeSupport: Float = 0.8
        /// Refinements that remove more than this share of the original
        /// subject are treated as leaks and rejected.
        public var maximumRemovedFraction: Float = 0.35
        /// Allowed drop in boundary edge alignment before rejecting.
        public var edgeAlignmentSlack: Float = 0.02

        public init() {}
    }

    public struct Result: Sendable {
        public var mask: FloatPlane
        /// Share of the original subject area that was returned to background.
        public var removedFraction: Float
        /// Fraction of boundary pixels lying on a visible image edge.
        public var edgeAlignmentBefore: Float
        public var edgeAlignmentAfter: Float
        public var accepted: Bool
        /// The adaptive color key actually used.
        public var tolerance: Float
    }

    public static func refine(
        _ mask: FloatPlane,
        image: Bitmap,
        options: Options = Options()
    ) -> Result {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2, mask.width == width, mask.height == height else {
            return Result(mask: mask, removedFraction: 0, edgeAlignmentBefore: 0, edgeAlignmentAfter: 0, accepted: false, tolerance: 0)
        }
        let count = width * height

        var colors = [SIMD3<Float>](repeating: .zero, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = image.rgba(x: x, y: y)
                colors[y * width + x] = pixel.w > 0.001
                    ? SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
                    : .zero
            }
        }

        var inside = [Bool](repeating: false, count: count)
        var insideCount = 0
        for index in 0..<count where mask.values[index] >= 0.5 {
            inside[index] = true
            insideCount += 1
        }
        guard insideCount > 0, insideCount < count else {
            return Result(mask: mask, removedFraction: 0, edgeAlignmentBefore: 0, edgeAlignmentAfter: 0, accepted: false, tolerance: 0)
        }

        // --- Band: inside pixels within `depth` steps of the outside --------
        let diagonal = Float(width * width + height * height).squareRoot()
        let depth = max(4, Int(options.bandFraction * diagonal))
        var distance = [Int32](repeating: Int32.max, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(count / 4)
        for index in 0..<count where !inside[index] {
            distance[index] = 0
            let x = index % width
            let y = index / width
            if (x > 0 && inside[index - 1]) || (x < width - 1 && inside[index + 1])
                || (y > 0 && inside[index - width]) || (y < height - 1 && inside[index + width]) {
                queue.append(index)
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let next = distance[index] + 1
            guard next <= Int32(depth) else { continue }
            forEachNeighbor(of: index, width: width, height: height) { neighbor in
                if inside[neighbor], distance[neighbor] > next {
                    distance[neighbor] = next
                    queue.append(neighbor)
                }
            }
        }

        let edges = edgeStrength(colors: colors, width: width, height: height)

        // --- Adaptive key: how much does the background vary by itself? ---
        // Median neighbor difference over the background just outside the
        // subject (within one band depth), scaled to a tolerance.
        var outsideRing = [Bool](repeating: false, count: count)
        queue.removeAll(keepingCapacity: true)
        for index in 0..<count where inside[index] {
            forEachNeighbor(of: index, width: width, height: height) { neighbor in
                if !inside[neighbor], !outsideRing[neighbor] {
                    outsideRing[neighbor] = true
                    queue.append(neighbor)
                }
            }
        }
        var ringDistance = [Int32](repeating: 0, count: count)
        cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let next = ringDistance[index] + 1
            guard next <= Int32(depth) else { continue }
            forEachNeighbor(of: index, width: width, height: height) { neighbor in
                if !inside[neighbor], !outsideRing[neighbor] {
                    outsideRing[neighbor] = true
                    ringDistance[neighbor] = next
                    queue.append(neighbor)
                }
            }
        }
        var ringEdges = queue.map { edges[$0] }
        ringEdges.sort()
        let backgroundNoise = ringEdges.isEmpty ? 0 : ringEdges[ringEdges.count / 2]
        let adaptiveTolerance = max(options.minimumColorTolerance, 0.015 + options.noiseScale * backgroundNoise)
        guard adaptiveTolerance <= options.colorTolerance else {
            // A busy, painted, or photographic background: color keying would
            // eat dark or textured parts of the character along with it.
            // Vision's region is the better answer there; leave it alone.
            return Result(
                mask: mask, removedFraction: 0, edgeAlignmentBefore: 0, edgeAlignmentAfter: 0,
                accepted: false, tolerance: adaptiveTolerance
            )
        }
        let tolerance = adaptiveTolerance
        let barrier = max(options.edgeBarrier, tolerance)

        // --- Flood from the background into background-colored band pixels --
        // Seeds sit a few pixels *outside* Vision's edge, so the reference is
        // surely background: right at the edge Vision often undercuts the
        // subject by a pixel or two, and seeding there would key the flood
        // on the character's own color (a flat coat would be hollowed out).
        let seedDepth: Int32 = 4
        var reached = [Bool](repeating: false, count: count)
        var reference = [SIMD3<Float>](repeating: .zero, count: count)
        queue.removeAll(keepingCapacity: true)
        for index in 0..<count where outsideRing[index] && ringDistance[index] >= seedDepth {
            reached[index] = true
            reference[index] = colors[index]
            queue.append(index)
        }
        cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let seed = reference[index]
            forEachNeighbor(of: index, width: width, height: height) { neighbor in
                guard !reached[neighbor] else { return }
                // Outside pixels are background already; only the color has
                // to agree (narrow openings between strands sit right next to
                // lines). Entering the subject additionally needs flat paint.
                let enterable = inside[neighbor]
                    ? distance[neighbor] <= Int32(depth) && edges[neighbor] < barrier
                    : outsideRing[neighbor] && ringDistance[neighbor] < seedDepth
                guard enterable,
                      simd_distance(colors[neighbor], seed) <= tolerance else { return }
                reached[neighbor] = true
                reference[neighbor] = seed
                queue.append(neighbor)
            }
        }
        var removed = [Bool](repeating: false, count: count)
        for index in 0..<count where reached[index] && inside[index] {
            removed[index] = true
        }

        // --- Per-region shape check -----------------------------------------
        // A real gap between strands is bounded by the drawing's lines: where
        // the flood stopped, the subject side shows a visible edge. A leak
        // into pale skin or cloth stops where the band or the color key ran
        // out, in flat paint. Regions whose inner boundary mostly lacks edges
        // are leaks; give them back to the subject.
        var label = [Int32](repeating: -1, count: count)
        var nextLabel: Int32 = 0
        for start in 0..<count where removed[start] && label[start] < 0 {
            var component = [start]
            label[start] = nextLabel
            var head = 0
            var interface = 0
            var lined = 0
            while head < component.count {
                let index = component[head]
                head += 1
                forEachNeighbor(of: index, width: width, height: height) { neighbor in
                    if removed[neighbor] {
                        if label[neighbor] < 0 {
                            label[neighbor] = nextLabel
                            component.append(neighbor)
                        }
                    } else if inside[neighbor] {
                        interface += 1
                        if edges[neighbor] >= options.edgeBarrier * 0.6
                            || simd_distance(colors[neighbor], reference[index]) >= 3 * tolerance {
                            lined += 1
                        }
                    }
                }
            }
            nextLabel += 1
            if interface > 0, Float(lined) / Float(interface) < options.minimumRegionEdgeSupport {
                for index in component { removed[index] = false }
            }
        }

        // --- Enclosed pockets ------------------------------------------------
        // Curly hair encloses background the outside flood can never reach.
        // Remove a pocket only if it is unmistakably that background: its
        // color sits within a fraction of the key of the background's own
        // color, it is as flat as the background, and lines surround it. A
        // white highlight is the risk here, so every test is strict.
        if options.pocketColorShare > 0 {
            var seedColors: [SIMD3<Float>] = []
            for index in 0..<count where outsideRing[index] && ringDistance[index] >= seedDepth {
                seedColors.append(colors[index])
            }
            if !seedColors.isEmpty {
                func median(_ values: [Float]) -> Float {
                    let sorted = values.sorted()
                    return sorted[sorted.count / 2]
                }
                let background = SIMD3(
                    median(seedColors.map(\.x)),
                    median(seedColors.map(\.y)),
                    median(seedColors.map(\.z))
                )
                let pocketTolerance = tolerance * options.pocketColorShare
                // Tiny pockets are invisible as halo but are where a white
                // knit rib or highlight can pass every color test; leave them.
                let minimumArea = max(24, count / 15_000)
                let maximumArea = max(minimumArea, insideCount / 250)
                var visited = [Bool](repeating: false, count: count)
                func isCandidate(_ index: Int) -> Bool {
                    inside[index] && !removed[index]
                        && distance[index] <= Int32(depth)
                        && edges[index] < barrier
                        && simd_distance(colors[index], background) <= pocketTolerance
                }
                for start in 0..<count where !visited[start] && isCandidate(start) {
                    var component = [start]
                    visited[start] = true
                    var head = 0
                    var interface = 0
                    var lined = 0
                    var tooLarge = false
                    while head < component.count {
                        let index = component[head]
                        head += 1
                        forEachNeighbor(of: index, width: width, height: height) { neighbor in
                            if isCandidate(neighbor) {
                                if !visited[neighbor] {
                                    visited[neighbor] = true
                                    component.append(neighbor)
                                }
                            } else if !removed[neighbor] {
                                interface += 1
                                if edges[neighbor] >= options.edgeBarrier * 0.6 { lined += 1 }
                            }
                        }
                        if component.count > maximumArea { tooLarge = true }
                    }
                    guard !tooLarge, component.count >= minimumArea, interface > 0,
                          Float(lined) / Float(interface) >= options.pocketEdgeSupport else { continue }
                    // As flat as the background: no shading inside.
                    var spread: Float = 0
                    for index in component {
                        spread = max(spread, simd_distance(colors[index], background))
                    }
                    guard spread <= pocketTolerance else { continue }
                    for index in component {
                        removed[index] = true
                        reference[index] = background
                    }
                }
            }
        }

        var removedCount = 0
        var refined = mask
        for index in 0..<count where removed[index] {
            refined.values[index] = 0
            removedCount += 1
        }
        // Soft rim: pixels touching the recovered background fade with their
        // similarity to it, so anti-aliased strand edges keep partial alpha.
        for index in 0..<count where inside[index] && !removed[index] && distance[index] <= Int32(depth) {
            var nearest = Float.greatestFiniteMagnitude
            forEachNeighbor(of: index, width: width, height: height) { neighbor in
                if removed[neighbor] {
                    nearest = min(nearest, simd_distance(colors[index], reference[neighbor]))
                }
            }
            if nearest < .greatestFiniteMagnitude {
                let t = min(max((nearest - tolerance) / (2 * tolerance), 0), 1)
                refined.values[index] = min(refined.values[index], t * t * (3 - 2 * t))
            }
        }

        let removedFraction = Float(removedCount) / Float(insideCount)
        let before = edgeAlignment(of: mask, edges: edges)
        let after = edgeAlignment(of: refined, edges: edges)
        let accepted = removedCount > 0
            && removedFraction <= options.maximumRemovedFraction
            && after >= before - options.edgeAlignmentSlack
        return Result(
            mask: accepted ? refined : mask,
            removedFraction: removedFraction,
            edgeAlignmentBefore: before,
            edgeAlignmentAfter: after,
            accepted: accepted,
            tolerance: tolerance
        )
    }

    @inline(__always)
    private static func forEachNeighbor(of index: Int, width: Int, height: Int, _ body: (Int) -> Void) {
        let x = index % width
        let y = index / width
        if x > 0 { body(index - 1) }
        if x < width - 1 { body(index + 1) }
        if y > 0 { body(index - width) }
        if y < height - 1 { body(index + width) }
    }

    /// Max color difference to the right/lower neighbor (a cheap edge map).
    static func edgeStrength(colors: [SIMD3<Float>], width: Int, height: Int) -> [Float] {
        var edges = [Float](repeating: 0, count: colors.count)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                var strength: Float = 0
                if x < width - 1 { strength = max(strength, simd_distance(colors[index], colors[index + 1])) }
                if y < height - 1 { strength = max(strength, simd_distance(colors[index], colors[index + width])) }
                if x > 0 { strength = max(strength, simd_distance(colors[index], colors[index - 1])) }
                if y > 0 { strength = max(strength, simd_distance(colors[index], colors[index - width])) }
                edges[index] = strength
            }
        }
        return edges
    }

    /// Fraction of boundary pixels (inside, with an outside 4-neighbor) whose
    /// edge strength marks a visible color change.
    static func edgeAlignment(of mask: FloatPlane, edges: [Float], threshold: Float = 0.06) -> Float {
        let width = mask.width
        let height = mask.height
        var boundary = 0
        var aligned = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask.values[index] >= 0.5 else { continue }
                let isBoundary = (x > 0 && mask.values[index - 1] < 0.5)
                    || (x < width - 1 && mask.values[index + 1] < 0.5)
                    || (y > 0 && mask.values[index - width] < 0.5)
                    || (y < height - 1 && mask.values[index + width] < 0.5)
                guard isBoundary else { continue }
                boundary += 1
                if edges[index] >= threshold { aligned += 1 }
            }
        }
        return boundary == 0 ? 0 : Float(aligned) / Float(boundary)
    }
}
