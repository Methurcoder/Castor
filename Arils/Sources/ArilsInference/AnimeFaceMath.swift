import Foundation

/// The data-dependent steps of `anime_face_detector` 0.1.0, ported line for
/// line so the Core ML networks reproduce the Python pipeline the calibration
/// was fitted against. Everything here is pure and unit tested; the networks
/// run behind `InferenceModel` (Core ML on the Mac, ONNX Runtime elsewhere)
/// and `AnimeFacePipeline` strings these steps between them.
///
/// Boxes are `[x1, y1, x2, y2]` in pixels, matching mmdet.
public enum AnimeFaceMath {
    public struct Box: Equatable, Sendable {
        public var x1: Float, y1: Float, x2: Float, y2: Float

        public init(x1: Float, y1: Float, x2: Float, y2: Float) {
            self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        }

        public var width: Float { x2 - x1 }
        public var height: Float { y2 - y1 }
        public var area: Float { width * height }
    }

    // MARK: Anchors and box coding (mmdet AnchorGenerator, DeltaXYWHBBoxCoder)

    /// Base anchors of one level: `scales = [8]`, `ratios = [0.5, 1, 2]`,
    /// centred on the origin, ratios outer and scales inner (`scale_major`).
    static func baseAnchors(stride: Int) -> [Box] {
        let base = Float(stride)
        return [0.5, 1.0, 2.0].map { (ratio: Float) -> Box in
            let heightRatio = ratio.squareRoot()
            let widthRatio = 1 / heightRatio
            let w = base * widthRatio * 8
            let h = base * heightRatio * 8
            return Box(x1: -0.5 * w, y1: -0.5 * h, x2: 0.5 * w, y2: 0.5 * h)
        }
    }

    /// `delta2bbox` with clipping to `(maxWidth, maxHeight)`.
    static func decode(
        anchor: Box,
        deltas: (Float, Float, Float, Float),
        stds: (Float, Float, Float, Float),
        maxWidth: Float,
        maxHeight: Float
    ) -> Box {
        let maxRatio = abs(log(Float(16.0 / 1000.0)))
        let dx = deltas.0 * stds.0
        let dy = deltas.1 * stds.1
        let dw = min(max(deltas.2 * stds.2, -maxRatio), maxRatio)
        let dh = min(max(deltas.3 * stds.3, -maxRatio), maxRatio)
        let px = (anchor.x1 + anchor.x2) * 0.5
        let py = (anchor.y1 + anchor.y2) * 0.5
        let pw = anchor.x2 - anchor.x1
        let ph = anchor.y2 - anchor.y1
        let gx = px + pw * dx
        let gy = py + ph * dy
        let gw = pw * exp(dw)
        let gh = ph * exp(dh)
        return Box(
            x1: min(max(gx - gw * 0.5, 0), maxWidth),
            y1: min(max(gy - gh * 0.5, 0), maxHeight),
            x2: min(max(gx + gw * 0.5, 0), maxWidth),
            y2: min(max(gy + gh * 0.5, 0), maxHeight)
        )
    }

    // MARK: NMS (torchvision.ops.nms)

