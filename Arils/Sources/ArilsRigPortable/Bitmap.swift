#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

/// CPU-side RGBA8 pixel buffer (premultiplied alpha, sRGB, row-major).
///
/// The rigging pipeline runs entirely on the CPU over small analysis images,
/// so a plain array with explicit indexing beats juggling CGContext state.
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    /// 4 bytes per pixel: R, G, B, A — premultiplied.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height * 4)
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }





    @inlinable
    public func index(x: Int, y: Int) -> Int {
        (y * width + x) * 4
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    /// Premultiplied RGBA in 0...1. Out-of-bounds reads return transparent black.
    public func rgba(x: Int, y: Int) -> SIMD4<Float> {
        guard contains(x: x, y: y) else { return .zero }
        let i = index(x: x, y: y)
        return SIMD4(
            Float(pixels[i]) / 255,
            Float(pixels[i + 1]) / 255,
            Float(pixels[i + 2]) / 255,
            Float(pixels[i + 3]) / 255
        )
    }

    public mutating func setRGBA(x: Int, y: Int, _ value: SIMD4<Float>) {
        guard contains(x: x, y: y) else { return }
        let i = index(x: x, y: y)
        let clamped = simd_clamp(value, SIMD4(repeating: 0), SIMD4(repeating: 1))
        pixels[i] = UInt8(clamped.x * 255 + 0.5)
        pixels[i + 1] = UInt8(clamped.y * 255 + 0.5)
        pixels[i + 2] = UInt8(clamped.z * 255 + 0.5)
        pixels[i + 3] = UInt8(clamped.w * 255 + 0.5)
    }

    public func alpha(x: Int, y: Int) -> Float {
        guard contains(x: x, y: y) else { return 0 }
        return Float(pixels[index(x: x, y: y) + 3]) / 255
    }

    /// Multiplies the pixel (all four premultiplied channels) by `factor`.
    public mutating func scaleAlpha(x: Int, y: Int, by factor: Float) {
        guard contains(x: x, y: y), factor < 1 else { return }
        let f = max(0, factor)
        let i = index(x: x, y: y)
        for offset in 0..<4 {
            pixels[i + offset] = UInt8(Float(pixels[i + offset]) * f)
        }
    }

    /// Un-premultiplied luminance in 0...1 (0 where fully transparent).
    public func luminance(x: Int, y: Int) -> Float {
        let c = rgba(x: x, y: y)
        guard c.w > 0.001 else { return 0 }
        return (0.299 * c.x + 0.587 * c.y + 0.114 * c.z) / c.w
    }

    /// Un-premultiplied saturation in 0...1.
    public func saturation(x: Int, y: Int) -> Float {
        let c = rgba(x: x, y: y)
        guard c.w > 0.001 else { return 0 }
        let r = c.x / c.w, g = c.y / c.w, b = c.z / c.w
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        guard maxC > 0.001 else { return 0 }
        return (maxC - minC) / maxC
    }

    /// Area-averaged downscale so the longest side is at most `maxDimension`.
    public func downscaled(maxDimension: Int) -> Bitmap {
        let longest = max(width, height)
        guard longest > maxDimension, maxDimension > 0 else { return self }
        let ratio = Double(maxDimension) / Double(longest)
        let newWidth = max(1, Int((Double(width) * ratio).rounded()))
        let newHeight = max(1, Int((Double(height) * ratio).rounded()))
        var result = Bitmap(width: newWidth, height: newHeight)
        for y in 0..<newHeight {
            let sourceY0 = y * height / newHeight
            let sourceY1 = max(sourceY0 + 1, (y + 1) * height / newHeight)
            for x in 0..<newWidth {
                let sourceX0 = x * width / newWidth
                let sourceX1 = max(sourceX0 + 1, (x + 1) * width / newWidth)
                var sum = SIMD4<Float>.zero
                var count: Float = 0
                for sy in sourceY0..<sourceY1 {
                    for sx in sourceX0..<sourceX1 {
                        sum += rgba(x: sx, y: sy)
                        count += 1
                    }
                }
                result.setRGBA(x: x, y: y, sum / max(1, count))
            }
        }
        return result
    }

    /// Integer crop, clamped to bounds. Out-of-range areas are dropped.
    public func cropped(to rect: CGRect) -> Bitmap {
        let minX = max(0, Int(rect.minX))
        let minY = max(0, Int(rect.minY))
        let maxX = min(width, Int(rect.maxX.rounded(.up)))
        let maxY = min(height, Int(rect.maxY.rounded(.up)))
        guard maxX > minX, maxY > minY else { return Bitmap(width: 0, height: 0) }
        var result = Bitmap(width: maxX - minX, height: maxY - minY)
        for y in 0..<result.height {
            let sourceStart = index(x: minX, y: minY + y)
            let destinationStart = y * result.width * 4
            result.pixels.replaceSubrange(
                destinationStart..<(destinationStart + result.width * 4),
                with: pixels[sourceStart..<(sourceStart + result.width * 4)]
            )
        }
        return result
    }

    /// Bilinear premultiplied sample at pixel-space coordinates.
    public func sample(x: Float, y: Float) -> SIMD4<Float> {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let c00 = rgba(x: x0, y: y0)
        let c10 = rgba(x: x0 + 1, y: y0)
        let c01 = rgba(x: x0, y: y0 + 1)
        let c11 = rgba(x: x0 + 1, y: y0 + 1)
        let top = c00 + (c10 - c00) * fx
        let bottom = c01 + (c11 - c01) * fx
        return top + (bottom - top) * fy
    }
}

