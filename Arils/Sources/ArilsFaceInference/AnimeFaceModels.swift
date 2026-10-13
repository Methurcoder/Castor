import CoreGraphics
import CoreML
import Foundation

/// The anime face detector (Faster R-CNN R50-FPN) and 28-point landmark model
/// (HRNetV2-W18) from hysts/anime-face-detector, MIT, running in-process on
/// Core ML. Exported by `Tools/AnimeFaceModels/export_coreml.py`; the steps
/// between the networks are in `AnimeFaceMath`.
///
/// `shared` is nil when the compiled models are not in the bundle (they are
/// generated, not checked in), and every caller treats that as "no estimate",
/// so Arils works exactly as before without them.
package final class AnimeFaceModels: @unchecked Sendable {
    package static let shared: AnimeFaceModels? = try? AnimeFaceModels()

    private let features: MLModel
    private let boxHead: MLModel
    private let landmarks: MLModel
    /// Core ML models are safe to call concurrently, but one face estimate
    /// already saturates the machine, so estimates run one at a time.
    private let lock = NSLock()

    static let modelDirectory = "AnimeFaceModels"

    static func modelURL(_ name: String, in bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: name, withExtension: "mlmodelc", subdirectory: modelDirectory)
    }

    init(bundle: Bundle = .module) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        func load(_ name: String) throws -> MLModel {
            guard let url = Self.modelURL(name, in: bundle) else { throw CocoaError(.fileNoSuchFile) }
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        features = try load("AnimeFaceFeatures")
        boxHead = try load("AnimeFaceBoxHead")
        landmarks = try load("AnimeFaceLandmarks")
    }

    // MARK: - Detection

    package struct Face: Sendable {
        /// Detector box scaled by 1.1 about its centre, as the package hands
        /// it to the landmark model and returns it.
        package var box: AnimeFaceMath.Box
        package var score: Float
        /// 28 landmarks as (x, y, score) in source pixels.
        package var keypoints: [(x: Float, y: Float, score: Float)]
    }

    /// The highest-scoring face with its landmarks, or nil.
    package func detect(_ image: CGImage) throws -> Face? {
        lock.lock()
        defer { lock.unlock() }
        guard let rgb = Self.rgbPixels(of: image) else { return nil }
        let width = image.width, height = image.height
        guard let detection = try detectFaces(rgb: rgb, width: width, height: height).first else { return nil }

        // LandmarkDetector._update_pred_box: scale by 1.1, with mmdet's +1 size.
        let w = detection.box.x2 - detection.box.x1 + 1
        let h = detection.box.y2 - detection.box.y1 + 1
        let cx = (detection.box.x1 + detection.box.x2) / 2
        let cy = (detection.box.y1 + detection.box.y2) / 2
        let x1 = cx - w * 1.1 / 2, y1 = cy - h * 1.1 / 2
        let box = AnimeFaceMath.Box(x1: x1, y1: y1, x2: x1 + w * 1.1, y2: y1 + h * 1.1)

        let keypoints = try landmarks(rgb: rgb, width: width, height: height, box: box)
        return Face(box: box, score: detection.score, keypoints: keypoints)
    }

    /// FasterRCNNFaceDetector.detect: boxes in source pixels, best first.
    func detectFaces(rgb: [UInt8], width: Int, height: Int) throws -> [(box: AnimeFaceMath.Box, score: Float)] {
        // Keep-ratio resize into (1333, 800), normalize, pad to stride 32.
        let factor = min(1333 / Float(max(width, height)), 800 / Float(min(width, height)))
        let newWidth = Int(Float(width) * factor + 0.5)
        let newHeight = Int(Float(height) * factor + 0.5)
        let scaleX = Float(newWidth) / Float(width)
        let scaleY = Float(newHeight) / Float(height)
        let resized = AnimeFaceMath.resize(rgb: rgb, width: width, height: height, toWidth: newWidth, toHeight: newHeight)
        let padWidth = (newWidth + 31) / 32 * 32
        let padHeight = (newHeight + 31) / 32 * 32

        let input = try MLMultiArray(shape: [1, 3, padHeight, padWidth].map { NSNumber(value: $0) }, dataType: .float32)
        let mean: [Float] = [123.675, 116.28, 103.53]
        let std: [Float] = [58.395, 57.12, 57.375]
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            for i in 0..<buffer.count { buffer[i] = 0 }
            for c in 0..<3 {
                for y in 0..<newHeight {
                    for x in 0..<newWidth {
                        let value = (Float(resized[(y * newWidth + x) * 3 + c]) - mean[c]) / std[c]
                        buffer[c * strides[1] + y * strides[2] + x * strides[3]] = value
                    }
                }
            }
        }
        let output = try features.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))

        // RPN proposals (RPNHead._get_bboxes_single and _bbox_post_process).
        var proposalBoxes: [AnimeFaceMath.Box] = []
        var proposalScores: [Float] = []
        var proposalLevels: [Int] = []
        let strides = [4, 8, 16, 32, 64]
        for level in 0..<5 {
            guard let scoreArray = output.featureValue(for: "rpn_score\(level)")?.multiArrayValue,
                  let deltaArray = output.featureValue(for: "rpn_delta\(level)")?.multiArrayValue else { return [] }
            let scores = Plane(scoreArray)
            let deltas = Plane(deltaArray)
            let base = AnimeFaceMath.baseAnchors(stride: strides[level])
            var candidates: [(score: Float, iy: Int, ix: Int, a: Int)] = []
            candidates.reserveCapacity(scores.height * scores.width * 3)
            for iy in 0..<scores.height {
                for ix in 0..<scores.width {
                    for a in 0..<3 {
                        candidates.append((1 / (1 + exp(-scores[a, iy, ix])), iy, ix, a))
                    }
                }
            }
            candidates.sort { $0.score > $1.score }
            for candidate in candidates.prefix(1000) {
                let shiftX = Float(candidate.ix * strides[level])
                let shiftY = Float(candidate.iy * strides[level])
                let anchor = base[candidate.a]
                let shifted = AnimeFaceMath.Box(x1: anchor.x1 + shiftX, y1: anchor.y1 + shiftY,
                                                x2: anchor.x2 + shiftX, y2: anchor.y2 + shiftY)
                let d = candidate.a * 4
                let box = AnimeFaceMath.decode(
                    anchor: shifted,
                    deltas: (deltas[d, candidate.iy, candidate.ix], deltas[d + 1, candidate.iy, candidate.ix],
                             deltas[d + 2, candidate.iy, candidate.ix], deltas[d + 3, candidate.iy, candidate.ix]),
                    stds: (1, 1, 1, 1), maxWidth: Float(newWidth), maxHeight: Float(newHeight)
                )
                guard box.width > 0, box.height > 0 else { continue }
                proposalBoxes.append(box)
                proposalScores.append(candidate.score)
                proposalLevels.append(level)
            }
        }
        // batched_nms over levels: NMS never crosses levels.
        var kept: [Int] = []
        for level in 0..<5 {
            let indices = proposalLevels.indices.filter { proposalLevels[$0] == level }
            let keep = AnimeFaceMath.nms(boxes: indices.map { proposalBoxes[$0] },
                                         scores: indices.map { proposalScores[$0] }, threshold: 0.7)
            kept.append(contentsOf: keep.map { indices[$0] })
        }
        kept.sort { proposalScores[$0] > proposalScores[$1] }
        let rois = kept.prefix(1000).map { proposalBoxes[$0] }
        guard !rois.isEmpty else { return [] }

        // RoIAlign over P2..P5, then the box head.
        let levels = try (2...5).map { index -> Plane in
            guard let array = output.featureValue(for: "p\(index)")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
            return Plane(array)
        }
        let roiFeatures = try MLMultiArray(shape: [NSNumber(value: rois.count), 256, 7, 7], dataType: .float32)
        roiFeatures.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, outStrides in
            for (r, roi) in rois.enumerated() {
                let level = AnimeFaceMath.roiLevel(roi)
                let plane = levels[level]
                let bins = AnimeFaceMath.roiAlignTaps(
                    box: roi, spatialScale: 1 / Float(strides[level]),
                    height: plane.height, width: plane.width
                )
                plane.values.withUnsafeBufferPointer { values in
                    let channelSize = plane.height * plane.width
                    for c in 0..<256 {
                        let channel = c * channelSize
                        for (bin, taps) in bins.enumerated() {
                            var sum: Float = 0
                            for tap in taps { sum += values[channel + tap.offset] * tap.weight }
                            buffer[r * outStrides[0] + c * outStrides[1] + (bin / 7) * outStrides[2] + (bin % 7) * outStrides[3]] = sum
                        }
                    }
                }
            }
        }
        let head = try boxHead.prediction(from: MLDictionaryFeatureProvider(dictionary: ["roi_features": roiFeatures]))
        guard let logitsArray = head.featureValue(for: "class_logits")?.multiArrayValue,
              let deltasArray = head.featureValue(for: "box_deltas")?.multiArrayValue else { return [] }
        let logits = Matrix(logitsArray)
        let boxDeltas = Matrix(deltasArray)

        // BBoxHead.get_bboxes with rescale, then multiclass_nms.
        var boxes: [AnimeFaceMath.Box] = []
        var scores: [Float] = []
        for (r, roi) in rois.enumerated() {
            let face = logits[r, 0], background = logits[r, 1]
            let top = max(face, background)
            let score = exp(face - top) / (exp(face - top) + exp(background - top))
            guard score > 0.05 else { continue }
            let decoded = AnimeFaceMath.decode(
                anchor: roi,
                deltas: (boxDeltas[r, 0], boxDeltas[r, 1], boxDeltas[r, 2], boxDeltas[r, 3]),
                stds: (0.1, 0.1, 0.2, 0.2), maxWidth: Float(newWidth), maxHeight: Float(newHeight)
            )
            boxes.append(AnimeFaceMath.Box(x1: decoded.x1 / scaleX, y1: decoded.y1 / scaleY,
                                           x2: decoded.x2 / scaleX, y2: decoded.y2 / scaleY))
            scores.append(score)
        }
        return AnimeFaceMath.nms(boxes: boxes, scores: scores, threshold: 0.5)
            .prefix(100)
            .map { (boxes[$0], scores[$0]) }
    }

    /// LandmarkModel.detect for one box: square crop with 1.25 padding,
    /// flip-tested heatmaps (inside the model), DARK decoding.
    func landmarks(rgb: [UInt8], width: Int, height: Int, box: AnimeFaceMath.Box) throws -> [(x: Float, y: Float, score: Float)] {
        let w = box.x2 - box.x1, h = box.y2 - box.y1
        let side = max(w, h) * 1.25
        let cx = box.x1 + w * 0.5, cy = box.y1 + h * 0.5
        let crop = AnimeFaceMath.crop(rgb: rgb, width: width, height: height, centreX: cx, centreY: cy, side: side)

        let input = try MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32)
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            for c in 0..<3 {
                for y in 0..<256 {
                    for x in 0..<256 {
                        buffer[c * strides[1] + y * strides[2] + x * strides[3]] =
                            (Float(crop[(y * 256 + x) * 3 + c]) / 255 - mean[c]) / std[c]
                    }
                }
            }
        }
        let output = try landmarks.prediction(from: MLDictionaryFeatureProvider(dictionary: ["crop": input]))
        guard let heatmaps = output.featureValue(for: "heatmaps")?.multiArrayValue else { return [] }
        let plane = Plane(heatmaps)
        let size = plane.width
        let unit = side / Float(size)
        return (0..<28).map { k in
            let map = Array(plane.values[(k * size * size)..<((k + 1) * size * size)])
            let decoded = AnimeFaceMath.decodeHeatmap(map, size: size)
            // transform_preds
            return (decoded.x * unit + cx - side * 0.5, decoded.y * unit + cy - side * 0.5, decoded.score)
        }
    }

    // MARK: - Pixels

    /// 8-bit RGB, with transparency composited over white so a cut-out
    /// character reads like the illustrations the detector was trained on.
    static func rgbPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let rgba = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }
}

