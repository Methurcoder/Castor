import CoreGraphics
import Metal
import ArilsRender
import ArilsRig

/// A fresh animation engine and offscreen Metal renderers for exporting avatar frames.
/// Quality uses its usual supported side direction, presentation and neck registration.
@MainActor
public final class AvatarImageExporter {
    private let front: CharacterEngine
    private let quality: QualityCharacterEngine?
    private let frontRenderer: MetalAvatarRenderer
    private let sideRenderer: MetalAvatarRenderer?

    private static var configuration: CharacterEngine.Configuration {
        .init(preferredFramesPerSecond: 20, sneezeInterval: .infinity, microActionsEnabled: false)
    }

    public init(archive: AvatarArchive) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalAvatarRenderer.RendererError.deviceUnavailable
        }
        front = CharacterEngine(avatar: try archive.makeAvatar(), configuration: Self.configuration)
        quality = nil
        sideRenderer = nil
        frontRenderer = try MetalAvatarRenderer(device: device, avatar: front.avatar, colorPixelFormat: .bgra8Unorm)
    }

    public init(qualityArchive: QualityAvatarArchive) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalAvatarRenderer.RendererError.deviceUnavailable
        }
        let engine = try QualityCharacterEngine(archive: qualityArchive, configuration: Self.configuration)
        engine.automaticTurn = false
        quality = engine
        front = engine.front
        frontRenderer = try MetalAvatarRenderer(device: device, avatar: engine.front.avatar, colorPixelFormat: .bgra8Unorm)
        sideRenderer = try MetalAvatarRenderer(device: device, avatar: engine.side.avatar, colorPixelFormat: .bgra8Unorm)
    }

    public func image(at time: Double, size: CGSize, gaze: SIMD2<Float>? = nil,
                      viewTurn: Float = 0) throws -> CGImage {
        front.externalGazeTarget = gaze
        quality?.externalGazeTarget = gaze
        quality?.viewTurn = viewTurn
        let frontParameters = front.parameters(at: time)
        // Advance both clocks even while one view is transparent, keeping blinks/motion in step.
        let sideParameters = quality?.side.parameters(at: time)
        let image = try frontRenderer.renderImage(parameters: frontParameters, size: size)
        guard let quality, let sideRenderer, quality.sideBlend > 0 else { return image }
        let bounds = CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height))
        let sideFrame = QualityRegistrationLayout.sideFrame(bounds: bounds,
            frontImageSize: CGSize(width: front.avatar.rig.imageWidth, height: front.avatar.rig.imageHeight),
            sideImageSize: CGSize(width: quality.side.avatar.rig.imageWidth, height: quality.side.avatar.rig.imageHeight),
            registration: quality.archive.registration)
        let side = try sideRenderer.renderImage(parameters: sideParameters ?? [:], size: sideFrame.size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MetalAvatarRenderer.RendererError.imageExportFailed
        }
        context.setAlpha(CGFloat(1 - quality.sideBlend))
        context.draw(image, in: bounds)
        context.setAlpha(CGFloat(quality.sideBlend))
        // Registration coordinates use a top-left origin; CGContext uses bottom-left.
        context.draw(side, in: CGRect(x: sideFrame.minX, y: bounds.height - sideFrame.maxY,
                                     width: sideFrame.width, height: sideFrame.height))
        guard let result = context.makeImage() else { throw MetalAvatarRenderer.RendererError.imageExportFailed }
        return result
    }
}
