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
/// the same way on every platform. Depth rigs use the same opaque/feather passes and depth bias as Metal.
/// Flat rigs retain their painter-order blend.
public final class PetPlayer {
    public let rig: AvatarRig
    private let controller: MotionController
    private let evaluator: DeformationEvaluator3D
    private let projection: RenderProjectionContract
    private var textures: [String: PetTexture] = [:]
    private let drawOrder: [AvatarPart]
    private let headRect: CGRect
    private var accumulation: [Float] = []
    private var depthBuffer: [Float] = []
    private let usesDepth: Bool

    /// A registered image frame, in canvas coordinates. nil retains legacy bottom alignment.
    public var imageFrame: CGRect?
    public var viewAngleXOverride: Float?
    public var viewAngleYOverride: Float?
    public let poseLimits: ValidatedPoseLimits
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
        usesDepth = rig.parts.contains { $0.mesh.depths.contains { abs($0) > 0.0001 } }
        poseLimits = wideHeadMovement ? rig.validatedPoseLimits.scaled(by: 1.5) : rig.validatedPoseLimits
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
        if let frame = imageFrame {
            return (Float(frame.width) / imageSize.x, SIMD2(Float(frame.minX), Float(frame.minY)))
        }
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
            lastPointerTime = nil
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

    public var currentGazeTarget: SIMD2<Float>? {
        lastPointer.map { Self.gazeTarget(imagePoint: $0, headRect: headRect, imageSize: imageSize) }
    }

