import CoreGraphics
import CoreVideo
import Foundation
import simd
import Vision
import ArilsSubjectInference

public struct VisionSubjectMaskProvider: SubjectMaskProviding {
    public let isAuthoritativeAlpha = false
    public var refinesBoundary: Bool
    public var usesCharacterSegmentation: Bool

    public init(refinesBoundary: Bool = true, usesCharacterSegmentation: Bool = true) {
        self.refinesBoundary = refinesBoundary
        self.usesCharacterSegmentation = usesCharacterSegmentation
    }

    public func mask(for context: AnalysisContext) async -> FloatPlane? {
        await masks(for: context)?.analysis
    }

    public func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        let characterModel = usesCharacterSegmentation
            ? Self.characterProbability(for: context.originalImage)
            : nil
        guard let extraction = Self.visionMask(for: context) else {
            // Vision found no foreground: trust the character model alone,
            // if it found a character.
            guard let model = characterModel, let alone = SubjectMaskFusion.modelOnly(model) else {
                return nil
            }
            return SubjectMaskSet(
                analysis: alone.resized(width: context.analysis.width, height: context.analysis.height),
                extraction: alone
            )
        }
        let analysis = extraction.resized(
            width: context.analysis.width,
            height: context.analysis.height
        )
        if let model = characterModel,
           let fused = SubjectMaskFusion.fuse(vision: extraction, model: model) {
            return SubjectMaskSet(analysis: analysis, extraction: fused.mask)
        }
        guard refinesBoundary,
              let original = context.originalBitmap ?? Bitmap(image: context.originalImage),
              original.width == extraction.width,
              original.height == extraction.height else {
            return SubjectMaskSet(analysis: analysis, extraction: extraction)
        }
        let refined = SubjectMaskBoundaryRefinement.refine(extraction, image: original)
        return SubjectMaskSet(analysis: analysis, extraction: refined.mask)
    }

    /// The anime segmentation model's probability at source resolution, or
    /// nil when the model is not bundled.
    static func characterProbability(for image: CGImage) -> FloatPlane? {
        guard let model = AnimeSegmentationModel.shared,
              let values = try? model.probability(for: image),
              values.count == image.width * image.height else { return nil }
        return FloatPlane(width: image.width, height: image.height, values: values)
    }

    /// Vision's foreground mask at source resolution, or nil.
    static func visionMask(for context: AnalysisContext) -> FloatPlane? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: context.originalImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let pixelBuffer: CVPixelBuffer
        do {
            pixelBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } catch {
            return nil
        }
        return plane(
            from: pixelBuffer,
            targetWidth: context.originalImage.width,
            targetHeight: context.originalImage.height
        )
    }

    static func plane(from pixelBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> FloatPlane? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else { return nil }

        var plane = FloatPlane(width: targetWidth, height: targetHeight)
        for y in 0..<targetHeight {
            let sourceY = min(sourceHeight - 1, y * sourceHeight / targetHeight)
            for x in 0..<targetWidth {
                let sourceX = min(sourceWidth - 1, x * sourceWidth / targetWidth)
                let value: Float
                switch format {
                case kCVPixelFormatType_OneComponent32Float:
                    let row = base.advanced(by: sourceY * bytesPerRow)
                        .assumingMemoryBound(to: Float.self)
                    value = row[sourceX]
                default:
                    // Treat anything else as single-component 8-bit.
                    let row = base.advanced(by: sourceY * bytesPerRow)
                        .assumingMemoryBound(to: UInt8.self)
                    value = Float(row[sourceX]) / 255
                }
                plane[x, y] = min(max(value, 0), 1)
            }
        }
        return plane
    }
}
