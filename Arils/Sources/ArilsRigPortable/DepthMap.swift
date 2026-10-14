import Foundation

/// Signed depth samples in normalized character-depth units. Positive values
/// point toward the viewer; image coordinates remain top-left/Y-down.
public struct DepthMap: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, fill: Float = 0) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.values = [Float](repeating: fill, count: self.width * self.height)
    }

    public init(width: Int, height: Int, values: [Float]) {
        precondition(width >= 0 && height >= 0 && values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public subscript(x: Int, y: Int) -> Float {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            return values[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            values[y * width + x] = newValue
        }
    }

    public func sample(u: Float, v: Float) -> Float {
        guard width > 0, height > 0 else { return 0 }
        let x = min(max(u, 0), 1) * Float(width - 1)
        let y = min(max(v, 0), 1) * Float(height - 1)
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        let top = self[x0, y0] + (self[x1, y0] - self[x0, y0]) * fx
        let bottom = self[x0, y1] + (self[x1, y1] - self[x0, y1]) * fx
        return top + (bottom - top) * fy
    }

    /// Portable grayscale PGM dump for inspecting estimated depth without
    /// adding an image-framework dependency to the pure rigging layer.
    public func debugPGMData() -> Data {
        let finite = values.filter(\.isFinite)
        let minimum = finite.min() ?? 0
        let maximum = finite.max() ?? 0
        let span = max(maximum - minimum, 0.000_001)
        var data = Data("P5\n\(width) \(height)\n255\n".utf8)
        data.append(contentsOf: values.map { value in
            let normalized = value.isFinite ? (value - minimum) / span : 0
            return UInt8((min(max(normalized, 0), 1) * 255).rounded())
        })
        return data
    }
}
