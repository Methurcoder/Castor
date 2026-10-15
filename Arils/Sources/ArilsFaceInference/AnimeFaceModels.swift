import CoreGraphics
import Foundation
@_exported import ArilsInference

/// The anime face detector (Faster R-CNN R50-FPN) and 28-point landmark model
/// (HRNetV2-W18) from hysts/anime-face-detector, MIT, running in-process on
/// Core ML. Exported by `Tools/AnimeFaceModels/export_coreml.py`; the steps
/// between the networks are the shared `AnimeFacePipeline`, which Windows
/// runs on ONNX Runtime with the same contract.
///
/// `shared` is nil when the compiled models are not in the bundle (they are
/// generated, not checked in), and every caller treats that as "no estimate",
/// so Arils works exactly as before without them.
package final class AnimeFaceModels: @unchecked Sendable {
    package static let shared: AnimeFaceModels? = try? AnimeFaceModels()

    package typealias Face = AnimeFace

    private let pipeline: AnimeFacePipeline

    static let modelDirectory = "AnimeFaceModels"

    static func modelURL(_ name: String, in bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: name, withExtension: "mlmodelc", subdirectory: modelDirectory)
    }

    init(bundle: Bundle = .module) throws {
        func load(_ name: String) throws -> CoreMLInferenceModel {
            guard let url = Self.modelURL(name, in: bundle) else { throw CocoaError(.fileNoSuchFile) }
            return try CoreMLInferenceModel(contentsOf: url)
        }
        pipeline = AnimeFacePipeline(
            features: try load("AnimeFaceFeatures"),
            boxHead: try load("AnimeFaceBoxHead"),
            landmarks: try load("AnimeFaceLandmarks")
        )
    }

    /// The highest-scoring face with its landmarks, or nil.
    package func detect(_ image: CGImage) throws -> Face? {
        guard let rgb = Self.rgbPixels(of: image) else { return nil }
        return try pipeline.detect(rgb: rgb, width: image.width, height: image.height)
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