/// A (1, C, H, W) model output copied into contiguous Float32, honouring the
/// array's strides (GPU outputs are often row-padded) and its element type.
struct Plane {
    let channels: Int, height: Int, width: Int
    let values: [Float]

    init(_ array: MLMultiArray) {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let rank = shape.count
        channels = rank >= 3 ? shape[rank - 3] : 1
        height = rank >= 2 ? shape[rank - 2] : 1
        width = shape[rank - 1]
        let cs = rank >= 3 ? strides[rank - 3] : 0
        let hs = rank >= 2 ? strides[rank - 2] : 0
        let ws = strides[rank - 1]
        var out = [Float](repeating: 0, count: channels * height * width)
        let (channels, height, width) = (channels, height, width)
        func copy<T>(_ type: T.Type, _ convert: (T) -> Float) {
            let pointer = array.dataPointer.bindMemory(to: T.self, capacity: array.count)
            for c in 0..<channels {
                for y in 0..<height {
                    for x in 0..<width {
                        out[(c * height + y) * width + x] = convert(pointer[c * cs + y * hs + x * ws])
                    }
                }
            }
        }
        switch array.dataType {
        case .float16:
            #if arch(arm64)
            copy(Float16.self) { Float($0) }
            #else
            // Core ML converts float16 without the ARM-only Swift type.
            var indices = [NSNumber](repeating: 0, count: rank)
            for c in 0..<channels {
                if rank >= 3 { indices[rank - 3] = NSNumber(value: c) }
                for y in 0..<height {
                    if rank >= 2 { indices[rank - 2] = NSNumber(value: y) }
                    for x in 0..<width {
                        indices[rank - 1] = NSNumber(value: x)
                        out[(c * height + y) * width + x] = array[indices].floatValue
                    }
                }
            }
            #endif
        case .double: copy(Double.self) { Float($0) }
        default: copy(Float.self) { $0 }
        }
        values = out
    }

