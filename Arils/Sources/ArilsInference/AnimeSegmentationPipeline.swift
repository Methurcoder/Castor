import Foundation

/// Where the source image sits inside the letterboxed network input.
public struct AnimeSegmentationLetterbox: Equatable, Sendable {
    public var top: Int
    public var left: Int
    public var height: Int
    public var width: Int

    /// Upstream `inference.get_mask`: aspect fit to `size`, centred.
    public init(sourceWidth: Int, sourceHeight: Int, size: Int = AnimeSegmentationPipeline.inputSize) {
        if sourceHeight > sourceWidth {
            height = size
            width = max(1, Int(Double(size) * Double(sourceWidth) / Double(sourceHeight)))
        } else {
            width = size
            height = max(1, Int(Double(size) * Double(sourceHeight) / Double(sourceWidth)))
        }
        top = (size - height) / 2
        left = (size - width) / 2
    }
}

/// Anime character segmentation (ISNet, `skytnt/anime-seg`, Apache 2.0) on
/// any `InferenceModel` runtime: letterbox in, sigmoid probability out,
/// resized back to the source. Core ML and ONNX Runtime run the same export.
public final class AnimeSegmentationPipeline: @unchecked Sendable {
    /// Network input side; images are letterboxed into this square.
    public static let inputSize = 1024
    public static let modelName = "AnimeSegmentation"

    private let model: any InferenceModel
    private let lock = NSLock()

    public init(model: any InferenceModel) {
        self.model = model
    }

    /// Character probability (0...1) for every source pixel, row-major.
    /// `letterboxed` is RGBA8 already drawn at `box.width`×`box.height` (the
    /// host's best resampler: Core Graphics on the Mac,
    /// `downsample(rgba:…)` elsewhere).
    public func probability(letterboxed pixels: [UInt8], box: AnimeSegmentationLetterbox,
                            sourceWidth: Int, sourceHeight: Int) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let size = Self.inputSize
        guard pixels.count == box.width * box.height * 4 else { throw InferenceError.unexpectedShape("letterboxed pixels") }
        var input = InferenceTensor(zeros: [1, 3, size, size])
        let plane = size * size
        input.values.withUnsafeMutableBufferPointer { pointer in
            for y in 0..<box.height {
                for x in 0..<box.width {
                    let source = (y * box.width + x) * 4
                    let target = (y + box.top) * size + (x + box.left)
                    pointer[target] = Float(pixels[source]) / 255
                    pointer[plane + target] = Float(pixels[source + 1]) / 255
                    pointer[2 * plane + target] = Float(pixels[source + 2]) / 255
                }
            }
        }
        let output = try model.run(["image": input], outputs: ["probability"])
        let probability = try model.output("probability", of: output)
        guard probability.values.count == plane else { throw InferenceError.unexpectedShape("probability") }
        return Self.resizeCrop(probability.values, size: size, box: box, toWidth: sourceWidth, height: sourceHeight)
    }

    /// Bilinear resize of the letterboxed crop back to the source size
    /// (cv2.resize's pixel-centre convention).
    public static func resizeCrop(_ values: [Float], size: Int, box: AnimeSegmentationLetterbox,
                                  toWidth width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)
        let scaleX = Float(box.width) / Float(width)
        let scaleY = Float(box.height) / Float(height)
        for y in 0..<height {
            let sy = min(max((Float(y) + 0.5) * scaleY - 0.5, 0), Float(box.height - 1))
            let y0 = Int(sy)
            let y1 = min(y0 + 1, box.height - 1)
            let fy = sy - Float(y0)
            for x in 0..<width {
                let sx = min(max((Float(x) + 0.5) * scaleX - 0.5, 0), Float(box.width - 1))
                let x0 = Int(sx)
                let x1 = min(x0 + 1, box.width - 1)
                let fx = sx - Float(x0)
                func at(_ px: Int, _ py: Int) -> Float {
                    values[(py + box.top) * size + (px + box.left)]
                }
                let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * fx
                let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * fx
                result[y * width + x] = min(max(top + (bottom - top) * fy, 0), 1)
            }
        }
        return result
    }

    /// Portable RGBA8 resampling for hosts without Core Graphics: area
    /// averaging when shrinking (anti-aliased, like PIL's reduction) and
    /// bilinear when enlarging.
    public static func downsample(rgba: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: toWidth * toHeight * 4)
        let sx = Double(width) / Double(toWidth), sy = Double(height) / Double(toHeight)
        for y in 0..<toHeight {
            for x in 0..<toWidth {
                var sum = (0.0, 0.0, 0.0, 0.0), weight = 0.0
                if sx >= 1, sy >= 1 {
                    let x0 = Double(x) * sx, x1 = x0 + sx, y0 = Double(y) * sy, y1 = y0 + sy
                    for py in Int(y0)..<min(height, Int(ceil(y1))) {
                        let wy = min(Double(py + 1), y1) - max(Double(py), y0)
                        for px in Int(x0)..<min(width, Int(ceil(x1))) {
                            let w = wy * (min(Double(px + 1), x1) - max(Double(px), x0))
                            let i = (py * width + px) * 4
                            sum.0 += w * Double(rgba[i]); sum.1 += w * Double(rgba[i + 1])
                            sum.2 += w * Double(rgba[i + 2]); sum.3 += w * Double(rgba[i + 3])
                            weight += w
                        }
                    }
                } else {
                    let fx = min(max((Double(x) + 0.5) * sx - 0.5, 0), Double(width - 1))
                    let fy = min(max((Double(y) + 0.5) * sy - 0.5, 0), Double(height - 1))
                    let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                    for (px, py, w) in [(x0, y0, (1 - (fx - Double(x0))) * (1 - (fy - Double(y0)))),
                                        (x1, y0, (fx - Double(x0)) * (1 - (fy - Double(y0)))),
                                        (x0, y1, (1 - (fx - Double(x0))) * (fy - Double(y0))),
                                        (x1, y1, (fx - Double(x0)) * (fy - Double(y0)))] {
                        let i = (py * width + px) * 4
                        sum.0 += w * Double(rgba[i]); sum.1 += w * Double(rgba[i + 1])
                        sum.2 += w * Double(rgba[i + 2]); sum.3 += w * Double(rgba[i + 3])
                        weight += w
                    }
                }
                let o = (y * toWidth + x) * 4
                let k = weight > 0 ? 1 / weight : 0
                out[o] = UInt8(min(255, (sum.0 * k).rounded())); out[o + 1] = UInt8(min(255, (sum.1 * k).rounded()))
                out[o + 2] = UInt8(min(255, (sum.2 * k).rounded())); out[o + 3] = UInt8(min(255, (sum.3 * k).rounded()))
            }
        }
        return out
    }
}
