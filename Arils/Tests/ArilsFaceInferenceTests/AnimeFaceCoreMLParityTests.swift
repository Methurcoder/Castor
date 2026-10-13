import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ArilsFaceInference

/// Compares the in-process Core ML pipeline with the Python package it was
/// ported from, image by image. The images and the reference live outside Git,
/// so this runs only when both are named:
///
///     python3 Tools/AnimeFaceModels/export_coreml.py --skip-export --reference <images>
///     ARILS_ANIME_FACE_REFERENCE=Tools/AnimeFaceModels/build/reference.json \
///     ARILS_ANIME_FACE_IMAGES=<image folder> \
///     swift test -c release -Xswiftc -enable-testing --filter AnimeFaceCoreMLParity
@Test func animeFaceCoreMLParityWithThePythonPackage() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let referencePath = environment["ARILS_ANIME_FACE_REFERENCE"],
          let imageFolder = environment["ARILS_ANIME_FACE_IMAGES"],
          let models = AnimeFaceModels.shared else { return }

    struct Record: Decodable {
        struct Face: Decodable { var bbox: [Float]; var score: Float; var keypoints: [[Float]] }
        var image: String
        var faces: [Face]
    }
    let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
    var keypointErrors: [Float] = []
    var boxIoUs: [Float] = []
    var scoreErrors: [Float] = []
    var seconds: [Double] = []
    var missing: [String] = []

    for record in records {
        guard let expected = record.faces.first else { continue }
        let url = URL(fileURLWithPath: imageFolder).appendingPathComponent(record.image)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
        let started = Date()
        let face = try models.detect(image)
        seconds.append(Date().timeIntervalSince(started))
        guard let face else { missing.append(record.image); continue }

        let reference = AnimeFaceMath.Box(x1: expected.bbox[0], y1: expected.bbox[1], x2: expected.bbox[2], y2: expected.bbox[3])
        boxIoUs.append(AnimeFaceMath.iou(face.box, reference))
        scoreErrors.append(abs(face.score - expected.score))
        // In units of the face box, so big and small faces weigh the same.
        let scale = max(reference.width, reference.height)
        for (point, ref) in zip(face.keypoints, expected.keypoints) {
            keypointErrors.append(hypot(point.x - ref[0], point.y - ref[1]) / scale)
        }
    }

    func mean(_ values: [Float]) -> Float { values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count) }
    let sorted = keypointErrors.sorted()
    let p95 = sorted.isEmpty ? 0 : sorted[Int(Float(sorted.count - 1) * 0.95)]
    print(String(
        format: "[parity] %d images  box IoU mean %.4f min %.4f  score err max %.4f  keypoint err (face-box units) mean %.4f p95 %.4f max %.4f  time mean %.2fs",
        boxIoUs.count, mean(boxIoUs), boxIoUs.min() ?? 0, scoreErrors.max() ?? 0,
        mean(keypointErrors), p95, sorted.last ?? 0, seconds.reduce(0, +) / Double(max(seconds.count, 1))
    ))
    #expect(missing.isEmpty, "no face where Python found one: \(missing)")
    #expect(mean(boxIoUs) > 0.97)
    #expect(mean(keypointErrors) < 0.01)
}