    subscript(c: Int, y: Int, x: Int) -> Float { values[(c * height + y) * width + x] }
}

/// An (N, K) model output as contiguous Float32.
struct Matrix {
    let rows: Int, columns: Int
    let values: [Float]

    init(_ array: MLMultiArray) {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        rows = shape[0]
        columns = shape.count > 1 ? shape[1] : 1
        let rs = strides[0], cs = shape.count > 1 ? strides[1] : 1
        var out = [Float](repeating: 0, count: rows * columns)
        let (rows, columns) = (rows, columns)
        func copy<T>(_ type: T.Type, _ convert: (T) -> Float) {
            let pointer = array.dataPointer.bindMemory(to: T.self, capacity: array.count)
            for r in 0..<rows { for c in 0..<columns { out[r * columns + c] = convert(pointer[r * rs + c * cs]) } }
        }
        switch array.dataType {
        case .float16:
            #if arch(arm64)
            copy(Float16.self) { Float($0) }
            #else
            for r in 0..<rows {
                for c in 0..<columns {
                    let indices = shape.count > 1
                        ? [NSNumber(value: r), NSNumber(value: c)] : [NSNumber(value: r)]
                    out[r * columns + c] = array[indices].floatValue
                }
            }
            #endif
        case .double: copy(Double.self) { Float($0) }
        default: copy(Float.self) { $0 }
        }
        values = out
    }

    subscript(r: Int, c: Int) -> Float { values[r * columns + c] }
}
