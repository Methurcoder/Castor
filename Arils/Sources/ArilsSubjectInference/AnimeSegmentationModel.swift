import CoreGraphics
import Foundation
@_exported import ArilsInference

/// Anime character segmentation (ISNet, `skytnt/anime-seg`, Apache 2.0)
/// running in-process on Core ML. Exported by
/// `Tools/AnimeSegmentationModel/export_coreml.py`; letterboxing and the
/// resize back are the shared `AnimeSegmentationPipeline`, which Windows
/// runs on ONNX Runtime with the same contract.
///
/// It learned what an illustrated character looks like, so unlike Vision's
/// person/object blob it separates individual hair strands and follows the
/// drawing's outline. It also tends to keep props and scenery that are drawn
/// in the same style, which is why `ArilsRig` fuses it with Vision's region
/// instead of using it alone.
///
/// `shared` is nil when the compiled model is not in the bundle (it is
/// generated, not checked in); callers then keep their non-ML path.
package final class AnimeSegmentationModel: @unchecked Sendable {
    package static let shared: AnimeSegmentationModel? = try? AnimeSegmentationModel()

    /// Network input side; images are letterboxed into this square.
    package static let inputSize = AnimeSegmentationPipeline.inputSize
    static let modelDirectory = "AnimeSegmentationModel"

    package typealias Letterbox = AnimeSegmentationLetterbox

    private let pipeline: AnimeSegmentationPipeline

    static func modelURL(in bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: "AnimeSegmentation", withExtension: "mlmodelc", subdirectory: modelDirectory)
    }

    init(bundle: Bundle = .module) throws {
        guard let url = Self.modelURL(in: bundle) else { throw CocoaError(.fileNoSuchFile) }
        pipeline = AnimeSegmentationPipeline(model: try CoreMLInferenceModel(contentsOf: url))
    }

    /// Character probability (0...1) for every source pixel, row-major,
    /// `image.width * image.height` values.
    package func probability(for image: CGImage) throws -> [Float] {
        let box = Letterbox(sourceWidth: image.width, sourceHeight: image.height)
        guard let pixels = Self.rgbaPixels(of: image, width: box.width, height: box.height) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try pipeline.probability(letterboxed: pixels, box: box, sourceWidth: image.width, sourceHeight: image.height)
    }

    /// Bilinear resize of the letterboxed crop back to the source size.
    static func resizeCrop(_ values: [Float], size: Int, box: Letterbox, toWidth width: Int, height: Int) -> [Float] {
        AnimeSegmentationPipeline.resizeCrop(values, size: size, box: box, toWidth: width, height: height)
    }

    /// RGBA8 pixels of `image` drawn at `width`×`height` (high-quality
    /// downsampling, like PIL's antialiased bilinear in the export parity).
    static func rgbaPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
