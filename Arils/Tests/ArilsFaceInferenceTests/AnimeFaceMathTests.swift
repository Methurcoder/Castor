import Foundation
import Testing

@testable import ArilsInference

// Expected values come from the implementations being ported:
// torchvision.ops.roi_align, mmpose keypoints_from_heatmaps('unbiased'),
// and cv2.resize(INTER_LINEAR). See Tools/AnimeFaceModels/export_coreml.py.

@Test func anchorsMatchMMDetForTheFirstLevel() {
    let anchors = AnimeFaceMath.baseAnchors(stride: 4)
    // ratios 0.5, 1, 2 with scale 8 on base size 4
    #expect(anchors[1] == AnimeFaceMath.Box(x1: -16, y1: -16, x2: 16, y2: 16))
    #expect(abs(anchors[0].width - 32 * 2.0.squareRoot().float) < 1e-3)
    #expect(abs(anchors[0].height - 32 / 2.0.squareRoot().float) < 1e-3)
}

@Test func nmsKeepsTheBestOfEachOverlappingCluster() {
    let boxes = [
        AnimeFaceMath.Box(x1: 0, y1: 0, x2: 10, y2: 10),
        AnimeFaceMath.Box(x1: 1, y1: 1, x2: 11, y2: 11),   // IoU 0.68 with the first
        AnimeFaceMath.Box(x1: 20, y1: 20, x2: 30, y2: 30),
    ]
    #expect(AnimeFaceMath.nms(boxes: boxes, scores: [0.6, 0.9, 0.5], threshold: 0.5) == [1, 2])
    #expect(AnimeFaceMath.nms(boxes: boxes, scores: [0.6, 0.9, 0.5], threshold: 0.7) == [1, 0, 2])
}

@Test func roiAlignMatchesTorchvisionAligned() {
    let height = 10, width = 12
    var plane = [Float](repeating: 0, count: height * width)
    for y in 0..<height {
        for x in 0..<width {
            plane[y * width + x] = Float(y * 12 + x) + 0.1 * pow(Float(x * y), 1.3)
        }
    }
    let cases: [([Float], [Float])] = [
        ([3.0, 5.0, 30.0, 22.0], [13.45395, 16.84514, 40.24367, 62.74035, 71.4446]),
        ([0.0, 0.0, 47.0, 39.0], [3.65766, 8.88574, 63.96483, 123.55981, 147.33026]),
        ([10.5, 2.25, 18.0, 35.5], [10.32455, 11.21899, 56.48205, 89.74389, 105.61356]),
    ]
    for (box, expected) in cases {
        let bins = AnimeFaceMath.roiAlignTaps(
            box: .init(x1: box[0], y1: box[1], x2: box[2], y2: box[3]),
            spatialScale: 0.25, height: height, width: width
        )
        let values = bins.map { taps in taps.reduce(Float(0)) { $0 + plane[$1.offset] * $1.weight } }
        for (bin, value) in zip([0, 3, 24, 41, 48], expected) {
            #expect(abs(values[bin] - value) < 1e-3, "bin \(bin) of \(box)")
        }
    }
}

@Test func heatmapDecodingMatchesMMPoseUnbiased() {
    let size = 64
    var heatmap = [Float](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            let dx = Double(x) - 20.3, dy = Double(y) - 33.7
            var v = exp(-(dx * dx + dy * dy) / 8) * 0.83
            let ex = Double(x - 45), ey = Double(y - 10)
            v += 0.02 * exp(-(ex * ex + ey * ey) / 30)
            heatmap[y * size + x] = Float(v)
        }
    }
    let decoded = AnimeFaceMath.decodeHeatmap(heatmap, size: size)
    #expect(abs(decoded.x - 20.299843) < 1e-3)
    #expect(abs(decoded.y - 33.700157) < 1e-3)
    #expect(abs(decoded.score - 0.8115335) < 1e-4)
}

