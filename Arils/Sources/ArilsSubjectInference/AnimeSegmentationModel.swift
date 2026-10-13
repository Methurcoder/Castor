import CoreGraphics
import CoreML
import Foundation

/// Anime character segmentation (ISNet, `skytnt/anime-seg`, Apache 2.0)
/// running in-process on Core ML. Exported by
/// `Tools/AnimeSegmentationModel/export_coreml.py`.
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
    package static let inputSize = 1024
    static let modelDirectory = "AnimeSegmentationModel"

    private let model: MLModel
    private let lock = NSLock()

    static func modelURL(in bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: "AnimeSegmentation", withExtension: "mlmodelc", subdirectory: modelDirectory)
    }

    init(bundle: Bundle = .module) throws {
        guard let url = Self.modelURL(in: bundle) else { throw CocoaError(.fileNoSuchFile) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Where the source image sits inside the letterboxed square.
    package struct Letterbox: Equatable, Sendable {
        package var top: Int
        package var left: Int
        package var height: Int
        package var width: Int

        /// Upstream `inference.get_mask`: aspect fit to `size`, centred.
        package init(sourceWidth: Int, sourceHeight: Int, size: Int = AnimeSegmentationModel.inputSize) {
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

    /// Character probability (0...1) for every source pixel, row-major,
    /// `image.width * image.height` values.
    package func probability(for image: CGImage) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let size = Self.inputSize
        let box = Letterbox(sourceWidth: image.width, sourceHeight: image.height)
        guard let pixels = Self.rgbaPixels(of: image, width: box.width, height: box.height) else {
            throw CocoaError(.coderReadCorrupt)
        }

        let input = try MLMultiArray(shape: [1, 3, size, size].map { NSNumber(value: $0) }, dataType: .float32)
        let plane = size * size
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        pointer.initialize(repeating: 0, count: 3 * plane)
        for y in 0..<box.height {
            for x in 0..<box.width {
                let source = (y * box.width + x) * 4
                let target = (y + box.top) * size + (x + box.left)
                pointer[target] = Float(pixels[source]) / 255
                pointer[plane + target] = Float(pixels[source + 1]) / 255
                pointer[2 * plane + target] = Float(pixels[source + 2]) / 255
            }
        }

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let probability = output.featureValue(for: "probability")?.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }
        let values = Self.floats(probability)
        guard values.count == plane else { throw CocoaError(.coderReadCorrupt) }
        return Self.resizeCrop(values, size: size, box: box, toWidth: image.width, height: image.height)
    }

    // MARK: - Helpers

    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            return (0..<count).map { Float(pointer[$0]) }
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    /// Bilinear resize of the letterboxed crop back to the source size
    /// (cv2.resize's pixel-centre convention).
    static func resizeCrop(_ values: [Float], size: Int, box: Letterbox, toWidth width: Int, height: Int) -> [Float] {
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
