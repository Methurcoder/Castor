import Foundation

/// Fuses Vision's foreground region with the anime segmentation model.
///
/// The two fail differently. Vision knows *which* thing is the subject but
/// wraps it in a smooth blob (hair halos, filled gaps). The anime model
/// traces an illustrated character's outline strand by strand, but it keeps
/// whatever else is drawn in the same style — a desk, a lamp, a floor
/// reflection, a soft drop shadow. So Vision decides the region and the
/// model decides the boundary: the model's probability is kept inside
/// Vision's region grown by a margin (for strands Vision rounded off) and
/// faded to nothing beyond it.
///
/// When the two disagree about the region itself — the model calls most of
/// Vision's subject background — neither can be trusted to have found the
/// character, and the fusion declines so the caller keeps its other path.
public enum SubjectMaskFusion {
    public struct Options: Sendable, Equatable {
        /// Growth of Vision's region, as a fraction of the image diagonal,
        /// within which the model may extend the subject.
        public var marginFraction: Float = 0.03
        /// Minimum share of Vision's region the model must also call subject.
        public var minimumAgreement: Float = 0.6
        /// The model outputs a probability, not coverage: values below
        /// `probabilityFloor` become transparent, values above
        /// `probabilityCeiling` fully opaque. Using the raw probability as
        /// alpha left hazy, translucent patches wherever the model was merely
        /// fairly sure (pale, foggy illustrations).
        public var probabilityFloor: Float = 0.3
        public var probabilityCeiling: Float = 0.6
        /// What the model adds *outside* Vision's region is kept only if it is
        /// thin — strands Vision rounded off — never a slab such as the edge
        /// of a desk drawn next to the character. Half-thickness limit as a
        /// fraction of the image diagonal.
        public var maximumAdditionHalfThickness: Float = 0.008

        public init() {}
    }

    public struct Result: Sendable {
        public var mask: FloatPlane
        /// Share of Vision's region the model also called subject.
        public var agreement: Float
    }

    /// The fused mask, or nil when the model disagrees with Vision's region.
    public static func fuse(
        vision: FloatPlane,
        model: FloatPlane,
        options: Options = Options()
    ) -> Result? {
        let width = vision.width
        let height = vision.height
        guard width > 0, height > 0, model.width == width, model.height == height else { return nil }
        let count = width * height

        var regionCount = 0
        var agreeing = 0
        var distance = [Int32](repeating: Int32.max, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(count / 4)
        for index in 0..<count where vision.values[index] >= 0.5 {
            regionCount += 1
            if model.values[index] >= 0.5 { agreeing += 1 }
            distance[index] = 0
            queue.append(index)
        }
        guard regionCount > 0 else { return nil }
        let agreement = Float(agreeing) / Float(regionCount)
        guard agreement >= options.minimumAgreement else { return nil }

        // Grow the region by `margin` (4-connected steps).
        let diagonal = Float(width * width + height * height).squareRoot()
        let margin = max(2, Int(options.marginFraction * diagonal))
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let next = distance[index] + 1
            guard next <= Int32(margin) else { continue }
            let x = index % width
            let y = index / width
            for neighbor in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1,
                             y > 0 ? index - width : -1, y < height - 1 ? index + width : -1]
            where neighbor >= 0 && distance[neighbor] > next {
                distance[neighbor] = next
                queue.append(neighbor)
            }
        }

        var fused = FloatPlane(width: width, height: height)
        let fadeStart = Float(margin) * 0.5
        for index in 0..<count where distance[index] != Int32.max {
            let d = Float(distance[index])
            let t = min(max((d - fadeStart) / max(1, Float(margin) - fadeStart), 0), 1)
            let allowance = 1 - t * t * (3 - 2 * t)
            let p = min(max(
                (model.values[index] - options.probabilityFloor)
                    / (options.probabilityCeiling - options.probabilityFloor), 0), 1)
            fused.values[index] = p * p * (3 - 2 * p) * allowance
        }
        removeThickAdditions(
            from: &fused,
            outsideRegion: { distance[$0] > 0 },
            limit: max(2, Int(options.maximumAdditionHalfThickness * diagonal))
        )
        return Result(mask: fused, agreement: agreement)
    }

    /// Clears every connected addition (subject pixels outside Vision's
    /// region) whose interior lies deeper than `limit` steps from its edge.
    static func removeThickAdditions(from mask: inout FloatPlane, outsideRegion: (Int) -> Bool, limit: Int) {
        let width = mask.width
        let height = mask.height
        let count = width * height
        var isAddition = [Bool](repeating: false, count: count)
        for index in 0..<count where mask.values[index] >= 0.5 && outsideRegion(index) {
            isAddition[index] = true
        }
        // Depth of each addition pixel from the nearest non-addition pixel.
        var depth = [Int32](repeating: Int32.max, count: count)
        var queue: [Int] = []
        for index in 0..<count where isAddition[index] {
            let x = index % width
            let y = index / width
            let onEdge = x == 0 || y == 0 || x == width - 1 || y == height - 1
                || !isAddition[index - 1] || !isAddition[index + 1]
                || !isAddition[index - width] || !isAddition[index + width]
            if onEdge {
                depth[index] = 1
                queue.append(index)
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let next = depth[index] + 1
            let x = index % width
            let y = index / width
            for neighbor in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1,
                             y > 0 ? index - width : -1, y < height - 1 ? index + width : -1]
            where neighbor >= 0 && isAddition[neighbor] && depth[neighbor] > next {
                depth[neighbor] = next
                queue.append(neighbor)
            }
        }
        // Clear whole components that contain a too-deep pixel.
        var visited = [Bool](repeating: false, count: count)
        for start in 0..<count where isAddition[start] && !visited[start] {
            var component = [start]
            visited[start] = true
            var head = 0
            var thick = false
            while head < component.count {
                let index = component[head]
                head += 1
                if depth[index] > Int32(limit) { thick = true }
                let x = index % width
                let y = index / width
                for neighbor in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1,
                                 y > 0 ? index - width : -1, y < height - 1 ? index + width : -1]
                where neighbor >= 0 && isAddition[neighbor] && !visited[neighbor] {
                    visited[neighbor] = true
                    component.append(neighbor)
                }
            }
            if thick {
                for index in component { mask.values[index] = 0 }
            }
        }
    }

    /// The model alone, for images where Vision found nothing. Rejects an
    /// empty or near-full-frame answer, which means it found no character.
    public static func modelOnly(_ model: FloatPlane, options: Options = Options()) -> FloatPlane? {
        guard !model.values.isEmpty else { return nil }
        let covered = model.values.reduce(0) { $0 + ($1 >= 0.5 ? 1 : 0) }
        let coverage = Float(covered) / Float(model.values.count)
        guard coverage >= 0.02, coverage <= 0.9 else { return nil }
        var mask = model
        for index in mask.values.indices {
            let p = min(max(
                (model.values[index] - options.probabilityFloor)
                    / (options.probabilityCeiling - options.probabilityFloor), 0), 1)
            mask.values[index] = p * p * (3 - 2 * p)
        }
        return mask
    }
}
