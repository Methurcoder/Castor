import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared decoded pixels and analysis scale. The CGImage bridge only exists on Mac.
public struct AnalysisContext: @unchecked Sendable {
    public let originalBitmap: Bitmap?
    public let analysis: Bitmap
    public let scaleToOriginal: CGFloat
    public let imageWidth: Int
    public let imageHeight: Int
#if canImport(CoreGraphics)
    public let originalImage: CGImage
    public init(originalImage: CGImage, analysis: Bitmap, originalBitmap: Bitmap? = nil) {
        self.originalImage = originalImage; self.originalBitmap = originalBitmap; self.analysis = analysis
        imageWidth = originalImage.width; imageHeight = originalImage.height
        scaleToOriginal = analysis.width > 0 ? CGFloat(imageWidth) / CGFloat(analysis.width) : 1
    }
#endif
    public init?(bitmap: Bitmap, analysisMaxDimension: Int = 256) {
        guard bitmap.width > 0, bitmap.height > 0, analysisMaxDimension > 0 else { return nil }
        let analysis = bitmap.downscaled(maxDimension: analysisMaxDimension)
#if canImport(CoreGraphics)
        guard let image = bitmap.cgImage() else { return nil }
        self.init(originalImage: image, analysis: analysis, originalBitmap: bitmap)
#else
        self.originalBitmap = bitmap; self.analysis = analysis
        imageWidth = bitmap.width; imageHeight = bitmap.height
        scaleToOriginal = CGFloat(imageWidth) / CGFloat(max(1, analysis.width))
#endif
    }
    public var decodedOriginalBitmap: Bitmap? {
        if let originalBitmap { return originalBitmap }
#if canImport(CoreGraphics)
        return Bitmap(image: originalImage)
#else
        return nil
#endif
    }
}