/// Planar float image for analysis (masks, luminance, edge energy).
public struct FloatPlane: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, fill: Float = 0) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.values = [Float](repeating: fill, count: self.width * self.height)
    }

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    @inlinable
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

    /// Bilinear sample at normalized coordinates (u, v in 0...1).
    public func sample(u: Float, v: Float) -> Float {
        guard width > 0, height > 0 else { return 0 }
        let x = min(max(u, 0), 1) * Float(width - 1)
        let y = min(max(v, 0), 1) * Float(height - 1)
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let top = self[x0, y0] + (self[min(x0 + 1, width - 1), y0] - self[x0, y0]) * fx
        let bottomLeft = self[x0, min(y0 + 1, height - 1)]
        let bottomRight = self[min(x0 + 1, width - 1), min(y0 + 1, height - 1)]
        let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
        return top + (bottom - top) * fy
    }

    /// Bilinearly resamples this plane to an explicit pixel size.
    public func resized(width: Int, height: Int) -> FloatPlane {
        guard width > 0, height > 0 else { return FloatPlane(width: 0, height: 0) }
        guard self.width != width || self.height != height else { return self }
        var result = FloatPlane(width: width, height: height)
        for y in 0..<height {
            let v = height > 1 ? Float(y) / Float(height - 1) : 0
            for x in 0..<width {
                let u = width > 1 ? Float(x) / Float(width - 1) : 0
                result[x, y] = sample(u: u, v: v)
            }
        }
        return result
    }

    /// Gradient magnitude via central differences — cheap edge energy.
    public func gradientMagnitude() -> FloatPlane {
        var result = FloatPlane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = self[x + 1, y] - self[x - 1, y]
                let dy = self[x, y + 1] - self[x, y - 1]
                result[x, y] = sqrt(dx * dx + dy * dy) * 0.5
            }
        }
        return result
    }

    /// Separable box blur with the given radius (in pixels).
    public func boxBlurred(radius: Int) -> FloatPlane {
        guard radius > 0 else { return self }
        var horizontal = FloatPlane(width: width, height: height)
        let window = Float(radius * 2 + 1)
        for y in 0..<height {
            var sum: Float = 0
            for x in -radius...radius {
                sum += self[min(max(x, 0), width - 1), y]
            }
            for x in 0..<width {
                horizontal[x, y] = sum / window
                let outgoing = min(max(x - radius, 0), width - 1)
                let incoming = min(max(x + radius + 1, 0), width - 1)
                sum += self[incoming, y] - self[outgoing, y]
            }
        }
        var result = FloatPlane(width: width, height: height)
        for x in 0..<width {
            var sum: Float = 0
            for y in -radius...radius {
                sum += horizontal[x, min(max(y, 0), height - 1)]
            }
            for y in 0..<height {
                result[x, y] = sum / window
                let outgoing = min(max(y - radius, 0), height - 1)
                let incoming = min(max(y + radius + 1, 0), height - 1)
                sum += horizontal[x, incoming] - horizontal[x, outgoing]
            }
        }
        return result
    }
}

extension Bitmap {
    public func alphaPlane() -> FloatPlane {
        var plane = FloatPlane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                plane[x, y] = alpha(x: x, y: y)
            }
        }
        return plane
    }

    public func luminancePlane() -> FloatPlane {
        var plane = FloatPlane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                plane[x, y] = luminance(x: x, y: y)
            }
        }
        return plane
    }

    public func saturationPlane() -> FloatPlane {
        var plane = FloatPlane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                plane[x, y] = saturation(x: x, y: y)
            }
        }
        return plane
    }
}
