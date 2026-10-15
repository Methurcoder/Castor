import Foundation

/// The highest-scoring face with its 28 landmarks.
public struct AnimeFace: Sendable {
    /// Detector box scaled by 1.1 about its centre, as the package hands
    /// it to the landmark model and returns it.
    public var box: AnimeFaceMath.Box
    public var score: Float
    /// 28 landmarks as (x, y, score) in source pixels.
    public var keypoints: [(x: Float, y: Float, score: Float)]
}

/// anime_face_detector 0.1.0's Faster R-CNN detector and HRNetV2 landmark
/// model, run on any `InferenceModel` runtime. The three networks are the
/// exports in Tools/AnimeFaceModels (Core ML and ONNX share their contract);
/// everything between them is `AnimeFaceMath`, so both runtimes produce the
/// same boxes and landmarks up to the networks' numeric precision.
public final class AnimeFacePipeline: @unchecked Sendable {
    public static let modelNames = ["AnimeFaceFeatures", "AnimeFaceBoxHead", "AnimeFaceLandmarks"]

    private let features: any InferenceModel
    private let boxHead: any InferenceModel
    private let landmarkModel: any InferenceModel
    /// One face estimate already saturates the machine; run them one at a time.
    private let lock = NSLock()

    public init(features: any InferenceModel, boxHead: any InferenceModel, landmarks: any InferenceModel) {
        self.features = features
        self.boxHead = boxHead
        self.landmarkModel = landmarks
    }

    /// The highest-scoring face with its landmarks, or nil. `rgb` is 8-bit
    /// RGB, row-major, with transparency already composited over white.
    public func detect(rgb: [UInt8], width: Int, height: Int) throws -> AnimeFace? {
        lock.lock()
        defer { lock.unlock() }
        guard let detection = try detectFaces(rgb: rgb, width: width, height: height).first else { return nil }

        // LandmarkDetector._update_pred_box: scale by 1.1, with mmdet's +1 size.
        let w = detection.box.x2 - detection.box.x1 + 1
        let h = detection.box.y2 - detection.box.y1 + 1
        let cx = (detection.box.x1 + detection.box.x2) / 2
        let cy = (detection.box.y1 + detection.box.y2) / 2
        let x1 = cx - w * 1.1 / 2, y1 = cy - h * 1.1 / 2
        let box = AnimeFaceMath.Box(x1: x1, y1: y1, x2: x1 + w * 1.1, y2: y1 + h * 1.1)

        let keypoints = try landmarks(rgb: rgb, width: width, height: height, box: box)
        return AnimeFace(box: box, score: detection.score, keypoints: keypoints)
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

        var input = InferenceTensor(zeros: [1, 3, padHeight, padWidth])
        let mean: [Float] = [123.675, 116.28, 103.53]
        let std: [Float] = [58.395, 57.12, 57.375]
        input.values.withUnsafeMutableBufferPointer { buffer in
            for c in 0..<3 {
                for y in 0..<newHeight {
                    for x in 0..<newWidth {
                        buffer[(c * padHeight + y) * padWidth + x] = (Float(resized[(y * newWidth + x) * 3 + c]) - mean[c]) / std[c]
                    }
                }
            }
        }
        let featureNames = (2...5).map { "p\($0)" } + (0..<5).map { "rpn_score\($0)" } + (0..<5).map { "rpn_delta\($0)" }
        let output = try features.run(["image": input], outputs: featureNames)

        // RPN proposals (RPNHead._get_bboxes_single and _bbox_post_process).
        var proposalBoxes: [AnimeFaceMath.Box] = []
        var proposalScores: [Float] = []
        var proposalLevels: [Int] = []
        let strides = [4, 8, 16, 32, 64]
        for level in 0..<5 {
            let scores = try features.output("rpn_score\(level)", of: output)
            let deltas = try features.output("rpn_delta\(level)", of: output)
            let (_, scoreHeight, scoreWidth) = scores.chw
            let base = AnimeFaceMath.baseAnchors(stride: strides[level])
            var candidates: [(score: Float, iy: Int, ix: Int, a: Int)] = []
            candidates.reserveCapacity(scoreHeight * scoreWidth * 3)
            for iy in 0..<scoreHeight {
                for ix in 0..<scoreWidth {
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
        let levels = try (2...5).map { try features.output("p\($0)", of: output) }
        var roiFeatures = InferenceTensor(zeros: [rois.count, 256, 7, 7])
        roiFeatures.values.withUnsafeMutableBufferPointer { buffer in
            for (r, roi) in rois.enumerated() {
                let level = AnimeFaceMath.roiLevel(roi)
                let plane = levels[level]
                let (_, planeHeight, planeWidth) = plane.chw
                let bins = AnimeFaceMath.roiAlignTaps(
                    box: roi, spatialScale: 1 / Float(strides[level]),
                    height: planeHeight, width: planeWidth
                )
                plane.values.withUnsafeBufferPointer { values in
                    let channelSize = planeHeight * planeWidth
                    for c in 0..<256 {
                        let channel = c * channelSize
                        for (bin, taps) in bins.enumerated() {
                            var sum: Float = 0
                            for tap in taps { sum += values[channel + tap.offset] * tap.weight }
                            buffer[((r * 256 + c) * 7 + bin / 7) * 7 + bin % 7] = sum
                        }
                    }
                }
            }
        }
        let head = try boxHead.run(["roi_features": roiFeatures], outputs: ["class_logits", "box_deltas"])
        let logits = try boxHead.output("class_logits", of: head)
        let boxDeltas = try boxHead.output("box_deltas", of: head)

        // BBoxHead.get_bboxes with rescale, then multiclass_nms.
        var boxes: [AnimeFaceMath.Box] = []
        var scores: [Float] = []
        for (r, roi) in rois.enumerated() {
            let face = logits[row: r, column: 0], background = logits[row: r, column: 1]
            let top = max(face, background)
            let score = exp(face - top) / (exp(face - top) + exp(background - top))
            guard score > 0.05 else { continue }
            let decoded = AnimeFaceMath.decode(
                anchor: roi,
                deltas: (boxDeltas[row: r, column: 0], boxDeltas[row: r, column: 1],
                         boxDeltas[row: r, column: 2], boxDeltas[row: r, column: 3]),
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

        var input = InferenceTensor(zeros: [1, 3, 256, 256])
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        input.values.withUnsafeMutableBufferPointer { buffer in
            for c in 0..<3 {
                for y in 0..<256 {
                    for x in 0..<256 {
                        buffer[(c * 256 + y) * 256 + x] = (Float(crop[(y * 256 + x) * 3 + c]) / 255 - mean[c]) / std[c]
                    }
                }
            }
        }
        let output = try landmarkModel.run(["crop": input], outputs: ["heatmaps"])
        let heatmaps = try landmarkModel.output("heatmaps", of: output)
        let size = heatmaps.chw.width
        let unit = side / Float(size)
        return (0..<28).map { k in
            let map = Array(heatmaps.values[(k * size * size)..<((k + 1) * size * size)])
            let decoded = AnimeFaceMath.decodeHeatmap(map, size: size)
            // transform_preds
            return (decoded.x * unit + cx - side * 0.5, decoded.y * unit + cy - side * 0.5, decoded.score)
        }
    }
}
