import CoreGraphics
import Foundation

/// One disconnected foreground region that can be independently auto-rigged.
/// Bounds are normalized to the original image, so hosts can draw a selection
/// affordance without knowing the pipeline's analysis resolution.
public struct RiggingSubjectCandidate: Identifiable, Equatable, Sendable {
    public let id: Int
    public let normalizedBounds: CGRect

    public init(id: Int, normalizedBounds: CGRect) {
        self.id = id
        self.normalizedBounds = normalizedBounds
    }
}

/// Connected-component analysis for masks. This deliberately separates only
/// regions that are already disconnected in the foreground mask; overlapping
/// or touching people remain one candidate rather than being guessed apart.
enum SubjectCandidates {
    private struct Component {
        var id: Int
        var pixelCount: Int
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
    }

    private static let threshold: Float = 0.25

    private static func detect(in mask: FloatPlane) -> [Component] {
        guard mask.width > 0, mask.height > 0 else { return [] }
        let count = mask.width * mask.height
        var labels = [Int](repeating: -1, count: count)
        var components: [Component] = []

        for start in 0..<count where labels[start] == -1 && mask.values[start] >= threshold {
            let id = components.count
            var queue = [start]
            labels[start] = id
            var cursor = 0
            var component = Component(
                id: id,
                pixelCount: 0,
                minX: start % mask.width,
                minY: start / mask.width,
                maxX: start % mask.width,
                maxY: start / mask.width
            )

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % mask.width
                let y = index / mask.width
                component.pixelCount += 1
                component.minX = min(component.minX, x)
                component.minY = min(component.minY, y)
                component.maxX = max(component.maxX, x)
                component.maxY = max(component.maxY, y)

                for offsetY in -1...1 {
                    for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                        let nx = x + offsetX
                        let ny = y + offsetY
                        guard nx >= 0, nx < mask.width, ny >= 0, ny < mask.height else { continue }
                        let neighbor = ny * mask.width + nx
                        guard labels[neighbor] == -1, mask.values[neighbor] >= threshold else { continue }
                        labels[neighbor] = id
                        queue.append(neighbor)
                    }
                }
            }
            components.append(component)
        }
        return components
    }

    static func candidates(in mask: FloatPlane) -> [RiggingSubjectCandidate] {
        let components = detect(in: mask)
        let minimumArea = max(16, mask.width * mask.height / 250)
        let retained = components.filter { $0.pixelCount >= minimumArea }
        let visible = retained.isEmpty ? components : retained
        return visible.map { component in
            let width = max(1, mask.width)
            let height = max(1, mask.height)
            return RiggingSubjectCandidate(
                id: component.id,
                normalizedBounds: CGRect(
                    x: CGFloat(component.minX) / CGFloat(width),
                    y: CGFloat(component.minY) / CGFloat(height),
                    width: CGFloat(component.maxX - component.minX + 1) / CGFloat(width),
                    height: CGFloat(component.maxY - component.minY + 1) / CGFloat(height)
                )
            )
        }.sorted {
            $0.normalizedBounds.minY == $1.normalizedBounds.minY
                ? $0.normalizedBounds.minX < $1.normalizedBounds.minX
                : $0.normalizedBounds.minY < $1.normalizedBounds.minY
        }
    }

    static func mask(in source: FloatPlane, selecting candidateID: Int) -> FloatPlane? {
        let components = detect(in: source)
        guard components.contains(where: { $0.id == candidateID }) else { return nil }
        let width = source.width
        var labels = [Int](repeating: -1, count: source.values.count)

        // Repeat the small flood fill so the public candidate stays a compact
        // value type rather than exposing a resolution-dependent label map.
        for component in components {
            var queue: [Int] = []
            for index in labels.indices where labels[index] == -1 && source.values[index] >= threshold {
                queue.append(index)
                labels[index] = component.id
                var cursor = 0
                while cursor < queue.count {
                    let current = queue[cursor]
                    cursor += 1
                    let x = current % width
                    let y = current / width
                    for offsetY in -1...1 {
                        for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                            let nx = x + offsetX
                            let ny = y + offsetY
                            guard nx >= 0, nx < source.width, ny >= 0, ny < source.height else { continue }
                            let neighbor = ny * width + nx
                            guard labels[neighbor] == -1, source.values[neighbor] >= threshold else { continue }
                            labels[neighbor] = component.id
                            queue.append(neighbor)
                        }
                    }
                }
                break
            }
        }

        var result = FloatPlane(width: source.width, height: source.height)
        for index in source.values.indices where labels[index] == candidateID {
            result.values[index] = source.values[index]
        }
        return result
    }
}