    package static func iou(_ a: Box, _ b: Box) -> Float {
        let w = max(0, min(a.x2, b.x2) - max(a.x1, b.x1))
        let h = max(0, min(a.y2, b.y2) - max(a.y1, b.y1))
        let intersection = w * h
        let union = a.area + b.area - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Indices kept, highest score first. A box is dropped when its IoU with
    /// an already kept box is strictly greater than `threshold`.
    static func nms(boxes: [Box], scores: [Float], threshold: Float) -> [Int] {
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        var suppressed = [Bool](repeating: false, count: boxes.count)
        var keep: [Int] = []
        for (rank, i) in order.enumerated() where !suppressed[i] {
            keep.append(i)
            for j in order[(rank + 1)...] where !suppressed[j] {
                if iou(boxes[i], boxes[j]) > threshold { suppressed[j] = true }
            }
        }
        return keep
    }

    // MARK: RoI level mapping and RoIAlign (mmdet SingleRoIExtractor)

    /// `floor(log2(sqrt(w * h) / 56 + 1e-6))`, clamped to the four levels.
    static func roiLevel(_ box: Box, levels: Int = 4) -> Int {
        let scale = (box.width * box.height).squareRoot()
        let level = Int(floor(log2(scale / 56 + 1e-6)))
        return min(max(level, 0), levels - 1)
    }

    /// One bilinear tap set: `(index into a channel plane, weight)`.
    typealias Taps = [(offset: Int, weight: Float)]

    /// torchvision `roi_align` with `aligned=True`, `sampling_ratio=0`
    /// (adaptive), output 7x7, for one RoI on one feature plane size. The
    /// returned taps already include the `1 / count` averaging, so a bin's
    /// value in channel `c` is `sum(plane_c[offset] * weight)`.
    static func roiAlignTaps(
        box: Box,
        spatialScale: Float,
        height: Int,
        width: Int,
        pooled: Int = 7
    ) -> [Taps] {
        let startX = box.x1 * spatialScale - 0.5
        let startY = box.y1 * spatialScale - 0.5
        let roiWidth = box.x2 * spatialScale - 0.5 - startX
        let roiHeight = box.y2 * spatialScale - 0.5 - startY
        let binWidth = roiWidth / Float(pooled)
        let binHeight = roiHeight / Float(pooled)
        let gridH = max(Int(ceil(roiHeight / Float(pooled))), 0)
        let gridW = max(Int(ceil(roiWidth / Float(pooled))), 0)
        let count = Float(max(gridH * gridW, 1))

        var bins: [Taps] = []
        bins.reserveCapacity(pooled * pooled)
        for ph in 0..<pooled {
            for pw in 0..<pooled {
                var taps: Taps = []
                for iy in 0..<gridH {
                    let y = startY + Float(ph) * binHeight + (Float(iy) + 0.5) * binHeight / Float(gridH)
                    for ix in 0..<gridW {
                        let x = startX + Float(pw) * binWidth + (Float(ix) + 0.5) * binWidth / Float(gridW)
                        appendBilinear(y: y, x: x, height: height, width: width, scale: 1 / count, into: &taps)
                    }
                }
                bins.append(taps)
            }
        }
        return bins
    }

    /// torchvision's `bilinear_interpolate`, as taps.
    private static func appendBilinear(y: Float, x: Float, height: Int, width: Int, scale: Float, into taps: inout Taps) {
        if y < -1 || y > Float(height) || x < -1 || x > Float(width) { return }
        var y = max(y, 0)
        var x = max(x, 0)
        var yLow = Int(y)
        var xLow = Int(x)
        let yHigh: Int
        let xHigh: Int
        if yLow >= height - 1 {
            yLow = height - 1; yHigh = yLow; y = Float(yLow)
        } else {
            yHigh = yLow + 1
        }
        if xLow >= width - 1 {
            xLow = width - 1; xHigh = xLow; x = Float(xLow)
        } else {
            xHigh = xLow + 1
        }
        let ly = y - Float(yLow), lx = x - Float(xLow)
        let hy = 1 - ly, hx = 1 - lx
        taps.append((yLow * width + xLow, hy * hx * scale))
        taps.append((yLow * width + xHigh, hy * lx * scale))
        taps.append((yHigh * width + xLow, ly * hx * scale))
        taps.append((yHigh * width + xHigh, ly * lx * scale))
    }

    // MARK: Heatmap decoding (mmpose keypoints_from_heatmaps, 'unbiased')

    /// cv2.getGaussianKernel(11, 0): sigma 2.0, normalized.
    static let gaussianKernel: [Float] = {
        let size = 11
        let sigma: Float = 0.3 * (Float(size - 1) * 0.5 - 1) + 0.8
        let raw = (0..<size).map { i -> Float in
            let d = Float(i - size / 2)
            return exp(-(d * d) / (2 * sigma * sigma))
        }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }()

    /// Decodes one `size x size` heatmap to `(x, y, maxValue)` in heatmap
    /// pixels: argmax, then DARK's Taylor refinement on the log of the
    /// zero-padded, max-preserving Gaussian blur.
    static func decodeHeatmap(_ heatmap: [Float], size: Int) -> (x: Float, y: Float, score: Float) {
        var maxValue = -Float.infinity
        var maxIndex = 0
        for (index, value) in heatmap.enumerated() where value > maxValue {
            maxValue = value
            maxIndex = index
        }
        guard maxValue > 0 else { return (-1, -1, maxValue) }
        var x = Float(maxIndex % size)
        var y = Float(maxIndex / size)

        let blurred = blur(heatmap, size: size)
        let blurredMax = blurred.max() ?? 0
        let gain = blurredMax > 0 ? maxValue / blurredMax : 0
        let logged = blurred.map { log(max($0 * gain, 1e-10)) }

        let px = Int(x), py = Int(y)
        if 1 < px, px < size - 2, 1 < py, py < size - 2 {
            func h(_ yy: Int, _ xx: Int) -> Float { logged[yy * size + xx] }
            let dx = 0.5 * (h(py, px + 1) - h(py, px - 1))
            let dy = 0.5 * (h(py + 1, px) - h(py - 1, px))
            let dxx = 0.25 * (h(py, px + 2) - 2 * h(py, px) + h(py, px - 2))
            let dxy = 0.25 * (h(py + 1, px + 1) - h(py - 1, px + 1) - h(py + 1, px - 1) + h(py - 1, px - 1))
            let dyy = 0.25 * (h(py + 2, px) - 2 * h(py, px) + h(py - 2, px))
            let determinant = dxx * dyy - dxy * dxy
            if determinant != 0 {
                // offset = -inverse(hessian) * derivative
                x -= (dyy * dx - dxy * dy) / determinant
                y -= (-dxy * dx + dxx * dy) / determinant
            }
        }
        return (x, y, maxValue)
    }

    /// Separable 11-tap Gaussian with zero padding (the padding of
    /// `_gaussian_blur` is wide enough that cv2's own border mode never
    /// reaches the interior).
    static func blur(_ plane: [Float], size: Int) -> [Float] {
        let kernel = gaussianKernel
        let radius = kernel.count / 2
        var horizontal = [Float](repeating: 0, count: plane.count)
        for y in 0..<size {
            for x in 0..<size {
                var sum: Float = 0
                for k in 0..<kernel.count {
                    let xx = x + k - radius
                    if xx >= 0, xx < size { sum += plane[y * size + xx] * kernel[k] }
                }
                horizontal[y * size + x] = sum
            }
        }
        var out = [Float](repeating: 0, count: plane.count)
        for y in 0..<size {
            for x in 0..<size {
                var sum: Float = 0
                for k in 0..<kernel.count {
                    let yy = y + k - radius
                    if yy >= 0, yy < size { sum += horizontal[yy * size + x] * kernel[k] }
                }
                out[y * size + x] = sum
            }
        }
        return out
    }

    // MARK: Resampling (cv2.resize / cv2.warpAffine, INTER_LINEAR)

    /// cv2.resize INTER_LINEAR on 8-bit RGB: half-pixel centres, edge clamp,
    /// result rounded back to 8 bits as cv2 does for uint8 input.
    static func resize(rgb: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        func taps(_ dst: Int, src: Int, scale: Float) -> (Int, Int, Float) {
            var f = (Float(dst) + 0.5) * scale - 0.5
            var i = Int(floor(f))
            f -= Float(i)
            if i < 0 { i = 0; f = 0 }
            if i >= src - 1 { i = src - 1; f = 0 }
            return (i, min(i + 1, src - 1), f)
        }
        let xs = (0..<toWidth).map { taps($0, src: width, scale: Float(width) / Float(toWidth)) }
        let ys = (0..<toHeight).map { taps($0, src: height, scale: Float(height) / Float(toHeight)) }
        var out = [UInt8](repeating: 0, count: toWidth * toHeight * 3)
        rgb.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<toHeight {
                    let (y0, y1, fy) = ys[y]
                    for x in 0..<toWidth {
                        let (x0, x1, fx) = xs[x]
                        for c in 0..<3 {
                            let a = Float(src[(y0 * width + x0) * 3 + c])
                            let b = Float(src[(y0 * width + x1) * 3 + c])
                            let d = Float(src[(y1 * width + x0) * 3 + c])
                            let e = Float(src[(y1 * width + x1) * 3 + c])
                            let top = a + (b - a) * fx
                            let bottom = d + (e - d) * fx
                            dst[(y * toWidth + x) * 3 + c] = UInt8(min(max((top + (bottom - top) * fy).rounded(), 0), 255))
                        }
                    }
                }
            }
        }
        return out
    }

    /// The landmark crop: cv2.warpAffine of the uniform scale-and-translate
    /// that `get_affine_transform` builds for a square box, INTER_LINEAR with
    /// cv2's 1/32 sub-pixel quantization and a constant zero border.
    static func crop(
        rgb: [UInt8], width: Int, height: Int,
        centreX: Float, centreY: Float, side: Float, output: Int = 256
    ) -> [UInt8] {
        let scale = side / Float(output)
        var out = [UInt8](repeating: 0, count: output * output * 3)
        rgb.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for v in 0..<output {
                    let sy = (Float(v) - Float(output) * 0.5) * scale + centreY
                    let qy = (sy * 32).rounded() / 32
                    let y0 = Int(floor(qy)), fy = qy - Float(y0)
                    for u in 0..<output {
                        let sx = (Float(u) - Float(output) * 0.5) * scale + centreX
                        let qx = (sx * 32).rounded() / 32
                        let x0 = Int(floor(qx)), fx = qx - Float(x0)
                        for c in 0..<3 {
                            func pixel(_ yy: Int, _ xx: Int) -> Float {
                                guard yy >= 0, yy < height, xx >= 0, xx < width else { return 0 }
                                return Float(src[(yy * width + xx) * 3 + c])
                            }
                            let top = pixel(y0, x0) * (1 - fx) + pixel(y0, x0 + 1) * fx
                            let bottom = pixel(y0 + 1, x0) * (1 - fx) + pixel(y0 + 1, x0 + 1) * fx
                            dst[(v * output + u) * 3 + c] = UInt8(min(max((top * (1 - fy) + bottom * fy).rounded(), 0), 255))
                        }
                    }
                }
            }
        }
        return out
    }
}
