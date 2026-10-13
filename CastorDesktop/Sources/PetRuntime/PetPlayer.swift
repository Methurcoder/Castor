import ArilsCore
import ArilsMotion
import ArilsPlayer
import Foundation
#if canImport(simd)
import simd
#endif

/// Plays an Arils avatar without any platform UI: motion, deformation and a
/// CPU rasterizer into a premultiplied BGRA canvas. The platform shell owns
/// the window and only feeds pointer positions and blits the canvas.
///
/// Deformation and projection are the ones the macOS Metal renderer uses
/// (`DeformationEvaluator3D`, `RenderProjectionContract`), so a pet moves
/// the same way on every platform. Parts are drawn back to front by
/// `zOrder`; there is no depth test, which matches 2D rigs exactly and is a
/// close approximation for depth rigs at the supported head angles.
public final class PetPlayer {
    public let rig: AvatarRig
    private let controller: MotionController
    private let evaluator: DeformationEvaluator3D
    private let projection: RenderProjectionContract
    private var textures: [String: PetTexture] = [:]
    private let drawOrder: [AvatarPart]
    private let headRect: CGRect
    private var accumulation: [Float] = []
    private var textureScaleBucket = 0

    // Pointer state for gaze and petting.
    private var lastPointer: SIMD2<Float>?
    private var lastPointerTime: Double?
    private var pettingVelocity = SIMD2<Float>(repeating: 0)
    private var pettingPosition: SIMD2<Float>?
    private var pettingUpdatedAt: Double = -.infinity
    private let pngs: [String: Data]

    /// Values that replace the motion output, e.g. a fixed head pose for
    /// checking how far a rig can turn.
    public var parameterOverrides: [ParameterID: Float] = [:]

    /// Matches the macOS app's "Wider head movement" beta.
    public static let wideHeadTurnGain: Float = 2

    /// `wideHeadMovement` lets the head turn about twice as far and the body
    /// follow (the macOS beta setting of the same name).
    public init(archive: AvatarArchive, wideHeadMovement: Bool = false) {
        let (rig, dropped) = archive.repairedRig()
        self.rig = rig
        pngs = archive.texturePNGs.filter { !dropped.contains($0.key) }
        var configuration = MotionController.Configuration()
        configuration.headTurnGain = wideHeadMovement ? Self.wideHeadTurnGain : 1
        configuration.swayChannels = rig.physics.channels.map {
            SwayChannelSettings(
                output: $0.output, frequency: $0.frequency, dampingRatio: $0.dampingRatio,
                headDrive: $0.headDrive, breeze: $0.breeze
            )
        }
        controller = MotionController(descriptors: rig.parameters, configuration: configuration)
        evaluator = DeformationEvaluator3D(rig: rig)
        projection = RenderProjectionContract(imageWidth: rig.imageWidth, imageHeight: rig.imageHeight)
        drawOrder = rig.partsInDrawOrder
        headRect = rig.firstPart(ofKind: .head)?.rect
            ?? CGRect(x: 0, y: 0, width: rig.imageWidth, height: rig.imageHeight / 3)
    }

    public var imageSize: SIMD2<Float> { SIMD2(Float(rig.imageWidth), Float(rig.imageHeight)) }

    /// Image → canvas placement: aspect-fit, centred horizontally, standing
    /// on the bottom edge.
    public func placement(canvasWidth: Int, canvasHeight: Int) -> (scale: Float, offset: SIMD2<Float>) {
        let scale = min(Float(canvasWidth) / imageSize.x, Float(canvasHeight) / imageSize.y)
        let offset = SIMD2((Float(canvasWidth) - imageSize.x * scale) / 2, Float(canvasHeight) - imageSize.y * scale)
        return (scale, offset)
    }

    // MARK: - Input

