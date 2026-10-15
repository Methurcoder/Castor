import Foundation
import Testing
@testable import PetRuntime

/// The Windows face path (ONNX Runtime) against the Mac's Core ML results on
/// the same images. Models, runtime and reference live outside Git, so this
/// runs only when all are named:
///
///     CASTOR_ONNXRUNTIME=/path/libonnxruntime.dylib CASTOR_MODELS_DIR=/path/models \
///     CASTOR_ML_REFERENCE=/path/core-ml-faces.txt CASTOR_ML_IMAGES=/path/images \
///     swift test --filter PortableMLParity
///
/// Reference lines: `NAME box X1 Y1 X2 Y2 score S kp X,Y,S;…` (28 points).
@Test func portableFaceModelMatchesTheMacOnTheSameImages() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let referencePath = environment["CASTOR_ML_REFERENCE"],
          let imageFolder = environment["CASTOR_ML_IMAGES"],
          environment[PortableML.runtimeEnvironmentKey] != nil else { return }
    let pipeline = try #require(PortableML.face, "\(PortableML.unavailableReason ?? "")")
    var ious: [Float] = [], keypointErrors: [Float] = []
    for line in try String(contentsOfFile: referencePath, encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count >= 9, parts[1] == "box" else { continue }
        let expected = parts[2...5].compactMap { Float($0) }
        let expectedPoints = parts.last!.split(separator: ";").map { $0.split(separator: ",").compactMap { Float($0) } }
        let image = try PortableRigImage(png: Data(contentsOf: URL(fileURLWithPath: imageFolder).appendingPathComponent(String(parts[0]))))
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for i in 0..<(image.width * image.height) {
            let a = Float(image.rgba[i * 4 + 3]) / 255
            for c in 0..<3 { rgb[i * 3 + c] = UInt8(Float(image.rgba[i * 4 + c]) * a + 255 * (1 - a) + 0.5) }
        }
        let face = try #require(try pipeline.detect(rgb: rgb, width: image.width, height: image.height))
        let ix = max(0, min(face.box.x2, expected[2]) - max(face.box.x1, expected[0]))
        let iy = max(0, min(face.box.y2, expected[3]) - max(face.box.y1, expected[1]))
        let union = face.box.area + (expected[2] - expected[0]) * (expected[3] - expected[1]) - ix * iy
        ious.append(ix * iy / union)
        let size = max(face.box.width, face.box.height)
        for (point, reference) in zip(face.keypoints, expectedPoints) where reference.count >= 2 {
            keypointErrors.append(hypot(point.x - reference[0], point.y - reference[1]) / size)
        }
    }
    #expect(!ious.isEmpty)
    let meanIoU = ious.reduce(0, +) / Float(ious.count)
    let meanKeypointError = keypointErrors.reduce(0, +) / Float(max(1, keypointErrors.count))
    print("portable face vs Core ML: \(ious.count) images, mean IoU \(meanIoU), min IoU \(ious.min() ?? 0), mean keypoint error \(meanKeypointError) of the face size")
    #expect(ious.min() ?? 0 > 0.95)
    #expect(meanKeypointError < 0.02)
}
