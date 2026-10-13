import CStbImage
import Foundation

/// A part texture: premultiplied RGBA, row-major, top-down.
public struct PetTexture: Sendable {
    public let width: Int
    public let height: Int
    /// 4 floats per pixel (r, g, b, a), premultiplied, 0...1.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Decodes a PNG (as stored in Arils archives) and premultiplies it.
    public init?(png data: Data) {
        var width: Int32 = 0
        var height: Int32 = 0
        var channels: Int32 = 0
        let decoded: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return stbi_load_from_memory(base, Int32(raw.count), &width, &height, &channels, 4)
        }
        guard let decoded, width > 0, height > 0 else { return nil }
        defer { stbi_image_free(decoded) }
        let count = Int(width) * Int(height)
        var pixels = [Float](repeating: 0, count: count * 4)
        for i in 0..<count {
            let a = Float(decoded[i * 4 + 3]) / 255
            pixels[i * 4] = Float(decoded[i * 4]) / 255 * a
            pixels[i * 4 + 1] = Float(decoded[i * 4 + 1]) / 255 * a
            pixels[i * 4 + 2] = Float(decoded[i * 4 + 2]) / 255 * a
            pixels[i * 4 + 3] = a
        }
        self.init(width: Int(width), height: Int(height), pixels: pixels)
    }

    /// Box-filtered reduction by an integer factor, so a large texture drawn
    /// small does not shimmer (there are no mipmaps on the CPU path).
    public func reduced(by factor: Int) -> PetTexture {
        guard factor > 1, width >= factor, height >= factor else { return self }
        let w = width / factor
        let h = height / factor
        var out = [Float](repeating: 0, count: w * h * 4)
        let norm = 1 / Float(factor * factor)
        for y in 0..<h {
            for x in 0..<w {
                var sum = SIMD4<Float>(repeating: 0)
                for dy in 0..<factor {
                    let row = (y * factor + dy) * width
                    for dx in 0..<factor {
                        let i = (row + x * factor + dx) * 4
                        sum += SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
                    }
                }
                let o = (y * w + x) * 4
                out[o] = sum.x * norm
                out[o + 1] = sum.y * norm
                out[o + 2] = sum.z * norm
                out[o + 3] = sum.w * norm
            }
        }
        return PetTexture(width: w, height: h, pixels: out)
    }

    /// Bilinear sample at texel-space coordinates (clamped at the edges).
    @inline(__always)
    func sample(_ x: Float, _ y: Float) -> SIMD4<Float> {
        let fx = min(max(x, 0), Float(width - 1))
        let fy = min(max(y, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ px: Int, _ py: Int) -> SIMD4<Float> {
            let i = (py * width + px) * 4
            return SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        let top = at(x0, y0) * (1 - tx) + at(x1, y0) * tx
        let bottom = at(x0, y1) * (1 - tx) + at(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }
}

/// The render target: 32-bit premultiplied BGRA, top-down — the layout a
/// Windows layered window (`UpdateLayeredWindow` with `ULW_ALPHA`) expects.
public struct PetCanvas: Sendable {
    public let width: Int
    public let height: Int
    public var bgra: [UInt8]

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        bgra = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    public mutating func clear() {
        for i in bgra.indices { bgra[i] = 0 }
    }
}