    /// Pointer in canvas pixels (top-left origin), or nil when unknown.
    /// Drives gaze; moving over the head counts as petting.
    public func pointerMoved(to canvasPoint: SIMD2<Float>?, canvasWidth: Int, canvasHeight: Int, time: Double) {
        guard let canvasPoint else {
            lastPointer = nil
            return
        }
        let (scale, offset) = placement(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let image = (canvasPoint - offset) / max(scale, 1e-6)
        if let lastPointer, let lastPointerTime, time > lastPointerTime {
            let velocity = (image - lastPointer) / Float(time - lastPointerTime)
            let petZone = headRect.insetBy(dx: -headRect.width * 0.15, dy: -headRect.height * 0.15)
            if petZone.contains(CGPoint(x: CGFloat(image.x), y: CGFloat(image.y))), simd_length(velocity) > 20 {
                let half = SIMD2(Float(headRect.width) / 2, Float(headRect.height) / 2)
                pettingPosition = simd_clamp(
                    SIMD2((image.x - Float(headRect.midX)) / half.x, (Float(headRect.midY) - image.y) / half.y),
                    SIMD2(-1, -1), SIMD2(1, 1)
                )
                pettingVelocity = SIMD2(velocity.x / half.x, -velocity.y / half.y)
                pettingUpdatedAt = time
            }
        }
        lastPointer = image
        lastPointerTime = time
    }

    private func inputs(at time: Double) -> MotionInputs {
        var inputs = MotionInputs()
        if let point = lastPointer {
            inputs.pointer = Self.gazeTarget(imagePoint: point, headRect: headRect, imageSize: imageSize)
        }
        let staleness = Float(max(0, time - pettingUpdatedAt))
        if let pettingPosition, staleness < 0.35 {
            inputs.petting = PettingInput(position: pettingPosition, velocity: pettingVelocity * exp(-staleness * 8))
        }
        return inputs
    }

    /// The macOS engine's mapping: each direction normalized by its own
    /// distance from the head centre to the image edge.
    static func gazeTarget(imagePoint point: SIMD2<Float>, headRect: CGRect, imageSize: SIMD2<Float>) -> SIMD2<Float> {
        let center = SIMD2(Float(headRect.midX), Float(headRect.midY))
        let xSpan = point.x < center.x ? center.x : imageSize.x - center.x
        let ySpan = point.y < center.y ? center.y : imageSize.y - center.y
        return simd_clamp(
            SIMD2((point.x - center.x) / max(1, xSpan), (center.y - point.y) / max(1, ySpan)),
            SIMD2(-1, -1), SIMD2(1, 1)
        )
    }

    // MARK: - Frame

    /// Advances motion to `time` (seconds, monotonic) and draws into `canvas`.
    /// `opacity` scales the whole pet (see-through mode).
    public func render(into canvas: inout PetCanvas, time: Double, opacity: Float = 1) {
        let (scale, offset) = placement(canvasWidth: canvas.width, canvasHeight: canvas.height)
        prepareTextures(scale: scale)
        var parameters = controller.update(at: time, inputs: inputs(at: time))
        parameters.merge(parameterOverrides) { _, override in override }
        let vertices = evaluator.evaluate(parameters: parameters)

        let count = canvas.width * canvas.height * 4
        if accumulation.count != count { accumulation = [Float](repeating: 0, count: count) }
        for i in accumulation.indices { accumulation[i] = 0 }

        for part in drawOrder {
            guard let texture = textures[part.id], let points = vertices[part.id] else { continue }
            let screen = points.map { vertex -> SIMD2<Float> in
                let p = projection.project(vertex)
                return SIMD2(p.x, p.y) * scale + offset
            }
            rasterize(part: part, screen: screen, texture: texture, opacity: part.opacity * opacity,
                      width: canvas.width, height: canvas.height)
        }

        for i in 0..<(canvas.width * canvas.height) {
            let a = min(1, max(0, accumulation[i * 4 + 3]))
            canvas.bgra[i * 4] = UInt8(min(1, max(0, accumulation[i * 4 + 2])) * 255 + 0.5)
            canvas.bgra[i * 4 + 1] = UInt8(min(1, max(0, accumulation[i * 4 + 1])) * 255 + 0.5)
            canvas.bgra[i * 4 + 2] = UInt8(min(1, max(0, accumulation[i * 4])) * 255 + 0.5)
            canvas.bgra[i * 4 + 3] = UInt8(a * 255 + 0.5)
        }
    }

    /// Decodes the PNGs once per display scale, reduced so a texel is about
    /// half a screen pixel (sharp, without shimmer).
    private func prepareTextures(scale: Float) {
        let factor = max(1, Int((0.5 / max(scale, 1e-3)).rounded(.down)))
        guard factor != textureScaleBucket || textures.isEmpty else { return }
        textureScaleBucket = factor
        textures = [:]
        for (id, png) in pngs {
            textures[id] = PetTexture(png: png)?.reduced(by: factor)
        }
    }

    private func rasterize(part: AvatarPart, screen: [SIMD2<Float>], texture: PetTexture, opacity: Float, width: Int, height: Int) {
        let mesh = part.mesh
        let tw = Float(texture.width), th = Float(texture.height)
        var t = 0
        while t + 2 < mesh.indices.count {
            let i0 = Int(mesh.indices[t]), i1 = Int(mesh.indices[t + 1]), i2 = Int(mesh.indices[t + 2])
            t += 3
            let p0 = screen[i0], p1 = screen[i1], p2 = screen[i2]
            let area = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y)
            guard abs(area) > 1e-6 else { continue }
            let minX = max(0, Int(min(p0.x, p1.x, p2.x).rounded(.down)))
            let maxX = min(width - 1, Int(max(p0.x, p1.x, p2.x).rounded(.up)))
            let minY = max(0, Int(min(p0.y, p1.y, p2.y).rounded(.down)))
            let maxY = min(height - 1, Int(max(p0.y, p1.y, p2.y).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            let uv0 = mesh.uvs[i0] * SIMD2(tw, th), uv1 = mesh.uvs[i1] * SIMD2(tw, th), uv2 = mesh.uvs[i2] * SIMD2(tw, th)
            let inverseArea = 1 / area
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let px = Float(x) + 0.5
                    let w1 = ((px - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (py - p0.y)) * inverseArea
                    let w2 = ((p1.x - p0.x) * (py - p0.y) - (px - p0.x) * (p1.y - p0.y)) * inverseArea
                    let w0 = 1 - w1 - w2
                    guard w0 >= -1e-4, w1 >= -1e-4, w2 >= -1e-4 else { continue }
                    let uv = uv0 * w0 + uv1 * w1 + uv2 * w2
                    let color = texture.sample(uv.x - 0.5, uv.y - 0.5) * opacity
                    guard color.w > 0.0005 else { continue }
                    let o = (y * width + x) * 4
                    let keep = 1 - color.w
                    accumulation[o] = color.x + accumulation[o] * keep
                    accumulation[o + 1] = color.y + accumulation[o + 1] * keep
                    accumulation[o + 2] = color.z + accumulation[o + 2] * keep
                    accumulation[o + 3] = color.w + accumulation[o + 3] * keep
                }
            }
        }
    }
}