    private func inputs(at time: Double) -> MotionInputs {
        var inputs = MotionInputs()
        if let point = lastPointer {
            inputs.pointer = Self.gazeTarget(imagePoint: point, headRect: headRect, imageSize: imageSize)
        }
        if let pitch = viewAngleYOverride, pitch.isFinite { inputs.headPitch = poseLimits.clampedPitch(pitch) }
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
        if let yaw = viewAngleXOverride, yaw.isFinite { parameters[.angleX] = poseLimits.clampedYaw(yaw) }
        parameters.merge(parameterOverrides) { _, override in override }
        let vertices = evaluator.evaluate(parameters: parameters)

        let count = canvas.width * canvas.height * 4
        if accumulation.count != count { accumulation = [Float](repeating: 0, count: count) }
        for i in accumulation.indices { accumulation[i] = 0 }

        if depthBuffer.count != canvas.width * canvas.height {
            depthBuffer = [Float](repeating: 1, count: canvas.width * canvas.height)
        }
        for i in depthBuffer.indices { depthBuffer[i] = 1 }
        let passes: [RasterPass] = usesDepth ? [.opaque, .feather] : [.flat]
        // Project once; the opaque and feather passes use exactly the same vertices.
        let drawableParts = drawOrder.filter { textures[$0.id] != nil }
        let projected: [String: [SIMD3<Float>]] = Dictionary(drawableParts.enumerated().compactMap { index, part in
            guard let points = vertices[part.id] else { return nil }
            return (part.id, points.map { vertex in
                let p = projection.project(vertex, zBias: projection.zBias(forDrawOrderIndex: index))
                let xy = SIMD2(p.x, p.y) * scale + offset
                return SIMD3(xy.x, xy.y, p.z)
            })
        }, uniquingKeysWith: { first, _ in first })
        for pass in passes {
            for part in drawableParts {
                guard let texture = textures[part.id], let screen = projected[part.id] else { continue }
                rasterize(part: part, screen: screen, texture: texture, opacity: part.opacity,
                          width: canvas.width, height: canvas.height, pass: pass)
            }
        }
        // Whole-view opacity is applied AFTER depth/alpha classification, as
        // NSView alpha / Windows click-through fades the complete pet.
        let opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1

        for i in 0..<(canvas.width * canvas.height) {
            let a = min(1, max(0, accumulation[i * 4 + 3] * opacity))
            canvas.bgra[i * 4] = UInt8(min(1, max(0, accumulation[i * 4 + 2] * opacity)) * 255 + 0.5)
            canvas.bgra[i * 4 + 1] = UInt8(min(1, max(0, accumulation[i * 4 + 1] * opacity)) * 255 + 0.5)
            canvas.bgra[i * 4 + 2] = UInt8(min(1, max(0, accumulation[i * 4] * opacity)) * 255 + 0.5)
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

    private enum RasterPass { case flat, opaque, feather }

    private func rasterize(part: AvatarPart, screen: [SIMD3<Float>], texture: PetTexture, opacity: Float,
                           width: Int, height: Int, pass: RasterPass) {
        let mesh = part.mesh
        let textureSize = SIMD2(Float(texture.width), Float(texture.height))
        func edge(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ p: SIMD3<Float>) -> Float {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        // Top-left fill rule: a shared mesh edge belongs to one triangle only.
        // Drawing it twice would darken translucent pixels along every diagonal.
        func covered(_ e: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            e > 1e-6 || (abs(e) <= 1e-6 && (b.y < a.y || (b.y == a.y && b.x > a.x)))
        }
        var t = 0
        while t + 2 < mesh.indices.count {
            let i0 = Int(mesh.indices[t]); var i1 = Int(mesh.indices[t + 1]); var i2 = Int(mesh.indices[t + 2])
            t += 3
            guard [i0, i1, i2].allSatisfy({ $0 < screen.count && $0 < mesh.uvs.count }) else { continue }
            let p0 = screen[i0]; var p1 = screen[i1]; var p2 = screen[i2]
            var area = edge(p0, p1, p2)
            guard [p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, p2.x, p2.y, p2.z].allSatisfy(\.isFinite), abs(area) > 1e-6 else { continue }
            if area < 0 { swap(&i1, &i2); swap(&p1, &p2); area = -area }
            // Clamp floating bounds before Int conversion, including offscreen profiles.
            let minX = Int(max(0, min(Float(width), min(p0.x, p1.x, p2.x).rounded(.down))))
            let maxX = Int(max(-1, min(Float(width - 1), max(p0.x, p1.x, p2.x).rounded(.up))))
            let minY = Int(max(0, min(Float(height), min(p0.y, p1.y, p2.y).rounded(.down))))
            let maxY = Int(max(-1, min(Float(height - 1), max(p0.y, p1.y, p2.y).rounded(.up))))
            guard minX <= maxX, minY <= maxY else { continue }
            let uv0 = mesh.uvs[i0] * textureSize, uv1 = mesh.uvs[i1] * textureSize, uv2 = mesh.uvs[i2] * textureSize
            for y in minY...maxY { for x in minX...maxX {
                let point = SIMD3(Float(x) + 0.5, Float(y) + 0.5, 0)
                let e0 = edge(p1, p2, point), e1 = edge(p2, p0, point), e2 = edge(p0, p1, point)
                guard covered(e0, p1, p2), covered(e1, p2, p0), covered(e2, p0, p1) else { continue }
                let w0 = e0 / area, w1 = e1 / area, w2 = e2 / area
                let uv = uv0 * w0 + uv1 * w1 + uv2 * w2
                let color = texture.sample(uv.x - 0.5, uv.y - 0.5) * opacity
                switch pass {
                case .flat: guard color.w > 0 else { continue }
                case .opaque: guard color.w >= RenderProjectionContract.opaqueAlphaThreshold else { continue }
                case .feather:
                    guard color.w > RenderProjectionContract.minimumVisibleAlpha,
                          color.w < RenderProjectionContract.opaqueAlphaThreshold else { continue }
                }
                let index = y * width + x
                if pass != .flat {
                    let depth = p0.z * w0 + p1.z * w1 + p2.z * w2
                    guard depth <= depthBuffer[index] else { continue }
                    if pass == .opaque { depthBuffer[index] = depth }
                }
                let o = index * 4, keep = 1 - color.w
                accumulation[o] = color.x + accumulation[o] * keep
                accumulation[o + 1] = color.y + accumulation[o + 1] * keep
                accumulation[o + 2] = color.z + accumulation[o + 2] * keep
                accumulation[o + 3] = color.w + accumulation[o + 3] * keep
            }}
        }
    }
}