@Test func resizeMatchesOpenCVLinearWithinRounding() {
    let source: [UInt8] = [139, 74, 229, 241, 169, 65, 6, 160, 149, 106, 38, 175, 188, 205, 175, 229, 98, 249, 10, 148, 95, 86, 147, 198, 66, 39, 106, 213, 171, 45, 167, 57, 69, 81, 55, 14, 153, 178, 215, 76, 52, 39, 250, 72, 215, 50, 161, 223, 112, 172, 161, 233, 38, 17, 89, 1, 221, 6, 242, 127, 143, 6, 60, 210, 94, 25, 166, 33, 249, 189, 12, 204, 33, 57, 124, 30, 199, 149, 202, 119, 72, 220, 3, 209, 122, 136, 147, 77, 133, 82, 115, 87, 162, 230, 70, 71, 240, 62, 47, 184, 31, 34, 63, 65, 146, 197, 142, 253, 81, 133, 240, 113, 30, 247, 103, 122, 31, 19, 42, 129, 141, 136, 33, 149, 161, 0, 178, 141, 107, 35, 107, 130, 72, 27, 217, 254, 99, 13, 195, 206, 59, 228, 235, 202, 183, 47, 69, 179, 82, 35, 71, 159, 110, 121, 77, 87, 3, 126, 44, 253, 233, 225, 90, 119, 137, 120, 30, 55, 33, 165, 87, 216, 229, 167, 3, 41, 109, 203, 129, 219, 63, 101, 207, 156, 27, 220, 93, 29, 143, 200, 63, 11, 11, 180, 219, 113, 190, 87, 34, 9, 133, 29, 61, 36, 244, 192, 207, 131, 254, 67, 99, 248, 47, 71, 89, 119, 137, 85, 246, 206, 214, 129, 203, 234, 113, 121, 206, 210, 200, 248, 20, 161, 52, 114, 255, 112, 206, 54, 157, 131, 133, 69, 42, 68, 243, 24, 51, 127, 8, 205, 30, 97, 79, 35, 93, 63, 131, 188, 69, 254, 233, 238, 4, 3, 167, 155, 225, 24, 84, 68, 65, 49, 124, 147, 17, 248, 94, 4, 41, 177, 159, 126, 192, 225, 86, 246, 90, 51, 34, 231, 145, 184, 128, 238, 153, 94, 63, 13, 48, 125, 47, 186, 244, 0, 105, 58, 23, 158, 13, 2, 126, 212, 229, 139, 231, 169, 235, 194, 138, 39, 29, 67, 167, 136, 85, 99, 129, 68, 235, 102, 3, 247, 178, 114, 93, 225, 31, 230, 172, 47, 136, 166, 129, 130, 134, 151, 147, 240, 170, 214, 222]
    let expected: [UInt8] = [170, 93, 141, 48, 140, 175, 201, 127, 130, 8, 185, 108, 121, 65, 84, 181, 61, 124, 86, 130, 133, 182, 72, 122, 118, 139, 109, 113, 87, 148, 243, 69, 40, 109, 94, 140, 128, 123, 204, 106, 89, 118, 110, 172, 122, 99, 94, 114, 59, 174, 99, 3, 41, 109, 83, 105, 209, 111, 28, 165, 92, 130, 130, 151, 128, 160, 109, 114, 46, 84, 141, 30, 77, 46, 98, 93, 228, 210, 179, 132, 166, 73, 79, 95, 172, 113, 193, 143, 116, 82, 135, 115, 101, 75, 200, 202, 39, 148, 154, 69, 130, 131, 102, 167, 189]
    let resized = AnimeFaceMath.resize(rgb: source, width: 13, height: 9, toWidth: 7, toHeight: 5)
    // cv2 uses 11-bit fixed-point weights, so a channel may round one step apart.
    #expect(zip(resized, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
}

private extension Double {
    var float: Float { Float(self) }
}
